import SwiftUI

/// What the status dot in the vertical tab sidebar shows for a tab: the most urgent state
/// among the coding agents running in the tab's terminals.
struct TerminalTabAgentIndicator: Equatable {
    /// The looks a dot can have. The cases are in priority order, most urgent first.
    enum Kind: Int, Comparable {
        /// The agent stopped on an API error.
        case error
        case blocked
        case working
        case done
        case idle

        static func < (lhs: Kind, rhs: Kind) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    let kind: Kind

    /// Why the agent is blocked: `permission` or `question`.
    var blockedKind: String?

    /// What the blocked agent is waiting on, such as "approve Write: /path".
    var message: String?

    /// Combines the statuses of a tab's terminals into one indicator, or nil when none of
    /// them runs an agent. `errored` says which terminals stopped on an API error. A tab that
    /// is selected has been looked at, so `done` shows as `idle` there.
    static func aggregate(
        _ statuses: [(status: Ghostty.AgentStatus?, errored: Bool)],
        isSelected: Bool
    ) -> TerminalTabAgentIndicator? {
        var best: TerminalTabAgentIndicator?
        for (status, errored) in statuses {
            let candidate: TerminalTabAgentIndicator
            if errored {
                candidate = .init(kind: .error, message: status?.message)
            } else if let status {
                switch status.state {
                case .blocked: candidate = .init(kind: .blocked, blockedKind: status.kind, message: status.message)
                case .working: candidate = .init(kind: .working)
                case .done: candidate = .init(kind: isSelected ? .idle : .done)
                case .idle: candidate = .init(kind: .idle)
                }
            } else {
                continue
            }
            if best == nil || candidate.kind < best!.kind { best = candidate }
        }
        return best
    }

    /// The tooltip and accessibility text for the dot.
    var description: String {
        switch kind {
        case .error: "Agent stopped on an API error"
        case .blocked:
            switch (blockedKind, message) {
            case ("question", let message?): "Agent has a question: \(message)"
            case ("question", nil): "Agent has a question"
            case (_, let message?): "Agent waiting for permission: \(message)"
            default: "Agent waiting for permission"
            }
        case .working: "Agent working"
        case .done: "Agent finished"
        case .idle: "Agent idle"
        }
    }
}

extension Ghostty.AgentStatus {
    /// The same status with a new state. A finished turn becomes `idle` once its tab has
    /// been looked at.
    func with(state: State) -> Ghostty.AgentStatus {
        Ghostty.AgentStatus(state: state, app: app, kind: kind, message: message)
    }
}

/// The status dot: 8pt in a row, smaller in a rail tile. A filled dot carries a 1pt outline
/// in the sidebar's background color so that it stays visible on a row tinted the same hue.
struct TerminalTabAgentDot: View {
    let kind: TerminalTabAgentIndicator.Kind
    var size: CGFloat = 8

    @Environment(\.terminalTabSidebarPalette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isDim = false

    var body: some View {
        Group {
            switch kind {
            case .idle:
                Circle().strokeBorder(Color.secondary, lineWidth: 1)
            case .working:
                filled(palette.foreground ?? Color.primary)
                    .opacity(reduceMotion || !isDim ? 1 : 0.35)
                    .animation(
                        reduceMotion ? nil : .easeInOut(duration: 0.9).repeatForever(autoreverses: true),
                        value: isDim
                    )
                    .onAppear { isDim = true }
            case .error:
                filled(palette.statusColor(.error))
            case .blocked:
                filled(palette.statusColor(.blocked))
            case .done:
                filled(palette.statusColor(.done))
            }
        }
        .frame(width: size, height: size)
    }

    private func filled(_ color: Color) -> some View {
        Circle()
            .fill(color)
            .overlay(Circle().strokeBorder(palette.background, lineWidth: 1))
    }
}
