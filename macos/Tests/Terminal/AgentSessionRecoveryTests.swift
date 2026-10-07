import Foundation
import Darwin
import Testing
@testable import Ghostty

struct AgentSessionRecoveryTests {
    private let id = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!

    @Test func legacyCommandsAreStrictlyMigrated() {
        #expect(AgentSessionBinding.legacy("codex resume \(id)", cwd: "/tmp", home: "/home/a")?.tool == .codex)
        #expect(AgentSessionBinding.legacy("claude --resume \(id); touch /tmp/evil", cwd: nil, home: "/home/a") == nil)
        #expect(AgentSessionBinding.legacy("echo anything", cwd: nil, home: "/home/a") == nil)
    }

    @Test func inferredClaudeDefaultRestoresOrdinaryConfiguration() {
        let binding = AgentSessionBinding(tool: .claude, sessionID: id, sessionRoot: "/home/test/.claude",
                                          launchCWD: "/work/space 'quote", configurationRootWasExplicit: false)
        #expect(binding.command(homeDirectory: "/home/test")
            == "cd -- '/work/space '\\''quote' && env -u CLAUDE_CONFIG_DIR claude --resume \(id.uuidString.lowercased())")
    }

    @Test func intentionalClaudeRootsRemainExplicit() {
        for root in ["/home/test/.claude", "/custom/space 'quote"] {
            let binding = AgentSessionBinding(tool: .claude, sessionID: id, sessionRoot: root,
                                              launchCWD: nil, configurationRootWasExplicit: true)
            #expect(binding.command(homeDirectory: "/home/test")
                == "env CLAUDE_CONFIG_DIR=\(AgentSessionBinding.quote(root)) claude --resume \(id.uuidString.lowercased())")
        }
    }

    @Test func priorBindingsDecodeWithoutInventingExplicitDefaultRoot() throws {
        for root in ["/home/test/.claude", "/custom/space 'quote"] {
            let data = try JSONSerialization.data(withJSONObject: ["tool": "claude", "sessionID": id.uuidString,
                                                                  "sessionRoot": root, "launchCWD": "/work"])
            let binding = try JSONDecoder().decode(AgentSessionBinding.self, from: data)
            #expect(binding.configurationRootWasExplicit == nil)
            let launch = root == "/home/test/.claude" ? "env -u CLAUDE_CONFIG_DIR"
                : "env CLAUDE_CONFIG_DIR=\(AgentSessionBinding.quote(root))"
            #expect(binding.command(homeDirectory: "/home/test")
                == "cd -- '/work' && \(launch) claude --resume \(id.uuidString.lowercased())")
        }
    }

    @Test func explicitRootIntentRoundTripsAndCodexKeepsItsRoot() throws {
        let explicit = AgentSessionBinding(tool: .claude, sessionID: id, sessionRoot: "/home/test/.claude",
                                           launchCWD: nil, configurationRootWasExplicit: true)
        let decoded = try JSONDecoder().decode(AgentSessionBinding.self, from: JSONEncoder().encode(explicit))
        #expect(decoded == explicit)
        let codex = AgentSessionBinding(tool: .codex, sessionID: id, sessionRoot: "/home/test/.codex", launchCWD: nil)
        #expect(codex.command(homeDirectory: "/home/test")
            == "env CODEX_HOME='/home/test/.codex' codex resume \(id.uuidString.lowercased())")
    }

    @Test func pendingAndFailedSurviveSecondRestart() throws {
        let binding = AgentSessionBinding(tool: .codex, sessionID: id, sessionRoot: "/custom/Unicode — root", launchCWD: "/tmp")
        for phase in [AgentSessionRecoveryRecord.Phase.pending, .launching, .failed] {
            let record = AgentSessionRecoveryRecord(binding: binding, phase: phase, reason: "permission blocked")
            let loaded = try JSONDecoder().decode(AgentSessionRecoveryRecord.self, from: JSONEncoder().encode(record)).restored
            #expect(loaded.binding == binding)
            #expect(loaded.phase == (phase == .failed ? .failed : .pending))
        }
    }

    @Test func deliberateExitTombstoneDoesNotResume() {
        let stopped = AgentSessionRecoveryRecord(binding: nil, phase: .stopped, reason: nil)
        #expect(stopped.restored == stopped)
    }

    @Test func ambiguityNeverSelectsFirstCandidate() {
        let a = AgentSessionBinding(tool: .codex, sessionID: id, sessionRoot: "/custom", launchCWD: nil)
        let b = AgentSessionBinding(tool: .claude, sessionID: id, sessionRoot: "/other", launchCWD: nil)
        if case .failure(.ambiguous) = AgentSessionSelection.unique([a, b]) {} else { Issue.record("Ambiguous sessions selected") }
        if case .success(let selected) = AgentSessionSelection.unique([a, a]) { #expect(selected == a) } else { Issue.record("Identical evidence rejected") }
    }

    @Test func duplicateTitlesAreNotKeys() throws {
        let binding = AgentSessionBinding(tool: .codex, sessionID: id, sessionRoot: "/custom", launchCWD: nil)
        let first = UUID(), second = UUID()
        let records = [first: AgentSessionRecoveryRecord(binding: binding, phase: .pending, reason: nil),
                       second: AgentSessionRecoveryRecord(binding: nil, phase: .stopped, reason: nil)]
        let restored = try JSONDecoder().decode([UUID: AgentSessionRecoveryRecord].self, from: JSONEncoder().encode(records))
        #expect(restored.count == 2)
        #expect(restored[first]?.binding == binding)
        #expect(restored[second]?.binding == nil)
    }
    @Test func wrapperAndPipelineResolveActualMember() {
        let binding = AgentSessionBinding(tool: .codex, sessionID: id, sessionRoot: "/custom", launchCWD: nil)
        let identity = AgentSessionProcessIdentity(pid: 202, startSeconds: 100, startMicroseconds: 0)
        let member = AgentSessionCandidate(identity: identity, identityAfterRead: identity,
                                          foregroundGroup: 101, tty: "/dev/ttys999", binding: binding)
        if case .success(let selected) = AgentSessionCandidateResolver.resolve(group: 101, tty: "/dev/ttys999", candidates: [member]) {
            #expect(selected?.identity.pid == 202)
        } else { Issue.record("Wrapper member rejected") }
        if case .success(let selected) = AgentSessionCandidateResolver.resolve(group: 101, tty: "/dev/ttys998", candidates: [member]) {
            #expect(selected == nil)
        } else { Issue.record("Unrelated terminal was not ignored") }
    }

    @Test func reusedPIDRejected() {
        let binding = AgentSessionBinding(tool: .claude, sessionID: id, sessionRoot: "/custom", launchCWD: nil)
        let before = AgentSessionProcessIdentity(pid: 202, startSeconds: 100, startMicroseconds: 0)
        let after = AgentSessionProcessIdentity(pid: 202, startSeconds: 101, startMicroseconds: 0)
        let stale = AgentSessionCandidate(identity: before, identityAfterRead: after, foregroundGroup: 101, tty: nil, binding: binding)
        if case .failure(.staleProcess) = AgentSessionCandidateResolver.resolve(group: 101, tty: nil, candidates: [stale]) {} else { Issue.record("Reused PID accepted") }
    }

    @Test func metadataSurvivesTruncatedLaterUnicode() throws {
        let header = "{\"type\":\"session_meta\",\"payload\":{\"id\":\"\(id)\"}}"
        var data = Data((header + "\n").utf8)
        data.append(contentsOf: [0xF0, 0x9F]) // Incomplete later codepoint.
        let line = try #require(AgentSessionResume.metadataLine(data))
        #expect(String(data: line, encoding: .utf8) == header)
        #expect(AgentSessionResume.metadataLine(Data(repeating: 65, count: 65536)) == nil)
    }

}

