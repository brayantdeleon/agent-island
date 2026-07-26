import Foundation
import Testing
@testable import AgentIslandCore

struct ClaudeSessionRegistryTests {
    @Test
    func claudeSessionRegistryRoundTripsTrackedSessions() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-island-claude-registry-\(UUID().uuidString)", isDirectory: true)
        let fileURL = rootURL.appendingPathComponent("claude-session-registry.json")
        let registry = ClaudeSessionRegistry(fileURL: fileURL)

        defer {
            try? FileManager.default.removeItem(at: rootURL)
        }

        let records = [
            ClaudeTrackedSessionRecord(
                sessionID: "claude-session-1",
                title: "Claude · agent-island",
                origin: .live,
                attachmentState: .attached,
                summary: "Working on the registry.",
                phase: .running,
                updatedAt: Date(timeIntervalSince1970: 1_000),
                runStartedAt: Date(timeIntervalSince1970: 900),
                jumpTarget: JumpTarget(
                    terminalApp: "Ghostty",
                    workspaceName: "agent-island",
                    paneTitle: "claude ~/Personal/agent-island",
                    workingDirectory: "/tmp/agent-island",
                    terminalSessionID: "ghostty-claude",
                    terminalTTY: "/dev/ttys002"
                ),
                claudeMetadata: ClaudeSessionMetadata(
                    transcriptPath: "/tmp/claude.jsonl",
                    initialUserPrompt: "Start with Claude recovery.",
                    lastUserPrompt: "Tighten Claude restart recovery.",
                    lastAssistantMessage: "Implementing the registry.",
                    currentTool: "Task",
                    currentToolInputPreview: "Implement ClaudeSessionRegistry",
                    model: "sonnet"
                )
            ),
        ]

        try registry.save(records)
        let reloaded = try registry.load()

        #expect(reloaded == records)
        #expect(reloaded.first?.session.claudeMetadata?.transcriptPath == "/tmp/claude.jsonl")
        #expect(reloaded.first?.session.jumpTarget?.terminalTTY == "/dev/ttys002")
        #expect(reloaded.first?.session.runStartedAt == Date(timeIntervalSince1970: 900))
    }

    @Test
    func claudeTrackedSessionRecordRestoresAsStale() {
        var session = AgentSession(
            id: "claude-session-1",
            title: "Claude · agent-island",
            tool: .claudeCode,
            origin: .live,
            attachmentState: .attached,
            phase: .running,
            summary: "Working on the registry.",
            updatedAt: .now,
            jumpTarget: JumpTarget(
                terminalApp: "Ghostty",
                workspaceName: "agent-island",
                paneTitle: "claude ~/Personal/agent-island",
                workingDirectory: "/tmp/agent-island",
                terminalSessionID: "ghostty-claude",
                terminalTTY: "/dev/ttys002"
            )
        )
        session.isHookManaged = true
        session.isProcessAlive = true
        let record = ClaudeTrackedSessionRecord(session: session)

        #expect(record.session.attachmentState == .attached)
        #expect(record.restorableSession.attachmentState == .stale)
        #expect(record.restorableSession.jumpTarget?.terminalSessionID == "ghostty-claude")
        #expect(record.restorableSession.isHookManaged)
        #expect(!record.restorableSession.isProcessAlive)
        #expect(record.shouldRestoreToLiveState)
    }

    @Test
    func explicitlyEndedClaudeRecordDoesNotRestoreToLiveState() {
        let record = ClaudeTrackedSessionRecord(
            sessionID: "claude-session-1",
            title: "Claude · agent-island",
            origin: .live,
            attachmentState: .attached,
            summary: "Working on the registry.",
            phase: .running,
            updatedAt: .now,
            jumpTarget: JumpTarget(
                terminalApp: "Ghostty",
                workspaceName: "agent-island",
                paneTitle: "claude ~/Personal/agent-island",
                workingDirectory: "/tmp/agent-island",
                terminalSessionID: "ghostty-claude",
                terminalTTY: "/dev/ttys002"
            ),
            isHookManaged: true,
            isSessionEnded: true
        )

        #expect(record.session.isSessionEnded)
        #expect(!record.shouldRestoreToLiveState)
    }

    @Test
    func legacyTranscriptOnlyRecordDoesNotRestoreAsLive() {
        let record = ClaudeTrackedSessionRecord(
            sessionID: "ordinary-chat",
            title: "Claude · agent-island",
            origin: .live,
            summary: "Historical transcript",
            phase: .completed,
            updatedAt: .now,
            jumpTarget: JumpTarget(
                terminalApp: "Unknown",
                workspaceName: "agent-island",
                paneTitle: "Claude ordinary",
                workingDirectory: "/tmp/agent-island"
            )
        )

        #expect(!record.isHookManaged)
        #expect(!record.shouldRestoreToLiveState)
    }

    @Test
    func passiveClaudeDesktopResumePlaceholderDoesNotRestoreToLiveState() {
        let record = ClaudeTrackedSessionRecord(
            sessionID: "claude-desktop-passive-resume",
            title: "Claude · agent-island",
            origin: .live,
            attachmentState: .attached,
            summary: "Resumed Claude Code session in agent-island.",
            phase: .completed,
            updatedAt: .now,
            jumpTarget: JumpTarget(
                terminalApp: "Claude.app",
                workspaceName: "agent-island",
                paneTitle: "Claude claude-d",
                workingDirectory: "/tmp/agent-island"
            ),
            claudeMetadata: ClaudeSessionMetadata(
                transcriptPath: "/tmp/claude-desktop-passive-resume.jsonl",
                startupSource: .resume
            ),
            isHookManaged: true
        )

        #expect(!record.shouldRestoreToLiveState)
    }

    @Test
    func activeClaudeDesktopResumeRecordStillRestoresToLiveState() {
        let record = ClaudeTrackedSessionRecord(
            sessionID: "claude-desktop-active-resume",
            title: "Claude · agent-island",
            origin: .live,
            attachmentState: .attached,
            summary: "Implemented the requested change.",
            phase: .completed,
            updatedAt: .now,
            jumpTarget: JumpTarget(
                terminalApp: "Claude.app",
                workspaceName: "agent-island",
                paneTitle: "Claude claude-d",
                workingDirectory: "/tmp/agent-island"
            ),
            claudeMetadata: ClaudeSessionMetadata(
                transcriptPath: "/tmp/claude-desktop-active-resume.jsonl",
                initialUserPrompt: "Implement the requested change.",
                lastUserPrompt: "Implement the requested change.",
                lastAssistantMessage: "Implemented the requested change.",
                startupSource: .resume
            ),
            isHookManaged: true
        )

        #expect(record.shouldRestoreToLiveState)
    }
}
