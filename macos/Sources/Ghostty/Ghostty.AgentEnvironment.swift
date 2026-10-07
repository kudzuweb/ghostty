import Foundation

extension Ghostty {
    /// Explicit process identity and harness transport keys. Configuration such as
    /// CLAUDE_CODE_USE_BEDROCK, ANTHROPIC_* and CODEX_HOME intentionally survives.
    static let agentEnvironmentNames: Set<String> = [
        "CLAUDECODE", "CLAUDE_CODE_SESSION_ID", "CLAUDE_SESSION_ID",
        "CLAUDE_CODE_ENTRYPOINT", "CLAUDE_CODE_PARENT_SESSION_ID",
        "CLAUDE_CODE_CHILD_SESSION", "CLAUDE_PID", "CLAUDE_CODE_MESSAGING_SOCKET",
        "CLAUDE_CODE_MESSAGING_TOKEN", "CLAUDE_CODE_SSE_PORT",
        "CODEX_THREAD_ID", "CODEX_SESSION_ID", "CODEX_SANDBOX", "CODEX_SANDBOX_NETWORK_DISABLED",
        "CODEX_APP_TOOLS_PIPE_PATH", "CODEX_INTERNAL_ORIGINATOR_OVERRIDE",
        "CODEX_TASK_WORKSPACE_VERIFYING_IDENTITY", "CODEX_SAGE_BACKFILL_TRACKER_TAB_REUSE",
    ]

    static func shouldStripAgentEnvironment(_ name: String) -> Bool {
        agentEnvironmentNames.contains(name) || name.hasPrefix("CODEX_MANAGED_")
    }

    static func stripAgentEnvironment() {
        let names = ProcessInfo.processInfo.environment.keys.filter(shouldStripAgentEnvironment).sorted()
        for name in names { unsetenv(name) }
        if !names.isEmpty { logger.info("stripped agent environment variables: \(names.joined(separator: ", "))") }
    }

    static var isDailyForkProfile: Bool { Bundle.main.bundleIdentifier == "com.mitchellh.ghostty" }

    static var forkProfileStateDirectory: URL {
        let root = FileManager.default.homeDirectoryForCurrentUser
        if isDailyForkProfile { return root.appendingPathComponent(".local/state/ghostty") }
        return root.appendingPathComponent("Library/Application Support/\(Bundle.main.bundleIdentifier ?? "ghostty.unidentified")/fork-profile/state")
    }

    /// Explicit test roots may only point inside the bundle's isolated profile.
    /// Resolve symlinks before accepting an override so a test cannot edit daily config.
    static func isolatedConfigPath(root: URL, arguments: [String], override: String?) throws -> URL {
        var explicit: [String] = []
        var index = 1
        while index < arguments.count {
            let argument = arguments[index]
            if argument.hasPrefix("--config-file=") {
                explicit.append(String(argument.dropFirst(14)))
            } else if argument == "--config-file", index + 1 < arguments.count {
                index += 1; explicit.append(arguments[index])
            }
            index += 1
        }
        guard explicit.count <= 1 else { throw CocoaError(.fileReadInvalidFileName) }
        let candidate = explicit.first ?? override.flatMap { $0.isEmpty ? nil : $0 }
        let config = candidate.map { URL(fileURLWithPath: $0) } ?? root.appendingPathComponent("config/ghostty/config")
        let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL
        let candidateURL = config.standardizedFileURL
        guard resolvedRoot == root.standardizedFileURL,
              candidateURL.path.hasPrefix(resolvedRoot.path + "/") else { throw CocoaError(.fileWriteNoPermission) }
        // Foundation can leave a symlink unresolved when the final file is missing.
        // Reject symlink components in test roots, including dangling links, rather
        // than trusting an incomplete resolution and creating a daily file through it.
        var component = candidateURL
        while component != resolvedRoot {
            if (try? FileManager.default.destinationOfSymbolicLink(atPath: component.path)) != nil {
                throw CocoaError(.fileWriteNoPermission)
            }
            component.deleteLastPathComponent()
        }
        return candidateURL
    }

    /// Debug and uniquely identified scratch bundles cannot read or write daily config.
    /// Run before ghostty_init; every launch route, including launchd, gets this profile.
    static func configureForkProfile() {
        guard !isDailyForkProfile else { return }
        let root = forkProfileStateDirectory.deletingLastPathComponent()
        let configRoot = root.appendingPathComponent("config")
        do {
            let config = try isolatedConfigPath(root: root, arguments: ProcessInfo.processInfo.arguments,
                                                override: ProcessInfo.processInfo.environment["GHOSTTY_FORK_CONFIG_FILE"])
            try FileManager.default.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: forkProfileStateDirectory, withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: config.path) {
                let text = "# Isolated fork test profile\nwindow-save-state = always\nkeep-alive-background = off\nkeep-alive-relaunch-ghostty = false\nsleep-guard-mode = manual\nrelease-check = false\nkeep-alive-events-file = \(forkProfileStateDirectory.appendingPathComponent("keep-alive-events.jsonl").path)\n"
                try text.write(to: config, atomically: true, encoding: .utf8)
            }
            setenv("XDG_CONFIG_HOME", configRoot.path, 1)
            setenv("GHOSTTY_FORK_CONFIG_FILE", config.path, 1)
        } catch {
            // A test app must never fall through to daily configuration.
            fputs("Ghostty isolated profile could not be created: \(error)\n", stderr)
            exit(1)
        }
    }
}
