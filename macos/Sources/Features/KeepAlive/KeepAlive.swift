import AppKit
import Darwin
import UserNotifications

/// Whether keep alive watches a tab, as the sidebar shows it.
enum KeepAliveTabState: Equatable {
    case off
    case on
    case gaveUp
}

extension TerminalWindow {
    var keepAliveState: KeepAliveTabState {
        guard keepAlive else { return .off }
        return keepAliveGaveUp ? .gaveUp : .on
    }
}

/// Keeps Claude Code and Codex sessions running in the tabs that have keep alive on, and
/// restarts Claude Code background sessions that failed. It replaces the watchdog daemon.
///
/// One timer ticks every `tickInterval`. For each kept-alive tab it remembers the session
/// running in the terminal's foreground, so the session is still known after its process dies.
/// A tab whose session died with a crash-like exit status gets the resume command typed into
/// it. A Claude Code session that is idle on an API error gets `continue` typed into it, on
/// the schedule the config sets. The decisions themselves are in `KeepAliveLogic.swift`.
///
/// The usage cutoff (`UsageCutoff.swift`) and the overnight switch live here too, because
/// they decide what keep alive may do to a tab: while the overnight switch is on every tab
/// running an agent is kept alive and under the cutoff, and a tab under the cutoff is asked
/// to wrap up and then left alone until the workday starts.
@MainActor
final class KeepAlive: ObservableObject {
    static let shared = KeepAlive()

    enum BackgroundMode: String {
        case failed
        case off
    }

    /// The config values keep alive reads. Updated on every config reload.
    struct Settings {
        var maxCrashes = 3
        var serverErrorInterval: TimeInterval = 300
        var rateLimitInterval: TimeInterval = 900
        var background = BackgroundMode.failed
        var relaunchGhostty = false
        var eventsFile: String?
        var usageCutoff = false
        var cutoff = UsageCutoff.Settings()
        var cutoffWarning: TimeInterval = 25 * 60
        var cutoffStopSessions = false
        var overnightRun = false
    }

    enum EventKind: String {
        case relaunched
        case gaveUp = "gave_up"
        case nudged
        case errorNotified = "error_notified"
        case respawned
        case cutoffWarning = "cutoff_warning"
        case cutoffReached = "cutoff_reached"
    }

    static let tickInterval: TimeInterval = 30

    /// How long to wait between typing a command and pressing Enter. Claude Code reads a
    /// burst of text that ends in a newline as a paste, so Enter has to arrive on its own.
    private static let enterDelay: Duration = .milliseconds(300)

    private(set) var settings = Settings()

    private struct RunningSession {
        let tool: AgentTool
        let id: String
        let pid: Int
    }

    /// What keep alive knows about one terminal in a kept-alive tab.
    private struct SurfaceState {
        /// The last session seen running here, kept after its process dies.
        var session: RunningSession?
        var crashes = KeepAliveCrashWindow()
        var gaveUpRecorded = false
        var warnedNoExitStatus = false
        /// The API error being handled, by transcript entry, and what was done about it.
        var errorUUID: String?
        var errorLastNudge: Date?
        var errorNotified = false
        /// The workday the usage cutoff was for when the wrap-up prompt was typed here, and
        /// when the cutoff was recorded, so each happens once per workday.
        var wrapUpFor: Date?
        var reachedFor: Date?
    }

    /// Where the usage cutoff stands, worked out once per tick.
    private struct CutoffContext {
        var cutoff: Date
        var phase: UsageCutoff.Phase
        /// The workday start the cutoff is aiming at. It changes when that workday begins.
        var workday: Date
    }

    private var surfaceStates: [UUID: SurfaceState] = [:]

    /// The exit status of the last command that finished in each terminal, as reported by
    /// shell integration. It is how a deliberate exit is told from a crash.
    private var exitStatuses: [UUID: Int16] = [:]

