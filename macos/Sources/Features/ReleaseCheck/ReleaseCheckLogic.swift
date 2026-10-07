import Foundation

/// A release version such as `v1.4.0`. Only plain `vMAJOR.MINOR.PATCH` tags parse, so
/// release candidates, `tip` and anything malformed are never reported.
struct ReleaseVersion: Comparable, Equatable {
    let major: Int
    let minor: Int
    let patch: Int

    init(major: Int, minor: Int, patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    /// Parses `v1.4.0` or `1.4.0`; nil for anything else.
    init?(_ text: String) {
        let trimmed = text.hasPrefix("v") ? String(text.dropFirst()) : text
        let parts = trimmed.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        let numbers = parts.compactMap { part -> Int? in
            guard !part.isEmpty, part.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
            return Int(part)
        }
        guard numbers.count == 3 else { return nil }
        self.init(major: numbers[0], minor: numbers[1], patch: numbers[2])
    }

    static func < (lhs: ReleaseVersion, rhs: ReleaseVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }

    var description: String { "\(major).\(minor).\(patch)" }
    var minorDescription: String { "\(major).\(minor)" }
    var tag: String { "v\(description)" }

    /// Whether this release is a new minor or major relative to `base`: a patch of the
    /// base's own minor is not.
    func isNewMinor(than base: ReleaseVersion) -> Bool {
        (major, minor) > (base.major, base.minor)
    }
}

/// The decisions of the weekly release check. Nothing here touches the network or the UI.
enum ReleaseCheckLogic {
    /// The check runs at most once a week.
    static let interval: TimeInterval = 7 * 24 * 3600
    /// After a failed attempt (offline, rate limited) the next try waits this long.
    static let retryInterval: TimeInterval = 6 * 3600

    /// The newest release among `tagNames` whose major.minor is greater than the base's, or
    /// nil. Tags that are not plain `vMAJOR.MINOR.PATCH` are ignored.
    static func newestMinorRelease(tagNames: [String], base: ReleaseVersion) -> ReleaseVersion? {
        tagNames.compactMap(ReleaseVersion.init)
            .filter { $0.isNewMinor(than: base) }
            .max()
    }

    /// The tag names in a GitHub `/tags` response; empty when the body is not that.
    static func tagNames(fromTagsResponse data: Data) -> [String] {
        guard let items = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return items.compactMap { $0["name"] as? String }
    }

    /// Whether a check is due: a week after the last successful check, and (after a failure)
    /// six hours after the last attempt.
    static func isDue(lastCheck: Date?, lastAttempt: Date?, now: Date) -> Bool {
        if let lastCheck, now.timeIntervalSince(lastCheck) < interval { return false }
        if let lastAttempt, now.timeIntervalSince(lastAttempt) < retryInterval { return false }
        return true
    }

    /// Whether `latest` is worth showing: it is a new minor over the dismissed one. A
    /// dismissal is stored as the version's `major.minor`, so a later patch of the same
    /// minor stays quiet.
    static func isShown(latest: ReleaseVersion, dismissed: String?) -> Bool {
        guard let dismissed, let dismissedVersion = ReleaseVersion(dismissed + ".0") else { return true }
        return latest.isNewMinor(than: dismissedVersion)
    }
}
