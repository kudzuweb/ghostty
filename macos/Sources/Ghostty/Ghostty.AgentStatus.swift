import Foundation

extension Ghostty {
    /// What a coding agent running in a terminal last reported about itself through OSC 7501
    /// (`ESC ] 7501 ; state=<state>:app=<app>[:kind=…][:msg=…] ST`).
    ///
    /// Claude Code and Codex both send it. Claude Code sends it only after the terminal
    /// answers its `OSC 7501 ; ?` query, which the core does. Checked against Claude Code
    /// 2.1.296 on 2026-10-13: `idle` at startup, `working` during a turn, `done` when the
    /// turn ends, `blocked` with `kind=permission` and a base64 `msg` while a permission
    /// prompt waits, and `clear` on exit. Codex (source at 0.162.1) sends `idle`, `working`,
    /// `blocked` and `clear`, and never `done`.
    struct AgentStatus: Equatable {
        enum State: String {
            case idle
            case working
            case blocked
            /// The turn finished. Only Claude Code sends it.
            case done
        }

        let state: State

        /// The `app` field, such as `claude-code` or `codex`.
        let app: String?

        /// Why the agent is blocked: `permission` or `question`. Nil otherwise.
        let kind: String?

        /// The decoded `msg` field, such as "approve Write: /path".
        let message: String?

        /// What one OSC 7501 payload asks the terminal to do with a surface's status.
        enum Update: Equatable {
            case set(AgentStatus)
            case clear
            /// A query, a status for a task inside the session (it carries an `id`), or a
            /// payload this parser does not understand. The surface's status is unchanged.
            case ignore
        }

        /// Parses the payload after `7501;`. Fields are `key=value` pairs joined by `:`, and
        /// `msg` and `title` are base64, so a value never contains a colon.
        static func parse(_ payload: String) -> Update {
            if payload.hasPrefix("?") { return .ignore }
            var fields: [String: String] = [:]
            for pair in payload.split(separator: ":") {
                guard let equals = pair.firstIndex(of: "=") else { continue }
                fields[String(pair[..<equals])] = String(pair[pair.index(after: equals)...])
            }
            // Only the session's own status drives the dot; per-task lines carry an `id`.
            if fields["id"] != nil { return .ignore }
            guard let rawState = fields["state"] else { return .ignore }
            if rawState == "clear" { return .clear }
            guard let state = State(rawValue: rawState) else { return .ignore }
            let message = fields["msg"]
                .flatMap { Data(base64Encoded: $0) }
                .flatMap { String(data: $0, encoding: .utf8) }
            return .set(AgentStatus(
                state: state,
                app: fields["app"],
                kind: state == .blocked ? fields["kind"] : nil,
                message: message))
        }
    }
}
