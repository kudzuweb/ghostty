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

    static let modeKey = "SleepGuardMode"

    /// How long Auto waits after the last program finished before allowing sleep again.
    static let graceKey = "SleepGuardGraceSeconds"
    static let defaultGraceSeconds: TimeInterval = 120

    /// The last value read from pmset. Nil when it couldn't be read.
    @Published private(set) var blocked: Bool? {
        didSet { updateStatusItem() }
    }

    @Published private(set) var mode: Mode = .manual

    private var statusItem: NSStatusItem?
    private var timer: Timer?
    private var busy = false

    /// When a program was last seen running. Auto allows sleep once this is older than the
    /// grace period. Starting Auto counts as "just seen", so it doesn't flip instantly.
    private var lastBusy = Date()

    /// Whether the current block was set by Auto, so quitting can undo it.
    private var autoBlocked = false

    /// After Auto fails to flip (no sudo rule), wait before trying again rather than
    /// failing every tick.
    private var retryAfter = Date.distantPast

    private var graceSeconds: TimeInterval {
        let value = UserDefaults.ghostty.object(forKey: Self.graceKey) as? Double
        return value ?? Self.defaultGraceSeconds
    }

    // MARK: Lifecycle

    func start() {
        guard statusItem == nil else { return }

        if let raw = UserDefaults.ghostty.string(forKey: Self.modeKey), let saved = Mode(rawValue: raw) {
            mode = saved
        }
        lastBusy = Date()

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
        updateStatusItem()

        tick()
        // Poll so the icon follows the real setting even when something else changes it.
        timer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(didWake),
            name: NSWorkspace.didWakeNotification, object: nil)
    }

    /// Called as Ghostty quits. A block Auto set shouldn't outlive the app, or a forgotten
    /// one drains a laptop in a bag. Runs synchronously because the process is exiting.
    func willTerminate() {
        timer?.invalidate()
        guard mode == .auto, autoBlocked, LidSleep.isBlocked() == true else { return }
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

            if mode == .auto, let read = current, Date() >= retryAfter {
                let desired = desiredBlocked(current: read)
                // Only call pmset when the wanted state differs from the read state.
                if desired != read {
                    let error = await Task.detached {
                        LidSleep.setBlocked(desired, allowPrompt: false)
                    }.value
                    if error == nil {
                        autoBlocked = desired
                    } else {
                        retryAfter = Date().addingTimeInterval(60)
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
    /// itself a shell.
    private static func anyProgramRunning() -> Bool {
        let controllers = NSApp.windows.compactMap { $0.windowController as? BaseTerminalController }
        for controller in controllers {
            for view in controller.surfaceTree.root?.leaves() ?? [] {
                guard let pid = view.surfaceModel?.foregroundPID,
                      let name = executableName(of: pid) else { continue }
                if !idleShells.contains(name) { return true }
            }
        }
        return false
    }

    private static let idleShells: Set<String> = [
        "sh", "bash", "zsh", "fish", "dash", "ksh", "tcsh", "csh",
        "nu", "elvish", "xonsh", "pwsh",
        // The brief login(1) step before it execs the shell.
        "login",
    ]

    private static func executableName(of pid: Int) -> String? {
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

    private func updateStatusItem() {
        guard let button = statusItem?.button else { return }
        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: summary)
        image?.isTemplate = true
        button.image = image
        button.toolTip = tooltip
        // Falls back to text if the symbol is ever unavailable.
        button.title = image == nil ? (blocked == true ? "Awake" : "Sleep") : ""
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

        if mode == .auto {
            let managed = NSMenuItem(title: "Auto mode is managing this", action: nil, keyEquivalent: "")
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
        mode = newMode
        UserDefaults.ghostty.set(raw, forKey: Self.modeKey)
        // A manual choice owns the setting from here, so quitting must not undo it.
        autoBlocked = false
        retryAfter = .distantPast
        lastBusy = Date()
        tick()
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
                let alert = NSAlert()
                alert.messageText = "Sleep Guard"
                alert.informativeText = error
                alert.alertStyle = .warning
                alert.runModal()
            }
        }
    }
}
