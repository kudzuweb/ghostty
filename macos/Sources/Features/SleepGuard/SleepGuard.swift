import AppKit
import Darwin

/// Reads and flips the system-wide `pmset disablesleep` flag, which is the only thing that
/// keeps a Mac awake with the lid closed when no external display is attached.
///
/// Ported from NoDoz. The flag survives reboots and is invisible in System Settings, so
/// `SleepGuard` always re-reads it rather than trusting what it last set.
enum LidSleep {
    /// Reads the flag. Returns nil if pmset can't be read.
    nonisolated static func isBlocked() -> Bool? {
        guard let out = run("/usr/bin/pmset", ["-g"]) else { return nil }
        for line in out.split(separator: "\n") where line.contains("SleepDisabled") {
            return line.split(whereSeparator: { $0.isWhitespace }).last == "1"
        }
        // pmset omits the line entirely on some systems when the flag is off.
        return false
    }

    /// Sets the flag with the narrow passwordless sudo rule, so the mutation and its
    /// child process remain bounded. Authorization AppleEvents can outlive osascript
    /// through a privileged helper and cannot safely share an automatic ownership lease.
    nonisolated static func setBlocked(_ blocked: Bool, allowPrompt: Bool, ownershipFD: Int32 = -1) -> String? {
        let target = blocked ? "1" : "0"
        if ForkBoundedProcess.run("/usr/bin/sudo", ["-n", "/usr/bin/pmset", "-a", "disablesleep", target], inheritedLockFD: ownershipFD).status == 0 {
            return nil
        }
        return "sudo -n /usr/bin/pmset -a disablesleep \(target) failed. The narrow passwordless sudo rule is required."
    }

    nonisolated private static func run(_ path: String, _ args: [String]) -> String? {
        let result = ForkBoundedProcess.run(path, args)
        return result.status == 0 ? result.output : nil
    }

}

/// Serialized ownership of a persistent system setting. A crash-safe lease is written
/// before mutation and a launchd recovery worker waits for our advisory lock to close.
/// Test bundles never mutate pmset, even if a copied config enables Auto.
final class SleepGuardOwnership: @unchecked Sendable {
    struct Result { let blocked: Bool?; let error: String? }
    private let queue = DispatchQueue(label: "ghostty.sleep.ownership")
    private var stopped = false
    private var lockFD: Int32 = -1
    private var ownsBlock = false
    private let token = UUID().uuidString
    private let state: URL
    private let allowed: Bool
    private let read: @Sendable () -> Bool?
    private let set: @Sendable (Bool, Bool, Int32) -> String?
    private let recovery: (@Sendable () -> String?)?

    init(state: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/state/ghostty"),
         allowed: Bool = Ghostty.isDailyForkProfile,
         read: @escaping @Sendable () -> Bool? = { LidSleep.isBlocked() },
         set: @escaping @Sendable (Bool, Bool, Int32) -> String? = { LidSleep.setBlocked($0, allowPrompt: $1, ownershipFD: $2) },
         recovery: (@Sendable () -> String?)? = nil) {
        self.state = state; self.allowed = allowed; self.read = read; self.set = set; self.recovery = recovery
    }
    private let recoveryLabel = "com.mauria.ghostty-sleep-recovery"
    private var lease: URL { state.appendingPathComponent("sleep-guard.lease") }
    private var lockFile: URL { state.appendingPathComponent("sleep-guard.lock") }

