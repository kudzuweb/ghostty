import AppKit
import GhosttyKit

/// Reads and writes the config file Ghostty loads, so the settings panel and the sidebar
/// menu change the same file a person or an agent edits by hand.
enum ConfigFile {
    /// The file Ghostty opens for "Open Configuration". Ghostty creates it, and its
    /// directory, when it is missing. Nil if Ghostty can't produce a path.
    /// `GHOSTTY_FORK_CONFIG_FILE` replaces it.
    static var path: String? {
        // A test points this at a scratch file so it never writes the live config.
        if let override = ProcessInfo.processInfo.environment["GHOSTTY_FORK_CONFIG_FILE"], !override.isEmpty {
            return override
        }
        if !Ghostty.isDailyForkProfile {
            return nil // Profile initialization must explicitly supply the editable root.
        }
        let explicit = explicitConfigPaths(ProcessInfo.processInfo.arguments)
        if !explicit.isEmpty { return explicit.count == 1 ? explicit[0] : nil }
        let path = Ghostty.AllocatedString(ghostty_config_open_path()).string
        return path.isEmpty ? nil : path
    }

    /// The current value of `key` in the file, or nil when no line sets it.
    static func value(of key: String, at path: String? = nil) -> String? {
        guard let path = path ?? Self.path else { return nil }
        let text = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        return ConfigFileEditor.value(of: key, in: text)
    }

    /// Writes `key = value` to the file, then asks Ghostty to reload it. Returns nil on
    /// success, or why the write failed. `reload` is false for tests against a scratch file.
    @MainActor
    @discardableResult
    static func set(
        _ key: String,
        to value: String,
        underForkHeader: Bool = false,
        at path: String? = nil,
        reload: Bool = true,
        beforeReplace: (() throws -> Void)? = nil
    ) -> String? {
        guard let path = path ?? Self.path else { return "Couldn't find Ghostty's config file." }
        let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            var coordinationError: NSError?
            var writeError: Error?
            NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { coordinatedURL in
                do {
                    let original = try read(coordinatedURL)
                    let text = String(data: original, encoding: .utf8)
                    guard let text else { throw CocoaError(.fileReadInapplicableStringEncoding) }
                    let updated = ConfigFileEditor.setting(key, to: value, in: text, underForkHeader: underForkHeader)
                    if updated != text {
                        try beforeReplace?()
                        guard try read(coordinatedURL) == original else { throw EditConflict() }
                        try updated.write(to: coordinatedURL, atomically: true, encoding: .utf8)
                    }
                } catch { writeError = error }
            }
            if let error = writeError ?? coordinationError { throw error }

        } catch {
            return "Couldn't write \(url.path): \(error.localizedDescription)"
        }
        NotificationCenter.default.post(name: .forkConfigDidChange, object: nil)
        if reload { (NSApp.delegate as? AppDelegate)?.ghostty.reloadConfig() }
        return nil
    }
    static func explicitConfigPaths(_ arguments: [String]) -> [String] {
        var paths: [String] = []
        var index = 1
        while index < arguments.count {
            let argument = arguments[index]
            if argument.hasPrefix("--config-file=") { paths.append(String(argument.dropFirst(14))) } else if argument == "--config-file", index + 1 < arguments.count {
                index += 1
                paths.append(arguments[index])
            }
            index += 1
        }
        return paths.filter { !$0.isEmpty }
    }

    private static func read(_ url: URL) throws -> Data {
        FileManager.default.fileExists(atPath: url.path) ? try Data(contentsOf: url) : Data()
    }

    private struct EditConflict: LocalizedError {
        var errorDescription: String? { "The configuration changed during this edit. Reload and try again; your edit was not saved." }
    }
}

extension Notification.Name {
    static let forkConfigDidChange = Notification.Name("forkConfigDidChange")
}
