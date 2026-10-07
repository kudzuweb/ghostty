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
            return line.contains("1")
        }
        // pmset omits the line entirely on some systems when the flag is off.
        return false
    }

    /// Sets the flag. Tries passwordless sudo first. With `allowPrompt`, falls back to a
    /// standard macOS authorization prompt. Returns nil on success, or why it failed.
    ///
    /// The argument strings are exactly what the NOPASSWD sudoers rule matches.
    nonisolated static func setBlocked(_ blocked: Bool, allowPrompt: Bool) -> String? {
        let target = blocked ? "1" : "0"
        if runStatus("/usr/bin/sudo", ["-n", "/usr/bin/pmset", "-a", "disablesleep", target]) == 0 {
            return nil
        }
        guard allowPrompt else {
            return "sudo -n /usr/bin/pmset -a disablesleep \(target) failed"
        }

        let script = "do shell script \"/usr/bin/pmset -a disablesleep \(target)\" with administrator privileges"
        if runStatus("/usr/bin/osascript", ["-e", script]) == 0 {
            return nil
        }
        return "Couldn't change the setting. If you cancelled the password prompt, try again."
    }

    @discardableResult
    nonisolated private static func runStatus(_ path: String, _ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return -1 }
        p.waitUntilExit()
        return p.terminationStatus
    }

    nonisolated private static func run(_ path: String, _ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8)
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
    private var autoBlocked = false

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
        // A manual choice owns the setting from here, so quitting must not undo it.
        autoBlocked = false
        retryAfter = .distantPast
        lastBusy = Date()
        if timer != nil { tick() }
    }

    /// Called when the overnight switch turns on or off, which changes the effective mode.
    func overnightDidChange() {
        NSLog("SleepGuard: effective mode is now %@ (configured mode %@)", effectiveMode.rawValue, mode.rawValue)
        // Going back to Manual must not leave behind the block the overnight Auto set.
        let releaseBlock = autoBlocked && effectiveMode == .manual
        if releaseBlock {
            Task {
                let error = await Task.detached { LidSleep.setBlocked(false, allowPrompt: false) }.value
                if let error { NSLog("SleepGuard: couldn't release the overnight block: %@", error) }
                blocked = await Task.detached { LidSleep.isBlocked() }.value
            }
        }
        autoBlocked = false
        retryAfter = .distantPast
        lastBusy = Date()
        if timer != nil { tick() }
    }

    /// Called as Ghostty quits. A block Auto set shouldn't outlive the app, or a forgotten
    /// one drains a laptop in a bag. Runs synchronously because the process is exiting.
    func willTerminate() {
        timer?.invalidate()
        guard effectiveMode == .auto, autoBlocked, LidSleep.isBlocked() == true else { return }
        _ = LidSleep.setBlocked(false, allowPrompt: false)
    }

    @objc private func didWake() {
        tick()
    }

    // MARK: Reading and Auto

    private func tick() {
        guard !busy else { return }
        busy = true
        Task {
            var current = await Task.detached { LidSleep.isBlocked() }.value
            blocked = current

            if effectiveMode == .auto, let read = current, Date() >= retryAfter {
                let desired = desiredBlocked(current: read)
                // Only call pmset when the wanted state differs from the read state.
                if desired != read {
                    let error = await Task.detached {
                        LidSleep.setBlocked(desired, allowPrompt: false)
                    }.value
                    if let error {
                        retryAfter = Date().addingTimeInterval(Self.retryDelay)
                        SleepGuardErrorPanel.shared.show(
                            message: "Auto mode couldn't change lid sleep.\n\(error)\n\n"
                                + "Retrying in \(Int(Self.retryDelay)) seconds.",
                            closeAfter: Self.retryDelay)
                    } else {
                        autoBlocked = desired
                    }
                    current = await Task.detached { LidSleep.isBlocked() }.value
                    blocked = current
                }
            }
            busy = false
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
        guard let current = blocked, !busy else { return }
        busy = true
        let target = !current
        Task {
            let error = await Task.detached {
                LidSleep.setBlocked(target, allowPrompt: true)
            }.value
            blocked = await Task.detached { LidSleep.isBlocked() }.value
            busy = false
            if let error {
                SleepGuardErrorPanel.shared.show(message: error, closeAfter: nil)
            }
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