    func reconcile(automatic: Bool, wantsBlock: Bool, canAcquire: Bool) -> Result {
        queue.sync {
            guard !stopped else { return Result(blocked: read(), error: nil) }
            guard allowed else { return Result(blocked: read(), error: nil) }
            if ownsBlock && (!automatic || !wantsBlock) { return release() }
            if ownsBlock && canAcquire && read() == false {
                let error = set(true, false, lockFD)
                return Result(blocked: read(), error: error)
            }
            guard automatic, wantsBlock, canAcquire, !ownsBlock else {
                return Result(blocked: read(), error: nil)
            }
            if let error = acquireLock() { return Result(blocked: read(), error: error) }
            // A prior owner may have crashed before its recovery worker got the lock.
            if FileManager.default.fileExists(atPath: lease.path) {
                if let error = set(false, false, lockFD) {
                    closeLock(); return Result(blocked: read(), error: "Sleep lease recovery failed: \(error)")
                }
                guard read() == false else {
                    closeLock(); return Result(blocked: read(), error: "Stale sleep lease recovery could not be verified.")
                }
                do { try FileManager.default.removeItem(at: lease) } catch { closeLock(); return Result(blocked: read(), error: "Could not remove stale sleep lease: \(error)") }
            }
            guard read() == false else {
                closeLock() // An external/manual block is never ours to clear.
                return Result(blocked: read(), error: nil)
            }
            do { try token.write(to: lease, atomically: true, encoding: .utf8) } catch { closeLock(); return Result(blocked: false, error: "Could not persist sleep lease: \(error)") }
            if let error = installRecovery() {
                try? FileManager.default.removeItem(at: lease)
                closeLock(); return Result(blocked: false, error: error)
            }
            // Retain ownership even if pmset fails or times out: a late/partial mutation
            // must still be released on disable, quit, or by crash recovery.
            ownsBlock = true
            let error = set(true, false, lockFD)
            return Result(blocked: read(), error: error)
        }
    }

    func manual(block: Bool) -> Result {
        queue.sync {
            guard !stopped, allowed else {
                return Result(blocked: read(), error: "Lid sleep changes are disabled in isolated test builds.")
            }
            if ownsBlock {
                let released = release()
                if released.error != nil { return released }
            }
            if let error = acquireLock() { return Result(blocked: read(), error: error) }
            defer { closeLock() }
            // Recover a stale automatic lease before an explicit manual takeover.
            if FileManager.default.fileExists(atPath: lease.path) {
                if let error = set(false, false, lockFD) {
                    return Result(blocked: read(), error: error)
                }
                try? FileManager.default.removeItem(at: lease)
            }
            let error = set(block, true, lockFD)
            return Result(blocked: read(), error: error)
        }
    }

    func shutdown() {
        queue.sync {
            stopped = true
            if ownsBlock { _ = release() }
            // Failed release retains the durable lease. Closing gives the recovery
            // worker ownership, so it retries passwordless restoration after exit.
            closeLock()
        }
    }

    private func release() -> Result {
        guard ownsBlock else { return Result(blocked: read(), error: nil) }
        if let error = set(false, false, lockFD) {
            return Result(blocked: read(), error: error)
        }
        guard read() == false else {
            return Result(blocked: read(), error: "Sleep release could not be verified; recovery lease retained.")
        }
        do { try FileManager.default.removeItem(at: lease) } catch { return Result(blocked: false, error: "Could not clear sleep lease: \(error)") }
        ownsBlock = false
        closeLock()
        return Result(blocked: false, error: nil)
    }

    private func acquireLock() -> String? {
        if lockFD >= 0 { return nil }
        do { try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true) } catch { return "Could not create sleep lease directory: \(error)" }
        lockFD = open(lockFile.path, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard lockFD >= 0 else { return "Could not open sleep ownership lock." }
        guard flock(lockFD, LOCK_EX | LOCK_NB) == 0 else {
            closeLock(); return "Another Ghostty instance owns lid sleep; Auto did not change it."
        }
        return nil
    }

    private func closeLock() {
        if lockFD >= 0 { _ = close(lockFD); lockFD = -1 }
    }

