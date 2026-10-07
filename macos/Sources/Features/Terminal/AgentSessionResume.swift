import Darwin
import Foundation

/// Finds the Claude Code or Codex session running in a terminal, so that window restore can
/// resume it. Both lookups read files the tools keep for their own use, which are undocumented
/// and may change. When they do, nothing is found and the terminal restores as a plain shell.
enum AgentSessionResume {
    /// The command that resumes the session running as `pid`, or nil when it isn't one.
    static func command(forProcess pid: Int) -> String? {
        session(forProcess: pid).map { $0.tool.resumeCommand(sessionID: $0.id) }
    }

    /// The tool and session id of the Claude Code or Codex session running as `pid`.
    static func session(forProcess pid: Int) -> (tool: AgentTool, id: String)? {
        if case .found(let binding, _) = observe(foregroundGroup: pid, tty: nil, cwd: nil) {
            return (binding.tool, binding.sessionID.uuidString.lowercased())
        }
        return nil
    }

    enum Observation {
        case found(AgentSessionBinding, pid: Int32)
        case absent
        case unavailable(String)
    }

    static func observe(foregroundGroup: Int, tty: String?, cwd: String?) -> Observation {
        guard let group = Int32(exactly: foregroundGroup) else { return .absent }
        var pids = [Int32](repeating: 0, count: 4096)
        let count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<Int32>.stride))
        guard count > 0 else { return .unavailable("Process discovery is unavailable") }
        var bindings: [AgentSessionBinding] = []
        var candidates: [AgentSessionCandidate] = []
        var sawUnverifiableAgent = false
        for pid in pids.prefix(Int(count)) where pid > 0 {
            guard let before = identity(pid), before.info.pbi_pgid == UInt32(group) else { continue }
            let bindingStart = bindings.count
            let processName = withUnsafeBytes(of: before.info.pbi_name) { raw in
                String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
            }
            guard let paths = openFilePaths(pid: pid) else {
                return .unavailable("Agent file discovery is unavailable; recovery is paused")
            }
            // Membership of the foreground group is authoritative; the TTY additionally
            // prevents accidentally accepting a different terminal's descriptor.
            if let tty, paths.contains(where: { $0.hasPrefix("/dev/tty") }), !paths.contains(tty) { continue }
            let environment = processEnvironment(pid)
            let home = environment["HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.path
            let claudeRoot = environment["CLAUDE_CONFIG_DIR"] ?? home + "/.claude"
            let recordURL = URL(fileURLWithPath: claudeRoot).appendingPathComponent("sessions/\(pid).json")
            if let data = try? Data(contentsOf: recordURL),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               json["pid"] as? Int == Int(pid),
               let text = json["sessionId"] as? String, let id = UUID(uuidString: text) {
                let modified = (try? recordURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                if let modified, modified.timeIntervalSince1970 >= Double(before.identity.startSeconds) + Double(before.identity.startMicroseconds) / 1_000_000 {
                    bindings.append(.init(tool: .claude, sessionID: id, sessionRoot: claudeRoot,
                                          launchCWD: json["cwd"] as? String ?? cwd))
                }
            }
            for path in paths where (path as NSString).lastPathComponent.hasPrefix("rollout-") && path.hasSuffix(".jsonl") {
                guard let range = path.range(of: "/sessions/", options: .backwards),
                      let handle = FileHandle(forReadingAtPath: path) else { continue }
                let data = handle.readData(ofLength: 65536)
                try? handle.close()
                guard let lineData = metadataLine(data),
                      let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                      json["type"] as? String == "session_meta",
                      let payload = json["payload"] as? [String: Any],
                      let text = payload["id"] as? String, let id = UUID(uuidString: text),
                      path.contains(id.uuidString.lowercased()) else { continue }
                bindings.append(.init(tool: .codex, sessionID: id,
                                      sessionRoot: String(path[..<range.lowerBound]),
                                      launchCWD: payload["cwd"] as? String ?? cwd))
            }
            if bindings.count == bindingStart,
               processName == "claude" || processName == "codex"
                || paths.contains(where: { $0.hasSuffix(".jsonl") && ($0 as NSString).lastPathComponent.hasPrefix("rollout-") }) {
                sawUnverifiableAgent = true
            }
            guard let after = identity(pid) else {
                return .unavailable("An agent process exited during discovery; retrying")
            }
            for binding in bindings.dropFirst(bindingStart) {
                candidates.append(.init(identity: before.identity, identityAfterRead: after.identity,
                                        foregroundGroup: group, tty: tty, binding: binding))
            }
        }
        if sawUnverifiableAgent {
            return .unavailable("Agent session metadata is missing or invalid; recovery cannot safely identify this session")
        }
        switch AgentSessionCandidateResolver.resolve(group: group, tty: tty, candidates: candidates) {
        case .success(let candidate):
            guard let candidate else { return .absent }
            return .found(candidate.binding, pid: candidate.identity.pid)
        case .failure(.staleProcess):
            return .unavailable("An agent process changed during discovery; retrying")
        case .failure(.ambiguous):
            return .unavailable("Multiple agent sessions share this terminal; select a session manually")
        }
    }

    static func processIdentity(_ pid: Int32) -> AgentSessionProcessIdentity? { identity(pid)?.identity }
    static func isAlive(_ process: AgentSessionProcessIdentity) -> Bool { identity(process.pid)?.identity == process }

    /// A matching live owner anywhere on the machine blocks resume in this app.
    /// This is deliberately independent of terminal ownership and display titles.
    static func liveOwners(of binding: AgentSessionBinding, diagnostic: ((String) -> Void)? = nil) -> [AgentSessionProcessIdentity]? {
        var pids = [Int32](repeating: 0, count: 4096)
        let count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<Int32>.stride))
        guard count > 0 else { return nil }
        var owners: [AgentSessionProcessIdentity] = []
        for pid in pids.prefix(Int(count)) where pid > 0 {
            guard let before = identity(pid) else { continue }
            var matches = false
            switch binding.tool {
            case .claude:
                let url = URL(fileURLWithPath: binding.sessionRoot).appendingPathComponent("sessions/\(pid).json")
                if FileManager.default.fileExists(atPath: url.path), (try? Data(contentsOf: url)) == nil { return nil }
                if let data = try? Data(contentsOf: url),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   json["pid"] as? Int == Int(pid),
                   let text = json["sessionId"] as? String, UUID(uuidString: text) == binding.sessionID,
                   let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate {
                    matches = modified.timeIntervalSince1970 >= Double(before.identity.startSeconds) + Double(before.identity.startMicroseconds) / 1_000_000
                }
            case .codex:
                // Only plausible CLI owners make inaccessible descriptors ambiguous;
                // unrelated protected applications must not block all recovery.
                guard before.info.pbi_uid == getuid() else { continue }
                let name = withUnsafeBytes(of: before.info.pbi_name) { raw in
                    String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
                }
                let executable = executablePath(pid)
                let arguments = processArguments(pid)
                let plausible = AgentSessionProcessClassifier.blocksOnUnavailableDescriptors(
                    executable: executable, name: name, arguments: arguments?.arguments ?? [])
                let report: ((String) -> Void)? = plausible ? { diagnostic?("pid=\(pid) executable=\((executable as NSString?)?.lastPathComponent ?? name) \($0)") } : nil
                guard let paths = openFilePaths(pid: pid, diagnostic: report) else {
                    if plausible {
                        if AgentSessionDescriptorInspection.configuredRootDiffers(target: binding.sessionRoot,
                                                                                 environment: arguments?.environment) {
                            diagnostic?("pid=\(pid) inaccessible descriptors excluded by verified different configured root")
                            continue
                        }
                        return nil
                    }
                    continue
                }
                for path in paths where path.hasPrefix(binding.sessionRoot + "/sessions/") && path.hasSuffix(".jsonl") {
                    guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
                    let data = handle.readData(ofLength: 65536)
                    try? handle.close()
                    guard let lineData = metadataLine(data),
                          let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                          json["type"] as? String == "session_meta", let payload = json["payload"] as? [String: Any],
                          let text = payload["id"] as? String, let id = UUID(uuidString: text) else { return nil }
                    if id == binding.sessionID { matches = true }
                }
            }
            if matches, identity(pid)?.identity == before.identity { owners.append(before.identity) }
        }
        return owners
    }

    private static func identity(_ pid: Int32) -> (identity: AgentSessionProcessIdentity, info: proc_bsdinfo)? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return (.init(pid: pid, startSeconds: info.pbi_start_tvsec,
                      startMicroseconds: info.pbi_start_tvusec), info)
    }

    private static func processArguments(_ pid: Int32) -> AgentSessionProcessArguments.Parsed? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var buffer = [UInt8](repeating: 0, count: 262144)
        var size = buffer.count
        guard sysctl(&mib, UInt32(mib.count), &buffer, &size, nil, 0) == 0 else { return nil }
        return AgentSessionProcessArguments.parse(Data(buffer.prefix(size)))
    }

    private static func processEnvironment(_ pid: Int32) -> [String: String] {
        processArguments(pid)?.environment ?? [:]
    }

    private static func executablePath(_ pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }

    /// Decode only the complete first JSON line. Later content may end mid UTF-8
    /// codepoint at our bounded read limit and must not invalidate session_meta.
    static func metadataLine(_ data: Data) -> Data? {
        if let newline = data.firstIndex(of: 10) { return Data(data[..<newline]) }
        return data.count < 65536 ? data : nil
    }

    private static func descriptorStillOpen(pid: pid_t, fd: Int32) -> Bool? {
        let size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard size > 0 else { return nil }
        let stride = MemoryLayout<proc_fdinfo>.stride
        var descriptors = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(size) / stride)
        let filled = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &descriptors, size)
        guard filled > 0 else { return nil }
        return descriptors.prefix(Int(filled) / stride).contains { $0.proc_fd == fd }
    }

    /// The paths of the files a process has open.
    private static func openFilePaths(pid: pid_t, diagnostic: ((String) -> Void)? = nil) -> [String]? {
        let bufferSize = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard bufferSize > 0 else { diagnostic?("fd-list-size errno=\(errno)"); return nil }
        let stride = MemoryLayout<proc_fdinfo>.stride
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(bufferSize) / stride)
        let filled = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, bufferSize)
        guard filled > 0 else { diagnostic?("fd-list-fill errno=\(errno)"); return nil }

        var paths: [String] = []
        for fd in fds.prefix(Int(filled) / stride) where fd.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) {
            var info = vnode_fdinfowithpath()
            let size = Int32(MemoryLayout<vnode_fdinfowithpath>.size)
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDVNODEPATHINFO, &info, size) == size else {
                let failure = errno
                diagnostic?("vnode fd=\(fd.proc_fd) errno=\(failure)")
                if failure == ENOENT {
                    var vnode = vnode_fdinfo()
                    let vnodeSize = Int32(MemoryLayout<vnode_fdinfo>.size)
                    let vnodeResult = proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDVNODEINFO, &vnode, vnodeSize)
                    diagnostic?("fd=\(fd.proc_fd) vnode-info-result=\(vnodeResult) expected=\(vnodeSize) errno=\(errno)")
                    let statError = vnodeResult == vnodeSize ? nil : errno
                    let links = vnodeResult == vnodeSize ? vnode.pvi.vi_stat.vst_nlink : nil
                    if AgentSessionDescriptorInspection.missingVnodeCanBeIgnored(pathError: failure,
                                                                                statError: statError, linkCount: links) {
                        diagnostic?("fd=\(fd.proc_fd) absent or unlinked vnode; continuing named-file inspection")
                        continue
                    }
                }
                if failure == EBADF || failure == ENOENT, descriptorStillOpen(pid: pid, fd: fd.proc_fd) == false {
                    diagnostic?("fd=\(fd.proc_fd) confirmed closed during inspection")
                    continue
                }
                return nil
            }
            paths.append(withUnsafeBytes(of: info.pvip.vip_path) { raw in
                String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
            })
        }
        return paths
    }
}
