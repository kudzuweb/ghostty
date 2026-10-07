import Testing
@testable import Ghostty
@testable import GhosttyKit
import SwiftUI

@Suite
struct ConfigTests {
    // MARK: - Boolean Properties

    @Test func initialWindowDefaultsToTrue() throws {
        let config = try TemporaryConfig("")
        #expect(config.initialWindow == true)
    }

    @Test func initialWindowSetToFalse() throws {
        let config = try TemporaryConfig("initial-window = false")
        #expect(config.initialWindow == false)
    }

    @Test func quitAfterLastWindowClosedDefaultsToFalse() throws {
        let config = try TemporaryConfig("")
        #expect(config.shouldQuitAfterLastWindowClosed == false)
    }

    @Test func quitAfterLastWindowClosedSetToTrue() throws {
        let config = try TemporaryConfig("quit-after-last-window-closed = true")
        #expect(config.shouldQuitAfterLastWindowClosed == true)
    }

    @Test func windowStepResizeDefaultsToFalse() throws {
        let config = try TemporaryConfig("")
        #expect(config.windowStepResize == false)
    }

    @Test func focusFollowsMouseDefaultsToFalse() throws {
        let config = try TemporaryConfig("")
        #expect(config.focusFollowsMouse == false)
    }

    @Test func focusFollowsMouseSetToTrue() throws {
        let config = try TemporaryConfig("focus-follows-mouse = true")
        #expect(config.focusFollowsMouse == true)
    }

    @Test func windowDecorationsDefaultsToTrue() throws {
        let config = try TemporaryConfig("")
        #expect(config.windowDecorations == true)
    }

    @Test func windowDecorationsNone() throws {
        let config = try TemporaryConfig("window-decoration = none")
        #expect(config.windowDecorations == false)
    }

    @Test func macosWindowShadowDefaultsToTrue() throws {
        let config = try TemporaryConfig("")
        #expect(config.macosWindowShadow == true)
    }

    @Test func maximizeDefaultsToFalse() throws {
        let config = try TemporaryConfig("")
        #expect(config.maximize == false)
    }

    @Test func maximizeSetToTrue() throws {
        let config = try TemporaryConfig("maximize = true")
        #expect(config.maximize == true)
    }

    // MARK: - String / Optional String Properties

    @Test func titleDefaultsToNil() throws {
        let config = try TemporaryConfig("")
        #expect(config.title == nil)
    }

    @Test func titleSetToCustomValue() throws {
        let config = try TemporaryConfig("title = My Terminal")
        #expect(config.title == "My Terminal")
    }

    @Test func windowTitleFontFamilyDefaultsToNil() throws {
        let config = try TemporaryConfig("")
        #expect(config.windowTitleFontFamily == nil)
    }

    @Test func windowTitleFontFamilySetToValue() throws {
        let config = try TemporaryConfig("window-title-font-family = Menlo")
        #expect(config.windowTitleFontFamily == "Menlo")
    }

    // MARK: - Enum Properties

    @Test func macosTitlebarStyleDefaultsToTransparent() throws {
        let config = try TemporaryConfig("")
        #expect(config.macosTitlebarStyle == .transparent)
    }

    @Test(arguments: [
        ("native", Ghostty.Config.MacOSTitlebarStyle.native),
        ("transparent", Ghostty.Config.MacOSTitlebarStyle.transparent),
        ("tabs", Ghostty.Config.MacOSTitlebarStyle.tabs),
        ("hidden", Ghostty.Config.MacOSTitlebarStyle.hidden),
    ])
    func macosTitlebarStyleValues(raw: String, expected: Ghostty.Config.MacOSTitlebarStyle) throws {
        let config = try TemporaryConfig("macos-titlebar-style = \(raw)")
        #expect(config.macosTitlebarStyle == expected)
    }

    @Test func resizeOverlayDefaultsToAfterFirst() throws {
        let config = try TemporaryConfig("")
        #expect(config.resizeOverlay == .after_first)
    }

    @Test(arguments: [
        ("always", Ghostty.Config.ResizeOverlay.always),
        ("never", Ghostty.Config.ResizeOverlay.never),
        ("after-first", Ghostty.Config.ResizeOverlay.after_first),
    ])
    func resizeOverlayValues(raw: String, expected: Ghostty.Config.ResizeOverlay) throws {
        let config = try TemporaryConfig("resize-overlay = \(raw)")
        #expect(config.resizeOverlay == expected)
    }

    @Test func resizeOverlayPositionDefaultsToCenter() throws {
        let config = try TemporaryConfig("")
        #expect(config.resizeOverlayPosition == .center)
    }

    @Test func macosIconDefaultsToOfficial() throws {
        let config = try TemporaryConfig("")
        #expect(config.macosIcon == .official)
    }

    @Test func macosIconFrameDefaultsToAluminum() throws {
        let config = try TemporaryConfig("")
        #expect(config.macosIconFrame == .aluminum)
    }

    @Test func macosWindowButtonsDefaultsToVisible() throws {
        let config = try TemporaryConfig("")
        #expect(config.macosWindowButtons == .visible)
    }

