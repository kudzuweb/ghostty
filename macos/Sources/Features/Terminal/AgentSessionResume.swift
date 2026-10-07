import Darwin
import Foundation

/// Finds the Claude Code or Codex session running in a terminal, so that window restore can
/// resume it. Both lookups read files the tools keep for their own use, which are undocumented
/// and may change. When they do, nothing is found and the terminal restores as a plain shell.
enum AgentSessionResume {
    /// The command that resumes the session running as `pid`, or nil when it isn't one.
    static func command(forProcess pid: Int) -> String? {
        guard let pid = pid_t(exactly: pid) else { return nil }
        if let id = claudeSessionID(pid: pid) { return "claude --resume \(id)" }
        if let id = codexSessionID(pid: pid) { return "codex resume \(id)" }
        return nil
    }

    /// Claude Code keeps `~/.claude/sessions/<pid>.json`, holding its session id, while it runs.
    private static func claudeSessionID(pid: pid_t) -> String? {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/sessions/\(pid).json")
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (json["pid"] as? Int) == Int(pid),
              let id = json["sessionId"] as? String,
              UUID(uuidString: id) != nil
        else { return nil }
        return id
    }

    /// Codex keeps its session log open while it runs, and the log's file name
    /// (`rollout-<timestamp>-<session id>.jsonl`) ends in the session id.
    private static func codexSessionID(pid: pid_t) -> String? {
        for path in openFilePaths(pid: pid) where path.contains("/.codex/sessions/") {
            let name = (path as NSString).lastPathComponent
            guard name.hasPrefix("rollout-"), name.hasSuffix(".jsonl") else { continue }
            let id = String(name.dropLast(".jsonl".count).suffix(36))
            if UUID(uuidString: id) != nil { return id }
        }
        return nil
    }

    /// The paths of the files a process has open.
    private static func openFilePaths(pid: pid_t) -> [String] {
        let bufferSize = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard bufferSize > 0 else { return [] }
        let stride = MemoryLayout<proc_fdinfo>.stride
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(bufferSize) / stride)
        let filled = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, bufferSize)
        guard filled > 0 else { return [] }

        return fds.prefix(Int(filled) / stride).compactMap { fd in
            guard fd.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) else { return nil }
            var info = vnode_fdinfowithpath()
            let size = Int32(MemoryLayout<vnode_fdinfowithpath>.size)
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDVNODEPATHINFO, &info, size) == size else {
                return nil
            }
            return withUnsafeBytes(of: info.pvip.vip_path) { raw in
                String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
            }
        }
    }
}
