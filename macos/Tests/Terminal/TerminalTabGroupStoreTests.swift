import Testing
@testable import Ghostty

@MainActor
struct TerminalTabGroupStoreTests {
    private func withGroup(_ body: (String) -> Void) {
        let name = "test-group-\(UUID().uuidString)"
        defer { TerminalTabGroupStore.removePresentationIfUnused(name, referencedNames: []) }
        body(name)
    }

    @Test func newGroupTakesThePreferredColor() {
        withGroup { name in
            TerminalTabGroupStore.assignColorIfNeeded(to: name, avoiding: [], preferred: .brightTeal)
            #expect(TerminalTabGroupStore.color(for: name) == .brightTeal)
        }
    }

    @Test func noColorIsNotPreferred() {
        withGroup { name in
            TerminalTabGroupStore.assignColorIfNeeded(to: name, avoiding: [], preferred: TerminalTabColor.none)
            #expect(TerminalTabGroupStore.color(for: name) == .blue)
        }
    }

    @Test func existingColorWinsOverPreferred() {
        withGroup { name in
            TerminalTabGroupStore.setColor(.pink, for: name)
            TerminalTabGroupStore.assignColorIfNeeded(to: name, avoiding: [], preferred: .red)
            #expect(TerminalTabGroupStore.color(for: name) == .pink)
        }
    }

    @Test func automaticPicksNeverReturnCursorOrBackgroundColors() {
        var used: Set<TerminalTabColor> = []
        // Walk through every automatic color, then past the end so the cycle is covered too.
        for count in 0..<30 {
            let next = TerminalTabGroupStore.nextAutomaticColor(avoiding: used, groupCount: count)
            #expect(next != .purple)
            #expect(next != .pink)
            #expect(next != .graphite)
            #expect(next != .none)
            used.insert(next)
        }
    }

    @Test func automaticPicksSkipColorsInUse() {
        let next = TerminalTabGroupStore.nextAutomaticColor(avoiding: [.blue, .green], groupCount: 2)
        #expect(next == .orange)
    }
}
