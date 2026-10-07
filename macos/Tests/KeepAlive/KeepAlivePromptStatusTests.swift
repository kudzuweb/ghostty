import Testing
@testable import Ghostty

struct KeepAlivePromptStatusTests {
    @Test func actualMailboxEventsProjectVisibleStatus() {
        #expect(KeepAlivePromptStatus.after(.submitted)?.phase == .waiting)
        #expect(KeepAlivePromptStatus.after(.claimed)?.phase == .waiting)
        #expect(KeepAlivePromptStatus.after(.accepted) == nil)
        #expect(KeepAlivePromptStatus.after(.dropped) == nil)
        #expect(KeepAlivePromptStatus.after(.unknown)?.phase == .attention)
        #expect(KeepAlivePromptStatus.after(.unavailable("Bridge missing"))?.message == "Bridge missing")
        #expect(KeepAlivePromptStatus.after(.rejected("Rejected"))?.phase == .attention)
        #expect(KeepAlivePromptStatus.after(.disabled) == nil)
        #expect(KeepAlivePromptStatus.after(.newSession) == nil)
    }
}
