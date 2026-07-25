import Foundation
import Testing
@testable import AgentIslandApp
import AgentIslandCore

/// Coverage for `adoptProcessTTYsForClaudeSessions`, which fills in a TTY the
/// hook could not resolve. It is private, so these drive it through
/// `reconcileSessionAttachments` with every ambient probe pinned so the tests
/// do not depend on what happens to be running on the machine.
@MainActor
struct ProcessMonitoringAdoptTests {
    private func reconcile(
        _ model: AppModel,
        activeProcesses: [ActiveAgentProcessDiscovery.ProcessSnapshot]
    ) {
        model.monitoring.reconcileSessionAttachments(
            activeProcesses: activeProcesses,
            ghosttyAvailability: .available([], appIsRunning: false),
            terminalAvailability: .available([], appIsRunning: false),
            preResolvedJumpTargets: [:],
            observedCodexAppRunning: false,
            observedClaudeDesktopRunning: false
        )
    }

    private func claudeProcess(
        tty: String? = "/dev/ttys002",
        workingDirectory: String = "/tmp/repo"
    ) -> ActiveAgentProcessDiscovery.ProcessSnapshot {
        ActiveAgentProcessDiscovery.ProcessSnapshot(
            tool: .claudeCode,
            sessionID: nil,
            workingDirectory: workingDirectory,
            terminalTTY: tty,
            terminalApp: "Ghostty"
        )
    }

    private func session(
        id: String,
        terminalApp: String,
        updatedAt: Date,
        workingDirectory: String = "/tmp/repo"
    ) -> AgentSession {
        AgentSession(
            id: id,
            title: "Claude · repo",
            tool: .claudeCode,
            origin: .live,
            attachmentState: .stale,
            phase: .completed,
            summary: "Completed the turn",
            updatedAt: updatedAt,
            jumpTarget: JumpTarget(
                terminalApp: terminalApp,
                workspaceName: "repo",
                paneTitle: "Claude \(id)",
                workingDirectory: workingDirectory
            )
        )
    }

    /// Adopting a TTY is an internal attachment correction, not user activity.
    /// Bumping `updatedAt` re-sorted the session list, reset the Done -> Idle
    /// age split, extended the one-hour retention window, and flipped the
    /// cwd-match tie-break in `uniqueTrackedClaudeSession` — all from a
    /// background poll on a session nobody touched.
    @Test
    func adoptedProcessTTYDoesNotBumpUpdatedAt() {
        let updatedAt = Date(timeIntervalSince1970: 100_000)
        let model = AppModel()
        model.state = SessionState(sessions: [
            session(id: "terminal-1", terminalApp: "Ghostty", updatedAt: updatedAt),
        ])

        reconcile(model, activeProcesses: [claudeProcess()])

        let adopted = model.state.session(id: "terminal-1")
        #expect(adopted?.jumpTarget?.terminalTTY == "/dev/ttys002")
        #expect(adopted?.attachmentState == .attached)
        #expect(adopted?.updatedAt == updatedAt)
    }

    /// A Claude.app session is TTY-less by construction. Letting a terminal
    /// `claude` in the same cwd hand it a TTY makes TerminalJumpTargetResolver
    /// start rewriting its jumpTarget, which destroys the "Claude.app" tag the
    /// desktop liveness gate depends on — a second, independent route to the
    /// session being wrongly marked ended.
    @Test
    func adoptSkipsClaudeDesktopSessions() {
        let updatedAt = Date(timeIntervalSince1970: 100_000)
        let model = AppModel()
        model.state = SessionState(sessions: [
            session(id: "desktop-1", terminalApp: "Claude.app", updatedAt: updatedAt),
        ])

        reconcile(model, activeProcesses: [claudeProcess()])

        let desktop = model.state.session(id: "desktop-1")
        #expect(desktop?.jumpTarget?.terminalTTY == nil)
        #expect(desktop?.jumpTarget?.terminalApp == "Claude.app")
    }

    /// An ended session must not claim a TTY: `ttyAlreadyClaimed` would then
    /// block the live session that actually owns that terminal.
    @Test
    func adoptSkipsEndedClaudeSessions() {
        let updatedAt = Date(timeIntervalSince1970: 100_000)
        let model = AppModel()
        var ended = session(id: "terminal-1", terminalApp: "Ghostty", updatedAt: updatedAt)
        ended.isSessionEnded = true
        model.state = SessionState(sessions: [ended])

        reconcile(model, activeProcesses: [claudeProcess()])

        #expect(model.state.session(id: "terminal-1")?.jumpTarget?.terminalTTY == nil)
    }
}
