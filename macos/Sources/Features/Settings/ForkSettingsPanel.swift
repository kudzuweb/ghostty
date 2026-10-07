import AppKit
import SwiftUI

/// The fork's settings window. It edits the live config file through `ConfigFile`, so a
/// person, an agent and this panel all change the same file.
///
/// To add a section, write a view that wraps its controls in `ForkSettingsSection`, and
/// list it in `ForkSettingsView.body`.
@MainActor
final class ForkSettingsPanelController: NSWindowController {
    static let shared = ForkSettingsPanelController()

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 640),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false)
        window.title = "Settings"
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: ForkSettingsView())
        window.setContentSize(NSSize(width: 460, height: 640))
        window.minSize = NSSize(width: 400, height: 420)
        window.center()
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

/// A titled group of controls. Every section of the panel uses it, so they look alike.
private struct ForkSettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            content
        }
    }
}

private struct ForkSettingsView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    AppearanceSection()
                    Divider()
                    SleepGuardSection()
                    Divider()
                    KeepAliveSection()
                    Divider()
                    UsageCutoffSection()
                }
                .padding(20)
            }
            Divider()
            FooterBar()
        }
        .frame(minWidth: 400, minHeight: 420)
    }
}

// MARK: Appearance

private struct AppearanceSection: View {
    @State private var currentTheme: String = ConfigFile.value(of: "theme") ?? ""
    @State private var search = ""
    @State private var errorMessage: String?

    private let themes = ThemeCatalog.names()

    private var filtered: [String] {
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return themes.names }
        return themes.names.filter { $0.localizedCaseInsensitiveContains(query) }
    }

    private var titlebarStyle: String {
        (NSApp.delegate as? AppDelegate)?.ghostty.config.macosTitlebarStyle.rawValue ?? "unknown"
    }

    var body: some View {
        ForkSettingsSection(title: "Appearance") {
            TextField("Search themes", text: $search)
                .textFieldStyle(.roundedBorder)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(filtered, id: \.self) { name in
                        Button { choose(name) } label: {
                            HStack {
                                Image(systemName: "checkmark")
                                    .opacity(name == currentTheme ? 1 : 0)
                                    .frame(width: 16)
                                Text(name)
                                if themes.custom.contains(name) {
                                    Text("custom").font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                            .padding(.vertical, 4)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(height: 220)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.15)))

            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.red)
            }
            if !currentTheme.isEmpty, !themes.names.contains(currentTheme) {
                Text("The current theme setting is \"\(currentTheme)\", which is not in the list.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            HStack {
                Text("Sidebar style (macos-titlebar-style)")
                Spacer()
                Text(titlebarStyle).foregroundStyle(.secondary)
            }
            .font(.callout)
        }
    }

    private func choose(_ name: String) {
        errorMessage = ConfigFile.set("theme", to: name)
        if errorMessage == nil { currentTheme = name }
    }
}

/// The themes Ghostty can load: the user's own folder and the ones bundled in the app.
private enum ThemeCatalog {
    static func names() -> (names: [String], custom: Set<String>) {
        let custom = Set(list(userThemesDirectory))
        let bundled = Set(list(bundledThemesDirectory))
        let all = custom.union(bundled).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        return (all, custom)
    }

    /// `$XDG_CONFIG_HOME/ghostty/themes`, or `~/.config/ghostty/themes`. This is where the
    /// core looks for a user's themes.
    private static var userThemesDirectory: URL {
        let base = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"]
            .flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config")
        return base.appendingPathComponent("ghostty/themes")
    }

    private static var bundledThemesDirectory: URL? {
        Bundle.main.resourceURL?.appendingPathComponent("ghostty/themes")
    }

    private static func list(_ directory: URL?) -> [String] {
        guard let directory,
              let entries = try? FileManager.default.contentsOfDirectory(atPath: directory.path)
        else { return [] }
        return entries.filter { !$0.hasPrefix(".") }
    }
}

// MARK: Sleep guard

private struct SleepGuardSection: View {
    @ObservedObject private var sleepGuard = SleepGuard.shared
    @State private var graceText: String = ""
    @State private var errorMessage: String?