    private var respawnLimiter = KeepAliveRespawnLimiter()
    private var transcriptPaths: [String: String] = [:]
    private var claudePath: String?
    private var timer: Timer?
    private var ticking = false
    private var relaunchApplied: Bool?

    // Usage cutoff and overnight state.
    private var stampsCache: (at: Date, stamps: [Date])?
    private static let stampsLifetime: TimeInterval = 300
    private var reachedWorkday: Date?
    private var lastLoggedCutoff: Date?
    private var respawnHoldLogged = false

    /// Whether the overnight switch is on and has not yet reached the workday start.
    @Published private(set) var overnightActive = false

    /// The workday start at which the overnight switch ends. It is kept in `UserDefaults`
    /// so a Ghostty restarted in the night still ends it in the morning.
    private var overnightEndsAt: Date?
    private static let overnightEndKey = "OvernightRunEndsAt"

    // MARK: Lifecycle

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: Self.tickInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    /// Takes the settings from the config. Called at launch and on every reload.
    func apply(_ config: Ghostty.Config) {
        settings = Settings(
            maxCrashes: config.keepAliveMaxCrashes,
            serverErrorInterval: config.keepAliveServerErrorInterval,
            rateLimitInterval: config.keepAliveRateLimitInterval,
            background: config.keepAliveBackground,
            relaunchGhostty: config.keepAliveRelaunchGhostty,
            eventsFile: config.keepAliveEventsFile,
            usageCutoff: config.usageCutoff,
            cutoff: config.usageCutoffSettings,
            cutoffWarning: config.usageCutoffWarning,
            cutoffStopSessions: config.usageCutoffStopSessions,
            overnightRun: config.overnightRun)
        NSLog("KeepAlive config: maxCrashes=%d server=%.0fs rate=%.0fs background=%@ relaunchGhostty=%@",
              settings.maxCrashes, settings.serverErrorInterval, settings.rateLimitInterval,
              settings.background.rawValue, settings.relaunchGhostty ? "true" : "false")
        NSLog("KeepAlive usage cutoff: on=%@ workday=%02d:%02d usable=%.0fs latestReset=%.0fs margin=%.0fs warning=%.0fs "
              + "stopSessions=%@ overnight=%@",
              settings.usageCutoff ? "true" : "false", settings.cutoff.workdayMinutes / 60,
              settings.cutoff.workdayMinutes % 60, settings.cutoff.usable, settings.cutoff.latestReset,
              settings.cutoff.margin, settings.cutoffWarning, settings.cutoffStopSessions ? "true" : "false",
              settings.overnightRun ? "true" : "false")
        refreshOvernight()
        if relaunchApplied != settings.relaunchGhostty {
            relaunchApplied = settings.relaunchGhostty
            KeepAliveRelaunchJob.sync(enabled: settings.relaunchGhostty)
        }
    }

    /// Called as Ghostty quits normally, so the relaunch job can tell a quit from a crash.
    func willTerminate() {
        timer?.invalidate()
        if settings.relaunchGhostty { KeepAliveRelaunchJob.markCleanQuit() }
    }

    /// Records the exit status of a command that finished in a terminal. Shell integration
    /// reports it, and a status of -1 means the shell did not say.
    func commandFinished(in surface: UUID, exitCode: Int16) {
        NSLog("KeepAlive: a command finished in terminal %@ with exit status %d", surface.uuidString, exitCode)
        if exitCode < 0 {
            exitStatuses[surface] = nil
        } else {
            exitStatuses[surface] = exitCode
        }
    }

    // MARK: Notifications

    /// While this returns true, no keep alive notification is shown: the overnight switch
    /// is on. Events are still written to the events file.
    func notificationsSuppressed() -> Bool { overnightActive }

