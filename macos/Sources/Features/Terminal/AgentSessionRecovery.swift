import AppKit
import Combine

/// One owner for restore and crash recovery. The journal supplements AppKit snapshots,
/// but never creates windows or resurrects a closed surface.
@MainActor
final class AgentSessionRecovery: ObservableObject {
    static let shared = AgentSessionRecovery()
    typealias Status = AgentSessionRecoveryRecord
    @Published private(set) var records: [UUID: AgentSessionRecoveryRecord] = [:]
    private var surfaces: [UUID: WeakSurface] = [:]
    private var timer: Timer?
    private var launchDates: [UUID: Date] = [:]
    private var attempts: [UUID: UUID] = [:]
    private var recoveryRevisions: [UUID: UInt64] = [:]
    struct RecoveryEvidence: Equatable {
        let binding: AgentSessionBinding?
        let revision: UInt64
    }
    func recoveryEvidence(surfaceID: UUID) -> RecoveryEvidence {
        .init(binding: records[surfaceID]?.binding, revision: recoveryRevisions[surfaceID] ?? 0)
    }
    private func revise(_ id: UUID) { recoveryRevisions[id, default: 0] &+= 1 }
    private var automaticAuthorizations: [UUID: @MainActor () -> Bool] = [:]
    private var observedProcesses: [UUID: AgentSessionProcessIdentity] = [:]
    private var discoveryTask: Task<Void, Never>?
    private var lastSaved: [UUID: AgentSessionRecoveryRecord] = [:]
    private var stopped = false
    private var legacyMigrationAllowlist: Set<UUID>?

    private struct Snapshot {
        let id: UUID
        let model: Ghostty.Surface
        let foregroundGroup: Int
        let tty: String?
        let cwd: String?
        let inputGeneration: UInt64
        let evidence: RecoveryEvidence
        var binding: AgentSessionBinding? { evidence.binding }
    }
    private struct Discovery {
        let snapshot: Snapshot
        let observation: AgentSessionResume.Observation
        let identity: AgentSessionProcessIdentity?
        let owners: [AgentSessionProcessIdentity]?
    }
    private let journalURL: URL
    private let clock: () -> Date
    private let writeJournal: (Data) throws -> Void
    private let processIsAlive: (AgentSessionProcessIdentity) -> Bool

    private struct WeakSurface { weak var value: Ghostty.SurfaceView? }

    private convenience init() {
        let url = Ghostty.forkProfileStateDirectory.appendingPathComponent("agent-recovery.json")
        self.init(journalURL: url)
    }

    init(journalURL: URL, initialRecords: [UUID: AgentSessionRecoveryRecord]? = nil,
         clock: @escaping () -> Date = Date.init,
         processIsAlive: @escaping (AgentSessionProcessIdentity) -> Bool = AgentSessionResume.isAlive,
         writeJournal: ((Data) throws -> Void)? = nil) {
        self.journalURL = journalURL
        self.clock = clock
        self.processIsAlive = processIsAlive
        self.writeJournal = writeJournal ?? { data in
            try FileManager.default.createDirectory(at: journalURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: journalURL, options: .atomic)
        }
        let saved = initialRecords ?? (try? Data(contentsOf: journalURL))
            .flatMap { try? JSONDecoder().decode([UUID: AgentSessionRecoveryRecord].self, from: $0) } ?? [:]
        records = saved.mapValues { $0.restored }
        lastSaved = saved
        let marker = journalURL.deletingLastPathComponent().appendingPathComponent("agent-recovery-migration.json")
        if FileManager.default.fileExists(atPath: marker.path) {
            let migration = (try? Data(contentsOf: marker))
                .flatMap { try? JSONDecoder().decode(AgentSessionRecoveryMigration.self, from: $0) }
            legacyMigrationAllowlist = migration?.version == 1 ? Set(migration?.surfaceIDs ?? []) : []
        }
    }

    func observeRunning(surfaceID: UUID, binding: AgentSessionBinding, process: AgentSessionProcessIdentity?) {
        observedProcesses[surfaceID] = process
        if records[surfaceID]?.binding != binding || records[surfaceID]?.phase != .running {
            revise(surfaceID)
            records[surfaceID] = .init(binding: binding, phase: .running, reason: nil, updatedAt: clock())
        }
        launchDates[surfaceID] = nil
        attempts[surfaceID] = nil
        automaticAuthorizations[surfaceID] = nil
    }

    func discoveryUnavailable(surfaceID: UUID, reason: String) {
        var record = records[surfaceID] ?? .init(binding: nil, phase: .failed, reason: nil, updatedAt: clock())
        record.phase = .failed
        record.reason = reason
        records[surfaceID] = record
    }

