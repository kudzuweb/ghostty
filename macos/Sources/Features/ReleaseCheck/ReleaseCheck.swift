import AppKit
import UserNotifications

/// A weekly look at upstream's tags for a new minor (or major) release. It reports what it
/// finds and never downloads or installs anything: the result is a pill in the update
/// pill's place and a macOS notification, both linking to the release. Patch releases of
/// the fork's base minor are ignored. The decisions are in `ReleaseCheckLogic.swift`.
///
/// Ghostty publishes no GitHub Releases for its versions (only the `tip` prerelease), so
/// the check reads the repository's tags, which carry every version.
@MainActor
final class ReleaseCheck: ObservableObject {
    static let shared = ReleaseCheck()

    struct Notice: Equatable {
        let version: ReleaseVersion
        var url: URL { ReleaseCheck.releaseURL(for: version) }
    }

    enum Status: Equatable {
        case idle
        case checking
        case upToDate
        case available(ReleaseVersion)
        case failed
    }

    nonisolated static let tagsURL = URL(string: "https://api.github.com/repos/ghostty-org/ghostty/tags?per_page=100")!

    nonisolated static func releaseURL(for version: ReleaseVersion) -> URL {
        URL(string: "https://github.com/ghostty-org/ghostty/releases/tag/\(version.tag)")!
    }

    private enum Key {
        static let lastCheck = "ReleaseCheckLastCheck"
        static let lastAttempt = "ReleaseCheckLastAttempt"
        static let latest = "ReleaseCheckLatest"
        static let dismissed = "ReleaseCheckDismissed"
        static let notified = "ReleaseCheckNotified"
    }

    @Published private(set) var status: Status = .idle
    @Published private(set) var lastCheck: Date?

    let base: ReleaseVersion
    var enabled = false

    private let defaults: UserDefaults
    private let fetchTags: () async throws -> [String]
    private let now: () -> Date
    private let present: @MainActor (Notice?) -> Void
    private let notify: @MainActor (Notice) -> Void
    private var timer: Timer?
    private var running = false

    init(
        defaults: UserDefaults = .standard,
        base: ReleaseVersion = ReleaseVersion(ForkBase.version) ?? ReleaseVersion(major: 0, minor: 0, patch: 0),
        fetchTags: @escaping () async throws -> [String] = ReleaseCheck.fetchUpstreamTags,
        now: @escaping () -> Date = Date.init,
        present: @escaping @MainActor (Notice?) -> Void = ReleaseCheck.presentInPill,
        notify: @escaping @MainActor (Notice) -> Void = ReleaseCheck.postNotification
    ) {
        self.defaults = defaults
        self.base = base
        self.fetchTags = fetchTags
        self.now = now
        self.present = present
        self.notify = notify
        lastCheck = defaults.object(forKey: Key.lastCheck) as? Date
    }

    // MARK: Lifecycle

    /// Brings the check in line with `release-check`: on, it shows what an earlier check
    /// found and checks if one is due; off, it clears the pill.
    func apply(enabled: Bool) {
        self.enabled = enabled
        guard enabled else {
            timer?.invalidate()
            timer = nil
            present(nil)
            status = .idle
            return
        }
        guard timer == nil else { return }
        evaluate(announce: false, ignoreDismissal: false)
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.run(force: false) }
        }
        Task { await run(force: false) }
    }

    // MARK: Checking

    /// Checks now, ignoring the weekly throttle and any dismissal.
    func checkNow() {
        Task { await run(force: true) }
    }

    /// One check: when `force` is false only if one is due. Offline and rate-limit failures
    /// are logged and retried after six hours.
    func run(force: Bool) async {
        guard enabled, !running else { return }
        let started = now()
        guard force || ReleaseCheckLogic.isDue(
            lastCheck: lastCheck, lastAttempt: defaults.object(forKey: Key.lastAttempt) as? Date, now: started
        ) else { return }

        running = true
        status = .checking
        defaults.set(started, forKey: Key.lastAttempt)
        defer { running = false }
        do {
            let tags = try await fetchTags()
            let latest = ReleaseCheckLogic.newestMinorRelease(tagNames: tags, base: base)
            lastCheck = started
            defaults.set(started, forKey: Key.lastCheck)
            if let latest {
                defaults.set(latest.tag, forKey: Key.latest)
                if force { defaults.removeObject(forKey: Key.dismissed) }
            } else {
                defaults.removeObject(forKey: Key.latest)
            }
            evaluate(announce: true, ignoreDismissal: force)
        } catch {
            NSLog("ReleaseCheck: the check failed quietly: %@", "\(error)")
            status = .failed
        }
    }

    /// Shows the stored result: the pill if there is a release newer than the dismissed one,
    /// and, when `announce` is set and this version has not been announced, a notification.
    private func evaluate(announce: Bool, ignoreDismissal: Bool) {
        guard let tag = defaults.string(forKey: Key.latest), let latest = ReleaseVersion(tag),
              latest.isNewMinor(than: base)
        else {
            present(nil)
            status = .upToDate
            return
        }
        guard ignoreDismissal || ReleaseCheckLogic.isShown(
            latest: latest, dismissed: defaults.string(forKey: Key.dismissed)
        ) else {
            present(nil)
            status = .upToDate
            return
        }
        let notice = Notice(version: latest)
        present(notice)
        status = .available(latest)
        if announce {
            let announced = defaults.string(forKey: Key.notified).flatMap(ReleaseVersion.init)
            if announced.map({ latest > $0 }) ?? true {
                defaults.set(latest.tag, forKey: Key.notified)
                notify(notice)
            }
        }
    }

    /// Hides the pill until a newer minor release than the one now showing appears.
    func dismiss() {
        if let tag = defaults.string(forKey: Key.latest), let latest = ReleaseVersion(tag) {
            defaults.set(latest.minorDescription, forKey: Key.dismissed)
        }
        present(nil)
        status = .upToDate
    }

    // MARK: Real network, pill and notification

    nonisolated static func fetchUpstreamTags() async throws -> [String] {
        var request = URLRequest(url: tagsURL, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Ghostty-fork-release-check", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        return ReleaseCheckLogic.tagNames(fromTagsResponse: data)
    }

    /// Shows or clears the notice on the update pill's view model. A Sparkle state that is
    /// already showing is left alone.
    static func presentInPill(_ notice: Notice?) {
        guard let model = (NSApp.delegate as? AppDelegate)?.updateViewModel else { return }
        if let notice {
            guard model.state.isIdle || model.state.isReleaseNotice else { return }
            model.state = .releaseAvailable(.init(
                version: notice.version.description,
                url: notice.url,
                dismiss: { Task { @MainActor in ReleaseCheck.shared.dismiss() } }))
        } else if model.state.isReleaseNotice {
            model.state = .idle
        }
    }

    static func postNotification(_ notice: Notice) {
        NSLog("ReleaseCheck notification: Ghostty %@ is out | %@", notice.version.description, notice.url.absoluteString)
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { _, error in
            if let error { NSLog("ReleaseCheck: notification authorization failed: %@", "\(error)") }
        }
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized else {
                NSLog("ReleaseCheck: notifications are not authorized, so the notification was not shown")
                return
            }
            let content = UNMutableNotificationContent()
            content.title = "Ghostty \(notice.version.description) is out"
            content.body = "Click to open the release page."
            content.sound = .default
            content.userInfo = [releaseURLKey: notice.url.absoluteString]
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
            NSLog("ReleaseCheck: notification posted")
        }
    }

    /// The `userInfo` key holding the release page a notification opens.
    nonisolated static let releaseURLKey = "releaseURL"
}