@MainActor
struct AgentSessionRecoveryCoordinatorTests {
    private let surface = UUID()
    private let binding = AgentSessionBinding(tool: .codex, sessionID: UUID(), sessionRoot: "/custom", launchCWD: "/tmp")
    private let process = AgentSessionProcessIdentity(pid: 99, startSeconds: 10, startMicroseconds: 0)

    private func coordinator(alive: Bool = false, write: @escaping (Data) throws -> Void = { _ in }) -> AgentSessionRecovery {
        AgentSessionRecovery(journalURL: URL(fileURLWithPath: "/unused-test-journal"),
                             initialRecords: [surface: .init(binding: binding, phase: .pending, reason: nil)],
                             clock: { Date(timeIntervalSince1970: 100) }, processIsAlive: { _ in alive }, writeJournal: write)
    }

    @Test func unavailableThenDeliberateExitPersistsTombstone() {
        let keeper = coordinator()
        keeper.observeRunning(surfaceID: surface, binding: binding, process: process)
        keeper.discoveryUnavailable(surfaceID: surface, reason: "permission blocked")
        keeper.commandFinished(surfaceID: surface, exitCode: 0)
        #expect(keeper.status(for: surface)?.phase == .stopped)
        #expect(keeper.status(for: surface)?.binding == nil)
    }

