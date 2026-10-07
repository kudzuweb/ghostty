import Foundation

// The usage cutoff, ported from the retired watchdog (`scripts/watchdog/watch.py` in
// claudemonorepo). Nothing here touches AppKit, so it can be tested on synthetic timestamps.

/// When agent work must stop so the workday starts in a usage window that is mostly unused.
/// Nothing exposes the real usage, so the windows are rebuilt from the timestamps of Claude
/// Code's assistant messages, and "at most half used" is a time stand-in (`usable`).
enum UsageCutoff {
    struct Settings: Equatable {
        /// The length of one usage window.
        var window: TimeInterval = 5 * 3600
        /// Work stops this long before the point the cutoff aims at.
        var margin: TimeInterval = 15 * 60
        /// How much of the workday's window may be used.
        var usable: TimeInterval = 2 * 3600
        /// How long after the workday starts its window may reset.
        var latestReset: TimeInterval = 2 * 3600
        /// The workday start, in minutes after local midnight.
        var workdayMinutes = 10 * 60
    }

    /// How far back transcripts are read, by modification time.
    static let horizon: TimeInterval = 36 * 3600

    // MARK: The computation

    /// The next occurrence of the workday start that is today if it has not passed, and
    /// otherwise tomorrow. A moment exactly at the start counts as passed, like the
    /// watchdog's `now().time() < WORKDAY`.
    static func workday(after now: Date, workdayMinutes: Int, calendar: Calendar = .current) -> Date {
        let nowMinutes = minutesIntoDay(now, calendar: calendar)
        let dayStart = calendar.startOfDay(for: now)
        let day = nowMinutes < Double(workdayMinutes)
            ? dayStart
            : calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart.addingTimeInterval(86400)
        return calendar.date(
            bySettingHour: workdayMinutes / 60, minute: workdayMinutes % 60, second: 0, of: day) ?? day
    }

    /// When work must stop, or nil while a later window still ends before the workday
    /// (so nothing needs winding down yet). `stamps` are assistant-message times.
    ///
    /// The window the workday starts in is the last window rebuilt from the stamps, or the
    /// one after it. If it ends before the workday, the next one is looked at: when that
    /// one ends before the workday too there is nothing to do; when it ends within
    /// `latestReset` after the workday the cutoff is the earlier of "`usable` into it" and the
    /// workday, less the margin; otherwise work stops a margin before the current window ends.
    /// A window that spans the workday and resets within `latestReset` of it gives the same
    /// formula from its own start. Any later reset means the window is already too far gone,
    /// so the cutoff is now.
    static func cutoff(
        stamps: [Date],
        now: Date,
        settings: Settings,
        calendar: Calendar = .current
    ) -> Date? {
        let sorted = stamps.sorted()
        guard var start = sorted.first else { return nil }
        for stamp in sorted where stamp >= start.addingTimeInterval(settings.window) {
            start = stamp
        }
        let end = start.addingTimeInterval(settings.window)
        let workday = workday(after: now, workdayMinutes: settings.workdayMinutes, calendar: calendar)

        if end <= workday {
            let nextEnd = end.addingTimeInterval(settings.window)
            if nextEnd <= workday { return nil }
            if nextEnd <= workday.addingTimeInterval(settings.latestReset) {
                return min(end.addingTimeInterval(settings.usable), workday).addingTimeInterval(-settings.margin)
            }
            return end.addingTimeInterval(-settings.margin)
        }
        if end <= workday.addingTimeInterval(settings.latestReset) {
            return min(start.addingTimeInterval(settings.usable), workday).addingTimeInterval(-settings.margin)
        }
        return now
    }

    /// Fractional minutes since local midnight.
    private static func minutesIntoDay(_ date: Date, calendar: Calendar) -> Double {
        date.timeIntervalSince(calendar.startOfDay(for: date)) / 60
    }

    // MARK: Reading transcripts

    /// Where Claude Code keeps transcripts. `GHOSTTY_CLAUDE_PROJECTS_DIR` replaces it, so a
    /// test can supply synthetic transcripts.
    static var projectsDirectory: String {
        if let override = ProcessInfo.processInfo.environment["GHOSTTY_CLAUDE_PROJECTS_DIR"], !override.isEmpty {
            return override
        }
        return NSHomeDirectory() + "/.claude/projects"
    }

