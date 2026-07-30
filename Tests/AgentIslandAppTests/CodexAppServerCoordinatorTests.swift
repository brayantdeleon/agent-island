import Foundation
import AgentIslandCore
import Testing
@testable import AgentIslandApp

@MainActor
struct CodexAppServerCoordinatorTests {
    @Test
    func observerWaitingOnApprovalIsNotActionable() throws {
        let coordinator = CodexAppServerCoordinator()
        var events: [AgentEvent] = []
        coordinator.onEvent = { events.append($0) }

        let status = try JSONDecoder().decode(
            CodexThreadStatus.self,
            from: Data(#"{"type":"active","activeFlags":["waitingOnApproval"]}"#.utf8)
        )
        coordinator.handleNotification(
            .threadStatusChanged(threadId: "desktop-thread", status: status)
        )

        #expect(events.count == 1)
        guard case let .activityUpdated(update) = events.first else {
            Issue.record("Expected an advisory activity update")
            return
        }
        #expect(update.sessionID == "desktop-thread")
        #expect(update.phase == .running)
        #expect(update.summary == "Codex is waiting for approval in Codex.")
    }
}