    var body: some View {
        ForkSettingsSection(title: "Sleep guard") {
            Picker("Mode", selection: Binding(
                get: { sleepGuard.mode },
                set: { sleepGuard.setMode($0) }
            )) {
                Text("Manual").tag(SleepGuard.Mode.manual)
                Text("Auto").tag(SleepGuard.Mode.auto)
            }
            .pickerStyle(.segmented)

            HStack {
                Text("Grace period (seconds)")
                Spacer()
                TextField("120", text: $graceText)
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 80)
                    .onSubmit(commitGrace)
            }
            Text("In Auto mode, lid sleep stays blocked this long after the last program in any terminal finishes.")
                .font(.caption).foregroundStyle(.secondary)

            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.red)
            }
        }
        .onAppear {
            graceText = String(Int(sleepGuard.graceSeconds))
        }
    }

    private func commitGrace() {
        guard let seconds = Int(graceText.trimmingCharacters(in: .whitespaces)), seconds >= 0 else {
            errorMessage = "Enter a whole number of seconds."
            return
        }
        errorMessage = ConfigFile.set("sleep-guard-grace", to: "\(seconds)s", underForkHeader: true)
    }
}

// MARK: Keep alive

private struct KeepAliveSection: View {
    @State private var maxCrashes = ""
    @State private var serverInterval = ""
    @State private var rateInterval = ""
    @State private var eventsFile = ""
    @State private var background = KeepAlive.BackgroundMode.failed
    @State private var relaunchGhostty = false
    @State private var errorMessage: String?

    var body: some View {
        ForkSettingsSection(title: "Keep alive") {
            Text("Turn keep alive on for a tab from its right-click menu.")
                .font(.caption).foregroundStyle(.secondary)

            field("Crashes allowed per hour", text: $maxCrashes, placeholder: "3") {
                guard let count = Int(maxCrashes.trimmingCharacters(in: .whitespaces)), count >= 0 else {
                    errorMessage = "Enter a whole number of crashes."
                    return
                }
                set("keep-alive-max-crashes", "\(count)")
            }
            field("Server error retry interval", text: $serverInterval, placeholder: "5m") {
                setDuration("keep-alive-server-error-interval", serverInterval)
            }
            field("Rate limit retry interval", text: $rateInterval, placeholder: "15m") {
                setDuration("keep-alive-rate-limit-interval", rateInterval)
            }

            Picker("Background sessions", selection: Binding(
                get: { background },
                set: { background = $0; set("keep-alive-background", $0.rawValue) }
            )) {
                Text("Respawn failed").tag(KeepAlive.BackgroundMode.failed)
                Text("Off").tag(KeepAlive.BackgroundMode.off)
            }

            Toggle("Reopen Ghostty after a crash", isOn: Binding(
                get: { relaunchGhostty },
                set: { relaunchGhostty = $0; set("keep-alive-relaunch-ghostty", $0 ? "true" : "false") }
            ))

            field("Events file", text: $eventsFile, placeholder: "~/.local/state/ghostty/keep-alive-events.jsonl",
                  width: 240) {
                let path = eventsFile.trimmingCharacters(in: .whitespaces)
                guard !path.isEmpty else {
                    errorMessage = "Enter a file path."
                    return
                }
                set("keep-alive-events-file", path)
            }

            Text("Intervals are Ghostty durations such as 30s, 5m or 1h. Press Return to apply a field.")
                .font(.caption).foregroundStyle(.secondary)
            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.red)
            }
        }
        .onAppear(perform: load)
    }

    private func field(
        _ title: String,
        text: Binding<String>,
        placeholder: String,
        width: CGFloat = 80,
        commit: @escaping () -> Void
    ) -> some View {
        HStack {
            Text(title)
            Spacer()
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: width)
                .onSubmit(commit)
        }
    }

    private func load() {
        let settings = KeepAlive.shared.settings
        maxCrashes = String(settings.maxCrashes)
        serverInterval = ConfigFile.value(of: "keep-alive-server-error-interval") ?? "5m"
        rateInterval = ConfigFile.value(of: "keep-alive-rate-limit-interval") ?? "15m"
        eventsFile = ConfigFile.value(of: "keep-alive-events-file") ?? ""
        background = settings.background
        relaunchGhostty = settings.relaunchGhostty
    }

    private func set(_ key: String, _ value: String) {
        errorMessage = ConfigFile.set(key, to: value, underForkHeader: true)
    }

    /// Ghostty rejects a bare number as a duration, so require a unit.
    private func setDuration(_ key: String, _ text: String) {
        let value = text.trimmingCharacters(in: .whitespaces)
        guard value.range(of: #"^(\d+\s*(y|w|d|h|m|s|ms|us|µs|ns)\s*)+$"#, options: .regularExpression) != nil else {
            errorMessage = "Enter a duration with a unit, such as 30s or 5m."
            return
        }
        set(key, value)
    }
}

// MARK: Usage cutoff and overnight

private struct UsageCutoffSection: View {
    @ObservedObject private var keepAlive = KeepAlive.shared
    @State private var enabled = false
    @State private var stopSessions = false
    @State private var workdayStart = ""
    @State private var usable = ""
    @State private var latestReset = ""
    @State private var margin = ""
    @State private var warning = ""
    @State private var errorMessage: String?

