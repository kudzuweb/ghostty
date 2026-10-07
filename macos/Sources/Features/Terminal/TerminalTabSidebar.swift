import AppKit
import SwiftUI

extension Notification.Name {
    /// Posted when the tabs of any terminal window may have changed: their order, titles,
    /// colors, key equivalents, or which one is selected.
    static let terminalTabsDidChange = Notification.Name("com.mitchellh.ghostty.terminalTabsDidChange")
}

/// The tabs of one terminal window's tab group, as listed by the vertical tab sidebar.
///
/// Every tab is its own window, so each window owns a model and shows its own copy of the
/// sidebar. Only the selected tab's window is on screen, so that is the copy the user sees.
@MainActor
final class TerminalTabSidebarModel: ObservableObject {
    struct Tab: Identifiable, Equatable {
        let id: ObjectIdentifier

        /// The 1-based position of the tab in its window.
        let index: Int
        let title: String
        let surfaceID: UUID?
        let keyEquivalent: String?
        let color: TerminalTabColor
        let isSelected: Bool

        /// The name of the tab group the tab belongs to, if any.
        let group: String?

        /// Whether keep alive watches the tab, and whether it gave up on it.
        let keepAlive: KeepAliveTabState
    }

    /// A named tab group, drawn as one container holding its tabs.
    struct Group: Identifiable, Equatable {
        var id: String { name }
        let name: String
        let color: TerminalTabColor
        let isCollapsed: Bool
        let tabs: [Tab]
    }

    /// One entry in the sidebar: a tab that isn't in any group, or a whole group.
    enum Section: Identifiable, Equatable {
        case tab(Tab)
        case group(Group)

        var id: String {
            switch self {
            case .tab(let tab): "tab-\(tab.id.hexString)"
            case .group(let group): "group-\(group.name)"
            }
        }
    }

    @Published private(set) var tabs: [Tab] = []
    @Published private(set) var sections: [Section] = []

    /// The names of the groups in this window, in sidebar order.
    var groupNames: [String] {
        sections.compactMap { section in
            if case .group(let group) = section { return group.name }
            return nil
        }
    }

    /// The window this sidebar is shown in.
    weak var window: NSWindow? {
        didSet {
            observeWindowClose()
            refresh()
        }
    }

    /// Whether the window uses `macos-titlebar-style = vertical-tabs`.
    var showsSidebar: Bool {
        (window as? TerminalWindow)?.showsTabSidebar ?? false
    }

    private var observer: NSObjectProtocol?
    private var closeObserver: NSObjectProtocol?

    init() {
        observer = NotificationCenter.default.addObserver(
            forName: .terminalTabsDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // The observer is delivered on the main queue.
            MainActor.assumeIsolated {
                self?.refresh()

                // The tab group takes an event loop cycle to settle after a tab is added or closed.
                DispatchQueue.main.async { self?.refresh() }
            }
        }
    }

    deinit {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
        if let closeObserver {
            NotificationCenter.default.removeObserver(closeObserver)
        }
    }

