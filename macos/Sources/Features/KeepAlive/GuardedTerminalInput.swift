import Foundation

/// Shell recovery is a single main-actor transaction. Native agent prompts use
/// AgentPromptBridge instead, so no delayed Enter can reach a replaced foreground app.
@MainActor
final class GuardedTerminalInput {
    static let shared = GuardedTerminalInput()
    private var claimed: Set<UUID> = []
    private let idleShellIdentity: @MainActor (Int) -> AgentSessionProcessIdentity?

    init(idleShellIdentity: @escaping @MainActor (Int) -> AgentSessionProcessIdentity? = { foreground in
        guard let pid = Int32(exactly: foreground),
              let identity = AgentSessionResume.processIdentity(pid),
              let name = SleepGuard.executableName(of: foreground),
              SleepGuard.idleShells.contains(name), AgentSessionResume.isAlive(identity) else { return nil }
        return identity
    }) {
        self.idleShellIdentity = idleShellIdentity
    }

    func canSend(into surface: Ghostty.SurfaceView) -> Bool {
        guard let model = surface.surfaceModel, let foreground = model.foregroundPID else { return false }
        return !claimed.contains(surface.id) && model.isAtEmptyShellPrompt
            && idleShellIdentity(foreground) != nil
    }

    @discardableResult
    func send(
        _ text: String,
        into surface: Ghostty.SurfaceView,
        authorized: @escaping @MainActor () -> Bool,
        completion: (@MainActor (Bool) -> Void)? = nil
    ) -> Bool {
        guard canSend(into: surface), authorized(), let model = surface.surfaceModel,
              let foreground = model.foregroundPID,
              let identity = idleShellIdentity(foreground) else { return false }
        let input = surface.userInputGeneration
        claimed.insert(surface.id)
        // Keep the claim through this actor turn; two coordinators cannot submit twice.
        Task { [weak self] in self?.claimed.remove(surface.id) }
        model.sendText(text)
        guard surface.surfaceModel === model, model.foregroundPID == foreground,
              surface.userInputGeneration == input, idleShellIdentity(foreground) == identity, authorized() else { completion?(false); return false }
        model.sendKeyEvent(.init(key: .enter, action: .press))
        model.sendKeyEvent(.init(key: .enter, action: .release))
        completion?(true)
        return true
    }

    func cancel(in id: UUID) { claimed.remove(id) }
    func cancelAll() { claimed.removeAll() }
}