    /// Shared by the actual launch path and transition tests. No action is authorized
    /// without a successful machine-wide owner observation.
    func permitsLaunch(surfaceID: UUID, liveOwners: [AgentSessionProcessIdentity]?, claimed: Set<String>,
                       evidence: RecoveryEvidence? = nil) -> Bool {
        if let evidence, evidence != recoveryEvidence(surfaceID: surfaceID) { return false }
        guard records[surfaceID]?.phase == .pending, let binding = records[surfaceID]?.binding else { return false }
        guard !claimed.contains(binding.key), liveOwners?.isEmpty == true else {
            discoveryUnavailable(surfaceID: surfaceID, reason: liveOwners == nil
                ? "Live session ownership could not be verified; recovery is paused"
                : "This session is already running or recovering in another terminal")
            return false
        }
        return true
    }

    func beginAttempt(surfaceID: UUID) -> UUID {
        revise(surfaceID)
        let attempt = UUID()
        attempts[surfaceID] = attempt
        records[surfaceID]?.phase = .launching
        launchDates[surfaceID] = clock()
        return attempt
    }

    func authorizesAttempt(surfaceID: UUID, attempt: UUID, binding: AgentSessionBinding) -> Bool {
        !stopped && (automaticAuthorizations[surfaceID]?() ?? true)
            && attempts[surfaceID] == attempt && records[surfaceID]?.phase == .launching
            && records[surfaceID]?.binding == binding
    }