    @Test func liveOwnerChildCompletionDoesNotClearBinding() {
        let keeper = coordinator(alive: true)
        keeper.observeRunning(surfaceID: surface, binding: binding, process: process)
        keeper.commandFinished(surfaceID: surface, exitCode: 0)
        #expect(keeper.status(for: surface)?.phase == .running)
        #expect(keeper.status(for: surface)?.binding == binding)
    }

    @Test func unknownExitNeedsManualDecisionAcrossRestart() throws {
        var saved = Data()
        let keeper = coordinator(write: { saved = $0 })
        keeper.observeRunning(surfaceID: surface, binding: binding, process: process)
        keeper.commandFinished(surfaceID: surface, exitCode: -1)
        let records = try JSONDecoder().decode([UUID: AgentSessionRecoveryRecord].self, from: saved)
        let next = AgentSessionRecovery(journalURL: URL(fileURLWithPath: "/unused"), initialRecords: records, writeJournal: { _ in })
        #expect(next.status(for: surface)?.phase == .failed)
        #expect(next.status(for: surface)?.binding == binding)
    }

    @Test func pendingImmediateRestartAndOneLaunch() throws {
        var saved = Data()
        let keeper = coordinator(write: { saved = $0 })
        #expect(keeper.permitsLaunch(surfaceID: surface, liveOwners: [], claimed: []))
        _ = keeper.beginAttempt(surfaceID: surface)
        #expect(!keeper.permitsLaunch(surfaceID: surface, liveOwners: [], claimed: []))
        keeper.saveCheckpoint()
        let records = try JSONDecoder().decode([UUID: AgentSessionRecoveryRecord].self, from: saved)
        let next = AgentSessionRecovery(journalURL: URL(fileURLWithPath: "/unused"), initialRecords: records, writeJournal: { _ in })
        #expect(next.status(for: surface)?.phase == .pending)
        #expect(next.status(for: surface)?.binding == binding)
    }

    @Test func externalOwnerOrUnavailableOwnershipBlocksLaunch() {
        let keeper = coordinator()
        #expect(!keeper.permitsLaunch(surfaceID: surface, liveOwners: [process], claimed: []))
        #expect(keeper.status(for: surface)?.phase == .failed)
        keeper.retry(surfaceID: surface)
        #expect(!keeper.permitsLaunch(surfaceID: surface, liveOwners: nil, claimed: []))
    }

