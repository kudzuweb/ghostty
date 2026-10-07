import Testing
import Foundation
@testable import Ghostty

/// The expected values were produced by running the watchdog's `usage_cutoff()`
/// (`scripts/watchdog/watch.py` in claudemonorepo) on the same timestamps with `TZ=UTC`.
struct UsageCutoffTests {
    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private func date(_ text: String) -> Date {
        UsageCutoff.parse("2026-10-\(text):00Z")!
    }

    private func cutoff(
        now: String,
        stamps: [String],
        settings: UsageCutoff.Settings = .init()
    ) -> Date? {
        UsageCutoff.cutoff(
            stamps: stamps.map(date), now: date(now), settings: settings, calendar: Self.calendar)
    }

    @Test func noStampsMeansNoCutoff() {
        #expect(cutoff(now: "07T22:00", stamps: []) == nil)
    }

    @Test func laterWindowEndsBeforeWorkday() {
        #expect(cutoff(now: "07T22:00", stamps: ["07T13:00"]) == nil)
    }

    @Test func nextWindowResetsWithinLatestReset() {
        #expect(cutoff(now: "08T02:00", stamps: ["08T01:00"]) == date("08T07:45"))
    }

    @Test func nextWindowResetsTooLate() {
        #expect(cutoff(now: "08T03:00", stamps: ["08T02:30"]) == date("08T07:15"))
    }

    @Test func windowSpansWorkdayAndResetsInTime() {
        #expect(cutoff(now: "08T08:00", stamps: ["08T07:00"]) == date("08T08:45"))
    }

    @Test func usableCappedAtWorkday() {
        var settings = UsageCutoff.Settings()
        settings.latestReset = 6 * 3600
        #expect(cutoff(now: "08T09:30", stamps: ["08T09:00"], settings: settings) == date("08T09:45"))
    }

    @Test func windowResetsTooLateMeansNow() {
        #expect(cutoff(now: "08T08:30", stamps: ["08T08:15"]) == date("08T08:30"))
    }

    @Test func windowsAreRebuiltFromTheStamps() {
        #expect(cutoff(now: "08T02:00", stamps: ["07T20:00", "08T00:30", "08T01:10"]) == date("08T07:55"))
    }

    @Test func afterTheWorkdayTargetsTomorrow() {
        #expect(cutoff(now: "08T14:00", stamps: ["08T12:00"]) == nil)
    }

    @Test func customSettings() {
        var settings = UsageCutoff.Settings()
        settings.workdayMinutes = 510
        settings.usable = 3600
        settings.margin = 300
        #expect(cutoff(now: "08T01:00", stamps: ["08T00:30"], settings: settings) == date("08T06:25"))
    }

    @Test func fractionalSecondsSurvive() {
        let now = UsageCutoff.parse("2026-10-08T07:30:00.5Z")!
        let stamp = UsageCutoff.parse("2026-10-08T05:00:00.123Z")!
        let result = UsageCutoff.cutoff(stamps: [stamp], now: now, settings: .init(), calendar: Self.calendar)
        #expect(abs(result!.timeIntervalSince(stamp) - (2 * 3600 - 15 * 60)) < 0.001)
    }

    @Test func workdayAtExactlyTheStartCountsAsPassed() {
        let start = date("08T10:00")
        let next = UsageCutoff.workday(after: start, workdayMinutes: 600, calendar: Self.calendar)
        #expect(next == date("09T10:00"))
    }

    @Test func phases() {
        let cutoff = date("08T07:00")
        #expect(UsageCutoff.phase(cutoff: nil, now: cutoff, warning: 1500) == .clear)
        #expect(UsageCutoff.phase(cutoff: cutoff, now: date("08T06:34"), warning: 1500) == .clear)
        #expect(UsageCutoff.phase(cutoff: cutoff, now: date("08T06:35"), warning: 1500) == .winding)
        #expect(UsageCutoff.phase(cutoff: cutoff, now: date("08T07:00"), warning: 1500) == .reached)
    }

    @Test func wrapUpPromptNamesTheCutoff() {
        #expect(UsageCutoff.wrapUpPrompt(cutoff: date("08T07:45"), calendar: Self.calendar)
            == "Usage cutoff at 07:45: finish the current step, commit, write down where you are, and stop.")
    }

    @Test func onlyAssistantLinesCount() {
        let transcript = """
        {"type":"user","timestamp":"2026-10-08T01:00:00.000Z"}
        {"type":"assistant","timestamp":"2026-10-08T01:05:00.250Z"}
        not json {"type":"assistant"
        {"type":"assistant","timestamp":"2026-10-08T01:06:00Z"}
        """
        let stamps = UsageCutoff.timestamps(inTranscript: Data(transcript.utf8))
        #expect(stamps.count == 2)
    }
}