    /// Forgets the window once it closes. Asking AppKit for a closed window's tabs (as a
    /// late refresh would) registers it with a tab group again, which keeps it alive.
    private func observeWindowClose() {
        if let closeObserver {
            NotificationCenter.default.removeObserver(closeObserver)
            self.closeObserver = nil
        }
        guard let window else { return }

        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.window = nil
            }
        }
    }

    /// The windows in our tab group in tab order. A window that isn't tabbed is its own only tab.
    private var tabWindows: [NSWindow] {
        guard let window else { return [] }
        return window.tabbedWindows ?? [window]
    }

    func refresh() {
        // The window only carries a key equivalent label while it is in a tab group, so a
        // lone tab would have none. Look the shortcuts up from the keybinds instead.
        let config = (window?.windowController as? BaseTerminalController)?.ghostty.config
        let newTabs = tabWindows.enumerated().map { offset, tabWindow in
            let index = offset + 1
            let shortcut = index <= 9 ? config?.keyboardShortcut(for: "goto_tab:\(index)") : nil
            return Tab(
                id: ObjectIdentifier(tabWindow),
                index: index,
                title: tabWindow.title,
                surfaceID: (tabWindow.windowController as? BaseTerminalController)?.surfaceTree.first(where: { _ in true })?.id,
                keyEquivalent: shortcut.map { "\($0)" },
                color: (tabWindow as? TerminalWindow)?.tabColor ?? .none,
                // Our window is only on screen while it is the selected tab.
                isSelected: tabWindow === window,
                group: (tabWindow as? TerminalWindow)?.tabGroupName,
                keepAlive: (tabWindow as? TerminalWindow)?.keepAliveState ?? .off
            )
        }

        let newSections = Self.sections(for: newTabs)
        guard newTabs != tabs || newSections != sections else { return }
        tabs = newTabs
        sections = newSections
    }

    /// Lists each group once, where its first tab is. Moving a tab into a group places it
    /// beside the group's other tabs, so a group's tabs are normally adjacent anyway.
    private static func sections(for tabs: [Tab]) -> [Section] {
        var sections: [Section] = []
        var seen: Set<String> = []
        for tab in tabs {
            guard let name = tab.group else {
                sections.append(.tab(tab))
                continue
            }
            guard seen.insert(name).inserted else { continue }
            sections.append(.group(Group(
                name: name,
                color: TerminalTabGroupStore.color(for: name),
                isCollapsed: TerminalTabGroupStore.isCollapsed(name),
                tabs: tabs.filter { $0.group == name }
            )))
        }
        return sections
    }

    func newTab() {
        (window?.windowController as? TerminalController)?.newTab(nil)
    }

    func displayTitle(_ tab: Tab) -> String {
        guard tabs.filter({ $0.title == tab.title }).count > 1, let id = tab.surfaceID else { return tab.title }
        return "\(tab.title) · \(id.uuidString.prefix(6).lowercased())"
    }

    func dropTarget(for tab: Tab) -> Ghostty.SurfaceView? {
        (tabWindow(for: tab)?.windowController as? BaseTerminalController)?.focusedSurface
    }

    func promptAttention(for tab: Tab) -> String? {
        let authorized = (tabWindow(for: tab) as? TerminalWindow)?.keepAlive == true || KeepAlive.shared.overnightActive
        let statuses = recoverySurfaces(for: tab).compactMap { KeepAlive.shared.promptStatuses[$0.id] }
        return TerminalTabAttention.promptMessage(statuses, authorized: authorized)
    }

    func recoverySurfaces(for tab: Tab) -> [Ghostty.SurfaceView] {
        guard let controller = tabWindow(for: tab)?.windowController as? BaseTerminalController else { return [] }
        return Array(controller.surfaceTree)
    }

    func select(_ tab: Tab) {
        tabWindow(for: tab)?.makeKeyAndOrderFront(nil)
    }

    func close(_ tab: Tab) {
        controller(for: tab)?.closeTab(nil)
    }

    func closeOthers(_ tab: Tab) {
        select(tab)
        controller(for: tab)?.closeOtherTabs(nil)
    }

    func closeBelow(_ tab: Tab) {
        select(tab)
        controller(for: tab)?.closeTabsOnTheRight(nil)
    }

    func moveToNewWindow(_ tab: Tab) {
        tabWindow(for: tab)?.moveTabToNewWindow(nil)
    }

    func showAllTabs() {
        window?.toggleTabOverview(nil)
    }

    func promptTitle(_ tab: Tab) {
        select(tab)
        controller(for: tab)?.promptTabTitle()
    }

    // MARK: Keep Alive

    func setKeepAlive(_ isOn: Bool, for tab: Tab) {
        (tabWindow(for: tab) as? TerminalWindow)?.keepAlive = isOn
    }

    /// Clears a gave-up tab's crash count so keep alive tries it again.
    func retryKeepAlive(for tab: Tab) {
        (tabWindow(for: tab) as? TerminalWindow)?.keepAliveGaveUp = false
    }

    private func keepAliveItem(for tab: Tab) -> NSMenuItem {
        if tab.keepAlive == .gaveUp {
            return menuItem("Keep alive: gave up, try again", symbol: "exclamationmark.arrow.circlepath") { [weak self] in
                self?.retryKeepAlive(for: tab)
            }
        }
        let item = menuItem("Keep alive", symbol: "arrow.clockwise.circle") { [weak self] in
            self?.setKeepAlive(tab.keepAlive == .off, for: tab)
        }
        item.state = tab.keepAlive == .off ? .off : .on
        return item
    }

    func setColor(_ color: TerminalTabColor, for tab: Tab) {
        (tabWindow(for: tab) as? TerminalWindow)?.tabColor = color
    }

    // MARK: Tab Groups

    func move(_ tab: Tab, toGroup name: String?) {
        (tabWindow(for: tab) as? TerminalWindow)?.moveToTabGroup(name)
    }

    func setGroupCollapsed(_ isCollapsed: Bool, _ name: String) {
        TerminalTabGroupStore.setCollapsed(isCollapsed, for: name)
    }

    func setGroupColor(_ color: TerminalTabColor, _ name: String) {
        TerminalTabGroupStore.setColor(color, for: name)
    }

    func ungroup(_ name: String) {
        for case let tabWindow as TerminalWindow in tabWindows where tabWindow.tabGroupName == name {
            tabWindow.tabGroupName = nil
        }
    }

    func renameGroup(_ name: String, to newName: String) {
        guard newName != name else { return }
        let allWindows = NSApp.windows.compactMap { $0 as? TerminalWindow }
        guard !allWindows.contains(where: { $0.tabGroupName == newName }),
              !allWindows.contains(where: { $0.tabGroupName == name && !tabWindows.contains($0) }),
              TerminalTabGroupStore.rename(name, to: newName) else {
            let alert = NSAlert()
            alert.messageText = "Couldn't rename group"
            alert.informativeText = "Choose an unused name. A group shared with another window must be renamed there together, so its appearance stays consistent."
            alert.runModal()
            return
        }
        for case let tabWindow as TerminalWindow in tabWindows where tabWindow.tabGroupName == name {
            tabWindow.tabGroupName = newName
        }
        TerminalTabGroupStore.removePresentationIfUnused(name)
    }

    /// Asks for a name for a new group and moves the tab into it.
    func promptNewGroup(for tab: Tab) {
        promptGroupName(title: "New Group", initialValue: "") { [weak self] name in
            self?.move(tab, toGroup: name)
        }
    }

    func promptRenameGroup(_ name: String) {
        promptGroupName(title: "Rename Group", initialValue: name) { [weak self] newName in
            self?.renameGroup(name, to: newName)
        }
    }

    private func promptGroupName(title: String, initialValue: String, completion: @escaping (String) -> Void) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = title
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")

        let field = NSTextField(string: initialValue)
        field.placeholderString = "Group name"
        field.frame = NSRect(x: 0, y: 0, width: 240, height: 24)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return }
            completion(name)
        }
    }

    /// The right-click menu for a group's header.
    func contextMenu(forGroup group: Group) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        menu.addItem(menuItem(group.isCollapsed ? "Expand Group" : "Collapse Group") { [weak self] in
            self?.setGroupCollapsed(!group.isCollapsed, group.name)
        })
        menu.addItem(menuItem("Rename Group...", symbol: "pencil.line") { [weak self] in
            self?.promptRenameGroup(group.name)
        })
        menu.addItem(menuItem("Ungroup Tabs", symbol: "rectangle.stack.badge.minus") { [weak self] in
            self?.ungroup(group.name)
        })

        menu.addItem(.separator())
        let palette = NSHostingView(rootView: TabColorMenuView(selectedColor: group.color, title: "Group Color") { [weak self] color in
            self?.setGroupColor(color, group.name)
        })
        palette.frame.size = palette.intrinsicContentSize
        let paletteItem = NSMenuItem()
        paletteItem.view = palette
        menu.addItem(paletteItem)

        return menu
    }

    private func groupSubmenu(for tab: Tab) -> NSMenuItem {
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        for name in groupNames {
            let item = menuItem(name, isEnabled: name != tab.group) { [weak self] in
                self?.move(tab, toGroup: name)
            }
            item.state = name == tab.group ? .on : .off
            submenu.addItem(item)
        }
        if !groupNames.isEmpty {
            submenu.addItem(.separator())
        }
        submenu.addItem(menuItem("New Group...") { [weak self] in
            self?.promptNewGroup(for: tab)
        })
        if tab.group != nil {
            submenu.addItem(menuItem("Remove from Group") { [weak self] in
                self?.move(tab, toGroup: nil)
            })
        }

        let item = NSMenuItem(title: "Move to Group", action: nil, keyEquivalent: "")
        item.setImageIfDesired(systemSymbolName: "rectangle.stack")
        item.submenu = submenu
        return item
    }

    /// The right-click menu for a tab. It has the same items as a native tab's menu, including
    /// the tab color palette, which is why it is an AppKit menu: the palette is a custom menu
    /// item view and SwiftUI menus can't hold one.
    func contextMenu(for tab: Tab) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        for (offset, surface) in recoverySurfaces(for: tab).enumerated() {
            guard let state = AgentSessionRecovery.shared.status(for: surface.id),
                  state.phase == .pending || state.phase == .failed || state.phase == .launching else { continue }
            let label = TerminalRecoveryPresentation.label(ordinal: offset + 1, binding: state.binding)
            let section = NSMenuItem(title: label, action: nil, keyEquivalent: "")
            let submenu = NSMenu(title: label)
            submenu.autoenablesItems = false
            let summary = NSMenuItem(title: state.reason ?? "Waiting to resume this terminal", action: nil, keyEquivalent: "")
            summary.isEnabled = false
            submenu.addItem(summary)
            let id = surface.id
            if state.binding == nil {
                let explanation = NSMenuItem(title: "No saved session is known for this terminal", action: nil, keyEquivalent: "")
                explanation.isEnabled = false
                submenu.addItem(explanation)
            } else if state.phase != .launching {
                submenu.addItem(menuItem("Retry resume in this terminal", symbol: "arrow.clockwise") {
                    AgentSessionRecovery.shared.retry(surfaceID: id)
                })
            }
            submenu.addItem(menuItem("Forget saved resume", symbol: "xmark.circle") {
                AgentSessionRecovery.shared.dismiss(surfaceID: id)
            })
            section.submenu = submenu
            menu.addItem(section)
        }
        if menu.numberOfItems > 0 { menu.addItem(.separator()) }

        if let message = promptAttention(for: tab) {
            let summary = NSMenuItem(title: "Keep alive: \(message)", action: nil, keyEquivalent: "")
            summary.isEnabled = false
            menu.addItem(summary)
            menu.addItem(.separator())
        }

        let hasOtherTabs = tabs.count > 1
        menu.addItem(menuItem("Close Tab", symbol: "xmark") { [weak self] in
            self?.close(tab)
        })
        menu.addItem(menuItem("Close Other Tabs", symbol: "xmark", isEnabled: hasOtherTabs) { [weak self] in
            self?.closeOthers(tab)
        })
        menu.addItem(menuItem("Close Tabs to the Right", symbol: "xmark", isEnabled: tab.index < tabs.count) { [weak self] in
            self?.closeBelow(tab)
        })
        menu.addItem(menuItem("Move Tab to New Window", symbol: "macwindow.badge.plus", isEnabled: hasOtherTabs) { [weak self] in
            self?.moveToNewWindow(tab)
        })
        menu.addItem(menuItem("Show All Tabs") { [weak self] in
            self?.showAllTabs()
        })

        menu.addItem(.separator())
        menu.addItem(menuItem("Rename Tab...", symbol: "pencil.line") { [weak self] in
            self?.promptTitle(tab)
        })
        menu.addItem(groupSubmenu(for: tab))
        menu.addItem(keepAliveItem(for: tab))

        let palette = NSHostingView(rootView: TabColorMenuView(selectedColor: tab.color) { [weak self] color in
            self?.setColor(color, for: tab)
        })
        palette.frame.size = palette.intrinsicContentSize
        let paletteItem = NSMenuItem()
        paletteItem.view = palette
        menu.addItem(paletteItem)

        return menu
    }

    func menuItem(
        _ title: String,
        symbol: String? = nil,
        isEnabled: Bool = true,
        handler: @escaping () -> Void
    ) -> NSMenuItem {
        let action = MenuAction(handler)
        let item = NSMenuItem(title: title, action: #selector(MenuAction.invokeSidebarMenuAction(_:)), keyEquivalent: "")
        item.target = action
        // The item's target is weak, so the item itself keeps the action alive.
        item.representedObject = action
        item.isEnabled = isEnabled
        if let symbol {
            item.setImageIfDesired(systemSymbolName: symbol)
        }
        return item
    }

    /// Runs a closure as a menu item's action.
    private final class MenuAction: NSObject {
        private let handler: () -> Void

        init(_ handler: @escaping () -> Void) {
            self.handler = handler
        }

        @objc func invokeSidebarMenuAction(_ sender: NSMenuItem) {
            handler()
        }
    }

    private func tabWindow(for tab: Tab) -> NSWindow? {
        tabWindows.first { ObjectIdentifier($0) == tab.id }
    }

    private func controller(for tab: Tab) -> TerminalController? {
        tabWindow(for: tab)?.windowController as? TerminalController
    }
}