    /// The one place keep alive shows a macOS notification.
    func notifyKeepAlive(title: String, body: String) {
        NSLog("KeepAlive notification: %@ | %@", title, body)
        guard !notificationsSuppressed() else {
            NSLog("KeepAlive: the overnight switch is on, so the notification was not shown")
            return
        }
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { _, error in
            if let error { NSLog("KeepAlive: notification authorization failed: %@", "\(error)") }
        }
        center.getNotificationSettings { notificationSettings in
            guard notificationSettings.authorizationStatus == .authorized else {
                NSLog("KeepAlive: notifications are not authorized, so the notification was not shown")
                return
            }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }

    // MARK: Overnight switch

    /// Writes `overnight-run` to the config file and reloads. The reload calls `apply(_:)`.
    func setOvernight(_ isOn: Bool) {
        if let error = ConfigFile.set("overnight-run", to: isOn ? "true" : "false", underForkHeader: true) {
            SleepGuardErrorPanel.shared.show(message: error, closeAfter: nil)
        }
    }

    /// When the overnight switch ends, for the sidebar's tooltip.
    var overnightEndDescription: String? {
        guard overnightActive, let end = overnightEndsAt else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: end)
    }

    /// Brings `overnightActive` in line with the config and the clock. The switch ends at
    /// the first workday start after it was turned on, by writing `overnight-run = false`.
    func refreshOvernight(now: Date = Date()) {
        let defaults = UserDefaults.ghostty
        var active = false
        if settings.overnightRun {
            if overnightEndsAt == nil {
                overnightEndsAt = defaults.object(forKey: Self.overnightEndKey) as? Date
                    ?? UsageCutoff.workday(after: now, workdayMinutes: settings.cutoff.workdayMinutes)
                defaults.set(overnightEndsAt, forKey: Self.overnightEndKey)
            }
            if let end = overnightEndsAt, now >= end {
                NSLog("KeepAlive: the workday has started, so the overnight switch turns itself off")
                if let error = ConfigFile.set("overnight-run", to: "false", underForkHeader: true) {
                    NSLog("KeepAlive: couldn't turn the overnight switch off in the config file: %@", error)
                }
            } else {
                active = true
            }
        } else if overnightEndsAt != nil {
            overnightEndsAt = nil
            defaults.removeObject(forKey: Self.overnightEndKey)
        }
        guard active != overnightActive else { return }
        overnightActive = active
        NSLog("KeepAlive: overnight switch is now %@", active ? "on" : "off")
        SleepGuard.shared.overnightDidChange()
    }

    // MARK: Events

    /// The events file path: the config value, or the default under `~/.local/state`.
    var eventsFilePath: String {
        settings.eventsFile
            ?? NSHomeDirectory() + "/.local/state/ghostty/keep-alive-events.jsonl"
    }

    /// Appends one JSON line to the events file.
    func record(
        _ kind: EventKind,
        tool: AgentTool?,
        sessionID: String?,
        tabTitle: String?,
        errorType: String? = nil,
        message: String? = nil
    ) {
        var event: [String: Any] = [
            "time": ISO8601DateFormatter().string(from: Date()),
            "event": kind.rawValue,
        ]
        if let tool { event["tool"] = tool.rawValue }
        if let sessionID { event["session_id"] = sessionID }
        if let tabTitle { event["tab_title"] = tabTitle }
        if let errorType { event["error_type"] = errorType }
        if let message { event["message"] = message }
        NSLog("KeepAlive event: %@ %@", kind.rawValue, sessionID ?? "")

        guard var data = try? JSONSerialization.data(withJSONObject: event, options: [.sortedKeys, .withoutEscapingSlashes])
        else { return }
        data.append(0x0A)
        let url = URL(fileURLWithPath: eventsFilePath)
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {
            NSLog("KeepAlive: couldn't write the events file %@: %@", url.path, "\(error)")
        }
    }

    // MARK: The tick

