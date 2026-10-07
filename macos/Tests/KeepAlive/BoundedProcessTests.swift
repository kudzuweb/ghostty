import Foundation
import Testing
@testable import Ghostty

struct BoundedProcessTests {
    @Test func ignoresTERMButDeadlineStillReturns() async {
        let start = ProcessInfo.processInfo.systemUptime
        let output = await BoundedProcess.run(
            executable: "/bin/sh", arguments: ["-c", "trap '' TERM; exec /bin/sleep 10"], timeout: 0.1)
        #expect(output == nil)
        #expect(ProcessInfo.processInfo.systemUptime - start < 1)
    }

    @Test func cancellationStopsOnlyItsOwnChild() async {
        let task = Task { await BoundedProcess.run(executable: "/bin/sleep", arguments: ["10"], timeout: 20) }
        try? await Task.sleep(for: .milliseconds(100))
        task.cancel()
        let output = await task.value
        #expect(output == nil)
    }

    @Test func completedOutputIsReturned() async {
        let output = await BoundedProcess.run(executable: "/usr/bin/printf", arguments: ["ok"])
        #expect(output == Data("ok".utf8))
    }
}
