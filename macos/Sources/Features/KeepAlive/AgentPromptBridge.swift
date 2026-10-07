import Foundation

/// Local native-engine mailbox. No terminal input is ever emitted by this adapter.
struct AgentPromptBridge {
    enum Action: String, Codable { case `continue`, wrapup }
    enum Status: String, Codable { case claimed, accepted, dropped, rejected }
    struct Capability: Codable, Equatable {
        let version: Int
        let sessionID: String
        let processID: Int32
        let incarnation: String
        let ready: Bool
        let updatedAt: Double
    }
    struct Receipt: Codable {
        let version: Int
        let requestID: UUID
        let sessionID: String
        let processID: Int32
        let incarnation: String
        let generation: String
        let status: Status
        let updatedAt: Double
        let detail: String?
    }
    private struct Authorization: Codable {
        var version = 1
        let sessionID: String
        let processID: Int32
        let incarnation: String
        let generation: String
        let enabled: Bool
        let expiresAt: Double
    }
    private struct Request: Codable {
        var version = 1
        let requestID: UUID
        let sessionID: String
        let processID: Int32
        let incarnation: String
        let generation: String
        let action: Action
        let reason: String
        let cutoffAt: Double?
        let expiresAt: Double
    }
    enum BridgeError: LocalizedError {
        case unavailable, stale, pending, invalidRequest
        var errorDescription: String? {
            switch self {
            case .unavailable: return "Keep alive native prompt bridge is unavailable for this Claude session."
            case .stale: return "Keep alive native prompt bridge registration is stale or belongs to another process."
            case .pending: return "Keep alive native prompt delivery is pending or uncertain; no duplicate was sent."
            case .invalidRequest: return "Keep alive native prompt request is invalid or expired."
            }
        }
    }
    let root: URL
    init(root: URL? = nil) {
        self.root = root ?? ProcessInfo.processInfo.environment["GHOSTTY_AGENT_BRIDGE_DIR"].map {
            URL(fileURLWithPath: $0, isDirectory: true)
        } ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/state/ghostty/agent-bridge")
    }
    private func directory(sessionID: String, processID: Int32) -> URL {
        root.appendingPathComponent(sessionID.lowercased()).appendingPathComponent(String(processID))
    }
    private func directory(_ capability: Capability) -> URL {
        directory(sessionID: capability.sessionID, processID: capability.processID)
    }
    private func read<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = attributes[.size] as? NSNumber, size.intValue <= 16_384 else {
            throw BridgeError.invalidRequest
        }
        return try JSONDecoder().decode(type, from: Data(contentsOf: url))
    }
    private func write<T: Encodable>(_ value: T, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(value).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    func capability(sessionID: UUID, processID: Int32, now: Date = Date()) throws -> Capability {
        let url = directory(sessionID: sessionID.uuidString, processID: processID).appendingPathComponent("capability.json")
        guard let capability = try? read(Capability.self, from: url) else { throw BridgeError.unavailable }
        let age = now.timeIntervalSince1970 * 1_000 - capability.updatedAt
        guard capability.version == 1, UUID(uuidString: capability.sessionID) == sessionID,
              capability.processID == processID, !capability.incarnation.isEmpty, age >= -1_000, age < 5_000 else {
            throw BridgeError.stale
        }
        // The caller must verify its captured process birth identity immediately before this
        // lookup and again before submission. No subprocess is run on the app's main actor.
        return capability
    }
    func authorize(capability: Capability, generation: String, expiresAt: Date) throws {
        guard !generation.isEmpty, expiresAt > Date() else { throw BridgeError.invalidRequest }
        try write(Authorization(sessionID: capability.sessionID, processID: capability.processID,
                                incarnation: capability.incarnation, generation: generation, enabled: true,
                                expiresAt: expiresAt.timeIntervalSince1970 * 1_000),
                  to: directory(capability).appendingPathComponent("authorization.json"))
    }
    func cancel(capability: Capability, generation: String) throws {
        try write(Authorization(sessionID: capability.sessionID, processID: capability.processID,
                                incarnation: capability.incarnation, generation: generation, enabled: false, expiresAt: 0),
                  to: directory(capability).appendingPathComponent("authorization.json"))
    }
    func submit(capability: Capability, generation: String, action: Action, reason: String,
                cutoffAt: Date? = nil, expiresAt: Date) throws -> UUID {
        let now = Date()
        guard reason.utf8.count <= 2_048, !generation.isEmpty, expiresAt > now,
              action == .wrapup || cutoffAt == nil || cutoffAt! > now else { throw BridgeError.invalidRequest }
        let requestURL = directory(capability).appendingPathComponent("request.json")
        if let previous = try? read(Request.self, from: requestURL) {
            let acknowledgment = try receipt(capability: capability, requestID: previous.requestID)
            if acknowledgment?.status == .claimed ||
                (acknowledgment == nil && previous.expiresAt > now.timeIntervalSince1970 * 1_000) {
                throw BridgeError.pending
            }
        }
        let requestID = UUID()
        try write(Request(requestID: requestID, sessionID: capability.sessionID, processID: capability.processID,
                          incarnation: capability.incarnation, generation: generation, action: action, reason: reason,
                          cutoffAt: cutoffAt.map { $0.timeIntervalSince1970 * 1_000 },
                          expiresAt: expiresAt.timeIntervalSince1970 * 1_000), to: requestURL)
        return requestID
    }
    func receipt(capability: Capability, requestID: UUID) throws -> Receipt? {
        let url = directory(capability).appendingPathComponent("receipt.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let receipt = try read(Receipt.self, from: url)
        guard receipt.version == 1, receipt.requestID == requestID,
              receipt.sessionID == capability.sessionID, receipt.processID == capability.processID,
              receipt.incarnation == capability.incarnation else { return nil }
        return receipt
    }
}
