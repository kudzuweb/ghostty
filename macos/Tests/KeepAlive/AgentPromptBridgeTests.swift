import Foundation
import Testing
@testable import Ghostty

struct AgentPromptBridgeTests {
    @Test func requestIdentityAndCancellation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let bridge = AgentPromptBridge(root: root)
        let capability = AgentPromptBridge.Capability(
            version: 1, sessionID: UUID().uuidString.lowercased(), processID: 123,
            incarnation: "birth-one", ready: true, updatedAt: Date().timeIntervalSince1970 * 1_000)
        let expiry = Date().addingTimeInterval(2)
        try bridge.authorize(capability: capability, generation: "one", expiresAt: expiry)
        let requestID = try bridge.submit(capability: capability, generation: "one", action: .continue,
                                          reason: "idle", expiresAt: expiry)
        let directory = root.appendingPathComponent(capability.sessionID).appendingPathComponent("123")
        let request = try #require(JSONSerialization.jsonObject(with: Data(contentsOf:
            directory.appendingPathComponent("request.json"))) as? [String: Any])
        #expect(request["requestID"] as? String == requestID.uuidString)
        #expect(request["incarnation"] as? String == capability.incarnation)
        #expect(request["generation"] as? String == "one")
        try bridge.cancel(capability: capability, generation: "two")
        let authorization = try #require(JSONSerialization.jsonObject(with: Data(contentsOf:
            directory.appendingPathComponent("authorization.json"))) as? [String: Any])
        #expect(authorization["enabled"] as? Bool == false)
        #expect(authorization["generation"] as? String == "two")
    }

    @Test func unresolvedClaimsCannotBeReplaced() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let bridge = AgentPromptBridge(root: root)
        let capability = AgentPromptBridge.Capability(
            version: 1, sessionID: UUID().uuidString.lowercased(), processID: 123,
            incarnation: "birth-one", ready: true, updatedAt: Date().timeIntervalSince1970 * 1_000)
        let expiry = Date().addingTimeInterval(2)
        let requestID = try bridge.submit(capability: capability, generation: "one", action: .continue,
                                          reason: "idle", expiresAt: expiry)
        let receipt = AgentPromptBridge.Receipt(
            version: 1, requestID: requestID, sessionID: capability.sessionID, processID: 123,
            incarnation: capability.incarnation, generation: "one", status: .claimed,
            updatedAt: 0, detail: nil)
        let file = root.appendingPathComponent(capability.sessionID).appendingPathComponent("123/receipt.json")
        try JSONEncoder().encode(receipt).write(to: file)
        #expect(throws: AgentPromptBridge.BridgeError.self) {
            try bridge.submit(capability: capability, generation: "two", action: .continue,
                              reason: "retry", expiresAt: expiry)
        }
    }

    @Test func sameSessionInDifferentProcessesHasSeparateMailboxes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let bridge = AgentPromptBridge(root: root)
        let sessionID = UUID().uuidString.lowercased()
        for processID: Int32 in [123, 124] {
            let capability = AgentPromptBridge.Capability(version: 1, sessionID: sessionID,
                processID: processID, incarnation: "birth-\(processID)", ready: true, updatedAt: 0)
            _ = try bridge.submit(capability: capability, generation: "one", action: .continue,
                                  reason: "idle", expiresAt: Date().addingTimeInterval(2))
        }
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(sessionID + "/123/request.json").path))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(sessionID + "/124/request.json").path))
    }
}
