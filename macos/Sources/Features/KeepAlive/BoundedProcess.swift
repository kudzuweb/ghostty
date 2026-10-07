import Foundation
import Darwin

/// External tools must never hold the lifecycle coordinator indefinitely. Output goes to
/// a file, so an inherited stdout descriptor in a grandchild cannot keep an EOF read open.
enum BoundedProcess {
    static func run(executable: String, arguments: [String], timeout: TimeInterval = 5) async -> Data? {
        let worker = Task.detached(priority: .utility) { () -> Data? in
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            guard FileManager.default.createFile(atPath: url.path, contents: nil),
                  let output = try? FileHandle(forWritingTo: url) else { return nil }
            defer { try? output.close(); try? FileManager.default.removeItem(at: url) }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            guard !Task.isCancelled else { return nil }
            do { try process.run() } catch { return nil }
            let deadline = ProcessInfo.processInfo.systemUptime + timeout
            while process.isRunning {
                if Task.isCancelled || ProcessInfo.processInfo.systemUptime >= deadline
                    || ((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) > 4 * 1024 * 1024 {
                    process.terminate()
                    // A tool can ignore TERM; reap only after a bounded grace period.
                    let grace = ProcessInfo.processInfo.systemUptime + 0.2
                    while process.isRunning && ProcessInfo.processInfo.systemUptime < grace {
                        usleep(10_000)
                    }
                    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                    return nil
                }
                try? await Task.sleep(for: .milliseconds(20))
            }
            guard process.terminationStatus == 0, !Task.isCancelled else { return nil }
            // Bound retained output as well as runtime.
            guard let reader = try? FileHandle(forReadingFrom: url) else { return nil }
            defer { try? reader.close() }
            return try? reader.read(upToCount: 4 * 1024 * 1024)
        }
        return await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
    }
}
