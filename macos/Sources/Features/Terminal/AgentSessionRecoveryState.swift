import Foundation
import Darwin

struct AgentSessionBinding: Codable, Equatable {
    let tool: AgentTool
    let sessionID: UUID
    let sessionRoot: String
    let launchCWD: String?

    /// Nil preserves compatibility with archives that saved only the effective root.
    /// False means the original Claude process used its ordinary environment.
    let configurationRootWasExplicit: Bool?

    init(tool: AgentTool, sessionID: UUID, sessionRoot: String, launchCWD: String?,
         configurationRootWasExplicit: Bool? = nil) {
        self.tool = tool
        self.sessionID = sessionID
        self.sessionRoot = sessionRoot
        self.launchCWD = launchCWD
        self.configurationRootWasExplicit = configurationRootWasExplicit
    }

    var key: String { "\(tool.rawValue):\(sessionRoot):\(sessionID.uuidString.lowercased())" }

    var command: String {
        command(homeDirectory: FileManager.default.homeDirectoryForCurrentUser.path)
    }

    func command(homeDirectory: String) -> String {
        let rootKey = tool == .codex ? "CODEX_HOME" : "CLAUDE_CONFIG_DIR"
        let resume = tool.resumeCommand(sessionID: sessionID.uuidString.lowercased())
        let defaultClaudeRoot = URL(fileURLWithPath: homeDirectory).appendingPathComponent(".claude")
            .standardizedFileURL.resolvingSymlinksInPath().path
        let savedRoot = URL(fileURLWithPath: sessionRoot).standardizedFileURL.resolvingSymlinksInPath().path
        let implicitClaudeRoot = tool == .claude && (configurationRootWasExplicit == false
            || (configurationRootWasExplicit == nil && savedRoot == defaultClaudeRoot))
        // An explicit ~/.claude is not equivalent to an unset CLAUDE_CONFIG_DIR:
        // Claude can select different trust/configuration state before registration.
        let launch = implicitClaudeRoot
            ? "env -u CLAUDE_CONFIG_DIR \(resume)"
            : "env \(rootKey)=\(Self.quote(sessionRoot)) \(resume)"
        return launchCWD.map { "cd -- \(Self.quote($0)) && \(launch)" } ?? launch
    }

    static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Old archives are data migration, never permission to execute arbitrary shell text.
    static func legacy(_ command: String, cwd: String?, home: String) -> Self? {
        let words = command.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard words.count == 3, let id = UUID(uuidString: words[2]) else { return nil }
        let tool: AgentTool
        if words[0] == "claude", words[1] == "--resume" { tool = .claude } else if words[0] == "codex", words[1] == "resume" { tool = .codex } else { return nil }
        return .init(tool: tool, sessionID: id,
                     sessionRoot: home + (tool == .claude ? "/.claude" : "/.codex"), launchCWD: cwd)
    }
}

struct AgentSessionRecoveryMigration: Codable {
    let version: Int
    let surfaceIDs: [UUID]
}

struct AgentSessionRecoveryRecord: Codable, Equatable {
    enum Phase: String, Codable { case pending, launching, running, failed, stopped }
    var binding: AgentSessionBinding?
    var phase: Phase
    var reason: String?
    var updatedAt: Date = Date()

    var restored: Self {
        guard binding != nil, phase != .stopped else { return self }
        var result = self
        result.updatedAt = Date()
        result.phase = phase == .failed ? .failed : .pending
        result.reason = phase == .failed ? reason : "Waiting for the restored shell to be ready"
        return result
    }
}

struct AgentSessionProcessIdentity: Equatable {
    let pid: Int32
    let startSeconds: UInt64
    let startMicroseconds: UInt64
}

/// Selection is independent of enumeration order and never guesses when records disagree.
enum AgentSessionSelection {
    static func unique(_ candidates: [AgentSessionBinding]) -> Result<AgentSessionBinding?, Failure> {
        let distinct = Dictionary(grouping: candidates, by: \.key)
        guard distinct.count <= 1 else { return .failure(.ambiguous) }
        return .success(distinct.values.first?.first)
    }
    enum Failure: Error { case ambiguous }
}

struct AgentSessionCandidate {
    let identity: AgentSessionProcessIdentity
    let identityAfterRead: AgentSessionProcessIdentity
    let foregroundGroup: Int32
    let tty: String?
    let binding: AgentSessionBinding
}

