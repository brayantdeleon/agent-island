import Foundation
import AgentIslandCore
import Testing
@testable import AgentIslandApp

@MainActor
struct CodexAppServerCoordinatorTests {
    @Test
    func nativeApprovalMonitorClearsCardWhenThreadResumes() async throws {
        let waiting = try decodeStatus(
            #"{"type":"active","activeFlags":["waitingOnApproval"]}"#
        )
        let resumed = try decodeStatus(
            #"{"type":"active","activeFlags":[]}"#
        )
        var reads = 0
        let coordinator = CodexAppServerCoordinator(
            threadStatusReader: { threadID in
                #expect(threadID == "desktop-thread")
                defer { reads += 1 }
                return reads == 0 ? waiting : resumed
            },
            nativeApprovalPollInterval: .milliseconds(1),
            nativeApprovalInitialGracePeriod: .seconds(1)
        )
        var events: [AgentEvent] = []
        coordinator.onEvent = { events.append($0) }

        coordinator.monitorNativeApprovalResolution(
            threadID: "desktop-thread"
        )
        for _ in 0..<100 where events.isEmpty {
            try? await Task.sleep(for: .milliseconds(1))
        }

        guard case let .activityUpdated(update) = events.first else {
            Issue.record("Expected the resumed activity update")
            return
        }
        #expect(update.sessionID == "desktop-thread")
        #expect(update.phase == .running)
        #expect(update.summary == "Codex resumed work.")
    }

    @Test
    func nativeApprovalMonitorClearsAutoReviewedRequestWithoutWaitingFlag()
        async throws
    {
        let resumed = try decodeStatus(
            #"{"type":"active","activeFlags":[]}"#
        )
        let coordinator = CodexAppServerCoordinator(
            threadStatusReader: { _ in resumed },
            nativeApprovalPollInterval: .milliseconds(1),
            nativeApprovalInitialGracePeriod: .zero
        )
        var events: [AgentEvent] = []
        coordinator.onEvent = { events.append($0) }

        coordinator.monitorNativeApprovalResolution(
            threadID: "auto-reviewed-thread"
        )
        for _ in 0..<100 where events.isEmpty {
            try? await Task.sleep(for: .milliseconds(1))
        }

        #expect(events.count == 1)
        #expect(events.first?.sessionID == "auto-reviewed-thread")
    }

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

    private func decodeStatus(_ json: String) throws -> CodexThreadStatus {
        try JSONDecoder().decode(
            CodexThreadStatus.self,
            from: Data(json.utf8)
        )
    }
}
