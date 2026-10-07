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
    private let notify: @MainActor (Notice, @escaping @MainActor () -> Bool) async -> Bool
    private var timer: Timer?
    private var running = false
    private var generation = 0
    private var checkTask: Task<Void, Never>?

    init(
        defaults: UserDefaults = .standard,
        base: ReleaseVersion = ReleaseVersion(ForkBase.version) ?? ReleaseVersion(major: 0, minor: 0, patch: 0),
        fetchTags: @escaping () async throws -> [String] = ReleaseCheck.fetchUpstreamTags,
        now: @escaping () -> Date = Date.init,
        present: @escaping @MainActor (Notice?) -> Void = ReleaseCheck.presentInPill,
        notify: @escaping @MainActor (Notice, @escaping @MainActor () -> Bool) async -> Bool = ReleaseCheck.postNotification
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
        if self.enabled != enabled || !enabled { generation += 1 }
        self.enabled = enabled
        guard enabled else {
            checkTask?.cancel()
            checkTask = nil
            timer?.invalidate()
            timer = nil
            present(nil)
            status = .idle
            return
        }
        guard timer == nil else { return }
        evaluate(ignoreDismissal: false)
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.run(force: false) }
        }
        checkTask = Task { await run(force: false) }
    }

    // MARK: Checking

    /// Checks now, ignoring the weekly throttle and any dismissal.
    func checkNow() {
        checkTask = Task { await run(force: true) }
    }

    /// One check: when `force` is false only if one is due. Offline and rate-limit failures
    /// are logged and retried after six hours.
    func run(force: Bool) async {
        guard enabled || force, !running else { return }
        let started = now()
        guard force || ReleaseCheckLogic.isDue(
            lastCheck: lastCheck, lastAttempt: defaults.object(forKey: Key.lastAttempt) as? Date, now: started
        ) else { return }

        let token = generation
        running = true
        status = .checking
        defaults.set(started, forKey: Key.lastAttempt)
        defer { running = false }
        do {
            let tags = try await fetchTags()
            guard token == generation, !Task.isCancelled else { return }
            let latest = ReleaseCheckLogic.newestMinorRelease(tagNames: tags, base: base)
            lastCheck = started
            defaults.set(started, forKey: Key.lastCheck)
            if let latest {
                defaults.set(latest.tag, forKey: Key.latest)
                if force { defaults.removeObject(forKey: Key.dismissed) }
            } else {
                defaults.removeObject(forKey: Key.latest)
            }
            evaluate(ignoreDismissal: force)
            if let latest, ReleaseCheckLogic.isShown(latest: latest, dismissed: defaults.string(forKey: Key.dismissed)),
               defaults.string(forKey: Key.notified).flatMap(ReleaseVersion.init).map({ latest > $0 }) ?? true {
                let delivered = await notify(Notice(version: latest), { [weak self] in
                    self?.generation == token && !Task.isCancelled
                })
                if delivered, token == generation, !Task.isCancelled {
                    defaults.set(latest.tag, forKey: Key.notified)
                }
            }
        } catch {
            guard token == generation, !Task.isCancelled else { return }
            NSLog("ReleaseCheck: the check failed quietly: %@", "\(error)")
            status = .failed
        }
    }

    /// Shows a stored release newer than the dismissed one. Notification delivery is awaited by run.
    private func evaluate(ignoreDismissal: Bool) {
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
        guard let items = try JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              items.allSatisfy({ $0["name"] is String }) else { throw URLError(.cannotParseResponse) }
        return items.compactMap { $0["name"] as? String }
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

    static func postNotification(_ notice: Notice, isCurrent: @escaping @MainActor () -> Bool) async -> Bool {
        let center = UNUserNotificationCenter.current()
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound])
            guard granted, isCurrent() else { return false }
            let content = UNMutableNotificationContent()
            content.title = "Ghostty \(notice.version.description) is out"
            content.body = "Click to open the release page."
            content.sound = .default
            content.userInfo = [releaseURLKey: notice.url.absoluteString]
            try await center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
            return true
        } catch {
            NSLog("ReleaseCheck: notification was not delivered: %@", "\(error)")
            return false
        }
    }

    /// The `userInfo` key holding the release page a notification opens.
    nonisolated static let releaseURLKey = "releaseURL"
}
