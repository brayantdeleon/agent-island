import Foundation
import Testing
@testable import AgentIslandApp
import AgentIslandCore

struct AgentSessionPresentationTests {
    @Test
    func completedSessionVisibilityIncludesExactlyOneHourButNotMore() {
        let now = Date(timeIntervalSince1970: 10_000)
        let exactlyOneHour = AgentSession(
            id: "one-hour",
            title: "Codex · one-hour",
            tool: .codex,
            attachmentState: .stale,
            phase: .completed,
            summary: "Done",
            updatedAt: now.addingTimeInterval(-3_600)
        )
        var moreThanOneHour = AgentSession(
            id: "over-one-hour",
            title: "Codex · over-one-hour",
            tool: .codex,
            attachmentState: .attached,
            phase: .completed,
            summary: "Done",
            updatedAt: now.addingTimeInterval(-3_600.001)
        )
        moreThanOneHour.isProcessAlive = true

        #expect(exactlyOneHour.isVisibleInIslandSessionList(at: now))
        #expect(!moreThanOneHour.isVisibleInIslandSessionList(at: now))
    }

    @Test
    func staleRunningSessionStillRequiresLiveVisibility() {
        let session = AgentSession(
            id: "stale-running",
            title: "Codex · stale",
            tool: .codex,
            attachmentState: .stale,
            phase: .running,
            summary: "Recovered",
            updatedAt: .now
        )

        #expect(!session.isVisibleInIslandSessionList(at: .now))
    }

    @Test
    func realtimeVoiceChatsAreExcludedOnlyForTheNumberedNamingConvention() {
        var voiceSession = AgentSession(
            id: "voice",
            title: "Codex voice helper",
            tool: .codex,
            attachmentState: .attached,
            phase: .running,
            summary: "Listening",
            updatedAt: .now,
            jumpTarget: JumpTarget(
                terminalApp: "Codex.app",
                workspaceName: "realtime-voice-chat-42",
                paneTitle: "Voice chat",
                workingDirectory: "/tmp/realtime-voice-chat-42"
            )
        )
        voiceSession.isProcessAlive = true

        var similarlyNamedSession = voiceSession
        similarlyNamedSession.id = "ordinary"
        similarlyNamedSession.jumpTarget?.workspaceName = "realtime-voice-chat-42-notes"

        var titledVoiceSession = voiceSession
        titledVoiceSession.id = "titled-voice"
        titledVoiceSession.title = "Codex · realtime-voice-chat-8"
        titledVoiceSession.jumpTarget = nil

        #expect(voiceSession.isRealtimeVoiceChatSession)
        #expect(!voiceSession.isVisibleInIsland)
        #expect(!voiceSession.isVisibleInIslandSessionList(at: .now))
        #expect(titledVoiceSession.isRealtimeVoiceChatSession)
        #expect(!similarlyNamedSession.isRealtimeVoiceChatSession)
        #expect(similarlyNamedSession.isVisibleInIslandSessionList(at: .now))
    }

    @Test
    func completedAndRequiredActionNotificationsStartExpanded() {
        let running = AgentSession(
            id: "running",
            title: "Running task",
            tool: .codex,
            phase: .running,
            summary: "Thinking",
            updatedAt: .now
        )
        let completed = AgentSession(
            id: "completed",
            title: "Completed task",
            tool: .codex,
            phase: .completed,
            summary: "Done",
            updatedAt: .now
        )
        let approval = AgentSession(
            id: "approval",
            title: "Approval task",
            tool: .codex,
            phase: .waitingForApproval,
            summary: "Needs approval",
            updatedAt: .now
        )

        #expect(!running.defaultsToExpandedNotificationDetails(isActionable: false))
        #expect(!running.defaultsToExpandedNotificationDetails(isActionable: true))
        #expect(completed.defaultsToExpandedNotificationDetails(isActionable: true))
        #expect(!approval.defaultsToExpandedNotificationDetails(isActionable: false))
        #expect(approval.defaultsToExpandedNotificationDetails(isActionable: true))
    }