/// Places the vertical tab sidebar beside a terminal window's content.
struct TerminalTabSidebarLayout<Content: View>: View {
    @ObservedObject var model: TerminalTabSidebarModel
    @ObservedObject var ghostty: Ghostty.App
    let content: Content

    @AppStorage(TerminalTabSidebar.collapsedKey) private var isCollapsed = false
    @AppStorage(TerminalTabSidebar.widthKey) private var width = TerminalTabSidebar.defaultWidth

    /// The sidebar width when the current resize drag began.
    @State private var widthAtDragStart: Double?

    init(model: TerminalTabSidebarModel, ghostty: Ghostty.App, @ViewBuilder content: () -> Content) {
        self.model = model
        self.ghostty = ghostty
        self.content = content()
    }

    var body: some View {
        HStack(spacing: 0) {
            if model.showsSidebar {
                TerminalTabSidebar(model: model, isCollapsed: $isCollapsed)
                    .frame(width: isCollapsed ? TerminalTabSidebar.collapsedWidth : width)
                    .background(ghostty.config.backgroundColor.opacity(ghostty.config.backgroundOpacity))
                    .environment(\.colorScheme, NSColor(ghostty.config.backgroundColor).isLightColor ? .light : .dark)
                    .environment(\.terminalTabSidebarPalette, TerminalTabSidebarPalette(ansi: ghostty.config.ansiPalette))

                divider
            }

            content
        }
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.15))
            .frame(width: TerminalTabSidebar.dividerWidth)
            .overlay {
                if !isCollapsed {
                    // A wider invisible strip so the divider is easy to grab.
                    Color.clear
                        .frame(width: 7)
                        .contentShape(Rectangle())
                        .gesture(resizeGesture)
                        .onHover { isHovering in
                            if isHovering {
                                NSCursor.resizeLeftRight.push()
                            } else {
                                NSCursor.pop()
                            }
                        }
                }
            }
    }

    private var resizeGesture: some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .global)
            .onChanged { value in
                let start = widthAtDragStart ?? width
                widthAtDragStart = start
                let range = TerminalTabSidebar.widthRange
                width = min(max(start + value.translation.width, range.lowerBound), range.upperBound)
            }
            .onEnded { _ in
                widthAtDragStart = nil
            }
    }
}

