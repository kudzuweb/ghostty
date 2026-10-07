import Foundation
for key in ["CLAUDECODE", "CLAUDE_CODE_CHILD_SESSION", "CLAUDE_PID", "CLAUDE_CODE_MESSAGING_SOCKET", "CLAUDE_CODE_MESSAGING_TOKEN", "CLAUDE_CODE_SESSION_ID", "CODEX_THREAD_ID", "CODEX_SESSION_ID", "CODEX_SANDBOX", "CODEX_MANAGED_TEST", "CODEX_APP_TOOLS_PIPE_PATH"] {
    precondition(Ghostty.shouldStripAgentEnvironment(key), "identity/transport survived: \(key)")
}
for key in ["CODEX_HOME", "CLAUDE_CONFIG_DIR", "CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_OAUTH_TOKEN", "ANTHROPIC_API_KEY", "CLAUDE_CODE_VERSION", "CODEX_CLI_PATH"] {
    precondition(!Ghostty.shouldStripAgentEnvironment(key), "configuration removed: \(key)")
}
print("Agent environment checks passed")
let root = FileManager.default.temporaryDirectory.appendingPathComponent("profile-policy-\(UUID())").resolvingSymlinksInPath()
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: root) }
let explicit = root.appendingPathComponent("custom/config.ghostty")
let accepted = try Ghostty.isolatedConfigPath(root: root, arguments: ["ghostty", "--config-file=\(explicit.path)"], override: nil)
precondition(accepted == explicit)
do {
    _ = try Ghostty.isolatedConfigPath(root: root, arguments: ["ghostty"], override: "/tmp/daily-config")
    fatalError("outside-profile override accepted")
} catch {}
let link = root.appendingPathComponent("linked")
try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "/tmp")
do {
    _ = try Ghostty.isolatedConfigPath(root: root, arguments: ["ghostty"], override: link.appendingPathComponent("daily-config").path)
    fatalError("symlink escape accepted")
} catch {}
print("Explicit test config isolation checks passed")
