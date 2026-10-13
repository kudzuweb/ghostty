import Testing
@testable import Ghostty

struct TerminalTabAgentIndicatorTests {
    private func status(_ state: Ghostty.AgentStatus.State, kind: String? = nil, message: String? = nil) -> Ghostty.AgentStatus {
        Ghostty.AgentStatus(state: state, app: "claude-code", kind: kind, message: message)
    }

    private func kind(_ statuses: [(Ghostty.AgentStatus?, Bool)], selected: Bool = false) -> TerminalTabAgentIndicator.Kind? {
        TerminalTabAgentIndicator.aggregate(statuses.map { (status: $0.0, errored: $0.1) }, isSelected: selected)?.kind
    }

    @Test func noAgentMeansNoDot() {
        #expect(kind([]) == nil)
        #expect(kind([(nil, false)]) == nil)
    }

    @Test func mostUrgentStateWins() {
        let all: [(Ghostty.AgentStatus?, Bool)] = [
            (status(.idle), false), (status(.done), false), (status(.working), false), (status(.blocked), false), (status(.idle), true),
        ]
        #expect(kind(all) == .error)
        #expect(kind(Array(all.dropLast())) == .blocked)
        #expect(kind(Array(all.dropLast(2))) == .working)
        #expect(kind(Array(all.dropLast(3))) == .done)
        #expect(kind(Array(all.dropLast(4))) == .idle)
    }

    @Test func errorShowsEvenWithoutAReportedStatus() {
        #expect(kind([(nil, true)]) == .error)
    }

    @Test func doneShowsAsIdleOnTheSelectedTab() {
        #expect(kind([(status(.done), false)], selected: true) == .idle)
        #expect(kind([(status(.done), false)], selected: false) == .done)
    }

    @Test func blockedDescriptionNamesTheReason() {
        let permission = TerminalTabAgentIndicator.aggregate([(status(.blocked, kind: "permission", message: "approve Write"), false)], isSelected: false)
        #expect(permission?.description == "Agent waiting for permission: approve Write")
        let question = TerminalTabAgentIndicator.aggregate([(status(.blocked, kind: "question", message: "Which one?"), false)], isSelected: false)
        #expect(question?.description == "Agent has a question: Which one?")
    }

    @Test func backgroundSessionsAreFilteredAndSorted() {
        func session(_ id: String, _ name: String, _ state: String) -> KeepAliveBackgroundSession {
            .init(id: id, name: name, state: state)
        }
        let listed = KeepAliveAgents.sidebarSessions([
            session("1", "zeta", "running"), session("2", "alpha", "queued"), session("3", "done-one", "done"),
            session("4", "beta", "failed"), session("5", "gamma", "blocked"), session("6", "stopped-one", "stopped"),
            session("7", "mystery", "hibernating"), session("8", "alpha", "running"),
        ])
        #expect(listed.map(\.id) == ["5", "4", "8", "1", "2"])
    }

    @Test func blockedSessionsAreAnnouncedOncePerBlock() {
        let blocked = KeepAliveBackgroundSession(id: "a", name: "one", state: "blocked")
        var result = KeepAliveAgents.newlyBlocked(in: [blocked], alreadyNotified: [])
        #expect(result.toAnnounce.map(\.id) == ["a"])
        result = KeepAliveAgents.newlyBlocked(in: [blocked], alreadyNotified: result.notified)
        #expect(result.toAnnounce.isEmpty)
        let running = KeepAliveBackgroundSession(id: "a", name: "one", state: "running")
        result = KeepAliveAgents.newlyBlocked(in: [running], alreadyNotified: result.notified)
        #expect(result.notified.isEmpty)
        result = KeepAliveAgents.newlyBlocked(in: [blocked], alreadyNotified: result.notified)
        #expect(result.toAnnounce.map(\.id) == ["a"])
    }
}