    var body: some View {
        ForkSettingsSection(title: "Usage cutoff") {
            Toggle("Overnight run", isOn: Binding(
                get: { keepAlive.overnightActive },
                set: { keepAlive.setOvernight($0) }
            ))
            Text("Until the workday starts, keeps every tab running an agent alive, applies the usage cutoff, "
                + "sets the sleep guard to Auto and silences keep alive notifications. It turns itself off "
                + "at the workday start.")
                .font(.caption).foregroundStyle(.secondary)

            Divider()

            Toggle("Usage cutoff for tabs with keep alive", isOn: Binding(
                get: { enabled },
                set: { enabled = $0; set("usage-cutoff", $0 ? "true" : "false") }
            ))
            Text("Winds work down so the workday starts in a usage window that is mostly unused. Idle Claude "
                + "Code sessions are asked to wrap up before the cutoff, and nothing is relaunched or nudged "
                + "after it until the workday starts.")
                .font(.caption).foregroundStyle(.secondary)

            field("Workday start (HH:MM)", text: $workdayStart, placeholder: "10:00") {
                let value = workdayStart.trimmingCharacters(in: .whitespaces)
                guard value.range(of: #"^([01]?\d|2[0-3]):[0-5]\d$"#, options: .regularExpression) != nil else {
                    errorMessage = "Enter a 24-hour time such as 10:00 or 8:30."
                    return
                }
                set("usage-cutoff-workday-start", value)
            }
            field("Usable part of the window", text: $usable, placeholder: "2h") {
                setDuration("usage-cutoff-usable", usable)
            }
            field("Latest reset after workday start", text: $latestReset, placeholder: "2h") {
                setDuration("usage-cutoff-latest-reset", latestReset)
            }
            field("Margin before the cutoff", text: $margin, placeholder: "15m") {
                setDuration("usage-cutoff-margin", margin)
            }
            field("Wrap-up warning before the cutoff", text: $warning, placeholder: "25m") {
                setDuration("usage-cutoff-warning", warning)
            }

            Toggle("Stop sessions at the cutoff", isOn: Binding(
                get: { stopSessions },
                set: { stopSessions = $0; set("usage-cutoff-stop-sessions", $0 ? "true" : "false") }
            ))
            Text("Sends SIGTERM to each covered session when the cutoff is reached, as the old watchdog did. "
                + "Off by default.")
                .font(.caption).foregroundStyle(.secondary)

            Text("Durations are Ghostty durations such as 30m or 2h. Press Return to apply a field.")
                .font(.caption).foregroundStyle(.secondary)
            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.red)
            }
        }
        .onAppear(perform: load)
    }

    private func field(
        _ title: String,
        text: Binding<String>,
        placeholder: String,
        commit: @escaping () -> Void
    ) -> some View {
        HStack {
            Text(title)
            Spacer()
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: 80)
                .onSubmit(commit)
        }
    }

    private func load() {
        let settings = KeepAlive.shared.settings
        enabled = settings.usageCutoff
        stopSessions = settings.cutoffStopSessions
        workdayStart = ConfigFile.value(of: "usage-cutoff-workday-start") ?? "10:00"
        usable = ConfigFile.value(of: "usage-cutoff-usable") ?? "2h"
        latestReset = ConfigFile.value(of: "usage-cutoff-latest-reset") ?? "2h"
        margin = ConfigFile.value(of: "usage-cutoff-margin") ?? "15m"
        warning = ConfigFile.value(of: "usage-cutoff-warning") ?? "25m"
    }

    private func set(_ key: String, _ value: String) {
        errorMessage = ConfigFile.set(key, to: value, underForkHeader: true)
    }

    private func setDuration(_ key: String, _ text: String) {
        let value = text.trimmingCharacters(in: .whitespaces)
        guard value.range(of: #"^(\d+\s*(y|w|d|h|m|s|ms|us|µs|ns)\s*)+$"#, options: .regularExpression) != nil else {
            errorMessage = "Enter a duration with a unit, such as 30m or 2h."
            return
        }
        set(key, value)
    }
}

// MARK: Footer

private struct FooterBar: View {
    private static let forkNotes = URL(string: "https://github.com/kudzuweb/ghostty/blob/main/FORK.md")

    var body: some View {
        HStack {
            Button("Open config file") {
                Ghostty.App.openConfig()
            }
            Button("Fork notes") {
                if let url = Self.forkNotes { NSWorkspace.shared.open(url) }
            }
            Spacer()
        }
        .padding(12)
    }
}
