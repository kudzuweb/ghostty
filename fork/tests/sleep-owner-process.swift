import Foundation
import Darwin
let root = URL(fileURLWithPath: CommandLine.arguments[1])
let command = CommandLine.arguments[2]
let value = root.appendingPathComponent("fake-sleep")
let owner = SleepGuardOwnership(state: root, allowed: true,
    read: { (try? String(contentsOf: value, encoding: .utf8)) == "1" },
    set: { block, _, descriptor in
        let result = ForkBoundedProcess.run(command, [block ? "1" : "0"], timeout: 3, inheritedLockFD: descriptor)
        return result.status == 0 ? nil : "fake command failed"
    }, recovery: { nil })
_ = owner.reconcile(automatic: true, wantsBlock: true, canAcquire: true)
sleep(10)