enum AgentSessionCandidateResolver {
    enum Failure: Error { case staleProcess, ambiguous }
    static func resolve(
        group: Int32, tty: String?, candidates: [AgentSessionCandidate]
    ) -> Result<AgentSessionCandidate?, Failure> {
        let members = candidates.filter { $0.foregroundGroup == group && (tty == nil || $0.tty == nil || $0.tty == tty) }
        guard members.allSatisfy({ $0.identity == $0.identityAfterRead }) else { return .failure(.staleProcess) }
        let sessions = Dictionary(grouping: members, by: { $0.binding.key })
        guard sessions.count <= 1 else { return .failure(.ambiguous) }
        return .success(sessions.values.first?.first)
    }
}

/// KERN_PROCARGS2 contains argc, an executable path, padding, exactly argc argv
/// strings, then environment strings. Values appearing in argv are not environment.
enum AgentSessionProcessArguments {
    struct Parsed {
        let executable: String
        let arguments: [String]
        let environment: [String: String]
    }

    static func parse(_ data: Data) -> Parsed? {
        let bytes = [UInt8](data)
        guard bytes.count >= 4 else { return nil }
        let argc = data.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard argc > 0, argc <= 65536 else { return nil }
        var cursor = 4
        func string() -> String? {
            guard cursor < bytes.count, let end = bytes[cursor...].firstIndex(of: 0),
                  let value = String(bytes: bytes[cursor..<end], encoding: .utf8) else { return nil }
            cursor = end + 1
            return value
        }
        guard let executable = string(), !executable.isEmpty else { return nil }
        while cursor < bytes.count && bytes[cursor] == 0 { cursor += 1 }
        var arguments: [String] = []
        for _ in 0..<argc {
            guard let argument = string() else { return nil }
            arguments.append(argument)
        }
        var environment: [String: String] = [:]
        while cursor < bytes.count {
            if bytes[cursor] == 0 { cursor += 1; continue }
            guard let entry = string(), let separator = entry.firstIndex(of: "=") else { return nil }
            let key = String(entry[..<separator])
            if ["HOME", "CODEX_HOME", "CLAUDE_CONFIG_DIR"].contains(key) {
                environment[key] = String(entry[entry.index(after: separator)...])
            }
        }
        return .init(executable: executable, arguments: arguments, environment: environment)
    }
}

enum AgentSessionProcessClassifier {
    static func plausibleCodex(executable: String?, name: String, arguments: [String] = []) -> Bool {
        // The desktop UI does not own terminal CLI sessions; its child CLI does.
        if let executable, executable.contains(".app/Contents/MacOS/") { return false }
        let basename = executable.map { ($0 as NSString).lastPathComponent.lowercased() } ?? name.lowercased()
        if basename == "codex" || basename.hasPrefix("codex-") { return true }
        return ["node", "bun"].contains(basename) && arguments.dropFirst().contains {
            let file = ($0 as NSString).lastPathComponent.lowercased()
            return file == "codex" || file == "codex.js"
        }
    }

    /// Inaccessible unrelated applications are not evidence of an unseen agent.
    static func blocksOnUnavailableDescriptors(executable: String?, name: String, arguments: [String] = []) -> Bool {
        plausibleCodex(executable: executable, name: name, arguments: arguments)
    }
}

enum AgentSessionDescriptorInspection {
    static func missingVnodeCanBeIgnored(pathError: Int32, statError: Int32?, linkCount: UInt16?) -> Bool {
        guard pathError == ENOENT else { return false }
        if let linkCount { return linkCount == 0 }
        // Independent vnode inspection bypasses path-specific policy. ENOENT
        // there establishes an absent/non-stat-able vnode, not denied visibility.
        return statError == ENOENT
    }

    /// Only an observed configuration root proves that an inaccessible process
    /// belongs elsewhere. Missing process environment remains uncertainty.
    static func configuredRootDiffers(target: String, environment: [String: String]?) -> Bool {
        guard let environment else { return false }
        let root = environment["CODEX_HOME"] ?? environment["HOME"].map { $0 + "/.codex" }
        guard let root, root.hasPrefix("/"), target.hasPrefix("/") else { return false }
        guard let configured = canonicalDirectory(root), let expected = canonicalDirectory(target) else { return false }
        return configured != expected
    }

    private static func canonicalDirectory(_ path: String) -> String? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue,
              let resolved = path.withCString({ realpath($0, nil) }) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