    private func installRecovery() -> String? {
        if let recovery { return recovery() }
        // Perl's flock is available on supported macOS and shares the same kernel lock
        // as Darwin.flock. No PID/name heuristic can clear a newer owner's lease.
        let script = #"""
        use strict; use POSIX ();
        my ($lock, $lease, $token) = @ARGV;
        open(my $fh, '+<', $lock) or exit 1;
        flock($fh, 2) or exit 1;
        open(my $lf, '<', $lease) or exit 0;
        local $/; my $owner = <$lf>; close($lf);
        exit 0 unless $owner eq $token;
        my $child = fork(); exit 1 unless defined $child;
        if ($child == 0) {
            POSIX::setpgid(0, 0) == 0 or exit 1;
            exec('/usr/bin/sudo', '-n', '/usr/bin/pmset', '-a', 'disablesleep', '0');
            exit 1;
        }
        $SIG{TERM} = sub { kill('KILL', -$child); kill('KILL', $child); waitpid($child, 0); exit 1; };
        my $deadline = time() + 15;
        while (waitpid($child, POSIX::WNOHANG()) == 0) {
            if (time() >= $deadline) {
                kill('TERM', -$child); select(undef, undef, undef, 0.1);
                kill('KILL', -$child); kill('KILL', $child); waitpid($child, 0); exit 1;
            }
            select(undef, undef, undef, 0.05);
        }
        my $status = $?; kill('KILL', -$child);
        exit 1 if $status != 0;
        unlink($lease) or exit 1;
        exit 0;
        """#
        let plist = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(recoveryLabel).plist")
        let job: [String: Any] = [
            "Label": recoveryLabel,
            "ProgramArguments": ["/usr/bin/perl", "-e", script, lockFile.path, lease.path, token],
            "RunAtLoad": true, "KeepAlive": ["SuccessfulExit": false], "ThrottleInterval": 10,
            "AssociatedBundleIdentifiers": ["com.mitchellh.ghostty"],
        ]
        do {
            try FileManager.default.createDirectory(at: plist.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try PropertyListSerialization.data(fromPropertyList: job, format: .xml, options: 0)
            try data.write(to: plist, options: .atomic)
        } catch { return "Could not persist sleep recovery job: \(error)" }
        _ = command(["bootout", "gui/\(getuid())/\(recoveryLabel)"])
        guard command(["bootstrap", "gui/\(getuid())", plist.path]) == 0 else {
            return "Sleep Auto refused to block: crash recovery watcher could not start."
        }
        return nil
    }

    private func command(_ arguments: [String]) -> Int32 {
        ForkBoundedProcess.run("/bin/launchctl", arguments, timeout: 10).status
    }
}

/// Keeps the Mac awake with the lid closed, either on request (Manual) or while any terminal
/// has a program running in it (Auto). It shows the state in a menu bar status item and in
/// the tab sidebar header, and both open the same menu.
@MainActor
final class SleepGuard: NSObject, ObservableObject, NSMenuDelegate {
    static let shared = SleepGuard()

    enum Mode: String {
        case manual
        case auto
    }

    /// How long Auto waits after the last program finished before allowing sleep again.
    /// Read from the `sleep-guard-grace` config key.
    private(set) var graceSeconds: TimeInterval = 120

    /// The last value read from pmset. Nil when it couldn't be read.
    @Published private(set) var blocked: Bool? {
        didSet { updateStatusItem() }
    }

    @Published private(set) var mode: Mode = .manual

    /// The mode in force: Auto while the overnight switch is on, otherwise the configured
    /// `sleep-guard-mode`, which the switch never rewrites.
    private var effectiveMode: Mode {
        KeepAlive.shared.overnightActive ? .auto : mode
    }

    private var statusItem: NSStatusItem?
    private var timer: Timer?
    private var busy = false

    /// When a program was last seen running. Auto allows sleep once this is older than the
    /// grace period. Starting Auto counts as "just seen", so it doesn't flip instantly.
    private var lastBusy = Date()

    /// Whether the current block was set by Auto, so quitting can undo it.
    private let ownership = SleepGuardOwnership()
    private var generation: UInt64 = 0
    private var terminating = false

    /// How long Auto waits after a failed flip before trying again. The error window stays
    /// up for the same time.
    static let retryDelay: TimeInterval = 30

    /// After Auto fails to flip (no sudo rule), wait before trying again rather than
    /// failing every tick.
    private var retryAfter = Date.distantPast

    // MARK: Lifecycle

    func start() {
        guard timer == nil else { return }

        lastBusy = Date()

        // Kept to restore the menu bar icon; the sidebar button is the only control for now.
        // let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // let menu = NSMenu()
        // menu.delegate = self
        // item.menu = menu
        // statusItem = item
        // updateStatusItem()

        tick()
        // Poll so the icon follows the real setting even when something else changes it.
        timer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(didWake),
            name: NSWorkspace.didWakeNotification, object: nil)
    }

    /// Takes the mode and grace period from the config. Called at launch and on every
    /// config reload, so editing `sleep-guard-mode` in the file or the settings panel
    /// takes effect without a restart.
    func apply(_ config: Ghostty.Config) {
        let newMode = config.sleepGuardMode
        graceSeconds = config.sleepGuardGrace
        NSLog("SleepGuard config: mode=%@ grace=%.0fs", newMode.rawValue, graceSeconds)
        guard newMode != mode else { return }
        mode = newMode
        generation &+= 1
        retryAfter = .distantPast
        lastBusy = Date()
        if timer != nil { tick() }
    }

    /// Called when the overnight switch turns on or off, which changes the effective mode.
    func overnightDidChange() {
        NSLog("SleepGuard: effective mode is now %@ (configured mode %@)", effectiveMode.rawValue, mode.rawValue)
        generation &+= 1
        retryAfter = .distantPast
        lastBusy = Date()
        if timer != nil { tick() }
    }

    /// Called as Ghostty quits. A block Auto set shouldn't outlive the app, or a forgotten
    /// one drains a laptop in a bag. Runs synchronously because the process is exiting.
    func willTerminate() {
        terminating = true
        generation &+= 1
        timer?.invalidate()
        ownership.shutdown()
    }

    @objc private func didWake() {
        tick()
    }

    // MARK: Reading and Auto

    private func tick() {
        guard !busy, !terminating else { return }
        busy = true
        let requestedGeneration = generation
        let automatic = effectiveMode == .auto
        let running = automatic && Self.anyProgramRunning()
        if running { lastBusy = Date() }
        let wantsBlock = automatic && (running || (blocked == true && Date().timeIntervalSince(lastBusy) < graceSeconds))
        let canAcquire = Date() >= retryAfter
        Task {
            let result = await Task.detached { [ownership] in
                ownership.reconcile(automatic: automatic, wantsBlock: wantsBlock, canAcquire: canAcquire)
            }.value
            busy = false
            guard !terminating else { return }
            blocked = result.blocked
            if let error = result.error {
                retryAfter = Date().addingTimeInterval(Self.retryDelay)
                SleepGuardErrorPanel.shared.show(message: error, closeAfter: Self.retryDelay)
            }
            // A queued config/overnight disable must release an acquisition that finished late.
            if generation != requestedGeneration { tick() }
        }
    }

    /// Block while a program is running. After the last one finishes, hold an existing
    /// block for the grace period, then allow sleep.
    private func desiredBlocked(current: Bool) -> Bool {
        let now = Date()
        if Self.anyProgramRunning() {
            lastBusy = now
            return true
        }
        return current && now.timeIntervalSince(lastBusy) < graceSeconds
    }

    /// Whether any terminal in Ghostty has a program running in it.
    ///
    /// A program is running when the terminal's foreground process group leader is not
    /// an idle shell. This reads the live foreground PID from the PTY and looks up its
    /// executable, so it needs nothing from the shell. `needsConfirmQuit` was rejected
    /// because it follows the `confirm-close-surface` setting (always false when that is
    /// `false`) and, in its default mode, relies on shell integration marking the prompt,
    /// so a terminal without integration reads as busy forever. The cost of this signal is
    /// that work done inside the shell itself (a builtin loop, a background job) reads as
    /// idle, and a nested shell or an interactive REPL reads as running only if it isn't
    /// itself a shell. The one exception is a background `claude` or `codex` anywhere on
    /// the terminal's TTY, which counts (see `agentRunning`).
    private static func anyProgramRunning() -> Bool {
        var devices = Set<dev_t>()
        let controllers = NSApp.windows.compactMap { $0.windowController as? BaseTerminalController }
        for controller in controllers {
            for view in controller.surfaceTree.root?.leaves() ?? [] {
                if let pid = view.surfaceModel?.foregroundPID,
                   let name = executableName(of: pid),
                   !idleShells.contains(name) { return true }
                if let tty = view.surfaceModel?.ttyName {
                    var info = stat()
                    if stat(tty, &info) == 0 { devices.insert(info.st_rdev) }
                }
            }
        }
        return !devices.isEmpty && agentRunning(onDevices: devices)
    }

    /// Executable names of coding agents. One of these running on a terminal's TTY counts
    /// as a running program even in the background; other background jobs do not.
    private static let agentNames: Set<String> = ["claude", "codex"]

    /// Whether any process attached to one of the given TTY devices is a coding agent.
    /// Lists all processes with one `sysctl(KERN_PROC_ALL)` call and matches `e_tdev`, so
    /// nothing is spawned. The name is checked against the kernel's process name and then
    /// the executable path, which covers a binary reached through a symlink.
    private static func agentRunning(onDevices devices: Set<dev_t>) -> Bool {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return false }
        // Leave slack for processes that start between the two calls.
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: size / MemoryLayout<kinfo_proc>.stride + 16)
        size = procs.count * MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, 3, &procs, &size, nil, 0) == 0 else { return false }
        let count = size / MemoryLayout<kinfo_proc>.stride

        for index in 0..<count {
            var proc = procs[index]
            guard devices.contains(proc.kp_eproc.e_tdev) else { continue }
            let comm = withUnsafePointer(to: &proc.kp_proc.p_comm) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXCOMLEN) + 1) { String(cString: $0) }
            }
            if agentNames.contains(comm) { return true }
            if let name = executableName(of: Int(proc.kp_proc.p_pid)), agentNames.contains(name) {
                return true
            }
        }
        return false
    }

    static let idleShells: Set<String> = [
        "sh", "bash", "zsh", "fish", "dash", "ksh", "tcsh", "csh",
        "nu", "elvish", "xonsh", "pwsh",
        // The brief login(1) step before it execs the shell.
        "login",
    ]

    static func executableName(of pid: Int) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(Int32(pid), &buffer, UInt32(buffer.count)) > 0 else { return nil }
        let path = String(cString: buffer)
        return (path as NSString).lastPathComponent
    }

    // MARK: Display

    var symbolName: String {
        switch blocked {
        case true: "sun.max.fill"
        case false: "moon.zzz.fill"
        default: "questionmark.circle"
        }
    }

    var summary: String {
        switch blocked {
        case true: "Lid sleep blocked"
        case false: "Lid sleep normal"
        default: "Lid sleep unknown"
        }
    }

    private var tooltip: String {
        switch blocked {
        case true:
            "Lid sleep BLOCKED — your Mac stays awake with the lid closed.\n"
                + "Keep it plugged in; this does not stop the battery draining."
        case false:
            "Lid sleep NORMAL — your Mac sleeps when you close the lid."
        default:
            "Couldn't read the sleep setting from pmset."
        }
    }

    // Kept to restore the menu bar icon (see `start()`).
    private func updateStatusItem() {
        // guard let button = statusItem?.button else { return }
        // let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: summary)
        // image?.isTemplate = true
        // button.image = image
        // button.toolTip = tooltip
        // // Falls back to text if the symbol is ever unavailable.
        // button.title = image == nil ? (blocked == true ? "Awake" : "Sleep") : ""
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        tick()
        fill(menu)
    }

    /// Shows the menu at the mouse, for the sidebar button.
    func popUpMenu() {
        tick()
        let menu = NSMenu()
        fill(menu)
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    private func fill(_ menu: NSMenu) {
        menu.removeAllItems()

        let stateTitle: String
        switch blocked {
        case true: stateTitle = "Lid sleep: BLOCKED"
        case false: stateTitle = "Lid sleep: NORMAL"
        default: stateTitle = "Lid sleep: unknown"
        }
        let state = NSMenuItem(title: stateTitle, action: nil, keyEquivalent: "")
        state.isEnabled = false
        menu.addItem(state)
        menu.addItem(.separator())

        if effectiveMode == .auto {
            let title = KeepAlive.shared.overnightActive
                ? "Overnight run: Auto mode is managing this" : "Auto mode is managing this"
            let managed = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            managed.isEnabled = false
            menu.addItem(managed)
        } else if let blocked {
            let title = blocked ? "Let it sleep when the lid closes" : "Keep it awake with the lid closed"
            let toggle = NSMenuItem(title: title, action: #selector(toggleManually), keyEquivalent: "")
            toggle.target = self
            menu.addItem(toggle)
        }
        menu.addItem(.separator())

        let modeItem = NSMenuItem(title: "Mode", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        for (title, value) in [("Manual", Mode.manual), ("Auto", Mode.auto)] {
            let item = NSMenuItem(title: title, action: #selector(selectMode(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = value.rawValue
            item.state = mode == value ? .on : .off
            submenu.addItem(item)
        }
        modeItem.submenu = submenu
        menu.addItem(modeItem)
    }

    @objc private func selectMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let newMode = Mode(rawValue: raw), newMode != mode else { return }
        setMode(newMode)
    }

    /// Writes `sleep-guard-mode` to the config file and reloads. The reload calls
    /// `apply(_:)`, which changes the mode.
    func setMode(_ newMode: Mode) {
        if let error = ConfigFile.set("sleep-guard-mode", to: newMode.rawValue, underForkHeader: true) {
            SleepGuardErrorPanel.shared.show(message: error, closeAfter: nil)
        }
    }

    @objc private func toggleManually() {
        guard let current = blocked, !busy, !terminating, effectiveMode == .manual else { return }
        busy = true
        Task {
            let result = await Task.detached { [ownership] in ownership.manual(block: !current) }.value
            busy = false
            guard !terminating else { return }
            blocked = result.blocked
            if let error = result.error { SleepGuardErrorPanel.shared.show(message: error, closeAfter: nil) }
        }
    }

}

/// A small non-modal window that reports a failed flip. One instance is reused, so repeated
/// failures replace the text instead of stacking windows.
@MainActor
final class SleepGuardErrorPanel {
    static let shared = SleepGuardErrorPanel()

    private var panel: NSPanel?
    private var label: NSTextField?
    private var closeTimer: Timer?

    /// Shows the message. With `closeAfter`, the window closes itself after that many
    /// seconds unless the user closed it first.
    func show(message: String, closeAfter: TimeInterval?) {
        NSLog("SleepGuard error: %@", message.replacingOccurrences(of: "\n", with: " | "))
        let panel = self.panel ?? makePanel()
        label?.stringValue = message
        closeTimer?.invalidate()
        closeTimer = nil
        if let closeAfter {
            closeTimer = Timer.scheduledTimer(withTimeInterval: closeAfter, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.panel?.close() }
            }
        }
        panel.orderFrontRegardless()
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 130),
            styleMask: [.titled, .closable, .utilityWindow],
            backing: .buffered, defer: false)
        panel.title = "Sleep Guard"
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false

        let label = NSTextField(wrappingLabelWithString: "")
        label.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView?.addSubview(label)
        if let content = panel.contentView {
            NSLayoutConstraint.activate([
                label.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
                label.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
                label.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
                label.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -16),
            ])
        }
        panel.center()
        self.panel = panel
        self.label = label
        return panel
    }
}