    @Test func scrollbarDefaultsToSystem() throws {
        let config = try TemporaryConfig("")
        #expect(config.scrollbar == .system)
    }

    @Test func scrollbarSetToNever() throws {
        let config = try TemporaryConfig("scrollbar = never")
        #expect(config.scrollbar == .never)
    }

    // MARK: - Numeric Properties

    @Test func backgroundOpacityDefaultsToOne() throws {
        let config = try TemporaryConfig("")
        #expect(config.backgroundOpacity == 1.0)
    }

    @Test func backgroundOpacitySetToCustom() throws {
        let config = try TemporaryConfig("background-opacity = 0.5")
        #expect(config.backgroundOpacity == 0.5)
    }

    @Test func windowPositionDefaultsToNil() throws {
        let config = try TemporaryConfig("")
        #expect(config.windowPositionX == nil)
        #expect(config.windowPositionY == nil)
    }

    // MARK: - Config Loading

    @Test func loadedIsTrueForValidConfig() throws {
        let config = try TemporaryConfig("")
        #expect(config.loaded == true)
    }

    @Test func unfinalizedConfigIsLoaded() throws {
        let config = try TemporaryConfig("", finalize: false)
        #expect(config.loaded == true)
    }

    @Test func defaultConfigIsLoaded() throws {
        let config = try TemporaryConfig("")
        #expect(config.optionalAutoUpdateChannel != nil) // release or tip
        let config1 = try TemporaryConfig("", finalize: false)
        #expect(config1.optionalAutoUpdateChannel == nil)
    }

    @Test func errorsEmptyForValidConfig() throws {
        let config = try TemporaryConfig("")
        #expect(config.errors.isEmpty)
    }

    @Test func errorsReportedForInvalidConfig() throws {
        let config = try TemporaryConfig("not-a-real-key = value")
        #expect(!config.errors.isEmpty)
    }

    // MARK: - Multiple Config Lines

    @Test func multipleConfigValues() throws {
        let config = try TemporaryConfig("""
        initial-window = false
        quit-after-last-window-closed = true
        maximize = true
        focus-follows-mouse = true
        """)
        #expect(config.initialWindow == false)
        #expect(config.shouldQuitAfterLastWindowClosed == true)
        #expect(config.maximize == true)
        #expect(config.focusFollowsMouse == true)
    }
}

/// Create a temporary config file and delete it when this is deallocated
class TemporaryConfig: Ghostty.Config {
    let temporaryFile: URL

    init(_ configText: String, finalize: Bool = true) throws {
        let temporaryFile = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("ghostty")
        try configText.write(to: temporaryFile, atomically: true, encoding: .utf8)
        self.temporaryFile = temporaryFile
        super.init(config: Self.loadConfig(at: temporaryFile.path(), finalize: finalize, respectForkProfile: false))
    }

    var optionalAutoUpdateChannel: Ghostty.AutoUpdateChannel? {
        guard let config = self.config else { return nil }
        var v: UnsafePointer<Int8>?
        let key = "auto-update-channel"
        guard ghostty_config_get(config, &v, key, UInt(key.lengthOfBytes(using: .utf8))) else { return nil }
        guard let ptr = v else { return nil }
        let str = String(cString: ptr)
        return Ghostty.AutoUpdateChannel(rawValue: str)
    }

    deinit {
        try? FileManager.default.removeItem(at: temporaryFile)
    }
}

@MainActor
struct ForkConfigWriteTests {
    @Test func concurrentHandEditIsPreservedAndReported() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let config = folder.appendingPathComponent("config")
        try "theme = original\n".write(to: config, atomically: true, encoding: .utf8)
        let error = ConfigFile.set("theme", to: "panel", at: config.path, reload: false, beforeReplace: {
            try "theme = original\nfont-size = 17\n".write(to: config, atomically: true, encoding: .utf8)
        })
        #expect(error?.contains("changed during this edit") == true)
        #expect(try String(contentsOf: config, encoding: .utf8) == "theme = original\nfont-size = 17\n")
    }

    @Test func explicitConfigRootParsingKeepsMultipleRootsVisible() {
        #expect(ConfigFile.explicitConfigPaths(["ghostty", "--config-file=/tmp/a"]) == ["/tmp/a"])
        #expect(ConfigFile.explicitConfigPaths(["ghostty", "--config-file", "/tmp/a", "--config-file=/tmp/b"]) == ["/tmp/a", "/tmp/b"])
    }
}

@MainActor
struct ForkGroupRenameTests {
    @Test func occupiedNameCannotMergePresentation() {
        #expect(!TerminalTabGroupStore.canRename("A", to: "B", occupied: ["A", "B"]))
        #expect(TerminalTabGroupStore.canRename("A", to: "C", occupied: ["A", "B"]))
        #expect(TerminalTabGroupStore.canRename("A", to: "A", occupied: ["A", "B"]))
        #expect(!TerminalTabGroupStore.canRename("A", to: "   ", occupied: []))
    }
}

