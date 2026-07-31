import Foundation
import Testing
@testable import AgentIslandApp
import AgentIslandCore

struct CodexNativeApprovalRemoteTests {
    @Test
    func threadIDFallsBackToDesktopSessionIDBeforeTargetMerge() {
        var session = AgentSession(
            id: "codex-desktop-thread",
            title: "Codex Desktop task",
            tool: .codex,
            phase: .waitingForApproval,
            summary: "Waiting",
            updatedAt: .now,
            jumpTarget: JumpTarget(
                terminalApp: "Unknown",
                workspaceName: "agent-island",
                paneTitle: "Codex"
            )
        )
        session.isCodexAppSession = true

        #expect(
            CodexNativeApprovalRemote.threadID(for: session)
                == "codex-desktop-thread"
        )
    }

    @Test
    func threadIDDoesNotTreatTerminalSessionIDAsDesktopThread() {
        let session = AgentSession(
            id: "codex-cli-session",
            title: "Codex CLI task",
            tool: .codex,
            phase: .waitingForApproval,
            summary: "Waiting",
            updatedAt: .now,
            jumpTarget: JumpTarget(
                terminalApp: "Ghostty",
                workspaceName: "agent-island",
                paneTitle: "codex"
            )
        )

        #expect(CodexNativeApprovalRemote.threadID(for: session) == nil)
    }
}
