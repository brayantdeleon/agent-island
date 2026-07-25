import Foundation
import Testing
@testable import AgentIslandApp
import AgentIslandCore

/// Coverage for `ProcessMonitoringCoordinator.sessionIDsWithAliveProcesses`,
/// which decides which sessions `SessionState.markProcessLiveness` is allowed
/// to age out. Claude Desktop ("local agent mode") runs Claude Code as a
/// TTY-less subprocess that ps/lsof discovery never returns, so these sessions
/// depend entirely on the Claude.app branch — nothing else can keep them alive.
@MainActor
struct ProcessMonitoringLivenessTests {
    private func claudeDesktopSession(
        id: String = "desktop-1",
        phase: SessionPhase = .completed,
        updatedAt: Date,
        workingDirectory: String = "/tmp/repo"
    ) -> AgentSession {
        AgentSession(
            id: id,
            title: "Claude · repo",
            tool: .claudeCode,
            origin: .live,
            attachmentState: .attached,
            phase: phase,
            summary: "Completed the turn",
            updatedAt: updatedAt,
            jumpTarget: JumpTarget(
                terminalApp: "Claude.app",
                workspaceName: "repo",
                paneTitle: "Claude \(id)",
                workingDirectory: workingDirectory
            )
        )
    }

    private func aliveIDs(
        for sessions: [AgentSession],
        isClaudeDesktopRunning: Bool = true,
        now: Date
    ) -> Set<String> {
        AppModel().monitoring.sessionIDsWithAliveProcesses(
            activeProcesses: [],
            isCodexAppRunning: false,
            isClaudeDesktopRunning: isClaudeDesktopRunning,
            sessions: sessions,
            now: now
        )
    }

    /// The reported bug. Claude's Stop hook fires `.completed` after every
    /// turn, so "completed 45 minutes ago" means "you haven't typed in 45
    /// minutes" — not "this conversation is over". The old ten-minute
    /// staleness window dropped the session from the alive set, and two
    /// missed polls later `markProcessLiveness` marked a perfectly healthy
    /// conversation as ended.
    @Test
    func claudeDesktopSessionStaysAliveWhileIdleBeyondTenMinutes() {
        let now = Date(timeIntervalSince1970: 100_000)
        let session = claudeDesktopSession(updatedAt: now.addingTimeInterval(-45 * 60))

        #expect(aliveIDs(for: [session], now: now).contains("desktop-1"))
    }

    /// The abandonment backstop still bounds state growth for a Claude.app
    /// instance left running for days.
    @Test
    func claudeDesktopSessionExpiresAfterAbandonedWindow() {
        let now = Date(timeIntervalSince1970: 100_000 + 25 * 3_600)
        let session = claudeDesktopSession(updatedAt: Date(timeIntervalSince1970: 100_000))

        #expect(aliveIDs(for: [session], now: now).isEmpty)
    }

    /// The backstop is not conditioned on `.completed`: a `.running` session
    /// that stopped receiving hooks a day ago is just as abandoned.
    @Test
    func runningClaudeDesktopSessionAlsoExpiresAfterAbandonedWindow() {
        let now = Date(timeIntervalSince1970: 100_000 + 25 * 3_600)
        let session = claudeDesktopSession(
            phase: .running,
            updatedAt: Date(timeIntervalSince1970: 100_000)
        )

        #expect(aliveIDs(for: [session], now: now).isEmpty)
    }

    /// Quitting Claude.app is the real "these conversations are gone" signal,
    /// and still clears the whole set on the normal two-poll path.
    @Test
    func claudeDesktopSessionDroppedWhenAppNotRunning() {
        let now = Date(timeIntervalSince1970: 100_000)
        let session = claudeDesktopSession(updatedAt: now.addingTimeInterval(-60))

        #expect(aliveIDs(for: [session], isClaudeDesktopRunning: false, now: now).isEmpty)
    }

    /// A SessionEnd hook is authoritative — app-level liveness must not undo it.
    @Test
    func endedClaudeDesktopSessionIsNotRevivedByAppLiveness() {
        let now = Date(timeIntervalSince1970: 100_000)
        var session = claudeDesktopSession(updatedAt: now.addingTimeInterval(-60))
        session.isSessionEnded = true

        #expect(aliveIDs(for: [session], now: now).isEmpty)
    }

    /// Several conversations open in one repo all survive: identity comes from
    /// the hook's session id, not from the (indistinguishable) processes.
    @Test
    func multipleClaudeDesktopSessionsInSameWorkspaceAllStayAlive() {
        let now = Date(timeIntervalSince1970: 100_000)
        let sessions = [
            claudeDesktopSession(id: "desktop-1", updatedAt: now.addingTimeInterval(-30 * 60)),
            claudeDesktopSession(id: "desktop-2", updatedAt: now.addingTimeInterval(-40 * 60)),
            claudeDesktopSession(id: "desktop-3", updatedAt: now.addingTimeInterval(-50 * 60)),
        ]

        #expect(aliveIDs(for: sessions, now: now) == ["desktop-1", "desktop-2", "desktop-3"])
    }

    /// A terminal Claude session carries no "Claude.app" tag, so it must not
    /// pick up desktop liveness — it ages out on process discovery as before.
    @Test
    func terminalClaudeSessionDoesNotInheritDesktopLiveness() {
        let now = Date(timeIntervalSince1970: 100_000)
        var session = claudeDesktopSession(updatedAt: now.addingTimeInterval(-60))
        session.jumpTarget?.terminalApp = "Ghostty"
        session.jumpTarget?.terminalTTY = "/dev/ttys002"

        #expect(aliveIDs(for: [session], now: now).isEmpty)
    }

    @Test
    func demoClaudeDesktopSessionIsNeverMarkedAlive() {
        let now = Date(timeIntervalSince1970: 100_000)
        var session = claudeDesktopSession(updatedAt: now.addingTimeInterval(-60))
        session.origin = .demo

        #expect(aliveIDs(for: [session], now: now).isEmpty)
    }
}