    func start() {
        guard timer == nil, !stopped else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            Task { @MainActor in self.checkpoint() }
        }
    }

    func register(_ surface: Ghostty.SurfaceView, restored: AgentSessionRecoveryRecord? = nil, legacyArchive: Bool = false) {
        surfaces[surface.id] = WeakSurface(value: surface)
        importArchive(surfaceID: surface.id, restored: restored, legacyArchive: legacyArchive)
        start()
    }

    func importArchive(surfaceID: UUID, restored: AgentSessionRecoveryRecord?, legacyArchive: Bool) {
        if records[surfaceID] == nil, legacyArchive, let allowlist = legacyMigrationAllowlist,
           !allowlist.contains(surfaceID) {
            records[surfaceID] = .init(binding: nil, phase: .failed,
                                       reason: "This saved terminal identity does not match the captured migration mapping; automatic recovery is paused.")
        } else if records[surfaceID] == nil, let restored { records[surfaceID] = restored.restored }
    }

    func status(for id: UUID) -> Status? { records[id] }
    func hasPendingRecovery(surfaceID: UUID) -> Bool {
        guard let phase = records[surfaceID]?.phase else { return false }
        return [.pending, .launching, .failed].contains(phase)
    }

    func retry(surfaceID: UUID) {
        revise(surfaceID)
        automaticAuthorizations[surfaceID] = nil
        guard var record = records[surfaceID], record.binding != nil else { return }
        GuardedTerminalInput.shared.cancel(in: surfaceID)
        attempts[surfaceID] = nil
        record.phase = .pending
        record.reason = "Waiting for an idle, empty shell prompt"
        record.updatedAt = clock()
        records[surfaceID] = record
        launchDates[surfaceID] = nil
        persist()
    }

    func dismiss(surfaceID: UUID) {
        revise(surfaceID)
        automaticAuthorizations[surfaceID] = nil
        attempts[surfaceID] = nil
        GuardedTerminalInput.shared.cancel(in: surfaceID)
        records[surfaceID] = .init(binding: nil, phase: .stopped, reason: nil)
        persist()
    }

    func requestResume(in surface: Ghostty.SurfaceView, binding: AgentSessionBinding? = nil,
                       authorized: @escaping @MainActor () -> Bool = { true }) {
        register(surface)
        prepareResume(surfaceID: surface.id, binding: binding, authorized: authorized)
    }

    func prepareResume(surfaceID: UUID, binding: AgentSessionBinding? = nil,
                       authorized: @escaping @MainActor () -> Bool = { true }) {
        if let binding { records[surfaceID] = .init(binding: binding, phase: .pending, reason: nil) }
        retry(surfaceID: surfaceID)
        automaticAuthorizations[surfaceID] = authorized
    }

    func commandFinished(surfaceID: UUID, exitCode: Int16) {
        guard records[surfaceID]?.binding != nil, let process = observedProcesses[surfaceID],
              !processIsAlive(process) else { return }
        if KeepAliveExit.isDeliberate(exitCode: exitCode) {
            dismiss(surfaceID: surfaceID)
        } else if exitCode == -1 {
            attempts[surfaceID] = nil
            GuardedTerminalInput.shared.cancel(in: surfaceID)
            discoveryUnavailable(surfaceID: surfaceID,
                                 reason: "The agent exited without a known status. Choose retry or forget before resuming.")
            persist()
        }
    }

    func saveCheckpoint() { persist() }

    func stop() {
        stopped = true
        timer?.invalidate()
        timer = nil
        discoveryTask?.cancel()
        discoveryTask = nil
        GuardedTerminalInput.shared.cancelAll()
        attempts.removeAll()
        persist()
    }

    func checkpoint() {
        guard !stopped, discoveryTask == nil else { return }
        let snapshots = surfaces.compactMap { id, weakSurface -> Snapshot? in
            guard let surface = weakSurface.value, let model = surface.surfaceModel,
                  let group = model.foregroundPID else { return nil }
            return .init(id: id, model: model, foregroundGroup: group, tty: model.ttyName,
                         cwd: surface.pwd, inputGeneration: surface.userInputGeneration, evidence: recoveryEvidence(surfaceID: id))
        }
        discoveryTask = Task { [weak self] in
            let discoveries = await Task.detached(priority: .utility) {
                snapshots.map { snapshot -> Discovery in
                    let result = AgentSessionResume.observe(foregroundGroup: snapshot.foregroundGroup,
                                                            tty: snapshot.tty, cwd: snapshot.cwd)
                    let identity: AgentSessionProcessIdentity?
                    if case .found(_, let pid) = result { identity = AgentSessionResume.processIdentity(pid) } else { identity = nil }
                    let owners = snapshot.binding.flatMap { AgentSessionResume.liveOwners(of: $0) }
                    return .init(snapshot: snapshot, observation: result, identity: identity, owners: owners)
                }
            }.value
            guard !Task.isCancelled, let self, !self.stopped else { return }
            self.discoveryTask = nil
            self.apply(discoveries)
        }
    }

    private func apply(_ discoveries: [Discovery]) {
        let current = discoveries.filter { result in
            guard let surface = surfaces[result.snapshot.id]?.value else { return false }
            return result.snapshot.evidence == recoveryEvidence(surfaceID: result.snapshot.id)
                && surface.surfaceModel === result.snapshot.model && surface.userInputGeneration == result.snapshot.inputGeneration
                && surface.surfaceModel?.foregroundPID == result.snapshot.foregroundGroup
        }
        let liveOwners = Dictionary(uniqueKeysWithValues: current.map { ($0.snapshot.id, $0.owners) })
        var claimed = Set(records.values.filter { $0.phase == .launching }.compactMap { $0.binding?.key })
        for result in current {
            let id = result.snapshot.id
            switch result.observation {
            case .found(let binding, _):
                guard let identity = result.identity, processIsAlive(identity) else { continue }
                claimed.insert(binding.key)
                observeRunning(surfaceID: id, binding: binding, process: identity)
            case .unavailable(let reason):
                discoveryUnavailable(surfaceID: id, reason: reason)
            case .absent: break // Discovery absence is never an intentional exit.
            }
        }
        for (id, weakSurface) in surfaces {
            guard let surface = weakSurface.value, var record = records[id], let binding = record.binding else { continue }
            if record.phase == .launching, let date = launchDates[id], clock().timeIntervalSince(date) > 30 {
                record.phase = .failed
                record.reason = "Resume was sent, but the session did not register. Check this terminal and retry."
                records[id] = record
            }
            if record.phase == .pending, automaticAuthorizations[id]?() == false {
                discoveryUnavailable(surfaceID: id, reason: "Automatic recovery was switched off. Choose retry to resume manually.")
                continue
            }
            guard record.phase == .pending, let snapshot = current.first(where: { $0.snapshot.id == id })?.snapshot else { continue }
            guard surface.surfaceModel?.isAtEmptyShellPrompt == true else {
                if clock().timeIntervalSince(record.updatedAt) > 60 {
                    record.phase = .failed
                    record.reason = "The shell has not reported an empty prompt. Check shell integration, then retry."
                    records[id] = record
                }
                continue
            }
            guard permitsLaunch(surfaceID: id, liveOwners: liveOwners[id] ?? nil, claimed: claimed,
                                evidence: snapshot.evidence) else { continue }
            let attempt = beginAttempt(surfaceID: id)
            if GuardedTerminalInput.shared.send(binding.command, into: surface, authorized: { [weak self] in
                guard let self else { return false }
                return self.authorizesAttempt(surfaceID: id, attempt: attempt, binding: binding)
                    && surface.userInputGeneration == snapshot.inputGeneration
            }, completion: { [weak self] sent in
                guard !sent, let self, self.attempts[id] == attempt, self.records[id]?.phase == .launching else { return }
                self.records[id]?.phase = .failed
                self.records[id]?.reason = "Resume was interrupted by terminal input or a foreground change; check the command before retrying."
                self.persist()
            }) {
                record.phase = .launching
                record.reason = "Waiting for the agent to confirm this session"
                records[id] = record
                launchDates[id] = clock()
                claimed.insert(binding.key)
            } else if records[id]?.phase == .launching {
                // A synchronous completion may already have retained a failed
                // target after partial input. Never turn that back into a retry.
                record.phase = .pending
                records[id] = record
            }
        }
        persist()
    }

    private func persist() {
        // Keep stopped tombstones so an older AppKit archive cannot revive a deliberate exit.
        guard records != lastSaved, let data = try? JSONEncoder().encode(records) else { return }
        do {
            try writeJournal(data)
            lastSaved = records
        } catch {
            for id in records.keys where records[id]?.binding != nil {
                records[id]?.reason = "Recovery checkpoint could not be saved: \(error.localizedDescription)"
            }
        }
        for weakSurface in surfaces.values { weakSurface.value?.window?.invalidateRestorableState() }
    }
}
