import Foundation

// The decisions keep alive makes, as functions of plain values, so they can be tested on
// real transcript lines without a running terminal. Nothing here touches AppKit or Ghostty.

/// Which coding agent a session belongs to.
enum AgentTool: String {
    case claude
    case codex

    /// The command that resumes a session of this tool.
    func resumeCommand(sessionID: String) -> String {
        switch self {
        case .claude: "claude --resume \(sessionID)"
        case .codex: "codex resume \(sessionID)"
        }
    }
}

/// An API error Claude Code wrote to its transcript as the session's last conversation entry.
struct KeepAliveApiError: Equatable {
    /// The `error` field: `rate_limit`, `server_error`, `authentication_failed`,
    /// `model_not_found` and others.
    let type: String
    let message: String
    let timestamp: Date
    /// The transcript entry's `uuid`, which identifies one occurrence of the error.
    let uuid: String
}

enum KeepAliveTranscript {
    /// Entry types that record bookkeeping rather than the conversation. They are written
    /// after the last real entry, so they are skipped to find it.
    private static let bookkeeping: Set<String> = [
        "cost-state", "bridge-session", "last-prompt", "file-history-snapshot", "system",
        "attachment", "permission-mode", "queue-operation", "summary", "custom-title",
        "agent-name", "mode", "progress",
    ]

    /// The API error the transcript ends with, or nil when its last conversation entry is
    /// anything else. `tail` is the end of the transcript file, in its JSON lines form; its
    /// first line may be cut off and is ignored if it does not parse.
    static func lastApiError(inTail tail: String) -> KeepAliveApiError? {
        for line in tail.split(separator: "\n", omittingEmptySubsequences: true).reversed() {
            guard let data = line.data(using: .utf8),
                  let entry = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = entry["type"] as? String
            else { continue }
            if bookkeeping.contains(type) { continue }
            // The newest conversation entry decides: an error answered by anything newer
            // (a user message, a normal reply) is no longer the session's state.
            guard type == "assistant", entry["isApiErrorMessage"] as? Bool == true else { return nil }
            return KeepAliveApiError(
                type: entry["error"] as? String ?? "unknown",
                message: messageText(entry),
                timestamp: (entry["timestamp"] as? String).flatMap(parseTimestamp) ?? Date(),
                uuid: entry["uuid"] as? String ?? "")
        }
        return nil
    }

    private static func messageText(_ entry: [String: Any]) -> String {
        guard let message = entry["message"] as? [String: Any] else { return "" }
        if let text = message["content"] as? String { return text }
        let parts = message["content"] as? [[String: Any]] ?? []
        return parts.compactMap { $0["text"] as? String }.joined(separator: "\n")
    }

    private static func parseTimestamp(_ text: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: text) { return date }
        return ISO8601DateFormatter().date(from: text)
    }
}

enum KeepAliveResetTime {
    /// The moment a session limit lifts, from the text "You've hit your session limit ·
    /// resets 3:20am (America/Chicago)". The time has no date, so it is the first such time
    /// after `reference`, which is when the error happened. Nil when the message has no
    /// reset time or its zone is unknown.
    static func parse(_ message: String, after reference: Date) -> Date? {
        let pattern = #"resets\s+(\d{1,2})(?::(\d{2}))?\s*([ap])m\s*\(([^)]+)\)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: message, range: NSRange(message.startIndex..., in: message))
        else { return nil }
        func group(_ index: Int) -> String? {
            Range(match.range(at: index), in: message).map { String(message[$0]) }
        }
        guard let hourText = group(1), var hour = Int(hourText), (1...12).contains(hour),
              let meridiem = group(3)?.lowercased(),
              let zoneName = group(4), let zone = TimeZone(identifier: zoneName.trimmingCharacters(in: .whitespaces))
        else { return nil }
        let minute = group(2).flatMap { Int($0) } ?? 0
        guard (0..<60).contains(minute) else { return nil }
        hour = hour % 12 + (meridiem == "p" ? 12 : 0)

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar.nextDate(
            after: reference,
            matching: DateComponents(hour: hour, minute: minute, second: 0),
            matchingPolicy: .nextTime)
    }
}

/// How often a repeated action may happen: at most `limit` times in any `window`.
struct KeepAliveCrashWindow {
    private(set) var times: [Date] = []