    private func tick() {
        refreshOvernight()
        guard !ticking else { return }
        let tabs = keptAliveTabs()
        let wantsBackground = settings.background == .failed
        guard !tabs.isEmpty || wantsBackground else {
            surfaceStates.removeAll()
            return
        }
        ticking = true

        // `claude agents --json --all` lists interactive sessions' status and background
        // sessions' state in one call, so it runs at most once per tick.
        Task {
            let snapshot = await fetchAgents()
            let context = await cutoffContext(for: tabs)
            process(tabs, snapshot: snapshot, cutoff: context)
            if wantsBackground, let snapshot, !(await respawnHeld()) { await respawnFailed(snapshot.background) }
            ticking = false
        }
    }

    private typealias Tab = (window: TerminalWindow, surfaces: [Ghostty.SurfaceView])

    /// The tabs keep alive looks at: those with keep alive on, and every tab while the
    /// overnight switch is on. A tab in the second group does nothing unless an agent runs
    /// in it, and its own keep alive flag is never changed.
    private func keptAliveTabs() -> [Tab] {
        NSApp.windows.compactMap { window in
            guard let terminalWindow = window as? TerminalWindow,
                  let controller = terminalWindow.windowController as? BaseTerminalController
            else { return nil }
            guard terminalWindow.keepAlive || overnightActive else {
                // A gave-up mark set by the overnight switch must not outlive it.
                terminalWindow.keepAliveGaveUp = false
                return nil
            }
            return (terminalWindow, controller.surfaceTree.root?.leaves() ?? [])
        }
    }

    /// Whether the usage cutoff covers a tab: the cutoff is on and the tab has keep alive on,
    /// or the overnight switch is on.
    private func usageCutoffApplies(to window: TerminalWindow) -> Bool {
        overnightActive || (settings.usageCutoff && window.keepAlive)
    }

    // MARK: Usage cutoff

    /// The assistant-message times from recent transcripts, read off the main thread and
    /// reused for a few minutes.
    private func transcriptStamps(now: Date) async -> [Date] {
        if let cache = stampsCache, now.timeIntervalSince(cache.at) < Self.stampsLifetime { return cache.stamps }
        let stamps = await Task.detached { UsageCutoff.assistantTimestamps(now: now) }.value
        stampsCache = (now, stamps)
        return stamps
    }

    /// Where the cutoff stands for this tick, or nil when no watched tab is covered by it
    /// or no cutoff is due yet. Reaching the cutoff holds until the workday starts, even if
    /// a later computation moves the cutoff.
    private func cutoffContext(for tabs: [Tab]) async -> CutoffContext? {
        guard tabs.contains(where: { usageCutoffApplies(to: $0.window) }) else { return nil }
        let now = Date()
        let workday = UsageCutoff.workday(after: now, workdayMinutes: settings.cutoff.workdayMinutes)
        if reachedWorkday != workday { reachedWorkday = nil }
        let stamps = await transcriptStamps(now: now)
        let computed = UsageCutoff.cutoff(stamps: stamps, now: now, settings: settings.cutoff)
        if computed != lastLoggedCutoff {
            lastLoggedCutoff = computed
            NSLog("KeepAlive: usage cutoff is %@ (workday start %@)",
                  computed.map { "\($0)" } ?? "not due", "\(workday)")
        }
        var phase = UsageCutoff.phase(cutoff: computed, now: now, warning: settings.cutoffWarning)
        if phase == .reached { reachedWorkday = workday }
        if reachedWorkday == workday { phase = .reached }
        guard phase != .clear, let cutoff = computed else { return nil }
        return CutoffContext(cutoff: cutoff, phase: phase, workday: workday)
    }