/// The vertical list of a terminal window's tabs, replacing the native tab bar.
struct TerminalTabSidebar: View {
    static let collapsedKey = "TerminalTabSidebarCollapsed"
    static let widthKey = "TerminalTabSidebarWidth"
    static let defaultWidth: Double = 200
    static let widthRange: ClosedRange<Double> = 120...400
    static let collapsedWidth: Double = 40
    static let dividerWidth: Double = 1

    /// The width the sidebar and its divider currently take out of a window's content.
    static var occupiedWidth: CGFloat {
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: collapsedKey) {
            return collapsedWidth + dividerWidth
        }

        let width = defaults.object(forKey: widthKey) as? Double ?? defaultWidth
        return width + dividerWidth
    }

    @ObservedObject var model: TerminalTabSidebarModel
    @Binding var isCollapsed: Bool
    @ObservedObject private var sleepGuard = SleepGuard.shared
    @ObservedObject private var keepAlive = KeepAlive.shared

    var body: some View {
        VStack(spacing: 0) {
            if isCollapsed {
                VStack(spacing: 4) {
                    collapseButton
                    overnightButton
                    sleepGuardButton
                    settingsButton
                    newTabButton
                }
                .padding(.top, 5)
                .padding(.bottom, 6)

                ScrollView(showsIndicators: false) {
                    LazyVStack(spacing: 0) {
                        sectionList(isCompact: true)
                    }
                    .padding(.bottom, 6)
                }
            } else {
                HStack {
                    collapseButton
                    Spacer()
                    overnightButton
                    sleepGuardButton
                    settingsButton
                    newTabButton
                }
                .padding(.horizontal, 6)
                .frame(height: 40)

                ScrollView {
                    LazyVStack(spacing: 0) {
                        sectionList(isCompact: false)
                    }
                    .padding(.bottom, 6)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// The tabs and groups as flat, full-width blocks with a hairline between each.
    private func sectionList(isCompact: Bool) -> some View {
        ForEach(model.sections) { section in
            VStack(spacing: 0) {
                switch section {
                case .tab(let tab):
                    TerminalTabSidebarRow(model: model, tab: tab, isCompact: isCompact)
                case .group(let group):
                    TerminalTabSidebarGroup(model: model, group: group, isCompact: isCompact)
                }

                Rectangle()
                    .fill(Color.primary.opacity(0.08))
                    .frame(height: 1)
            }
        }
    }

    private var collapseButton: some View {
        TerminalTabSidebarButton(
            systemName: "sidebar.left",
            label: isCollapsed ? "Show Tab Sidebar" : "Hide Tab Sidebar"
        ) {
            isCollapsed.toggle()
        }
    }

    private var overnightButton: some View {
        TerminalTabSidebarButton(
            systemName: keepAlive.overnightActive ? "clock.fill" : "clock",
            label: keepAlive.overnightEndDescription.map { "Overnight run: on until \($0). Click to turn off" }
                ?? "Overnight run: off. Click to turn on"
        ) {
            keepAlive.setOvernight(!keepAlive.overnightActive)
        }
    }

    private var sleepGuardButton: some View {
        TerminalTabSidebarButton(systemName: sleepGuard.symbolName, label: sleepGuard.summary) {
            sleepGuard.popUpMenu()
        }
    }

    private var settingsButton: some View {
        TerminalTabSidebarButton(systemName: "gearshape", label: "Settings") {
            ForkSettingsPanelController.shared.show()
        }
    }

    private var newTabButton: some View {
        TerminalTabSidebarButton(systemName: "plus", label: "New Tab") {
            model.newTab()
        }
    }
}

/// A round icon button in the tab sidebar, drawn like the native tab bar's buttons.
private struct TerminalTabSidebarButton: View {
    enum Kind {
        /// Like the tab bar's new tab button: a large glass circle.
        case bar

        /// Like a tab's close button: a small circle lighter than the tab it sits on.
        case close
    }

    let systemName: String
    let label: String
    var kind: Kind = .bar
    let action: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: glyphSize, weight: glyphWeight))
                .frame(width: diameter, height: diameter)
                .background(Circle().fill(kind == .close ? closeFill : .clear))
                .terminalTabSidebarGlass(
                    in: Circle(),
                    isEnabled: kind == .bar,
                    isInteractive: true,
                    tint: isHovering ? Color.primary.opacity(0.12) : nil,
                    fallback: barFallbackFill
                )
                // The click target can be larger than the circle that is drawn.
                .frame(width: targetSize, height: targetSize)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .onHover { isHovering = $0 }
        .help(label)
        .accessibilityLabel(label)
    }

    private var diameter: CGFloat {
        switch kind {
        case .bar: 30
        case .close: 16
        }
    }

    private var targetSize: CGFloat {
        switch kind {
        case .bar: 30
        case .close: 22
        }
    }

    private var glyphSize: CGFloat {
        switch kind {
        case .bar: 14
        case .close: 8.5
        }
    }

    private var glyphWeight: Font.Weight {
        switch kind {
        case .bar: .medium
        case .close: .bold
        }
    }

    private var closeFill: Color {
        Color.primary.opacity(isHovering ? 0.30 : 0.16)
    }

    /// What the bar buttons are filled with where there is no glass.
    private var barFallbackFill: Color {
        if isHovering { return Color.primary.opacity(0.14) }
        return Color.black.opacity(colorScheme == .dark ? 0.28 : 0.07)
    }
}

