import Foundation
import Testing
@testable import AgentIslandApp
import AgentIslandCore

@MainActor
@Suite(.serialized)
struct AgentControlProjectionTests {
    @Test
    func hiddenApprovalRemainsEligibleWhileHiddenRunningSessionDoesNot() {
        let defaults = makeDefaults()
        let model = makeModel(defaults: defaults)
        let now = Date()
        let running = makeSession(id: "running", firstSeenAt: now, updatedAt: now)
        let approval = makeSession(
            id: "approval",
            firstSeenAt: now.addingTimeInterval(1),
            updatedAt: now,
            phase: .waitingForApproval,
            permissionRequest: PermissionRequest(
                title: "Edit",
                summary: "Edit a file",
                affectedPath: "/tmp/file"
            )
        )
        model.state = SessionState(sessions: [running, approval])
        model.hideSession(running)
        model.hideSession(approval)

        let projection = model.agentControlSlotProjection(at: now)

        #expect(projection.assignedSlots.map(\.sessionID) == ["approval"])
        #expect(projection.assignedSlots.first?.lightState == .waitingForObservedApproval)
        #expect(model.agentControlSlotLabel(for: "running", at: now) == nil)
        #expect(model.agentControlSlotLabel(for: "approval", at: now) == "1")
    }

    @Test
    func staleCompletionReleasesItsSlotForTheNextAgent() {
        let defaults = makeDefaults()
        let model = makeModel(defaults: defaults)
        let originalThreshold = model.completedStaleThreshold
        defer { model.completedStaleThreshold = originalThreshold }
        model.completedStaleThreshold = .fiveMinutes

        let now = Date()
        let completed = makeSession(
            id: "completed",
            firstSeenAt: now.addingTimeInterval(-60),
            updatedAt: now,
            phase: .completed
        )
        model.state = SessionState(sessions: [completed])

        let recentProjection = model.agentControlSlotProjection(at: now)
        #expect(recentProjection.slot(for: "completed")?.index == 0)
        #expect(recentProjection.slot(for: "completed")?.lightState == .recentlyCompleted)

        let newcomer = makeSession(
            id: "newcomer",
            firstSeenAt: now.addingTimeInterval(1),
            updatedAt: now.addingTimeInterval(1)
        )
        model.state = SessionState(sessions: [completed, newcomer])
        let expiredProjection = model.agentControlSlotProjection(
            at: now.addingTimeInterval(5 * 60)
        )

        #expect(expiredProjection.slot(for: "completed") == nil)
        #expect(expiredProjection.slot(for: "newcomer")?.index == 0)
        #expect(model.agentControlSlotLabel(
            for: "newcomer",
            at: now.addingTimeInterval(5 * 60)
        ) == "1")
    }

    @Test
    func appRestartRestoresPresentationLabelsFromPersistedAssignments() {
        let defaults = makeDefaults()
        let now = Date()
        let a = makeSession(id: "A", firstSeenAt: now, updatedAt: now)
        let b = makeSession(
            id: "B",
            firstSeenAt: now.addingTimeInterval(1),
            updatedAt: now
        )

        let firstModel = makeModel(defaults: defaults)
        firstModel.state = SessionState(sessions: [a, b])
        let firstProjection = firstModel.agentControlSlotProjection(at: now)
        #expect(firstProjection.keyLabel(for: "A") == "1")
        #expect(firstProjection.keyLabel(for: "B") == "2")

        let restartedModel = makeModel(defaults: defaults)
        restartedModel.state = SessionState(sessions: [b, a])
        let restartedProjection = restartedModel.agentControlSlotProjection(at: now)

        #expect(restartedProjection.keyLabel(for: "A") == "1")
        #expect(restartedProjection.keyLabel(for: "B") == "2")
    }

    @Test
    func subagentsAndRealtimeVoiceSessionsAreExcluded() {
        let defaults = makeDefaults()
        let model = makeModel(defaults: defaults)
        let now = Date()
        let normal = makeSession(id: "normal", firstSeenAt: now, updatedAt: now)
        let subagent = makeSession(
            id: "subagent",
            firstSeenAt: now.addingTimeInterval(1),
            updatedAt: now,
            transcriptPath: "/tmp/project/subagents/worker.jsonl"
        )
        let realtime = makeSession(
            id: "realtime",
            title: "Claude · realtime-voice-chat-1",
            firstSeenAt: now.addingTimeInterval(2),
            updatedAt: now
        )
        model.state = SessionState(sessions: [subagent, realtime, normal])

        let projection = model.agentControlSlotProjection(at: now)

        #expect(projection.assignedSlots.map(\.sessionID) == ["normal"])
        #expect(projection.overflowCount == 0)
    }

    @Test
    func zeroIsReservedAndTheTenthAgentOverflows() {
        let defaults = makeDefaults()
        let model = makeModel(defaults: defaults)
        let now = Date()
        model.state = SessionState(
            sessions: (0..<10).map { index in
                makeSession(
                    id: "session-\(index)",
                    firstSeenAt: now.addingTimeInterval(Double(index)),
                    updatedAt: now
                )
            }
        )

        let projection = model.agentControlSlotProjection(at: now)

        #expect(projection.assignedSlots.count == 9)
        #expect(projection.assignedSlots.map(\.keyLabel) == [
            "1", "2", "3", "4", "5", "6", "7", "8", "9",
        ])
        #expect(projection.keyLabel(for: "session-9") == nil)
        #expect(projection.overflowCount == 1)
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "agent-island-control-projection-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private func makeModel(defaults: UserDefaults) -> AppModel {
        AppModel(
            hiddenSessionStore: HiddenSessionStore(defaults: defaults),
            agentControlSlotAssignmentStore: AgentControlSlotAssignmentStore(
                defaults: defaults
            )
        )
    }

    private func makeSession(
        id: String,
        title: String? = nil,
        firstSeenAt: Date,
        updatedAt: Date,
        phase: SessionPhase = .running,
        permissionRequest: PermissionRequest? = nil,
        transcriptPath: String? = nil
    ) -> AgentSession {
        var session = AgentSession(
            id: id,
            title: title ?? "Claude · \(id)",
            tool: .claudeCode,
            origin: .live,
            attachmentState: .attached,
            phase: phase,
            summary: "",
            updatedAt: updatedAt,
            firstSeenAt: firstSeenAt,
            permissionRequest: permissionRequest,
            jumpTarget: JumpTarget(
                terminalApp: "Ghostty",
                workspaceName: id,
                paneTitle: "claude ~/\(id)",
                workingDirectory: "/tmp/\(id)",
                terminalSessionID: "ghostty-\(id)"
            ),
            claudeMetadata: ClaudeSessionMetadata(
                transcriptPath: transcriptPath ?? "/tmp/\(id).jsonl",
                currentTool: "Task"
            )
        )
        session.isProcessAlive = true
        session.isHookManaged = true
        return session
    }
}