    /// Whether the usage cutoff holds background-session respawns back this tick. It applies
    /// when `usage-cutoff` or the overnight switch is on, whether or not any tab is watched.
    private func respawnHeld() async -> Bool {
        let applies = settings.usageCutoff || overnightActive
        var held = false
        if applies {
            let now = Date()
            let workday = UsageCutoff.workday(after: now, workdayMinutes: settings.cutoff.workdayMinutes)
            if reachedWorkday != workday { reachedWorkday = nil }
            let stamps = await transcriptStamps(now: now)
            let computed = UsageCutoff.cutoff(stamps: stamps, now: now, settings: settings.cutoff)
            held = UsageCutoff.holdsRespawn(
                applies: true, cutoff: computed, now: now, reachedWorkday: reachedWorkday, workday: workday)
            if held { reachedWorkday = workday }
        }
        if held != respawnHoldLogged {
            respawnHoldLogged = held
            NSLog("KeepAlive: background respawns are %@", held ? "held until the workday starts" : "no longer held")
        }
        return held
    }

    private func process(_ tabs: [Tab], snapshot: KeepAliveAgents.Snapshot?, cutoff: CutoffContext?) {
        let live = Set(tabs.flatMap { $0.surfaces.map(\.id) })
        surfaceStates = surfaceStates.filter { live.contains($0.key) }
        exitStatuses = exitStatuses.filter { live.contains($0.key) }

        for tab in tabs {
            for surface in tab.surfaces {
                processSurface(surface, in: tab.window, snapshot: snapshot, context: cutoff)
            }
        }
    }

    private func processSurface(
        _ surface: Ghostty.SurfaceView,
        in window: TerminalWindow,
        snapshot: KeepAliveAgents.Snapshot?,
        context: CutoffContext?
    ) {
        let key = surface.id
        let cutoff = usageCutoffApplies(to: window) ? context : nil
        var state = surfaceStates[key] ?? SurfaceState()
        defer { surfaceStates[key] = state }

        // Turning keep alive off and on again, or "try again" in the menu, starts a fresh count.
        if state.gaveUpRecorded, !window.keepAliveGaveUp {
            state.crashes = KeepAliveCrashWindow()
            state.gaveUpRecorded = false
        }

        guard let foreground = surface.surfaceModel?.foregroundPID else { return }

        if let found = AgentSessionResume.session(forProcess: foreground) {
            if state.session?.id != found.id || state.session?.pid != foreground {
                exitStatuses[key] = nil
                state.warnedNoExitStatus = false
            }
            if state.session?.id != found.id || state.session?.pid != foreground {
                NSLog("KeepAlive: watching %@ session %@ (pid %d) in %@", found.tool.rawValue, found.id, foreground, window.title)
            }
            state.session = RunningSession(tool: found.tool, id: found.id, pid: foreground)
            if let cutoff {
                handleCutoff(surface, window: window, state: &state, pid: foreground, snapshot: snapshot, cutoff: cutoff)
                // After the cutoff nothing is typed into the session until the workday starts.
                if cutoff.phase == .reached { return }
            }
            if found.tool == .claude {
                handleApiError(surface, window: window, state: &state, pid: foreground, snapshot: snapshot)
            }
            return
        }

        // No session in the foreground. It is a crash only if the session we knew has gone,
        // the shell is back, and the shell reported a crash-like exit status.
        guard let known = state.session,
              !processExists(known.pid),
              let name = SleepGuard.executableName(of: foreground),
              SleepGuard.idleShells.contains(name)
        else { return }

        guard let exitStatus = exitStatuses[key] else {
            if !state.warnedNoExitStatus {
                NSLog("KeepAlive: %@ session %@ ended and the shell gave no exit status, so it is not relaunched",
                      known.tool.rawValue, known.id)
                state.warnedNoExitStatus = true
            }
            return
        }
        if KeepAliveExit.isDeliberate(exitCode: exitStatus) {
            state.session = nil
            exitStatuses[key] = nil
            return
        }
        guard !window.keepAliveGaveUp else { return }
        // Once the wrap-up is due, a session that ended is left ended, as the watchdog did.
        if cutoff != nil { return }

        let title = window.title
        if state.crashes.allowAttempt(at: Date(), limit: settings.maxCrashes) {
            exitStatuses[key] = nil
            record(.relaunched, tool: known.tool, sessionID: known.id, tabTitle: title,
                   message: "exited with status \(exitStatus)")
            type(known.tool.resumeCommand(sessionID: known.id), into: surface)
        } else {
            window.keepAliveGaveUp = true
            state.gaveUpRecorded = true
            record(.gaveUp, tool: known.tool, sessionID: known.id, tabTitle: title,
                   message: "crashed more than \(settings.maxCrashes) times in 60 minutes")
            notifyKeepAlive(
                title: "Keep alive gave up",
                body: "\(title) crashed more than \(settings.maxCrashes) times in an hour.")
        }
    }

