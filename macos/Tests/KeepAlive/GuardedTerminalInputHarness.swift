// Compile with -D GUARDED_INPUT_HARNESS and GuardedTerminalInput.swift.
#if GUARDED_INPUT_HARNESS
import Foundation
struct AgentSessionProcessIdentity: Equatable {
    let pid: Int32
    let startSeconds: UInt64
    let startMicroseconds: UInt64
}
enum AgentSessionResume {
    static func processIdentity(_ pid: Int32) -> AgentSessionProcessIdentity? { nil }
    static func isAlive(_ identity: AgentSessionProcessIdentity) -> Bool { false }
}
enum SleepGuard {
    static let idleShells: Set<String> = ["zsh"]
    static func executableName(of foreground: Int) -> String? { nil }
}
@MainActor enum Ghostty {
    final class SurfaceView {
        var id = UUID()
        var surfaceModel: Surface? = Surface()
        var userInputGeneration: UInt64 = 0
    }
    final class Surface {
        var foregroundPID: Int? = 1
        var isAtEmptyShellPrompt = true
        var text: [String] = []
        var enters = 0
        var didSendText: (() -> Void)?
        struct KeyEvent {
            enum Key { case enter }
            enum Action { case press, release }
            var key: Key
            var action: Action
        }
        func sendText(_ value: String) { text.append(value); isAtEmptyShellPrompt = false; didSendText?() }
        func sendKeyEvent(_ event: KeyEvent) { if event.action == .press { enters += 1 } }
    }
}
@main struct GuardedTerminalInputHarness {
    @MainActor static func main() async {
        var identity: AgentSessionProcessIdentity? = .init(pid: 1, startSeconds: 10, startMicroseconds: 1)
        let dispatcher = GuardedTerminalInput(idleShellIdentity: { _ in identity })
        let surface = Ghostty.SurfaceView()
        let model = surface.surfaceModel!
        var allowed = true
        precondition(dispatcher.send("first", into: surface, authorized: { allowed }))
        precondition(!dispatcher.send("second", into: surface, authorized: { allowed }))
        precondition(model.text == ["first"] && model.enters == 1)
        // Reaching an empty prompt again is the shell's acknowledgment of completion.
        await Task.yield()
        model.isAtEmptyShellPrompt = true
        allowed = false
        precondition(!dispatcher.send("disabled", into: surface, authorized: { allowed }))
        precondition(model.text == ["first"])
        allowed = true
        model.isAtEmptyShellPrompt = false
        precondition(!dispatcher.send("draft", into: surface, authorized: { allowed }))
        model.isAtEmptyShellPrompt = true
        model.foregroundPID = nil
        precondition(!dispatcher.send("unknown PID", into: surface, authorized: { allowed }))
        model.foregroundPID = 1
        identity = nil // A live non-shell foreground is rejected even with stale prompt markers.
        precondition(!dispatcher.send("non-shell", into: surface, authorized: { allowed }))
        precondition(model.text == ["first"])
        identity = .init(pid: 1, startSeconds: 10, startMicroseconds: 1)
        model.didSendText = { identity = .init(pid: 1, startSeconds: 20, startMicroseconds: 1) }
        precondition(!dispatcher.send("stale", into: surface, authorized: { allowed }))
        precondition(model.enters == 1) // Reused PID cannot receive Enter.
        surface.surfaceModel = nil
        precondition(!dispatcher.send("closed", into: surface, authorized: { allowed }))
        dispatcher.cancelAll()
        precondition(model.enters == 1)
        print("actual shell dispatcher: transaction, authorization, draft, unknown PID, non-shell, stale birth and closed surface passed")
    }
}
#endif