    /// Records an attempt at `now` and returns true when it is within the limit. Returns
    /// false, recording nothing, when `limit` attempts already happened in the last `window`.
    mutating func allowAttempt(at now: Date, limit: Int, window: TimeInterval = 3600) -> Bool {
        times.removeAll { now.timeIntervalSince($0) >= window }
        guard times.count < limit else { return false }
        times.append(now)
        return true
    }
}

/// What to do about an API error in a live, idle Claude Code session.
struct KeepAliveErrorDecision: Equatable {
    /// Show a notification and write an `error_notified` event, once for this error.
    var notify = false
    /// Type `continue` and press Enter now.
    var nudge = false
}

enum KeepAliveErrorPolicy {
    static let resetMargin: TimeInterval = 60

    /// Applies the policy to an error that is the session's last entry.
    ///
    /// - `rate_limit` that names a reset time is nudged once, just after it, and then every
    ///   `rateLimitInterval` if the same error is still the last entry.
    /// - Other `rate_limit` errors (out of usage credits, or an unreadable reset time)
    ///   notify once and are nudged every `rateLimitInterval`.
    /// - `server_error` is nudged every `serverErrorInterval`.
    /// - Anything else notifies once and is never retried.
    ///
    /// `lastNudge` is when this same error was last nudged; `alreadyNotified` is whether it
    /// has been notified.
    static func decide(
        _ error: KeepAliveApiError,
        now: Date,
        lastNudge: Date?,
        alreadyNotified: Bool,
        serverErrorInterval: TimeInterval,
        rateLimitInterval: TimeInterval
    ) -> KeepAliveErrorDecision {
        var decision = KeepAliveErrorDecision()
        switch error.type {
        case "rate_limit":
            if let reset = KeepAliveResetTime.parse(error.message, after: error.timestamp) {
                let due = lastNudge.map { $0.addingTimeInterval(rateLimitInterval) }
                    ?? reset.addingTimeInterval(resetMargin)
                decision.nudge = now >= due
            } else {
                decision.notify = !alreadyNotified
                let due = (lastNudge ?? error.timestamp).addingTimeInterval(rateLimitInterval)
                decision.nudge = now >= due
            }
        case "server_error":
            let due = (lastNudge ?? error.timestamp).addingTimeInterval(serverErrorInterval)
            decision.nudge = now >= due
        default:
            decision.notify = !alreadyNotified
        }
        return decision
    }
}

enum KeepAliveExit {
    /// Whether a tool's exit status means a person ended it. 0 is a normal exit (`/exit`,
    /// Ctrl-D), and 130 is Ctrl-C. Anything else is a crash or a kill. A missing status
    /// means it is unknown, which is never treated as a crash.
    static func isDeliberate(exitCode: Int16) -> Bool {
        exitCode == 0 || exitCode == 130
    }
}

/// A background session as `claude agents --json --all` lists it.
struct KeepAliveBackgroundSession: Equatable {
    let id: String
    let name: String
    let state: String
}

enum KeepAliveAgents {
    /// What `claude agents --json --all` said at one moment.
    struct Snapshot: Equatable {
        /// The `status` (`idle`, `waiting` or `busy`) of each interactive session, by pid.
        var interactiveStatus: [Int: String] = [:]
        var background: [KeepAliveBackgroundSession] = []
    }

    static func parse(_ data: Data) -> Snapshot? {
        guard let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        var snapshot = Snapshot()
        for entry in entries {
            switch entry["kind"] as? String {
            case "interactive":
                if let pid = entry["pid"] as? Int, let status = entry["status"] as? String {
                    snapshot.interactiveStatus[pid] = status
                }
            case "background":
                if let id = entry["id"] as? String, let state = entry["state"] as? String {
                    snapshot.background.append(.init(id: id, name: entry["name"] as? String ?? "", state: state))
                }
            default:
                continue
            }
        }
        return snapshot
    }

    /// The background sessions to respawn: only those that failed. A `stopped` session was
    /// stopped by a person and a `done` one finished, so neither is touched.
    static func respawnTargets(_ sessions: [KeepAliveBackgroundSession]) -> [KeepAliveBackgroundSession] {
        sessions.filter { $0.state == "failed" }
    }
}
