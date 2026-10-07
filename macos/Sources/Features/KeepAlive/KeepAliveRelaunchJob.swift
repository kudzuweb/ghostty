import Darwin
import Foundation

/// The launchd job that reopens Ghostty after it crashes (`keep-alive-relaunch-ghostty`).
///
/// launchd's `KeepAlive` can only restart a process that it started itself, and a Ghostty
/// opened from the Dock or Finder is not one. So the job is a small watcher instead: it
/// waits for the running Ghostty's pid to disappear and then opens the app, unless Ghostty
/// left a clean-quit marker file on its way out. It has `KeepAlive` `SuccessfulExit` false,
/// so a failed `open` is retried while a normal exit is not, and `RunAtLoad` true, which
/// `SuccessfulExit` implies. Each Ghostty launch reinstalls the job with its own pid.
enum KeepAliveRelaunchJob {
    /// A debug build gets its own job, so testing it can't replace or remove the job of the
    /// Ghostty that is in daily use.
    private static var label: String {
        let isDebug = Bundle.main.bundleIdentifier?.hasSuffix(".debug") == true
        return isDebug ? "com.mauria.ghostty-relaunch.debug" : "com.mauria.ghostty-relaunch"
    }

    private static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    private static var markerPath: String {
        NSHomeDirectory() + "/.local/state/ghostty/clean-quit.\(label)"
    }

    private static let watcherScript = """
    pid="$1"; app="$2"; marker="$3"
    while kill -0 "$pid" 2>/dev/null; do
        case "$(ps -p "$pid" -o comm= 2>/dev/null)" in */ghostty) sleep 2 ;; *) break ;; esac
    done
    if [ -f "$marker" ]; then rm -f "$marker"; exit 0; fi
    exec /usr/bin/open "$app"
    """

    /// Installs or removes the job to match the config. Runs off the main thread, since it
    /// starts `launchctl`.
    static func sync(enabled: Bool) {
        let label = label, plistURL = plistURL, markerPath = markerPath
        let pid = getpid(), appPath = Bundle.main.bundlePath
        let bundleID = Bundle.main.bundleIdentifier
        DispatchQueue.global(qos: .utility).async {
            let domain = "gui/\(getuid())"
            // Boot out first in both cases: a loaded job keeps the old pid and the old plist.
            _ = launchctl(["bootout", "\(domain)/\(label)"])
            guard enabled else {
                try? FileManager.default.removeItem(at: plistURL)
                NSLog("KeepAlive: removed the relaunch job %@", label)
                return
            }

            // A marker left by the previous run must not hide this run's crash.
            try? FileManager.default.removeItem(atPath: markerPath)
            try? FileManager.default.createDirectory(
                atPath: (markerPath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            var job: [String: Any] = [
                "Label": label,
                "ProgramArguments": ["/bin/sh", "-c", watcherScript, "ghostty-relaunch", "\(pid)", appPath, markerPath],
                "RunAtLoad": true,
                "KeepAlive": ["SuccessfulExit": false],
                "ThrottleInterval": 10,
                "ProcessType": "Background",
            ]
            // Without this, Login Items lists the job as "sh" instead of under Ghostty.
            if let bundleID { job["AssociatedBundleIdentifiers"] = [bundleID] }
            do {
                try FileManager.default.createDirectory(
                    at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                let data = try PropertyListSerialization.data(fromPropertyList: job, format: .xml, options: 0)
                try data.write(to: plistURL, options: .atomic)
            } catch {
                NSLog("KeepAlive: couldn't write %@: %@", plistURL.path, "\(error)")
                return
            }
            let status = launchctl(["bootstrap", domain, plistURL.path])
            NSLog("KeepAlive: installed the relaunch job %@ (launchctl bootstrap status %d)", label, status)
        }
    }

    /// Tells the job that Ghostty is quitting on purpose. Called synchronously as the app
    /// terminates, because the process is about to exit.
    static func markCleanQuit() {
        try? FileManager.default.createDirectory(
            atPath: (markerPath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: markerPath, contents: Data())
    }

    @discardableResult
    private static func launchctl(_ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return -1 }
        process.waitUntilExit()
        return process.terminationStatus
    }
}