private extension View {
    /// Draws the view on the system's Liquid Glass, which is what the native tab bar's tabs
    /// and buttons are made of and what gives them their bright rim. Glass needs macOS 26;
    /// earlier systems get a flat fill instead.
    @ViewBuilder
    func terminalTabSidebarGlass<S: Shape>(
        in shape: S,
        isEnabled: Bool = true,
        isInteractive: Bool = false,
        tint: Color? = nil,
        fallback: Color
    ) -> some View {
#if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            glassEffect(
                isEnabled ? Glass.regular.tint(tint).interactive(isInteractive) : .identity,
                in: shape
            )
        } else {
            background(shape.fill(isEnabled ? fallback : .clear))
        }
#else
        background(shape.fill(isEnabled ? fallback : .clear))
#endif
    }
}

/// One tab in the sidebar: a flat, full-width row when the sidebar is expanded, or a tile
/// showing its key equivalent in the collapsed rail. The selected tab gets a solid highlight.
private struct TerminalTabSidebarRow: View {
    let model: TerminalTabSidebarModel
    let tab: TerminalTabSidebarModel.Tab
    let isCompact: Bool

    /// Whether the row sits on a group's tinted block, where the selected tab needs a
    /// stronger fill to stand out.
    var isInGroup = false

    @Environment(\.terminalTabSidebarPalette) private var palette
    @State private var isHovering = false
    @ObservedObject private var recovery = AgentSessionRecovery.shared
    @ObservedObject private var keepAlive = KeepAlive.shared