struct KeepAliveRespawnLimiterTests {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func givesUpAfterTheLimitAndStaysGivenUp() {
        var limiter = KeepAliveRespawnLimiter()
        var all: [KeepAliveRespawnLimiter.Action] = []
        for tick in 0..<8 {
            all += limiter.decide(failed: ["a"], now: start.addingTimeInterval(Double(tick) * 30), limit: 3)
        }
        #expect(all == [.respawn("a"), .respawn("a"), .respawn("a"), .giveUp("a")])
    }

    @Test func staysGivenUpPastAnHourWhileStillFailed() {
        var limiter = KeepAliveRespawnLimiter()
        for tick in 0..<4 { _ = limiter.decide(failed: ["a"], now: start.addingTimeInterval(Double(tick)), limit: 3) }
        #expect(limiter.hasGivenUp(on: "a"))
        #expect(limiter.decide(failed: ["a"], now: start.addingTimeInterval(7200), limit: 3).isEmpty)
    }

    @Test func respawnsAgainOnceTheStateLeavesFailed() {
        var limiter = KeepAliveRespawnLimiter()
        for tick in 0..<4 { _ = limiter.decide(failed: ["a"], now: start.addingTimeInterval(Double(tick)), limit: 3) }
        #expect(limiter.decide(failed: [], now: start.addingTimeInterval(60), limit: 3).isEmpty)
        #expect(!limiter.hasGivenUp(on: "a"))
        #expect(limiter.decide(failed: ["a"], now: start.addingTimeInterval(120), limit: 3) == [.respawn("a")])
    }

    @Test func aSessionThatFailsAgainAfterEachRespawnStillRunsOut() {
        var limiter = KeepAliveRespawnLimiter()
        var actions: [KeepAliveRespawnLimiter.Action] = []
        for tick in 0..<4 {
            actions += limiter.decide(failed: ["a"], now: start.addingTimeInterval(Double(tick) * 60), limit: 3)
            _ = limiter.decide(failed: [], now: start.addingTimeInterval(Double(tick) * 60 + 30), limit: 3)
        }
        #expect(actions == [.respawn("a"), .respawn("a"), .respawn("a"), .giveUp("a")])
    }

    @Test func sessionsAreCountedSeparately() {
        var limiter = KeepAliveRespawnLimiter()
        for tick in 0..<4 { _ = limiter.decide(failed: ["a"], now: start.addingTimeInterval(Double(tick)), limit: 3) }
        #expect(limiter.decide(failed: ["a", "b"], now: start.addingTimeInterval(10), limit: 3) == [.respawn("b")])
    }
}

struct RespawnHoldTests {
    private let now = Date(timeIntervalSince1970: 1_000_000)
    private let workday = Date(timeIntervalSince1970: 1_050_000)

    private func held(
        applies: Bool = true,
        cutoff: Date?,
        reached: Date? = nil
    ) -> Bool {
        UsageCutoff.holdsRespawn(applies: applies, cutoff: cutoff, now: now, reachedWorkday: reached, workday: workday)
    }

    @Test func notHeldWhenTheCutoffDoesNotApply() {
        #expect(!held(applies: false, cutoff: now.addingTimeInterval(-60), reached: workday))
    }

    @Test func notHeldWithoutACutoff() {
        #expect(!held(cutoff: nil))
    }

    @Test func notHeldBeforeTheCutoff() {
        #expect(!held(cutoff: now.addingTimeInterval(60)))
    }

    @Test func heldAtAndAfterTheCutoff() {
        #expect(held(cutoff: now))
        #expect(held(cutoff: now.addingTimeInterval(-60)))
    }

    @Test func heldUntilTheWorkdayEvenIfTheCutoffMovesLater() {
        #expect(held(cutoff: now.addingTimeInterval(3600), reached: workday))
        #expect(held(cutoff: nil, reached: workday))
    }

    @Test func aReachMarkFromAnEarlierWorkdayHoldsNothing() {
        #expect(!held(cutoff: nil, reached: workday.addingTimeInterval(-86400)))
    }
}
