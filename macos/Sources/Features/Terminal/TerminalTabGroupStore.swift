import AppKit

/// The settings of the vertical tab sidebar's tab groups that belong to a group's name
/// rather than to any one tab: its color and whether it is collapsed. They are shared by
/// every window and kept across launches, so a group looks the same wherever it appears.
@MainActor
enum TerminalTabGroupStore {
    private static let colorsKey = "TerminalTabGroupColors"
    private static let collapsedKey = "TerminalTabGroupsCollapsed"

    /// The colors a new group is given, in order, skipping any already in use.
    private static let newGroupColors: [TerminalTabColor] = [
        .blue, .green, .purple, .orange, .teal, .pink, .red, .yellow,
    ]

    static func color(for name: String) -> TerminalTabColor {
        let colors = UserDefaults.standard.dictionary(forKey: colorsKey) as? [String: Int] ?? [:]
        return colors[name].flatMap(TerminalTabColor.init(rawValue:)) ?? .graphite
    }

    static func setColor(_ color: TerminalTabColor, for name: String) {
        var colors = UserDefaults.standard.dictionary(forKey: colorsKey) as? [String: Int] ?? [:]
        guard colors[name] != color.rawValue else { return }
        colors[name] = color.rawValue
        UserDefaults.standard.set(colors, forKey: colorsKey)
        NotificationCenter.default.post(name: .terminalTabsDidChange, object: nil)
    }

    /// Gives a group a color the first time it is used, choosing one that none of the
    /// groups in `existing` already has.
    static func assignColorIfNeeded(to name: String, avoiding existing: [String]) {
        let colors = UserDefaults.standard.dictionary(forKey: colorsKey) as? [String: Int] ?? [:]
        guard colors[name] == nil else { return }
        let used = Set(existing.map(color(for:)))
        let next = newGroupColors.first { !used.contains($0) } ?? newGroupColors[existing.count % newGroupColors.count]
        setColor(next, for: name)
    }

    /// Carries a group's color and collapsed state over to its new name.
    @discardableResult
    static func rename(_ name: String, to newName: String) -> Bool {
        guard newName != name else { return true }
        removePresentationIfUnused(newName)
        let colors = UserDefaults.standard.dictionary(forKey: colorsKey) ?? [:]
        guard canRename(name, to: newName, occupied: Set(colors.keys).union(UserDefaults.standard.stringArray(forKey: collapsedKey) ?? [])) else { return false }
        setColor(color(for: name), for: newName)
        setCollapsed(isCollapsed(name), for: newName)
        return true
    }

    /// Obsolete labels must not permanently reserve names. Shared live groups keep their data.
    static func removePresentationIfUnused(_ name: String, referencedNames: Set<String>? = nil) {
        let references = referencedNames ?? Set(NSApp.windows.compactMap { ($0 as? TerminalWindow)?.tabGroupName })
        guard !references.contains(name) else { return }
        var colors = UserDefaults.standard.dictionary(forKey: colorsKey) ?? [:]
        colors.removeValue(forKey: name)
        UserDefaults.standard.set(colors, forKey: colorsKey)
        setCollapsed(false, for: name)
    }

    static func canRename(_ name: String, to newName: String, occupied: Set<String>) -> Bool {
        name == newName || (!newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !occupied.contains(newName))
    }

    static func isCollapsed(_ name: String) -> Bool {
        let collapsed = UserDefaults.standard.stringArray(forKey: collapsedKey) ?? []
        return collapsed.contains(name)
    }

    static func setCollapsed(_ isCollapsed: Bool, for name: String) {
        var collapsed = Set(UserDefaults.standard.stringArray(forKey: collapsedKey) ?? [])
        guard collapsed.contains(name) != isCollapsed else { return }
        if isCollapsed {
            collapsed.insert(name)
        } else {
            collapsed.remove(name)
        }
        UserDefaults.standard.set(collapsed.sorted(), forKey: collapsedKey)
        NotificationCenter.default.post(name: .terminalTabsDidChange, object: nil)
    }
}

extension TerminalWindow {
    /// Puts this window's tab in a sidebar group, or takes it out of its group when `name`
    /// is nil, and moves the tab next to the group's other tabs so that they stay together.
    @MainActor
    func moveToTabGroup(_ name: String?) {
        let previous = tabGroupName
        guard previous != name else { return }
        let siblings = tabbedWindows ?? [self]

        if let name {
            var existing: [String] = []
            for case let window as TerminalWindow in siblings {
                if let group = window.tabGroupName, !existing.contains(group) {
                    existing.append(group)
                }
            }
            TerminalTabGroupStore.assignColorIfNeeded(to: name, avoiding: existing)
        }

        // A tab joining a group goes after the group's last tab. A tab leaving one goes after
        // its old group's last tab, so that it doesn't split the group in two.
        let anchorGroup = name ?? previous
        let anchor = siblings.last { other in
            other !== self && (other as? TerminalWindow)?.tabGroupName == anchorGroup
        }
        tabGroupName = name
        if let anchor { moveTab(after: anchor, in: siblings) }
    }

    /// Moves this tab to just after another tab in the same window, keeping the selected tab.
    private func moveTab(after anchor: NSWindow, in siblings: [NSWindow]) {
        guard let tabGroup,
              let anchorIndex = siblings.firstIndex(of: anchor),
              siblings.firstIndex(of: self) != anchorIndex + 1
        else { return }
        let selected = tabGroup.selectedWindow

        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0
        tabGroup.removeWindow(self)
        anchor.addTabbedWindowSafely(self, ordered: .above)
        NSAnimationContext.endGrouping()

        selected?.makeKeyAndOrderFront(nil)
    }
}