    /// The timestamps of every assistant message in transcripts (`**/*.jsonl` under `root`)
    /// modified within `horizon` of `now`, oldest first. Lines that do not parse are skipped.
    static func assistantTimestamps(root: String = projectsDirectory, now: Date = Date()) -> [Date] {
        let fileManager = FileManager.default
        guard let walker = fileManager.enumerator(
            at: URL(fileURLWithPath: root), includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]) else { return [] }
        let cutoffDate = now.addingTimeInterval(-horizon)
        var stamps: [Date] = []
        for case let url as URL in walker where url.pathExtension == "jsonl" {
            guard let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate, modified >= cutoffDate,
                let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { continue }
            stamps.append(contentsOf: timestamps(inTranscript: data))
        }
        return stamps.sorted()
    }

    /// The assistant-message timestamps in one transcript's JSON lines.
    static func timestamps(inTranscript data: Data) -> [Date] {
        let marker = Data(#""type":"assistant""#.utf8)
        var stamps: [Date] = []
        var lineStart = data.startIndex
        while lineStart < data.endIndex {
            let lineEnd = data[lineStart...].firstIndex(of: 0x0A) ?? data.endIndex
            let line = data[lineStart..<lineEnd]
            lineStart = lineEnd < data.endIndex ? data.index(after: lineEnd) : data.endIndex
            guard line.range(of: marker) != nil,
                  let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let text = object["timestamp"] as? String,
                  let date = parse(text)
            else { continue }
            stamps.append(date)
        }
        return stamps
    }

    static func parse(_ text: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: text) { return date }
        return ISO8601DateFormatter().date(from: text)
    }

    // MARK: Phases

    /// Where a tab stands relative to the cutoff.
    enum Phase: Equatable {
        /// No cutoff applies yet.
        case clear
        /// Within `warning` of the cutoff: sessions are asked to wrap up, and a crashed one
        /// is not relaunched.
        case winding
        /// At or past the cutoff: nothing is relaunched or nudged until the workday.
        case reached
    }

    static func phase(cutoff: Date?, now: Date, warning: TimeInterval) -> Phase {
        guard let cutoff else { return .clear }
        if now >= cutoff { return .reached }
        if now >= cutoff.addingTimeInterval(-warning) { return .winding }
        return .clear
    }

    /// Whether failed background sessions are held back from respawning: the cutoff applies
    /// to them (`usage-cutoff` or the overnight switch is on) and it has been reached, which
    /// holds until the workday starts even if a later computation moves the cutoff.
    static func holdsRespawn(
        applies: Bool,
        cutoff: Date?,
        now: Date,
        reachedWorkday: Date?,
        workday: Date
    ) -> Bool {
        guard applies else { return false }
        if reachedWorkday == workday { return true }
        guard let cutoff else { return false }
        return now >= cutoff
    }

    /// The wrap-up prompt typed into an idle Claude Code session in the warning window.
    static func wrapUpPrompt(cutoff: Date, calendar: Calendar = .current) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "HH:mm"
        return "Usage cutoff at \(formatter.string(from: cutoff)): finish the current step, commit, "
            + "write down where you are, and stop."
    }
}

/// How often a failed background session is respawned: at most `limit` times in any 60
/// minutes, then never again until the session's state leaves `failed`.
struct KeepAliveRespawnLimiter {
    enum Action: Equatable {
        case respawn(String)
        case giveUp(String)
    }

    private var windows: [String: KeepAliveCrashWindow] = [:]
    private var givenUp: Set<String> = []

    func hasGivenUp(on id: String) -> Bool { givenUp.contains(id) }

    /// What to do about the sessions listed as `failed` now. A session no longer listed as
    /// failed has changed state, so a give-up is forgotten along with its count and a later
    /// failure starts a fresh count. Without a give-up the count is kept, so a session that
    /// fails again right after each respawn still runs out of attempts.
    mutating func decide(failed: [String], now: Date, limit: Int) -> [Action] {
        let failedSet = Set(failed)
        for id in givenUp.subtracting(failedSet) {
            givenUp.remove(id)
            windows[id] = nil
        }

        var actions: [Action] = []
        for id in failed where !givenUp.contains(id) {
            var window = windows[id] ?? KeepAliveCrashWindow()
            let allowed = window.allowAttempt(at: now, limit: limit)
            windows[id] = window
            if allowed {
                actions.append(.respawn(id))
            } else {
                givenUp.insert(id)
                actions.append(.giveUp(id))
            }
        }
        return actions
    }
}