    // MARK: Usage cutoff handling

    private func handleCutoff(
        _ surface: Ghostty.SurfaceView,
        window: TerminalWindow,
        state: inout SurfaceState,
        pid: Int,
        snapshot: KeepAliveAgents.Snapshot?,
        cutoff: CutoffContext
    ) {
        guard let session = state.session else { return }
        let when = cutoff.cutoff.formatted(date: .omitted, time: .shortened)

        // Claude Code only: Codex has no idle status to wait for.
        if state.wrapUpFor != cutoff.workday, session.tool == .claude, snapshot?.interactiveStatus[pid] == "idle" {
            state.wrapUpFor = cutoff.workday
            record(.cutoffWarning, tool: .claude, sessionID: session.id, tabTitle: window.title,
                   message: "usage cutoff at \(when); wrap-up prompt typed")
            type(UsageCutoff.wrapUpPrompt(cutoff: cutoff.cutoff), into: surface)
        }

        if cutoff.phase == .reached, state.reachedFor != cutoff.workday {
            state.reachedFor = cutoff.workday
            let prompted = state.wrapUpFor == cutoff.workday
            var message = "usage cutoff reached at \(when)"
            if !prompted { message += "; the wrap-up prompt was never typed" }
            if settings.cutoffStopSessions { message += "; the session was stopped" }
            record(.cutoffReached, tool: session.tool, sessionID: session.id, tabTitle: window.title, message: message)
            if settings.cutoffStopSessions, let target = pid_t(exactly: pid) {
                kill(target, SIGTERM)
            }
        }
    }

    // MARK: API errors

    private func handleApiError(
        _ surface: Ghostty.SurfaceView,
        window: TerminalWindow,
        state: inout SurfaceState,
        pid: Int,
        snapshot: KeepAliveAgents.Snapshot?
    ) {
        guard let session = state.session,
              let path = transcriptPath(forSession: session.id),
              let error = KeepAliveTranscript.lastApiError(inTail: Self.tail(of: path))
        else {
            state.errorUUID = nil
            return
        }
        if state.errorUUID != error.uuid {
            state.errorUUID = error.uuid
            state.errorLastNudge = nil
            state.errorNotified = false
        }

        let decision = KeepAliveErrorPolicy.decide(
            error, now: Date(), lastNudge: state.errorLastNudge, alreadyNotified: state.errorNotified,
            serverErrorInterval: settings.serverErrorInterval, rateLimitInterval: settings.rateLimitInterval)

        if decision.notify {
            state.errorNotified = true
            record(.errorNotified, tool: .claude, sessionID: session.id, tabTitle: window.title,
                   errorType: error.type, message: error.message)
            notifyKeepAlive(title: "Claude Code is stuck: \(error.type)", body: "\(window.title): \(error.message)")
        }
        // Typing needs the session to say it is idle. A busy or waiting session, or an
        // unreadable status, is left alone.
        if decision.nudge, snapshot?.interactiveStatus[pid] == "idle" {
            state.errorLastNudge = Date()
            record(.nudged, tool: .claude, sessionID: session.id, tabTitle: window.title,
                   errorType: error.type, message: error.message)
            type("continue", into: surface)
        }
    }