    @Test
    func manuallyExpandedCompletionShowsItsFullEmbeddedBody() {
        #expect(
            IslandSessionEmbeddedDetailPolicy.shouldShow(
                phase: .completed,
                completionHasExpandedBody: true,
                runningDetailAvailable: false
            )
        )
        #expect(
            !IslandSessionEmbeddedDetailPolicy.shouldShow(
                phase: .completed,
                completionHasExpandedBody: false,
                runningDetailAvailable: false
            )
        )
    }

    @Test
    func persistentPermissionApprovalIsOnlyOfferedForClaudeRules() {
        let request = PermissionRequest(
            title: "Run tool",
            summary: "Run tool",
            affectedPath: "tool",
            toolName: "Bash"
        )
        let codex = AgentSession(
            id: "codex-approval",
            title: "Codex approval",
            tool: .codex,
            phase: .waitingForApproval,
            summary: "Approval needed",
            updatedAt: .now,
            permissionRequest: request
        )
        let claude = AgentSession(
            id: "claude-approval",
            title: "Claude approval",
            tool: .claudeCode,
            phase: .waitingForApproval,
            summary: "Approval needed",
            updatedAt: .now,
            permissionRequest: request
        )

        #expect(!codex.supportsPersistentPermissionApproval)
        #expect(claude.supportsPersistentPermissionApproval)
    }

    @Test
    func activeRunTimerSurvivesApprovalAndAnswerResolution() throws {
        let startedAt = Date(timeIntervalSince1970: 10_000)
        var state = SessionState()
        state.apply(.sessionStarted(SessionStarted(
            sessionID: "agent-run",
            title: "Agent run",
            tool: .codex,
            summary: "Working",
            timestamp: startedAt
        )))
        let request = PermissionRequest(
            title: "Run tests",
            summary: "Needs approval",
            affectedPath: "/tmp/repo"
        )
        state.apply(.permissionRequested(PermissionRequested(
            sessionID: "agent-run",
            request: request,
            timestamp: startedAt.addingTimeInterval(60)
        )))
        state.resolvePermission(
            sessionID: "agent-run",
            requestID: request.id,
            resolution: .allowOnce(),
            at: startedAt.addingTimeInterval(120)
        )

        var session = try #require(state.session(id: "agent-run"))
        #expect(session.runStartedAt == startedAt)
        #expect(session.spotlightAgeBadge(at: startedAt.addingTimeInterval(180)) == "3m")

        state.apply(.questionAsked(QuestionAsked(
            sessionID: "agent-run",
            prompt: QuestionPrompt(title: "Which option?", options: ["A", "B"]),
            timestamp: startedAt.addingTimeInterval(210)
        )))
        state.answerQuestion(
            sessionID: "agent-run",
            response: QuestionPromptResponse(answer: "A"),
            at: startedAt.addingTimeInterval(240)
        )

        session = try #require(state.session(id: "agent-run"))
        #expect(session.runStartedAt == startedAt)
        #expect(session.spotlightAgeBadge(at: startedAt.addingTimeInterval(300)) == "5m")
    }

    @Test
    func completedAgeUsesCompletionTimeAndNextRunGetsANewTimer() throws {
        let startedAt = Date(timeIntervalSince1970: 20_000)
        var state = SessionState()
        state.apply(.sessionStarted(SessionStarted(
            sessionID: "agent-run",
            title: "Agent run",
            tool: .claudeCode,
            summary: "Working",
            timestamp: startedAt
        )))
        state.apply(.sessionCompleted(SessionCompleted(
            sessionID: "agent-run",
            summary: "Done",
            timestamp: startedAt.addingTimeInterval(300)
        )))

        var session = try #require(state.session(id: "agent-run"))
        #expect(session.spotlightAgeBadge(at: startedAt.addingTimeInterval(420)) == "2m")

        state.apply(.activityUpdated(SessionActivityUpdated(
            sessionID: "agent-run",
            summary: "Working again",
            phase: .running,
            timestamp: startedAt.addingTimeInterval(600)
        )))

        session = try #require(state.session(id: "agent-run"))
        #expect(session.runStartedAt == startedAt.addingTimeInterval(600))
        #expect(session.spotlightAgeBadge(at: startedAt.addingTimeInterval(660)) == "1m")
    }

    @Test
    func attachedCompletedSessionStaysActiveWhileRecent() {
        let referenceDate = Date(timeIntervalSince1970: 10_000)
        let session = AgentSession(
            id: "session-1",
            title: "Codex · worktree",
            tool: .codex,
            origin: .live,
            attachmentState: .attached,
            phase: .completed,
            summary: "Ready",
            updatedAt: referenceDate.addingTimeInterval(-1_199),
            jumpTarget: JumpTarget(
                terminalApp: "Ghostty",
                workspaceName: "worktree",
                paneTitle: "codex ~/tmp/worktree",
                workingDirectory: "/tmp/worktree",
                terminalSessionID: "ghostty-1"
            )
        )

        #expect(session.islandPresence(at: referenceDate) == .active)
    }

    @Test
    func attachedCompletedSessionCollapsesWhenOld() {
        let referenceDate = Date(timeIntervalSince1970: 10_000)
        let session = AgentSession(
            id: "session-1",
            title: "Codex · worktree",
            tool: .codex,
            origin: .live,
            attachmentState: .attached,
            phase: .completed,
            summary: "Ready",
            updatedAt: referenceDate.addingTimeInterval(-1_201),
            jumpTarget: JumpTarget(
                terminalApp: "Ghostty",
                workspaceName: "worktree",
                paneTitle: "codex ~/tmp/worktree",
                workingDirectory: "/tmp/worktree",
                terminalSessionID: "ghostty-1"
            ),
            codexMetadata: CodexSessionMetadata(
                initialUserPrompt: "Initial prompt",
                lastUserPrompt: "Follow-up prompt",
                lastAssistantMessage: "Last assistant message"
            )
        )

        #expect(session.islandPresence(at: referenceDate) == .inactive)
        #expect(session.spotlightShowsDetailLines(at: referenceDate) == false)
    }

    @Test
    func detachedCompletedSessionCanStillCollapseToInactive() {
        let referenceDate = Date(timeIntervalSince1970: 10_000)
        let session = AgentSession(
            id: "session-1",
            title: "Codex · worktree",
            tool: .codex,
            origin: .live,
            attachmentState: .detached,
            phase: .completed,
            summary: "Ready",
            updatedAt: referenceDate.addingTimeInterval(-1_801)
        )

        #expect(session.islandPresence(at: referenceDate) == .inactive)
        #expect(session.spotlightShowsDetailLines(at: referenceDate) == false)
    }

    @Test
    func detachedCompletedSessionStaysActiveWithinTwentyMinutes() {
        let referenceDate = Date(timeIntervalSince1970: 10_000)
        let session = AgentSession(
            id: "session-1",
            title: "Codex · worktree",
            tool: .codex,
            origin: .live,
            attachmentState: .detached,
            phase: .completed,
            summary: "Ready",
            updatedAt: referenceDate.addingTimeInterval(-1_199),
            codexMetadata: CodexSessionMetadata(
                lastUserPrompt: "Follow-up prompt",
                lastAssistantMessage: "Last assistant message"
            )
        )

        #expect(session.islandPresence(at: referenceDate) == .active)
        #expect(session.spotlightShowsDetailLines(at: referenceDate))
    }

    @Test
    func completionReplyRecipientCoversEveryAgentTool() {
        let expectedNames: [(AgentTool, String)] = [
            (.claudeCode, "Claude"),
            (.codex, "Codex"),
            (.geminiCLI, "Gemini"),
            (.openCode, "OpenCode"),
            (.qoder, "Qoder"),
            (.qwenCode, "Qwen Code"),
            (.factory, "Factory"),
            (.codebuddy, "CodeBuddy"),
            (.cursor, "Cursor"),
            (.kimiCLI, "Kimi"),
        ]
        #expect(expectedNames.map { $0.0.rawValue }.sorted() == AgentTool.allCases.map(\.rawValue).sorted())

        for (tool, expectedName) in expectedNames {
            let session = AgentSession(
                id: "\(tool.rawValue)-session",
                title: "\(expectedName) · worktree",
                tool: tool,
                phase: .completed,
                summary: "Ready",
                updatedAt: .now
            )

            #expect(session.completionReplyRecipientName == expectedName)
        }
    }

    @Test
    func completedSessionBecomesV8StaleAfterFiveMinutes() {
        let referenceDate = Date(timeIntervalSince1970: 10_000)
        let session = AgentSession(
            id: "session-1",
            title: "Codex · worktree",
            tool: .codex,
            origin: .live,
            attachmentState: .attached,
            phase: .completed,
            summary: "Ready",
            updatedAt: referenceDate.addingTimeInterval(-301)
        )

        #expect(session.isStaleCompletedForIsland(at: referenceDate))
        #expect(session.islandPresence(at: referenceDate) == .active)
    }

    @Test
    func completedSessionDoesNotBecomeV8StaleWhenThresholdIsNever() {
        let referenceDate = Date(timeIntervalSince1970: 10_000)
        let session = AgentSession(
            id: "session-1",
            title: "Codex · worktree",
            tool: .codex,
            origin: .live,
            attachmentState: .attached,
            phase: .completed,
            summary: "Ready",
            updatedAt: referenceDate.addingTimeInterval(-86_400)
        )

        #expect(!session.isStaleCompletedForIsland(
            at: referenceDate,
            threshold: IslandCompletedStaleThreshold.never.seconds
        ))
    }

    @Test
    func nonCompletedSessionsDoNotBecomeV8Stale() {
        let referenceDate = Date(timeIntervalSince1970: 10_000)
        let session = AgentSession(
            id: "session-1",
            title: "Codex · worktree",
            tool: .codex,
            origin: .live,
            attachmentState: .attached,
            phase: .running,
            summary: "Working",
            updatedAt: referenceDate.addingTimeInterval(-3_600)
        )

        #expect(!session.isStaleCompletedForIsland(at: referenceDate))
    }

    @Test
    func liveHeadlineUsesProjectAndCodexSessionName() {
        let session = AgentSession(
            id: "session-1",
            title: "Improve island hover behavior",
            tool: .codex,
            origin: .live,
            attachmentState: .attached,
            phase: .running,
            summary: "Working",
            updatedAt: Date(timeIntervalSince1970: 10_000),
            jumpTarget: JumpTarget(
                terminalApp: "Ghostty",
                workspaceName: "worktree",
                paneTitle: "codex ~/tmp/worktree",
                workingDirectory: "/tmp/worktree",
                terminalSessionID: "ghostty-1"
            ),
            codexMetadata: CodexSessionMetadata(
                initialUserPrompt: "Start by fixing the island hover behavior.",
                lastUserPrompt: "Now make the overlay height fit the content.",
                lastAssistantMessage: "Updating the layout logic."
            )
        )

        #expect(session.spotlightHeadlineText == "worktree · Improve island hover behavior")
        #expect(session.spotlightPromptLineText == "You: Now make the overlay height fit the content.")
    }

    @Test
    func detachedSessionHeadlineUsesClaudeSessionName() {
        let session = AgentSession(
            id: "session-1",
            title: "Island hover cleanup",
            tool: .claudeCode,
            origin: .live,
            attachmentState: .detached,
            phase: .completed,
            summary: "Done",
            updatedAt: Date.now.addingTimeInterval(-30),
            jumpTarget: JumpTarget(
                terminalApp: "Claude.app",
                workspaceName: "worktree",
                paneTitle: "Island hover cleanup",
                workingDirectory: "/tmp/worktree"
            ),
            claudeMetadata: ClaudeSessionMetadata(
                initialUserPrompt: "Start by fixing the island hover behavior.",
                lastUserPrompt: "Now make the overlay height fit the content.",
                lastAssistantMessage: "Updating the layout logic."
            )
        )

        #expect(session.spotlightHeadlineText == "worktree · Island hover cleanup")
        #expect(session.spotlightPromptLineText == "You: Now make the overlay height fit the content.")
    }

    @Test
    func completedSessionShowsDifferentHeadlineAndPrompt() {
        let now = Date.now
        let session = AgentSession(
            id: "session-1",
            title: "README release notes",
            tool: .codex,
            origin: .live,
            attachmentState: .attached,
            phase: .completed,
            summary: "Done",
            updatedAt: now.addingTimeInterval(-30),
            jumpTarget: JumpTarget(
                terminalApp: "Ghostty",
                workspaceName: "worktree",
                paneTitle: "codex ~/tmp/worktree",
                workingDirectory: "/tmp/worktree",
                terminalSessionID: "ghostty-1"
            ),
            codexMetadata: CodexSessionMetadata(
                initialUserPrompt: "Commit the README change.",
                lastUserPrompt: "Also confirm the worktree status.",
                lastAssistantMessage: "Committed and verified."
            )
        )

        #expect(session.spotlightHeadlineText == "worktree · README release notes")
        #expect(session.notificationHeadlineText == "worktree · README release notes")
        #expect(session.spotlightPromptLineText == "You: Also confirm the worktree status.")
        #expect(session.notificationHeaderPromptLineText == nil)
    }

    @Test
    func genericProviderTitleDoesNotDuplicateProjectOrFallBackToPrompt() {
        let session = AgentSession(
            id: "session-1",
            title: "Codex · worktree",
            tool: .codex,
            phase: .running,
            summary: "Working",
            updatedAt: .now,
            jumpTarget: JumpTarget(
                terminalApp: "Codex.app",
                workspaceName: "worktree",
                paneTitle: "Codex · worktree"
            ),
            codexMetadata: CodexSessionMetadata(
                initialUserPrompt: "This prompt should not become the title."
            )
        )

        #expect(session.spotlightHeadlineText == "worktree")
    }

    @Test
    func runningCodexSessionWithoutToolShowsThinkingBesidePrompt() {
        let session = AgentSession(
            id: "session-1",
            title: "Codex · worktree",
            tool: .codex,
            origin: .live,
            attachmentState: .attached,
            phase: .running,
            summary: "Thinking.",
            updatedAt: Date(timeIntervalSince1970: 10_000),
            codexMetadata: CodexSessionMetadata(
                lastUserPrompt: "Align the Codex statuses."
            )
        )

        #expect(session.spotlightPromptLineText == "You: Align the Codex statuses.")
        #expect(session.spotlightActivityLineText == "Thinking")
        #expect(session.displayCurrentToolName == nil)
    }

    @Test
    func runningCodexSessionKeepsWriteStdinAsInput() {
        let session = AgentSession(
            id: "session-1",
            title: "Codex · worktree",
            tool: .codex,
            origin: .live,
            attachmentState: .attached,
            phase: .running,
            summary: "Running input.",
            updatedAt: Date(timeIntervalSince1970: 10_000),
            codexMetadata: CodexSessionMetadata(
                lastUserPrompt: "Continue the command.",
                currentTool: "write_stdin",
                currentCommandPreview: "y"
            )
        )

        #expect(session.spotlightActivityLineText == "Input y")
        #expect(session.spotlightStatusLabel == "Live · Input")
        #expect(session.displayCurrentToolName == "Input")
    }

    @Test
    func runningCodexSessionDisplaysWebSearchAction() {
        let session = AgentSession(
            id: "session-1",
            title: "Codex · worktree",
            tool: .codex,
            origin: .live,
            attachmentState: .attached,
            phase: .running,
            summary: "Running web search.",
            updatedAt: Date(timeIntervalSince1970: 10_000),
            codexMetadata: CodexSessionMetadata(
                lastUserPrompt: "Check the Codex repo.",
                currentTool: "web_search",
                currentCommandPreview: "Codex rollout ResponseItem"
            )
        )

        #expect(session.spotlightActivityLineText == "Search Codex rollout ResponseItem")
        #expect(session.spotlightStatusLabel == "Live · Search")
        #expect(session.spotlightSecondaryText == "Running Search")
        #expect(session.displayCurrentToolName == "Search")
    }

    @Test
    func runtimeSurfaceBadgeDistinguishesAppsFromTerminals() {
        let appSession = AgentSession(
            id: "app-session",
            title: "Claude Code · app",
            tool: .claudeCode,
            phase: .running,
            summary: "Working",
            updatedAt: .now,
            jumpTarget: JumpTarget(
                terminalApp: "Claude.app",
                workspaceName: "app",
                paneTitle: "Claude"
            )
        )
        let terminalSession = AgentSession(
            id: "terminal-session",
            title: "Codex · terminal",
            tool: .codex,
            phase: .running,
            summary: "Working",
            updatedAt: .now,
            jumpTarget: JumpTarget(
                terminalApp: "Ghostty",
                workspaceName: "terminal",
                paneTitle: "codex"
            )
        )

        #expect(appSession.spotlightRuntimeSurfaceBadge == "app")
        #expect(terminalSession.spotlightRuntimeSurfaceBadge == "terminal")
    }

    @Test
    func runningCodexAndClaudeSessionsUseProviderTitleColors() {
        var codex = AgentSession(
            id: "codex",
            title: "Codex",
            tool: .codex,
            phase: .running,
            summary: "Working",
            updatedAt: .now
        )
        let claude = AgentSession(
            id: "claude",
            title: "Claude Code",
            tool: .claudeCode,
            phase: .running,
            summary: "Working",
            updatedAt: .now
        )

        #expect(codex.spotlightActiveTitleColorHex == AgentTool.codex.brandColorHex)
        #expect(claude.spotlightActiveTitleColorHex == AgentTool.claudeCode.brandColorHex)

        codex.phase = .completed
        #expect(codex.spotlightActiveTitleColorHex == nil)
    }

    private func completedSession(id: String, updatedAt: Date, phase: SessionPhase = .completed) -> AgentSession {
        AgentSession(
            id: id,
            title: "Claude · repo",
            tool: .claudeCode,
            attachmentState: .stale,
            phase: phase,
            summary: "Completed the turn",
            updatedAt: updatedAt
        )
    }

    @Test
    func idleForIslandMatchesStaleCompletedAtDefaultThreshold() {
        let now = Date(timeIntervalSince1970: 10_000)
        let session = completedSession(id: "s", updatedAt: now.addingTimeInterval(-360))

        #expect(session.isIdleForIsland(at: now, completedStaleThreshold: 5 * 60))
        #expect(!session.isJustDoneForIsland(at: now, completedStaleThreshold: 5 * 60))
    }

    /// `islandPresence` flips to `.inactive` at a fixed 20 minutes. Folding
    /// that into the idle predicate — as the island header used to — overrides
    /// a user who explicitly chose "Never" for the Done timeout.
    @Test
    func idleForIslandIgnoresTwentyMinutePresenceWhenThresholdIsNever() {
        let now = Date(timeIntervalSince1970: 100_000)
        let session = completedSession(id: "s", updatedAt: now.addingTimeInterval(-24 * 3_600))

        #expect(session.islandPresence(at: now) == .inactive)
        #expect(!session.isIdleForIsland(at: now, completedStaleThreshold: .infinity))
        #expect(session.isJustDoneForIsland(at: now, completedStaleThreshold: .infinity))
    }

    @Test
    func idleForIslandIsFalseForNonCompletedPhases() {
        let now = Date(timeIntervalSince1970: 100_000)
        let running = completedSession(id: "s", updatedAt: now.addingTimeInterval(-3_600), phase: .running)

        #expect(!running.isIdleForIsland(at: now, completedStaleThreshold: 5 * 60))
        #expect(!running.isJustDoneForIsland(at: now, completedStaleThreshold: 5 * 60))
    }

    /// Every completed row belongs to exactly one of the two island buckets,
    /// so the section headings and the header chips can never disagree.
    @Test
    func justDoneAndIdleArePartitionOfCompleted() {
        let now = Date(timeIntervalSince1970: 100_000)
        let ages: [TimeInterval] = [-60, -360, -1_260, -7_200]

        for threshold in IslandCompletedStaleThreshold.allCases {
            for age in ages {
                let session = completedSession(id: "s", updatedAt: now.addingTimeInterval(age))
                let idle = session.isIdleForIsland(at: now, completedStaleThreshold: threshold.seconds)
                let done = session.isJustDoneForIsland(at: now, completedStaleThreshold: threshold.seconds)
                #expect(idle != done, "age \(age) at \(threshold) landed in \(idle) / \(done)")
            }
        }
    }
}