    @Test func retryCannotAuthorizeOldTransaction() {
        let keeper = coordinator()
        let old = keeper.beginAttempt(surfaceID: surface)
        keeper.retry(surfaceID: surface)
        let current = keeper.beginAttempt(surfaceID: surface)
        #expect(!keeper.authorizesAttempt(surfaceID: surface, attempt: old, binding: binding))
        #expect(keeper.authorizesAttempt(surfaceID: surface, attempt: current, binding: binding))
        keeper.dismiss(surfaceID: surface)
        #expect(!keeper.authorizesAttempt(surfaceID: surface, attempt: current, binding: binding))
    }

    @Test func delayedOwnerEvidenceCannotAuthorizeReplacementBinding() {
        let keeper = coordinator()
        let oldEvidence = keeper.recoveryEvidence(surfaceID: surface)
        let replacement = AgentSessionBinding(tool: .codex, sessionID: UUID(), sessionRoot: "/custom", launchCWD: nil)
        keeper.prepareResume(surfaceID: surface, binding: replacement)
        // A delayed scan proves A has no owner. It says nothing about live B.
        #expect(!keeper.permitsLaunch(surfaceID: surface, liveOwners: [], claimed: [], evidence: oldEvidence))
        #expect(keeper.status(for: surface)?.phase == .pending)
        let newEvidence = keeper.recoveryEvidence(surfaceID: surface)
        #expect(!keeper.permitsLaunch(surfaceID: surface, liveOwners: [process], claimed: [], evidence: newEvidence))
        #expect(keeper.status(for: surface)?.phase == .failed)
        #expect(keeper.status(for: surface)?.binding == replacement)
    }

    @Test func seededMigrationRejectsUnknownLegacySurfaceIdentity() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let marker = AgentSessionRecoveryMigration(version: 1, surfaceIDs: [surface])
        try JSONEncoder().encode(marker).write(to: root.appendingPathComponent("agent-recovery-migration.json"))
        let keeper = AgentSessionRecovery(journalURL: root.appendingPathComponent("agent-recovery.json"), initialRecords: [:], writeJournal: { _ in })
        let unknown = UUID()
        let restored = AgentSessionRecoveryRecord(binding: binding, phase: .pending, reason: nil)
        keeper.importArchive(surfaceID: unknown, restored: restored, legacyArchive: true)
        #expect(keeper.status(for: unknown)?.binding == nil)
        #expect(keeper.status(for: unknown)?.phase == .failed)
        keeper.importArchive(surfaceID: surface, restored: restored, legacyArchive: true)
        #expect(keeper.status(for: surface)?.binding == binding)
        let typed = UUID()
        keeper.importArchive(surfaceID: typed, restored: restored, legacyArchive: false)
        #expect(keeper.status(for: typed)?.binding == binding)
    }

    @Test func journalFailureKeepsTargetVisible() {
        struct Denied: Error {}
        let keeper = coordinator(write: { _ in throw Denied() })
        keeper.retry(surfaceID: surface)
        #expect(keeper.status(for: surface)?.binding == binding)
        #expect(keeper.status(for: surface)?.reason?.contains("could not be saved") == true)
    }
}

struct AgentSessionProcessArgumentsTests {
    private func fixture(arguments: [String], environment: [String], padding: Int = 3) -> Data {
        var argc = Int32(arguments.count)
        var data = withUnsafeBytes(of: &argc) { Data($0) }
        data.append(Data("/usr/local/bin/codex\0".utf8))
        data.append(Data(repeating: 0, count: padding))
        for string in arguments + environment { data.append(Data((string + "\0").utf8)) }
        return data
    }

    @Test func argumentsAreNotToolHomeEnvironment() throws {
        let data = fixture(arguments: ["codex", "HOME=/fake", "CODEX_HOME=/argv", ""],
                           environment: ["HOME=/real", "CODEX_HOME=/custom", "OTHER=x=y"])
        let parsed = try #require(AgentSessionProcessArguments.parse(data))
        #expect(parsed.arguments == ["codex", "HOME=/fake", "CODEX_HOME=/argv", ""])
        #expect(parsed.environment["HOME"] == "/real")
        #expect(parsed.environment["CODEX_HOME"] == "/custom")
        #expect(parsed.environment["OTHER"] == nil)
    }

