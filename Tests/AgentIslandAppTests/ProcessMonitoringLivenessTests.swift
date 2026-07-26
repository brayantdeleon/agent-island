import Foundation
import Testing
@testable import AgentIslandApp
import AgentIslandCore

@MainActor
struct ProcessMonitoringLivenessTests {
    private func desktopSession(
        id: String,
        workingDirectory: String = "/tmp/repo",
        updatedAt: Date = .now
    ) -> AgentSession {
        var session = AgentSession(
            id: id,
            title: "Claude · repo",
            tool: .claudeCode,
            origin: .live,
            attachmentState: .attached,
            phase: .completed,
            summary: "Turn completed",
            updatedAt: updatedAt,
            jumpTarget: JumpTarget(
                terminalApp: "Claude.app",
                workspaceName: "repo",
                paneTitle: "Claude \(id)",
                workingDirectory: workingDirectory
            )
        )
        session.isHookManaged = true
        return session
    }

    private func desktopHost(
        workingDirectory: String = "/tmp/repo"
    ) -> ActiveProcessSnapshot {
        ActiveProcessSnapshot(
            tool: .claudeCode,
            sessionID: nil,
            workingDirectory: workingDirectory,
            terminalTTY: nil,
            terminalApp: "Claude.app",
            evidenceScope: .desktopHost
        )
    }

    @Test
    func desktopHostEvidenceKeepsAllHookTaggedChatsInWorkspaceAlive() {
        let sessions = [
            desktopSession(id: "chat-1"),
            desktopSession(id: "chat-2"),
            desktopSession(id: "other-workspace", workingDirectory: "/tmp/other"),
        ]
        let monitoring = AppModel().monitoring

        let aliveIDs = monitoring.sessionIDsWithAliveProcesses(
            activeProcesses: [desktopHost()],
            isCodexAppRunning: false,
            isClaudeDesktopRunning: false,
            sessions: sessions
        )

        #expect(aliveIDs == ["chat-1", "chat-2"])
    }

    @Test
    func desktopHostEvidenceDoesNotPromoteOrdinaryTranscriptChat() {
        let ordinaryChat = AgentSession(
            id: "ordinary-chat",
            title: "Claude · repo",
            tool: .claudeCode,
            origin: .live,
            attachmentState: .stale,
            phase: .completed,
            summary: "Historical chat",
            updatedAt: .now,
            jumpTarget: JumpTarget(
                terminalApp: "Unknown",
                workspaceName: "repo",
                paneTitle: "Claude ordinary",
                workingDirectory: "/tmp/repo"
            ),
            claudeMetadata: ClaudeSessionMetadata(
                transcriptPath: "/tmp/ordinary-chat.jsonl"
            )
        )
        let monitoring = AppModel().monitoring

        let aliveIDs = monitoring.sessionIDsWithAliveProcesses(
            activeProcesses: [desktopHost()],
            isCodexAppRunning: false,
            isClaudeDesktopRunning: false,
            sessions: [ordinaryChat]
        )

        #expect(aliveIDs.isEmpty)
        #expect(
            monitoring.mergedWithSyntheticClaudeSessions(
                existingSessions: [ordinaryChat],
                activeProcesses: [desktopHost()]
            ).map(\.id) == ["ordinary-chat"]
        )
    }

    @Test
    func claudeDesktopAppLivenessDoesNotExpireIdleOrReviveEndedChats() {
        let now = Date(timeIntervalSince1970: 100_000)
        var idle = desktopSession(
            id: "idle",
            updatedAt: now.addingTimeInterval(-3_600)
        )
        var ended = desktopSession(id: "ended", updatedAt: now)
        ended.isSessionEnded = true
        idle.isProcessAlive = false
        let monitoring = AppModel().monitoring

        let aliveIDs = monitoring.sessionIDsWithAliveProcesses(
            activeProcesses: [],
            isCodexAppRunning: false,
            isClaudeDesktopRunning: true,
            sessions: [idle, ended],
            now: now
        )

        #expect(aliveIDs == ["idle"])
    }

    @Test
    func terminalClaudeProcessDoesNotClaimDesktopChatInSameWorkspace() {
        let terminalProcess = ActiveProcessSnapshot(
            tool: .claudeCode,
            sessionID: nil,
            workingDirectory: "/tmp/repo",
            terminalTTY: "/dev/ttys001",
            terminalApp: "Ghostty"
        )
        let monitoring = AppModel().monitoring

        let aliveIDs = monitoring.sessionIDsWithAliveProcesses(
            activeProcesses: [terminalProcess],
            isCodexAppRunning: false,
            isClaudeDesktopRunning: false,
            sessions: [desktopSession(id: "desktop")]
        )

        #expect(aliveIDs.isEmpty)
    }
}