    var body: some View {
        content
            .font(.system(size: 13))
            .foregroundStyle(Color.primary.opacity(tab.isSelected ? 1 : 0.75))
            .frame(maxWidth: .infinity)
            .background(Rectangle().fill(rowFill))
            .contentShape(Rectangle())
            .onTapGesture { model.select(tab) }
            .onHover { isHovering = $0 }
            .help([model.displayTitle(tab), attentionMessage].compactMap { $0 }.joined(separator: "\n"))
            .overlay(TerminalTabSidebarMenuArea(dropTarget: { model.dropTarget(for: tab) }, menu: { model.contextMenu(for: tab) }))
            .accessibilityElement(children: .combine)
            .accessibilityLabel(model.displayTitle(tab))
            .accessibilityAddTraits(tab.isSelected ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction { model.select(tab) }
    }

    private var recoveryStatus: AgentSessionRecovery.Status? {
        model.recoverySurfaces(for: tab).compactMap { recovery.status(for: $0.id) }
            .first { $0.phase == .failed || $0.phase == .pending || $0.phase == .launching }
    }

    private var attentionMessage: String? {
        recoveryStatus.map { $0.reason ?? "Waiting to resume this terminal" } ?? model.promptAttention(for: tab)
    }

    @ViewBuilder
    private var statusBadge: some View {
        if let status = recoveryStatus {
            Image(systemName: status.phase == .failed ? "exclamationmark.triangle" : "clock")
                .font(.system(size: 10))
                .foregroundStyle(status.phase == .failed ? Color.red : Color.secondary)
                .help(status.reason ?? "Waiting to resume this terminal")
        } else if let message = model.promptAttention(for: tab) {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 10))
                .foregroundStyle(.orange)
                .help(message)
                .accessibilityLabel("Keep alive needs attention: \(message)")
        } else if tab.keepAlive != .off {
            keepAliveBadge
        }
    }

    /// Rows are flat: the selected tab gets a solid highlight, and a hovered one a lighter one.
    private var rowFill: Color {
        if tab.isSelected { return Color.primary.opacity(isInGroup ? 0.16 : 0.12) }
        return Color.primary.opacity(isHovering ? 0.06 : 0)
    }

    @ViewBuilder
    private var content: some View {
        if isCompact {
            tile
        } else {
            row
        }
    }

    private var tile: some View {
        // The key equivalent that selects the tab (e.g. ⌘1), or its position when it has none.
        Text(tab.keyEquivalent ?? "\(tab.index)")
            .font(.system(size: 11))
            .frame(width: 30, height: 30)
            .overlay(alignment: .topTrailing) {
                if let color = palette.color(for: tab.color) {
                    Circle()
                        .fill(Color(nsColor: color))
                        .frame(width: 6, height: 6)
                        .padding(3)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                statusBadge.padding(2)
            }
    }

    /// The small icon for a kept-alive tab: a refresh arrow while it is being watched, and a
    /// red warning once keep alive gave up on it.
    @ViewBuilder
    private var keepAliveBadge: some View {
        switch tab.keepAlive {
        case .off:
            EmptyView()
        case .on:
            Image(systemName: "arrow.clockwise.circle.fill")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .help("Keep alive")
        case .gaveUp:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10))
                .foregroundStyle(.red)
                .help("Keep alive gave up: this tab's session kept crashing")
        }
    }

    private var row: some View {
        HStack(spacing: 4) {
            // Like a native tab, the close button is on the leading side and only shows
            // on hover. Its slot is always reserved so the title doesn't shift.
            ZStack {
                if isHovering {
                    TerminalTabSidebarButton(systemName: "xmark", label: "Close Tab", kind: .close) {
                        model.close(tab)
                    }
                } else if let color = palette.color(for: tab.color) {
                    Circle()
                        .fill(Color(nsColor: color))
                        .frame(width: 8, height: 8)
                }
            }
            .frame(width: 22, height: 22)

            Text(tab.title)
                .lineLimit(1)
                .truncationMode(.tail)
            if model.tabs.filter({ $0.title == tab.title }).count > 1, let id = tab.surfaceID {
                Text(String(id.uuidString.prefix(6)).lowercased())
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }

            Spacer(minLength: 4)

            statusBadge

            if let keyEquivalent = tab.keyEquivalent {
                Text(keyEquivalent)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.leading, 6)
        .padding(.trailing, 10)
        .frame(height: 32)
    }
}

