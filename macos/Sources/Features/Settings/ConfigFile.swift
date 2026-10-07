import AppKit
import GhosttyKit

/// Reads and writes the config file Ghostty loads, so the settings panel and the sidebar
/// menu change the same file a person or an agent edits by hand.
enum ConfigFile {
    /// The file Ghostty opens for "Open Configuration". Ghostty creates it, and its
    /// directory, when it is missing. Nil if Ghostty can't produce a path.
    static var path: String? {
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
        reload: Bool = true
    ) -> String? {
        guard let path = path ?? Self.path else { return "Couldn't find Ghostty's config file." }
        let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        do {
            let text = FileManager.default.fileExists(atPath: url.path)
                ? try String(contentsOf: url, encoding: .utf8)
                : ""
            let updated = ConfigFileEditor.setting(key, to: value, in: text, underForkHeader: underForkHeader)
            if updated != text {
                try updated.write(to: url, atomically: true, encoding: .utf8)
            }
        } catch {
            return "Couldn't write \(url.path): \(error.localizedDescription)"
        }
        if reload { (NSApp.delegate as? AppDelegate)?.ghostty.reloadConfig() }
        return nil
    }
}
