import Foundation

/// Edits the text of a Ghostty config file one setting at a time, leaving every other
/// line, comment and blank line as it was.
///
/// This type only transforms strings. `ConfigFile` reads and writes the real file.
enum ConfigFileEditor {
    /// The comment above the settings this fork adds. It is created once, the first time
    /// a fork setting is appended.
    static let forkHeader = "# Mauria's fork settings"

    /// The value of the last active `key = value` line, which is the one Ghostty uses.
    /// Returns nil when no active line sets the key, and "" for `key =` with no value.
    static func value(of key: String, in text: String) -> String? {
        for line in text.components(separatedBy: "\n").reversed() {
            if let value = parse(line, key: key) { return value }
        }
        return nil
    }

    /// Returns `text` with `key` set to `value`.
    ///
    /// The last active `key = ...` line is rewritten, because Ghostty uses the last
    /// occurrence of a key and a rewrite of an earlier line would have no effect. A key
    /// with no active line is appended: under the fork header when `underForkHeader` is
    /// true (the header is created if missing), otherwise at the end of the file.
    static func setting(_ key: String, to value: String, in text: String, underForkHeader: Bool = false) -> String {
        var lines = text.components(separatedBy: "\n")
        let newLine = "\(key) = \(value)"

        if let index = lines.lastIndex(where: { parse($0, key: key) != nil }) {
            let line = lines[index]
            let indent = String(line.prefix(while: { $0 == " " || $0 == "\t" }))
            let ending = line.hasSuffix("\r") ? "\r" : ""
            lines[index] = indent + newLine + ending
            return lines.joined(separator: "\n")
        }

        // The split leaves an empty last element when the text ends with a newline.
        let hadTrailingNewline = lines.last == ""
        if hadTrailingNewline { lines.removeLast() }

        if underForkHeader {
            if let header = lines.firstIndex(where: {
                $0.trimmingCharacters(in: .whitespaces) == forkHeader
            }) {
                // End of the block: the first blank line after the header, or the end.
                var end = header + 1
                while end < lines.count, !lines[end].trimmingCharacters(in: .whitespaces).isEmpty {
                    end += 1
                }
                lines.insert(newLine, at: end)
            } else {
                if let last = lines.last, !last.trimmingCharacters(in: .whitespaces).isEmpty {
                    lines.append("")
                }
                lines.append(forkHeader)
                lines.append(newLine)
            }
        } else {
            lines.append(newLine)
        }

        return lines.joined(separator: "\n") + "\n"
    }

    /// The value on a line of the form `key = value`, or nil for any other line. Comment
    /// lines never match.
    private static func parse(_ line: String, key: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.hasPrefix("#"), trimmed.hasPrefix(key) else { return nil }
        let rest = trimmed.dropFirst(key.count).drop(while: { $0 == " " || $0 == "\t" })
        guard rest.hasPrefix("=") else { return nil }
        var value = rest.dropFirst().trimmingCharacters(in: .whitespacesAndNewlines)
        if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
            value = String(value.dropFirst().dropLast())
        }
        return value
    }
}
