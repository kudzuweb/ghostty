import Foundation
final class Store: @unchecked Sendable {
    var installed = false
    var marker = false
    var writes: [String] = []
}
let queue = RelaunchReconciler()
let started = DispatchSemaphore(value: 0), finish = DispatchSemaphore(value: 0)
let store = Store()
queue.submit { started.signal(); finish.wait() }
precondition(started.wait(timeout: .now() + 2) == .success)
queue.submit { store.installed = true; store.writes.append("enable-old") }
queue.submit { store.installed = false; store.writes.append("disable") }
finish.signal(); queue.drain()
precondition(!store.installed && store.writes == ["disable"], "queued latest generation wins")
let quit = RelaunchReconciler()
let installStarted = DispatchSemaphore(value: 0), installFinish = DispatchSemaphore(value: 0)
quit.submit { installStarted.signal(); installFinish.wait(); store.marker = false; store.installed = true }
precondition(installStarted.wait(timeout: .now() + 2) == .success)
let receipt = DispatchSemaphore(value: 0)
DispatchQueue.global().async { quit.finish { store.marker = true }; receipt.signal() }
installFinish.signal()
precondition(receipt.wait(timeout: .now() + 2) == .success)
quit.submit { store.marker = false }
quit.drain()
precondition(store.marker, "clean quit receipt survives active and queued startup work")
print("Relaunch reconciliation checks passed")
