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
