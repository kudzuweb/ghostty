import Foundation
import Darwin

final class FakeSleep: @unchecked Sendable {
    private let lock = NSLock()
    var value: Bool = false
    var writes: [Bool] = []
    var failRelease = false
    var acquireStarted: DispatchSemaphore?
    var finishAcquire: DispatchSemaphore?
    func read() -> Bool? { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ block: Bool, _: Bool) -> String? {
        if block { acquireStarted?.signal(); finishAcquire?.wait() }
        lock.lock(); defer { lock.unlock() }
        if !block && failRelease { return "injected release failure" }
        value = block; writes.append(block); return nil
    }
}
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fatalError(message) }
}
func fixture(_ fake: FakeSleep, allowed: Bool = true, recovery: @escaping @Sendable () -> String? = { nil }) -> SleepGuardOwnership {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("sleep-tests-\(UUID())")
    return SleepGuardOwnership(state: root, allowed: allowed, read: { fake.read() }, set: { block, prompt, _ in fake.set(block, prompt) }, recovery: recovery)
}
let external = FakeSleep(); external.value = true
let unowned = fixture(external)
_ = unowned.reconcile(automatic: true, wantsBlock: true, canAcquire: true)
unowned.shutdown()
check(external.writes.isEmpty, "must preserve an external block")
let owned = FakeSleep(); let service = fixture(owned)
_ = service.reconcile(automatic: true, wantsBlock: true, canAcquire: true)
_ = service.reconcile(automatic: true, wantsBlock: true, canAcquire: true) // overnight/config Auto -> Auto
check(owned.writes == [true], "Auto transitions must retain ownership")
_ = service.reconcile(automatic: false, wantsBlock: false, canAcquire: true)
check(owned.writes == [true, false], "Auto -> Manual must release")
service.shutdown()
let failure = FakeSleep(); let retained = fixture(failure)
_ = retained.reconcile(automatic: true, wantsBlock: true, canAcquire: true)
failure.failRelease = true
check(retained.reconcile(automatic: false, wantsBlock: false, canAcquire: true).error != nil, "release failure reported")
failure.failRelease = false
retained.shutdown()
check(failure.read() == false, "failed release must retain ownership for quit retry")
let noRecovery = FakeSleep(); let refused = fixture(noRecovery, recovery: { "watcher failed" })
check(refused.reconcile(automatic: true, wantsBlock: true, canAcquire: true).error != nil, "watcher failure surfaced")
check(noRecovery.writes.isEmpty, "must not acquire without crash recovery")
let testProfile = FakeSleep(); let isolated = fixture(testProfile, allowed: false)
_ = isolated.reconcile(automatic: true, wantsBlock: true, canAcquire: true)
_ = isolated.manual(block: true)
check(testProfile.writes.isEmpty, "test profiles may never mutate system sleep")
let race = FakeSleep(); race.acquireStarted = DispatchSemaphore(value: 0); race.finishAcquire = DispatchSemaphore(value: 0)
let serialized = fixture(race)
let done = DispatchGroup(); done.enter()
DispatchQueue.global().async { _ = serialized.reconcile(automatic: true, wantsBlock: true, canAcquire: true); done.leave() }
check(race.acquireStarted!.wait(timeout: .now() + 2) == .success, "acquire started")
done.enter()
DispatchQueue.global().async { serialized.shutdown(); done.leave() }
race.finishAcquire!.signal()
check(done.wait(timeout: .now() + 2) == .success, "shutdown drains in-flight operation")
_ = serialized.reconcile(automatic: true, wantsBlock: true, canAcquire: true)
check(race.writes == [true, false], "shutdown releases late acquisition and gates queued enables")
print("Sleep ownership checks passed")