    /// `~/.claude/projects/<project>/<session id>.jsonl`. The project folder is derived from
    /// the working directory in a way that is not worth repeating, so the folders are searched.
    private func transcriptPath(forSession id: String) -> String? {
        if let cached = transcriptPaths[id], FileManager.default.fileExists(atPath: cached) { return cached }
        let root = NSHomeDirectory() + "/.claude/projects"
        let projects = (try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []
        for project in projects {
            let path = "\(root)/\(project)/\(id).jsonl"
            if FileManager.default.fileExists(atPath: path) {
                transcriptPaths[id] = path
                return path
            }
        }
        return nil
    }

    /// The last 64 KB of a file as text.
    private static func tail(of path: String) -> String {
        guard let handle = FileHandle(forReadingAtPath: path) else { return "" }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return "" }
        let start = size > 65536 ? size - 65536 : 0
        try? handle.seek(toOffset: start)
        let data = (try? handle.readToEnd()) ?? Data()
        return String(bytes: data, encoding: .utf8) ?? ""
    }

    // MARK: Background sessions

    private func respawnFailed(_ sessions: [KeepAliveBackgroundSession]) async {
        let failed = KeepAliveAgents.respawnTargets(sessions)
        let names = Dictionary(failed.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        let actions = respawnLimiter.decide(failed: failed.map(\.id), now: Date(), limit: settings.maxCrashes)

        for action in actions {
            switch action {
            case .giveUp(let id):
                let name = names[id] ?? ""
                record(.gaveUp, tool: .claude, sessionID: id, tabTitle: name,
                       message: "background session failed more than \(settings.maxCrashes) times in 60 minutes")
                notifyKeepAlive(title: "Keep alive gave up", body: "Background session \(name) keeps failing.")
            case .respawn(let id):
                record(.respawned, tool: .claude, sessionID: id, tabTitle: names[id],
                       message: "background session state was failed")
                _ = await runClaude(["respawn", id])
            }
        }
    }

    // MARK: Typing

    /// Types a line into a terminal: the text, then Enter as its own key press.
    private func type(_ text: String, into surface: Ghostty.SurfaceView) {
        guard let model = surface.surfaceModel else { return }
        model.sendText(text)
        Task { [weak surface] in
            try? await Task.sleep(for: Self.enterDelay)
            guard let model = surface?.surfaceModel else { return }
            model.sendKeyEvent(.init(key: .enter, action: .press))
            model.sendKeyEvent(.init(key: .enter, action: .release))
        }
    }

    // MARK: Processes

    private func processExists(_ pid: Int) -> Bool {
        guard let pid = pid_t(exactly: pid) else { return false }
        return kill(pid, 0) == 0 || errno == EPERM
    }

    private func fetchAgents() async -> KeepAliveAgents.Snapshot? {
        guard let output = await runClaude(["agents", "--json", "--all"]) else { return nil }
        return KeepAliveAgents.parse(output)
    }

    /// Runs `claude` with the arguments and returns its output, or nil if it failed.
    private func runClaude(_ arguments: [String]) async -> Data? {
        guard let path = claudeExecutable() else {
            NSLog("KeepAlive: couldn't find the claude executable")
            return nil
        }
        return await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = arguments
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            do { try process.run() } catch { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return process.terminationStatus == 0 ? data : nil
        }.value
    }

    /// Where `claude` is. Ghostty started from the Dock has no shell PATH, so the usual
    /// install places are tried before asking a login shell.
    private func claudeExecutable() -> String? {
        if let claudePath { return claudePath }
        let home = NSHomeDirectory()
        let candidates = ["\(home)/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
        if let found = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            claudePath = found
            return found
        }
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/zsh")
        shell.arguments = ["-lc", "command -v claude"]
        let pipe = Pipe()
        shell.standardOutput = pipe
        shell.standardError = FileHandle.nullDevice
        guard (try? shell.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        shell.waitUntilExit()
        let path = (String(bytes: data, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) else { return nil }
        claudePath = path
        return path
    }
}
