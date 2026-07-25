import Foundation
import Testing
@testable import AgentIslandApp
import AgentIslandCore

@MainActor
struct ActiveSessionPetTests {
    @Test
    func leadingSlotWidthFitsOneOrBothProviderPets() {
        #expect(V6LeadingActivityView.intrinsicWidth(for: []) == 24)
        #expect(V6LeadingActivityView.intrinsicWidth(for: [.codex]) == 24)
        #expect(V6LeadingActivityView.intrinsicWidth(for: [.codex, .claude]) == 52)
        #expect(V6LeadingActivityView.macbookLeadingExtension(for: [.codex, .claude]) == 28)
    }

    @Test
    func currentClawdArtworkIsPackagedWithTheApp() {
        #expect(Bundle.appResources.url(forResource: "clawd-menubar", withExtension: "png") != nil)
    }

    @Test
    func petAnimationTimingKeepsClawdCenteredAndSlowsCodex() {
        let codexSpeed = V6LeadingActivityView.clawdFrameDuration
            / V6LeadingActivityView.codexFrameDuration
        #expect(abs(codexSpeed - 0.75) < 0.0001)
        #expect(V6LeadingActivityView.clawdHopOffsets.reduce(0, +) == 0)
        #expect(V6LeadingActivityView.clawdHopOffsets.min() == -1.75)
        #expect(V6LeadingActivityView.clawdHopOffsets.max() == 1.75)
    }

    @Test
    func runningSessionsProduceOnePetPerProviderInStableOrder() {
        let model = AppModel()
        model.state = SessionState(sessions: [
            runningSession(id: "claude-1", tool: .claudeCode),
            runningSession(id: "codex-1", tool: .codex),
            runningSession(id: "codex-2", tool: .codex),
        ])

        #expect(model.islandClosedActivePets == [.codex, .claude])
    }

    @Test
    func completedAndWaitingSessionsDoNotProduceRunningPets() {
        let model = AppModel()
        var waiting = runningSession(id: "claude-waiting", tool: .claudeCode)
        waiting.phase = .waitingForApproval
        var completed = runningSession(id: "codex-completed", tool: .codex)
        completed.phase = .completed
        model.state = SessionState(sessions: [waiting, completed])

        #expect(model.islandClosedActivePets.isEmpty)
    }

    @Test
    func unrelatedRunningProvidersKeepTheWaveformFallback() {
        let model = AppModel()
        model.state = SessionState(sessions: [
            runningSession(id: "gemini-1", tool: .geminiCLI),
        ])

        #expect(model.islandClosedActivePets.isEmpty)
    }

    private func runningSession(id: String, tool: AgentTool) -> AgentSession {
        var session = AgentSession(
            id: id,
            title: "\(tool.displayName) · active",
            tool: tool,
            origin: .live,
            attachmentState: .attached,
            phase: .running,
            summary: "Running",
            updatedAt: .now
        )
        session.isProcessAlive = true
        return session
    }
}
