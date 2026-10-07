import Foundation

extension Ghostty {
    /// Prefixes and exact names of environment variables that identify a
    /// running Claude Code or Codex session. User-configured variables such as
    /// `CODEX_HOME` are deliberately absent.
    private static let agentEnvironmentPrefixes = [
        "CLAUDE",
        "CODEX_SANDBOX",
        "CODEX_MANAGED_"
    ]
    private static let agentEnvironmentNames: Set<String> = [
        "CODEX_THREAD_ID",
        "CODEX_SESSION_ID"
    ]

    /// Removes agent session variables from the process environment and logs
    /// the names removed (never the values). An app launched from inside an
    /// agent session otherwise passes that identity to every shell it starts.
    static func stripAgentEnvironment() {
        let names = ProcessInfo.processInfo.environment.keys.filter { name in
            agentEnvironmentNames.contains(name) ||
                agentEnvironmentPrefixes.contains { name.hasPrefix($0) }
        }.sorted()
        guard !names.isEmpty else { return }
        for name in names { unsetenv(name) }
        logger.info("stripped agent environment variables: \(names.joined(separator: ", "))")
    }
}