@MainActor
struct ForkGroupRoundtripTests {
    @Test func renameRoundtripReleasesTheOldName() {
        let first = "roundtrip-A-\(UUID())"
        let second = "roundtrip-B-\(UUID())"
        defer {
            TerminalTabGroupStore.removePresentationIfUnused(first, referencedNames: [])
            TerminalTabGroupStore.removePresentationIfUnused(second, referencedNames: [])
        }
        TerminalTabGroupStore.setColor(.purple, for: first)
        TerminalTabGroupStore.setCollapsed(true, for: first)
        #expect(TerminalTabGroupStore.rename(first, to: second))
        TerminalTabGroupStore.removePresentationIfUnused(first, referencedNames: [second])
        #expect(TerminalTabGroupStore.color(for: second) == .purple)
        #expect(TerminalTabGroupStore.isCollapsed(second))
        #expect(!TerminalTabGroupStore.isCollapsed(first))
        #expect(TerminalTabGroupStore.rename(second, to: first))
        TerminalTabGroupStore.removePresentationIfUnused(second, referencedNames: [first])
        #expect(TerminalTabGroupStore.color(for: first) == .purple)
        #expect(TerminalTabGroupStore.isCollapsed(first))
        #expect(!TerminalTabGroupStore.isCollapsed(second))
    }

    @Test func cleanupPreservesGloballyReferencedGroup() {
        let name = "shared-\(UUID())"
        defer { TerminalTabGroupStore.removePresentationIfUnused(name, referencedNames: []) }
        TerminalTabGroupStore.setColor(.teal, for: name)
        TerminalTabGroupStore.setCollapsed(true, for: name)
        TerminalTabGroupStore.removePresentationIfUnused(name, referencedNames: [name])
        #expect(TerminalTabGroupStore.color(for: name) == .teal)
        #expect(TerminalTabGroupStore.isCollapsed(name))
    }
}

struct ForkSettingsRefreshTests {
    @Test func refreshPreservesPendingFieldAndUpdatesUntouchedField() {
        var refresh = ForkSettingsRefresh()
        #expect(refresh.value(current: "", latest: "5m", key: "interval") == "5m")
        #expect(refresh.value(current: "", latest: "3", key: "crashes") == "3")
        #expect(refresh.value(current: "20m", latest: "10m", key: "interval") == "20m")
        #expect(refresh.value(current: "3", latest: "4", key: "crashes") == "4")
        // Once the pending value is saved, a later external edit is visible again.
        #expect(refresh.value(current: "20m", latest: "20m", key: "interval") == "20m")
        #expect(refresh.value(current: "20m", latest: "30m", key: "interval") == "30m")
    }
}

struct TerminalTabAttentionTests {
    @Test func attentionRequiresAuthorizationAndOmitsPendingReceipts() {
        let pending = KeepAlivePromptStatus(phase: .waiting, message: "Waiting")
        let unavailable = KeepAlivePromptStatus(phase: .attention, message: "The agent bridge is unavailable")
        let uncertain = KeepAlivePromptStatus(phase: .attention, message: "Check the agent; delivery is unconfirmed")
        #expect(TerminalTabAttention.promptMessage([pending], authorized: true) == nil)
        #expect(TerminalTabAttention.promptMessage([unavailable], authorized: false) == nil)
        #expect(TerminalTabAttention.promptMessage([pending, unavailable, unavailable], authorized: true) == unavailable.message)
        #expect(TerminalTabAttention.promptMessage([uncertain], authorized: true) == uncertain.message)
    }
}

struct TerminalRecoveryPresentationTests {
    @Test func splitLabelsIdentifyPositionToolAndSavedSession() {
        let first = AgentSessionBinding(tool: .codex,
                                       sessionID: UUID(uuidString: "00000000-0000-0000-0000-000000111111")!,
                                       sessionRoot: "/tmp/codex", launchCWD: "/tmp/project")
        let second = AgentSessionBinding(tool: .claude,
                                        sessionID: UUID(uuidString: "00000000-0000-0000-0000-000000222222")!,
                                        sessionRoot: "/tmp/claude", launchCWD: "/tmp/project")
        #expect(TerminalRecoveryPresentation.label(ordinal: 1, binding: first) == "Terminal 1 · Codex …111111")
        #expect(TerminalRecoveryPresentation.label(ordinal: 2, binding: second) == "Terminal 2 · Claude …222222")
        #expect(TerminalRecoveryPresentation.label(ordinal: 2, binding: nil) == "Terminal 2 · No saved session")
    }
}

@MainActor
struct TerminalSidebarMenuDispatchTests {
    @Test func retainedTargetDispatchesTheMenuItemThroughAppKit() {
        var calls = 0
        let item: NSMenuItem
        do {
            let model = TerminalTabSidebarModel()
            item = model.menuItem("Test sidebar action") { calls += 1 }
        }
        #expect(item.target != nil)
        #expect(item.action.map(NSStringFromSelector) == "invokeSidebarMenuAction:")
        #expect(NSApplication.shared.sendAction(item.action!, to: item.target, from: item))
        #expect(calls == 1)
    }
}