    @Test func malformedArgumentsFailClosed() {
        #expect(AgentSessionProcessArguments.parse(Data([2, 0])) == nil)
        var truncated = fixture(arguments: ["codex", "arg"], environment: [])
        truncated.removeLast()
        #expect(AgentSessionProcessArguments.parse(truncated) == nil)
    }

    @Test func irrelevantProtectedApplicationsDoNotBlockRecovery() {
        #expect(!AgentSessionProcessClassifier.blocksOnUnavailableDescriptors(
            executable: "/Applications/Safari.app/Contents/MacOS/Safari", name: "Safari"))
        #expect(!AgentSessionProcessClassifier.blocksOnUnavailableDescriptors(executable: nil, name: "WindowServer"))
        #expect(AgentSessionProcessClassifier.blocksOnUnavailableDescriptors(executable: "/opt/bin/codex", name: "codex"))
        #expect(AgentSessionProcessClassifier.blocksOnUnavailableDescriptors(executable: "/opt/bin/node", name: "node", arguments: ["node", "/pkg/codex.js"]))
        #expect(!AgentSessionProcessClassifier.blocksOnUnavailableDescriptors(executable: "/opt/bin/node", name: "node", arguments: ["node", "server.js"]))
    }
}

struct AgentSessionDescriptorInspectionTests {
    @Test func absentVnodeIsNotPermissionDenial() {
        #expect(AgentSessionDescriptorInspection.missingVnodeCanBeIgnored(pathError: ENOENT, statError: ENOENT, linkCount: nil))
        #expect(AgentSessionDescriptorInspection.missingVnodeCanBeIgnored(pathError: ENOENT, statError: nil, linkCount: 0))
        #expect(!AgentSessionDescriptorInspection.missingVnodeCanBeIgnored(pathError: ENOENT, statError: nil, linkCount: 1))
        #expect(!AgentSessionDescriptorInspection.missingVnodeCanBeIgnored(pathError: ENOENT, statError: EACCES, linkCount: nil))
        #expect(!AgentSessionDescriptorInspection.missingVnodeCanBeIgnored(pathError: EPERM, statError: ENOENT, linkCount: nil))
        #expect(!AgentSessionDescriptorInspection.missingVnodeCanBeIgnored(pathError: EACCES, statError: nil, linkCount: 0))
    }

    @Test func differentConfiguredRootExcludesOnlyProvenMismatch() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let target = root.appendingPathComponent("codex")
        let other = root.appendingPathComponent("other")
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: target)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(AgentSessionDescriptorInspection.configuredRootDiffers(target: target.path, environment: ["CODEX_HOME": other.path]))
        #expect(!AgentSessionDescriptorInspection.configuredRootDiffers(target: target.path, environment: ["CODEX_HOME": alias.path]))
        #expect(!AgentSessionDescriptorInspection.configuredRootDiffers(target: target.path, environment: ["CODEX_HOME": target.path]))
        #expect(!AgentSessionDescriptorInspection.configuredRootDiffers(target: target.path, environment: nil))
        #expect(!AgentSessionDescriptorInspection.configuredRootDiffers(target: target.path, environment: [:]))
        #expect(!AgentSessionDescriptorInspection.configuredRootDiffers(target: target.path, environment: ["CODEX_HOME": "relative"]))
        #expect(!AgentSessionDescriptorInspection.configuredRootDiffers(target: target.path, environment: ["CODEX_HOME": "~/codex"]))
        #expect(!AgentSessionDescriptorInspection.configuredRootDiffers(target: target.path, environment: ["CODEX_HOME": root.appendingPathComponent("missing").path]))
    }
}
