import Darwin
import Foundation

/// Latest request wins among queued work. Termination gates new work immediately and
/// drains the active operation before writing the clean-quit receipt.
final class RelaunchReconciler: @unchecked Sendable {
    private let queue = DispatchQueue(label: "ghostty.relaunch.reconcile")
    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var terminating = false

    func submit(_ action: @escaping @Sendable () -> Void) {
        lock.lock()
        guard !terminating else { lock.unlock(); return }
        generation &+= 1
        let requested = generation
        lock.unlock()
        queue.async {
            self.lock.lock()
            let current = !self.terminating && self.generation == requested
            self.lock.unlock()
            if current { action() }
        }
    }

    func finish(_ receipt: () -> Void) {
        lock.lock()
        terminating = true
        generation &+= 1
        lock.unlock()
        queue.sync(execute: receipt)
    }

    func drain() { queue.sync {} }
}

/// The launchd job that reopens Ghostty after it crashes (`keep-alive-relaunch-ghostty`).
///
/// launchd's `KeepAlive` can only restart a process that it started itself, and a Ghostty
/// opened from the Dock or Finder is not one. So the job is a small watcher instead: it
/// waits for the running Ghostty's pid to disappear and then opens the app, unless Ghostty
/// left a clean-quit marker file on its way out. It has `KeepAlive` `SuccessfulExit` false,
/// so a failed `open` is retried while a normal exit is not, and `RunAtLoad` true, which
/// `SuccessfulExit` implies. Each Ghostty launch reinstalls the job with its own pid.
enum KeepAliveRelaunchJob {
    private static let reconciler = RelaunchReconciler()
    private static let incarnation = UUID().uuidString
    private static var label: String {
        "com.mauria.ghostty-relaunch." + (Bundle.main.bundleIdentifier ?? "unidentified")
    }

    private static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    private static var markerPath: String {
        Ghostty.forkProfileStateDirectory.appendingPathComponent("clean-quit.\(incarnation)").path
    }

    private static let watcherScript = """
    pid="$1"; app="$2"; marker="$3"; birth="$4"
    while kill -0 "$pid" 2>/dev/null; do
        [ "$(/bin/ps -p "$pid" -o lstart= 2>/dev/null)" = "$birth" ] || break
        sleep 2
    done
    if [ -f "$marker" ]; then rm -f "$marker"; exit 0; fi
    expected="$app/Contents/MacOS/ghostty"
    if /bin/ps -axo comm= | /usr/bin/awk -v expected="$expected" '$0 == expected { found=1 } END { exit !found }'; then exit 0; fi
    exec /usr/bin/open "$app"
    """

    /// Installs or removes the job to match the config. Runs off the main thread, since it
    /// starts `launchctl`.
    static func sync(enabled: Bool) {
        let label = label, plistURL = plistURL, markerPath = markerPath
        let pid = getpid(), appPath = Bundle.main.bundlePath
        let bundleID = Bundle.main.bundleIdentifier
        reconciler.submit {
            let domain = "gui/\(getuid())"
            // Retire only this profile's old label when upgrading the fork.
            if Ghostty.isDailyForkProfile {
                _ = launchctl(["bootout", "\(domain)/com.mauria.ghostty-relaunch"])
            } else if Bundle.main.bundleIdentifier == "com.mitchellh.ghostty.debug" {
                _ = launchctl(["bootout", "\(domain)/com.mauria.ghostty-relaunch.debug"])
            }
            // Boot out first in both cases: a loaded job keeps the old pid and the old plist.
            _ = launchctl(["bootout", "\(domain)/\(label)"])
            guard enabled else {
                try? FileManager.default.removeItem(at: plistURL)
                NSLog("KeepAlive: removed the relaunch job %@", label)
                return
            }

            // Marker is unique to this process incarnation; never erase a quit receipt.
            try? FileManager.default.createDirectory(
                atPath: (markerPath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            let birth = processBirth(pid)
            guard !birth.isEmpty, birth != "unknown" else {
                NSLog("KeepAlive: refused relaunch watcher without process birth identity")
                return
            }
            var job: [String: Any] = [
                "Label": label,
                "ProgramArguments": ["/bin/sh", "-c", watcherScript, "ghostty-relaunch", "\(pid)", appPath, markerPath, birth],
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
        reconciler.finish {
            do {
                try FileManager.default.createDirectory(
                    atPath: (markerPath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
                try Data().write(to: URL(fileURLWithPath: markerPath), options: .atomic)
            } catch {
                // Without a receipt, unload the watcher rather than risk reopening a clean quit.
                _ = launchctl(["bootout", "gui/\(getuid())/\(label)"])
                NSLog("KeepAlive: clean quit receipt failed: %@", "\(error)")
            }
        }
    }

    private static func processBirth(_ pid: pid_t) -> String {
        ForkBoundedProcess.run("/bin/ps", ["-p", "\(pid)", "-o", "lstart="], timeout: 5)
            .output?.trimmingCharacters(in: .newlines) ?? "unknown"
    }

    @discardableResult
    private static func launchctl(_ arguments: [String]) -> Int32 {
        ForkBoundedProcess.run("/bin/launchctl", arguments, timeout: 10).status
    }
}
