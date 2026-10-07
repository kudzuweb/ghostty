import Testing
import Foundation
@testable import Ghostty

struct ReleaseVersionTests {
    private let base = ReleaseVersion("v1.3.1")!

    private func reported(_ tags: [String]) -> String? {
        ReleaseCheckLogic.newestMinorRelease(tagNames: tags, base: base)?.tag
    }

    @Test func aPatchOfTheBaseMinorIsNotReported() { #expect(reported(["v1.3.2"]) == nil) }
    @Test func aNewMinorIsReported() { #expect(reported(["v1.4.0"]) == "v1.4.0") }
    @Test func aNewMajorIsReported() { #expect(reported(["v2.0.0"]) == "v2.0.0") }
    @Test func aPrereleaseIsNotReported() { #expect(reported(["v1.4.0-rc1"]) == nil) }
    @Test func malformedTagsAreNotReported() {
        #expect(reported(["tip", "v1.4", "v1.x.0", "1.4.0.1", "", "v1..0", "v-1.4.0"]) == nil)
    }
    @Test func theNewestWinsAcrossAMixedList() {
        #expect(reported(["tip", "v1.3.2", "v1.4.0", "v1.4.2", "v1.4.1", "v1.4.0-rc1", "v1.2.0"]) == "v1.4.2")
    }
    @Test func olderAndEqualReleasesAreNotReported() { #expect(reported(["v1.3.1", "v1.3.0", "v1.2.3"]) == nil) }

    @Test func tagsAreReadFromAGitHubResponse() {
        let body = Data(#"[{"name":"v1.4.0","commit":{}},{"name":"tip"}]"#.utf8)
        #expect(ReleaseCheckLogic.tagNames(fromTagsResponse: body) == ["v1.4.0", "tip"])
        #expect(ReleaseCheckLogic.tagNames(fromTagsResponse: Data(#"{"message":"rate limited"}"#.utf8)).isEmpty)
    }

    @Test func theCheckIsDueAtMostOncePerWeek() {
        let now = Date(timeIntervalSince1970: 10_000_000)
        #expect(ReleaseCheckLogic.isDue(lastCheck: nil, lastAttempt: nil, now: now))
        #expect(!ReleaseCheckLogic.isDue(lastCheck: now.addingTimeInterval(-6 * 86400), lastAttempt: nil, now: now))
        #expect(ReleaseCheckLogic.isDue(lastCheck: now.addingTimeInterval(-7 * 86400), lastAttempt: nil, now: now))
    }

    @Test func aFailedAttemptWaitsSixHours() {
        let now = Date(timeIntervalSince1970: 10_000_000)
        #expect(!ReleaseCheckLogic.isDue(lastCheck: nil, lastAttempt: now.addingTimeInterval(-3600), now: now))
        #expect(ReleaseCheckLogic.isDue(lastCheck: nil, lastAttempt: now.addingTimeInterval(-7 * 3600), now: now))
    }

    @Test func aDismissalKeepsTheMinorQuietUntilANewerMinor() {
        #expect(ReleaseCheckLogic.isShown(latest: ReleaseVersion("v1.4.0")!, dismissed: nil))
        #expect(!ReleaseCheckLogic.isShown(latest: ReleaseVersion("v1.4.0")!, dismissed: "1.4"))
        #expect(!ReleaseCheckLogic.isShown(latest: ReleaseVersion("v1.4.2")!, dismissed: "1.4"))
        #expect(ReleaseCheckLogic.isShown(latest: ReleaseVersion("v1.5.0")!, dismissed: "1.4"))
        #expect(ReleaseCheckLogic.isShown(latest: ReleaseVersion("v2.0.0")!, dismissed: "1.4"))
    }
}

@MainActor
struct ReleaseCheckFlowTests {
    private final class Recorder {
        var tags: [String] = []
        var fails = false
        var fetches = 0
        var shown: [String?] = []
        var notified: [String] = []
        var clock = Date(timeIntervalSince1970: 10_000_000)
    }

    private func make(_ recorder: Recorder) -> ReleaseCheck {
        let suite = "ReleaseCheckTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let check = ReleaseCheck(
            defaults: defaults,
            base: ReleaseVersion("v1.3.1")!,
            fetchTags: {
                recorder.fetches += 1
                if recorder.fails { throw URLError(.notConnectedToInternet) }
                return recorder.tags
            },
            now: { recorder.clock },
            present: { recorder.shown.append($0?.version.tag) },
            notify: { recorder.notified.append($0.version.tag) })
        check.enabled = true
        return check
    }

    @Test func aNewMinorShowsAndNotifiesOnce() async {
        let recorder = Recorder()
        recorder.tags = ["v1.3.2", "v1.4.0"]
        let check = make(recorder)
        await check.run(force: false)
        #expect(recorder.shown.last == "v1.4.0")
        #expect(recorder.notified == ["v1.4.0"])

        recorder.clock.addTimeInterval(8 * 86400)
        await check.run(force: false)
        #expect(recorder.fetches == 2)
        #expect(recorder.notified == ["v1.4.0"])
    }

    @Test func theThrottleSkipsASecondCheckWithinAWeek() async {
        let recorder = Recorder()
        let check = make(recorder)
        await check.run(force: false)
        recorder.clock.addTimeInterval(86400)
        await check.run(force: false)
        #expect(recorder.fetches == 1)
        await check.run(force: true)
        #expect(recorder.fetches == 2)
    }

    @Test func onlyAPatchShowsNothing() async {
        let recorder = Recorder()
        recorder.tags = ["v1.3.2"]
        let check = make(recorder)
        await check.run(force: false)
        #expect(recorder.shown.last == .some(nil))
        #expect(recorder.notified.isEmpty)
        #expect(check.status == .upToDate)
    }

    @Test func aDismissalStaysQuietUntilANewerMinor() async {
        let recorder = Recorder()
        recorder.tags = ["v1.4.0"]
        let check = make(recorder)
        await check.run(force: false)
        check.dismiss()
        #expect(recorder.shown.last == .some(nil))

        recorder.tags = ["v1.4.0", "v1.4.1"]
        recorder.clock.addTimeInterval(8 * 86400)
        await check.run(force: false)
        #expect(recorder.shown.last == .some(nil))
        #expect(recorder.notified == ["v1.4.0"])

        recorder.tags = ["v1.4.1", "v1.5.0"]
        recorder.clock.addTimeInterval(8 * 86400)
        await check.run(force: false)
        #expect(recorder.shown.last == "v1.5.0")
        #expect(recorder.notified == ["v1.4.0", "v1.5.0"])
    }

    @Test func aFailureIsQuietAndRetriesAfterSixHours() async {
        let recorder = Recorder()
        recorder.fails = true
        let check = make(recorder)
        await check.run(force: false)
        #expect(check.status == .failed)
        #expect(check.lastCheck == nil)
        #expect(recorder.notified.isEmpty)

        recorder.clock.addTimeInterval(3600)
        await check.run(force: false)
        #expect(recorder.fetches == 1)

        recorder.clock.addTimeInterval(6 * 3600)
        await check.run(force: false)
        #expect(recorder.fetches == 2)
    }
}