/// A tab group: one flat tinted block holding a header with the group's name and the
/// group's tabs, so the group reads as a single object. In the collapsed rail, a color bar
/// stands in for the header. A collapsed group still shows its selected tab, if it has one.
private struct TerminalTabSidebarGroup: View {
    let model: TerminalTabSidebarModel
    let group: TerminalTabSidebarModel.Group
    let isCompact: Bool

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.terminalTabSidebarPalette) private var palette

    var body: some View {
        VStack(spacing: 0) {
            if isCompact {
                compactHeader
            } else {
                header
            }

            ForEach(visibleTabs) { tab in
                TerminalTabSidebarRow(model: model, tab: tab, isCompact: isCompact, isInGroup: true)
            }
        }
        .frame(maxWidth: .infinity)
        .background(Rectangle().fill(fillColor))
    }

    private var visibleTabs: [TerminalTabSidebarModel.Tab] {
        group.isCollapsed ? group.tabs.filter(\.isSelected) : group.tabs
    }

    /// How many tabs a collapsed group is hiding.
    private var hiddenCount: Int {
        group.tabs.count - visibleTabs.count
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .opacity(0.7)
                .rotationEffect(.degrees(group.isCollapsed ? 0 : 90))
                .frame(width: 14)

            Text(group.name)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 4)

            if group.isCollapsed && hiddenCount > 0 {
                Text(visibleTabs.isEmpty ? "\(hiddenCount)" : "+\(hiddenCount)")
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(accentColor.opacity(0.2)))
            }
        }
        .foregroundStyle(nameColor)
        .padding(.leading, 10)
        .padding(.trailing, 10)
        .frame(height: 30)
        .contentShape(Rectangle())
        .onTapGesture { toggle() }
        .help(group.isCollapsed ? "Expand \(group.name)" : "Collapse \(group.name)")
        .overlay(TerminalTabSidebarMenuArea { model.contextMenu(forGroup: group) })
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Group \(group.name), \(group.tabs.count) tabs")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { toggle() }
    }

    /// In the collapsed rail: a color bar, or when the group is collapsed, a tile with the
    /// number of tabs it hides.
    @ViewBuilder
    private var compactHeader: some View {
        Group {
            if group.isCollapsed && hiddenCount > 0 {
                Text("\(hiddenCount)")
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(nameColor)
                    .frame(width: 30, height: 22)
            } else {
                Rectangle()
                    .fill(accentColor)
                    .frame(height: 3)
                    .frame(maxWidth: .infinity)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { toggle() }
        .help(group.name)
        .overlay(TerminalTabSidebarMenuArea { model.contextMenu(forGroup: group) })
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Group \(group.name), \(group.tabs.count) tabs")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { toggle() }
    }

    private func toggle() {
        model.setGroupCollapsed(!group.isCollapsed, group.name)
    }

    /// Graphite (and no color) groups are drawn neutral: a gray name on a gray fill would be
    /// as hard to read as the captions this is meant to replace.
    private var isNeutral: Bool {
        group.color == .graphite || palette.color(for: group.color) == nil
    }

    private var accentColor: Color {
        guard !isNeutral, let color = palette.color(for: group.color) else { return Color.primary.opacity(0.5) }
        return Color(nsColor: color)
    }

    /// The group color, lightened on dark backgrounds and darkened on light ones so the
    /// name stays readable on the container's tint.
    private var nameColor: Color {
        guard !isNeutral, let color = palette.color(for: group.color) else { return Color.primary.opacity(0.9) }
        let toward: NSColor = colorScheme == .dark ? .white : .black
        return Color(nsColor: color.blended(withFraction: 0.3, of: toward) ?? color)
    }

    private var fillColor: Color {
        if isNeutral { return Color.primary.opacity(0.06) }
        // Yellow turns muddy at the opacity the other colors use.
        return accentColor.opacity(group.color == .yellow ? 0.08 : 0.12)
    }
}

/// Shows an AppKit menu when its area is right-clicked or control-clicked, and lets every
/// other mouse event through to the SwiftUI views beneath it.
private struct TerminalTabSidebarMenuArea: NSViewRepresentable {
    var dropTarget: (() -> Ghostty.SurfaceView?)?
    let menu: () -> NSMenu

    func makeNSView(context: Context) -> MenuAreaView {
        let view = MenuAreaView()
        view.menuProvider = menu
        view.dropTargetProvider = dropTarget
        return view
    }

    func updateNSView(_ nsView: MenuAreaView, context: Context) {
        nsView.menuProvider = menu
        nsView.dropTargetProvider = dropTarget
    }

    final class MenuAreaView: NSView, TerminalSidebarDropDestination {
        var dropTargetProvider: (() -> Ghostty.SurfaceView?)?
        var sidebarDropTarget: Ghostty.SurfaceView? { dropTargetProvider?() }
        var representsSidebarTab: Bool { dropTargetProvider != nil }
        var menuProvider: (() -> NSMenu)?

        override func hitTest(_ point: NSPoint) -> NSView? {
            // Only claim the clicks that open a context menu. Everything else, such as
            // selecting the tab or pressing its close button, belongs to the row beneath.
            guard let event = NSApp.currentEvent else { return nil }
            switch event.type {
            case .rightMouseDown, .rightMouseUp:
                return super.hitTest(point)
            case .leftMouseDown where event.modifierFlags.contains(.control):
                return super.hitTest(point)
            default:
                return nil
            }
        }

        override func menu(for event: NSEvent) -> NSMenu? {
            menuProvider?()
        }
    }
}

/// Resolves tab and group colors to the terminal theme's ANSI colors, so the sidebar's
/// colors change with the theme. Without a palette it falls back to the system colors.
struct TerminalTabSidebarPalette {
    private let ansi: [NSColor]

    init(ansi: [Color] = []) {
        self.ansi = ansi.map { NSColor($0).usingColorSpace(.sRGB) ?? NSColor($0) }
    }

    func color(for tabColor: TerminalTabColor) -> NSColor? {
        guard ansi.count >= 16 else { return tabColor.displayColor }
        switch tabColor {
        case .none: return nil
        case .red: return ansi[1]
        case .green: return ansi[2]
        case .yellow: return ansi[3]
        case .blue: return ansi[4]
        case .purple: return ansi[5]
        case .teal: return ansi[6]
        case .pink: return ansi[13]
        // Terminal palettes have no orange, so mix the theme's red and yellow.
        case .orange: return ansi[1].blended(withFraction: 0.5, of: ansi[3]) ?? ansi[1]
        case .graphite: return ansi[8]
        }
    }
}

private struct TerminalTabSidebarPaletteKey: EnvironmentKey {
    static let defaultValue = TerminalTabSidebarPalette()
}

extension EnvironmentValues {
    var terminalTabSidebarPalette: TerminalTabSidebarPalette {
        get { self[TerminalTabSidebarPaletteKey.self] }
        set { self[TerminalTabSidebarPaletteKey.self] = newValue }
    }
}

/// A prompt problem remains visible only while this tab is authorized for keep alive.
enum TerminalTabAttention {
    static func promptMessage(_ statuses: [KeepAlivePromptStatus], authorized: Bool) -> String? {
        guard authorized else { return nil }
        let messages = statuses.filter { $0.phase == .attention }.map(\.message)
        return messages.isEmpty ? nil : Array(Set(messages)).sorted().joined(separator: "\n")
    }
}

/// Split order supplies a human location; the saved tool/session disambiguates identities.
enum TerminalRecoveryPresentation {
    static func label(ordinal: Int, binding: AgentSessionBinding?) -> String {
        let terminal = "Terminal \(ordinal)"
        guard let binding else { return "\(terminal) · No saved session" }
        let tool = binding.tool == .codex ? "Codex" : "Claude"
        return "\(terminal) · \(tool) …\(binding.sessionID.uuidString.suffix(6).lowercased())"
    }
}
