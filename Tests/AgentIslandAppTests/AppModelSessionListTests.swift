import Foundation
import Testing
@testable import AgentIslandApp
import AgentIslandCore

@MainActor
@Suite(.serialized)
struct AppModelSessionListTests {
    init() {
        [
            "appearance.island.v8.stateIndicator",
            "appearance.island.v8.sessionGroup",
            "appearance.island.v8.sessionSort",
            "appearance.island.v8.completedStaleThreshold",
            "appearance.island.v8.notch.rightSlot",
            "appearance.island.v8.notch.closedPresentation",
            "appearance.island.v8.notch.centerLabel",
            "appearance.island.v8.notch.stateIndicator",
            "appearance.island.v8.notch.sessionGroup",
            "appearance.island.v8.notch.sessionSort",
            "appearance.island.v8.notch.completedStaleThreshold",
            "appearance.island.v8.topBar.rightSlot",
            "appearance.island.v8.topBar.closedPresentation",
            "appearance.island.v8.topBar.centerLabel",
            "appearance.island.v8.topBar.stateIndicator",
            "appearance.island.v8.topBar.sessionGroup",
            "appearance.island.v8.topBar.sessionSort",
            "appearance.island.v8.topBar.completedStaleThreshold",
            "app.suppressFrontmostNotifications",
            "feature.completionReply.enabled",
            HiddenSessionStore.defaultsKey,
            "overlay.sound.muted",
        ].forEach(UserDefaults.standard.removeObject(forKey:))
    }

    @Test
    func islandListKeepsRecentCompletedSessionsAfterTheirProcessEnds() {
        let now = Date()
        let model = AppModel()

        var liveSession = AgentSession(
            id: "live-session",
            title: "Claude · active",
            tool: .claudeCode,
            origin: .live,
            attachmentState: .attached,
            phase: .running,
            summary: "Running",
            updatedAt: now,
            jumpTarget: JumpTarget(
                terminalApp: "Ghostty",
                workspaceName: "active",
                paneTitle: "claude ~/active",
                workingDirectory: "/tmp/active",
                terminalSessionID: "ghostty-1"
            ),
            claudeMetadata: ClaudeSessionMetadata(
                transcriptPath: "/tmp/live.jsonl",
                currentTool: "Task"
            )
        )
        liveSession.isProcessAlive = true

        model.state = SessionState(
            sessions: [
                liveSession,
                AgentSession(
                    id: "recent-session",
                    title: "Claude · recent",
                    tool: .claudeCode,
                    origin: .live,
                    attachmentState: .stale,
                    phase: .completed,
                    summary: "Finished",
                    updatedAt: now.addingTimeInterval(-300),
                    jumpTarget: JumpTarget(
                        terminalApp: "Ghostty",
                        workspaceName: "recent",
                        paneTitle: "claude ~/recent",
                        workingDirectory: "/tmp/recent",
                        terminalSessionID: "ghostty-2"
                    ),
                    claudeMetadata: ClaudeSessionMetadata(
                        transcriptPath: "/tmp/recent.jsonl",
                        lastAssistantMessage: "Finished"
                    )
                ),
            ]
        )

        #expect(model.surfacedSessions.map(\.id) == ["live-session", "recent-session"])
        #expect(model.recentSessions.isEmpty)
        #expect(model.islandListSessions.map(\.id) == ["live-session", "recent-session"])
    }

    @Test
    func islandListHidesCompletedSessionsIdleForMoreThanOneHour() {
        let now = Date()
        let model = AppModel()

        var recentCompleted = listSession(
            id: "recent-completed",
            phase: .completed,
            updatedAt: now.addingTimeInterval(-3_599)
        )
        recentCompleted.isProcessAlive = false

        var oldCompleted = listSession(
            id: "old-completed",
            phase: .completed,
            updatedAt: now.addingTimeInterval(-3_601)
        )
        oldCompleted.isProcessAlive = true

        model.state = SessionState(sessions: [oldCompleted, recentCompleted])

        #expect(model.islandListSessions.map(\.id) == ["recent-completed"])
        #expect(model.recentSessions.map(\.id) == ["old-completed"])
    }

    @Test
    func realtimeVoiceChatsAreAbsentFromOpenAndRecentSessions() {
        let now = Date()
        let model = AppModel()

        var voiceSession = listSession(
            id: "realtime-voice-chat",
            phase: .running,
            updatedAt: now
        )
        voiceSession.title = "realtime-voice-chat-7"
        voiceSession.isProcessAlive = true

        let ordinarySession = listSession(
            id: "ordinary",
            phase: .completed,
            updatedAt: now
        )

        model.state = SessionState(sessions: [voiceSession, ordinarySession])

        #expect(model.allSessions.map(\.id).contains("realtime-voice-chat"))
        #expect(model.surfacedSessions.map(\.id) == ["ordinary"])
        #expect(model.recentSessions.isEmpty)
    }

    @Test
    func completedSessionDoesNotHopOutWhenAttachmentStateChanges() {
        let now = Date()
        let model = AppModel()
        var session = listSession(id: "completed", phase: .completed, updatedAt: now.addingTimeInterval(-600))
        session.isProcessAlive = true

        model.state = SessionState(sessions: [session])
        #expect(model.islandListSessions.map(\.id) == ["completed"])

        session.isProcessAlive = false
        session.attachmentState = .stale
        session.isSessionEnded = true
        model.state = SessionState(sessions: [session])

        #expect(model.islandListSessions.map(\.id) == ["completed"])
    }

    @Test
    func islandListDeduplicatesSessionsSharingTheSameLiveGhosttyTerminal() {
        let now = Date()
        let model = AppModel()

        var runningLive = AgentSession(
            id: "running-live",
            title: "Codex · agent-island",
            tool: .codex,
            origin: .live,
            attachmentState: .attached,
            phase: .running,
            summary: "Current live turn",
            updatedAt: now,
            jumpTarget: JumpTarget(
                terminalApp: "Ghostty",
                workspaceName: "agent-island",
                paneTitle: "codex ~/p/agent-island",
                workingDirectory: "/tmp/agent-island",
                terminalSessionID: "ghostty-split-1"
            )
        )
        runningLive.isProcessAlive = true

        var oldTurnSameSplit = AgentSession(
            id: "old-turn-same-split",
            title: "Codex · agent-island",
            tool: .codex,
            origin: .live,
            attachmentState: .attached,
            phase: .completed,
            summary: "Historical turn on the same split",
            updatedAt: now.addingTimeInterval(-90),
            jumpTarget: JumpTarget(
                terminalApp: "Ghostty",
                workspaceName: "agent-island",
                paneTitle: "codex ~/p/agent-island",
                workingDirectory: "/tmp/agent-island",
                terminalSessionID: "ghostty-split-1"
            )
        )
        oldTurnSameSplit.isProcessAlive = true

        var otherLive = AgentSession(
            id: "other-live",
            title: "Codex · agent-island",
            tool: .codex,
            origin: .live,
            attachmentState: .attached,
            phase: .completed,
            summary: "Another live split",
            updatedAt: now.addingTimeInterval(-30),
            jumpTarget: JumpTarget(
                terminalApp: "Ghostty",
                workspaceName: "agent-island",
                paneTitle: "codex ~/p/agent-island",
                workingDirectory: "/tmp/agent-island",
                terminalSessionID: "ghostty-split-2"
            )
        )
        otherLive.isProcessAlive = true

        model.state = SessionState(
            sessions: [runningLive, oldTurnSameSplit, otherLive]
        )

        #expect(model.surfacedSessions.map(\.id) == ["running-live", "other-live"])
        #expect(model.recentSessions.map(\.id).contains("old-turn-same-split"))
        #expect(model.liveSessionCount == 2)
        #expect(model.liveRunningCount == 1)
        #expect(model.liveAttentionCount == 0)
    }

    @Test
    func islandListKeepsDistinctCodexAppThreadsInTheSameWorkspace() {
        let now = Date()
        let model = AppModel()

        var firstThread = AgentSession(
            id: "codex-app-thread-1",
            title: "Codex · agent-island",
            tool: .codex,
            origin: .live,
            attachmentState: .attached,
            phase: .completed,
            summary: "First Codex.app thread",
            updatedAt: now,
            jumpTarget: JumpTarget(
                terminalApp: "Codex.app",
                workspaceName: "agent-island",
                paneTitle: "Codex · agent-island",
                workingDirectory: "/tmp/agent-island",
                codexThreadID: "codex-app-thread-1"
            )
        )
        firstThread.isCodexAppSession = true
        firstThread.isProcessAlive = true

        var secondThread = AgentSession(
            id: "codex-app-thread-2",
            title: "Codex · agent-island",
            tool: .codex,
            origin: .live,
            attachmentState: .attached,
            phase: .completed,
            summary: "Second Codex.app thread",
            updatedAt: now.addingTimeInterval(-30),
            jumpTarget: JumpTarget(
                terminalApp: "Codex.app",
                workspaceName: "agent-island",
                paneTitle: "Codex · agent-island",
                workingDirectory: "/tmp/agent-island",
                codexThreadID: "codex-app-thread-2"
            )
        )
        secondThread.isCodexAppSession = true
        secondThread.isProcessAlive = true

        model.state = SessionState(sessions: [firstThread, secondThread])

        #expect(model.surfacedSessions.map(\.id) == ["codex-app-thread-1", "codex-app-thread-2"])
        #expect(model.liveSessionCount == 2)
    }

    @Test
    func sessionBootstrapPlaceholderAppearsWhileStartupResolutionIsPending() {
        let now = Date(timeIntervalSince1970: 2_000)
        let model = AppModel()
        model.isResolvingInitialLiveSessions = true
        model.state = SessionState(
            sessions: [
                AgentSession(
                    id: "recovered-session",
                    title: "Codex · agent-island",
                    tool: .codex,
                    origin: .live,
                    attachmentState: .stale,
                    phase: .running,
                    summary: "Recovered from cache",
                    updatedAt: now
                ),
            ]
        )

        #expect(model.liveSessionCount == 0)
        #expect(model.shouldShowSessionBootstrapPlaceholder)
    }

    @Test
    func sessionBootstrapPlaceholderClearsOnceALiveSessionIsConfirmed() {
        let now = Date(timeIntervalSince1970: 2_000)
        let model = AppModel()
        model.isResolvingInitialLiveSessions = true

        var liveSession = AgentSession(
            id: "live-session",
            title: "Codex · agent-island",
            tool: .codex,
            origin: .live,
            attachmentState: .attached,
            phase: .running,
            summary: "Working",
            updatedAt: now
        )
        liveSession.isProcessAlive = true

        model.state = SessionState(sessions: [liveSession])

        #expect(model.liveSessionCount == 1)
        #expect(!model.shouldShowSessionBootstrapPlaceholder)
    }

    @Test
    func freshCompletedSessionsSortAheadOfV8StaleCompletedSessions() {
        let now = Date()
        let model = AppModel()

        var staleCompleted = AgentSession(
            id: "stale-completed",
            title: "Codex · stale",
            tool: .codex,
            origin: .live,
            attachmentState: .attached,
            phase: .completed,
            summary: "Finished earlier",
            updatedAt: now.addingTimeInterval(-301),
            jumpTarget: JumpTarget(
                terminalApp: "Ghostty",
                workspaceName: "stale",
                paneTitle: "codex ~/stale",
                workingDirectory: "/tmp/stale",
                terminalSessionID: "ghostty-stale"
            )
        )
        staleCompleted.isProcessAlive = true

        var freshCompleted = AgentSession(
            id: "fresh-completed",
            title: "Codex · fresh",
            tool: .codex,
            origin: .live,
            attachmentState: .attached,
            phase: .completed,
            summary: "Finished just now",
            updatedAt: now.addingTimeInterval(-299),
            jumpTarget: JumpTarget(
                terminalApp: "Ghostty",
                workspaceName: "fresh",
                paneTitle: "codex ~/fresh",
                workingDirectory: "/tmp/fresh",
                terminalSessionID: "ghostty-fresh"
            )
        )
        freshCompleted.isProcessAlive = true

        model.state = SessionState(sessions: [staleCompleted, freshCompleted])

        #expect(model.islandListSessions.map(\.id) == ["fresh-completed", "stale-completed"])
    }

    @Test
    func islandSessionSectionsGroupStaleCompletedIntoIdle() {
        let now = Date()
        let model = AppModel()
        model.islandSessionGroup = .state
        model.completedStaleThreshold = .fiveMinutes

        var approval = listSession(id: "approval", phase: .waitingForApproval, updatedAt: now)
        approval.permissionRequest = PermissionRequest(
            title: "Approve",
            summary: "Run tool",
            affectedPath: "/tmp"
        )

        var done = listSession(id: "done", phase: .completed, updatedAt: now.addingTimeInterval(-60))
        var stale = listSession(id: "stale", phase: .completed, updatedAt: now.addingTimeInterval(-360))
        approval.isProcessAlive = true
        done.isProcessAlive = true
        stale.isProcessAlive = true

        model.state = SessionState(sessions: [stale, done, approval])

        #expect(model.islandSessionSections.map(\.id) == ["state-approval", "state-done", "state-idle"])
        #expect(model.islandSessionSections.map(\.sessions.first?.id) == ["approval", "done", "stale"])
    }

    @Test
    func islandSessionSectionsKeepCompletedInDoneWhenStaleThresholdIsNever() {
        let now = Date()
        let model = AppModel()
        model.islandSessionGroup = .state
        model.completedStaleThreshold = .never

        var oldDone = listSession(id: "old-done", phase: .completed, updatedAt: now.addingTimeInterval(-1_800))
        oldDone.isProcessAlive = true
        model.state = SessionState(sessions: [oldDone])

        #expect(model.islandSessionSections.map(\.id) == ["state-done"])
        #expect(model.islandSessionSections.first?.sessions.first?.id == "old-done")
    }

    @Test
    func hiddenConversationPersistsAndStaysOutOfNormalIslandPresentation() {
        let storage = makeHiddenSessionStorage()
        defer {
            storage.defaults.removePersistentDomain(forName: storage.suiteName)
        }

        var session = listSession(id: "hidden-running", phase: .running, updatedAt: .now)
        session.isProcessAlive = true

        let model = AppModel(hiddenSessionStore: storage.store)
        model.state = SessionState(sessions: [session])
        model.hideSession(session)

        #expect(model.isSessionHidden(session))
        #expect(model.surfacedSessions.isEmpty)
        #expect(model.islandListSessions.isEmpty)
        #expect(model.hiddenIslandSessions.map(\.id) == [session.id])
        #expect(model.islandClosedActivePets.isEmpty)
        #expect(model.islandClosedRightSlotContent() == nil)
        #expect(!model.isHiddenSessionSectionExpanded)
        #expect(model.islandRenderedSessions.isEmpty)

        model.toggleHiddenSessionSection()
        #expect(model.islandRenderedSessions.map(\.id) == [session.id])

        let reloaded = AppModel(hiddenSessionStore: storage.store)
        reloaded.state = SessionState(sessions: [session])
        #expect(reloaded.isSessionHidden(session))
        #expect(reloaded.hiddenIslandSessions.map(\.id) == [session.id])

        reloaded.unhideSession(session)
        #expect(!reloaded.isSessionHidden(session))
        #expect(reloaded.surfacedSessions.map(\.id) == [session.id])
    }

    @Test
    func hiddenConversationSuppressesCompletionButSurfacesApproval() {
        let storage = makeHiddenSessionStorage()
        defer {
            storage.defaults.removePersistentDomain(forName: storage.suiteName)
        }

        let now = Date()
        var session = listSession(id: "hidden-action", phase: .running, updatedAt: now)
        session.isProcessAlive = true

        let model = AppModel(
            isNotificationSessionAlreadyFrontmost: { _ in false },
            hiddenSessionStore: storage.store
        )
        model.suppressFrontmostNotifications = false
        model.state = SessionState(sessions: [session])
        model.hideSession(session)

        let completion = AgentEvent.sessionCompleted(
            SessionCompleted(
                sessionID: session.id,
                summary: "Hidden work finished.",
                timestamp: now.addingTimeInterval(1)
            )
        )
        model.applyTrackedEvent(completion, updateLastActionMessage: false, ingress: .bridge)

        #expect(model.notchStatus == .closed)
        #expect(model.hiddenIslandSessions.map(\.id) == [session.id])
        #expect(!model.shouldExposeEventFromHiddenSession(
            completion,
            session: model.state.session(id: session.id)
        ))

        model.applyTrackedEvent(
            .activityUpdated(
                SessionActivityUpdated(
                    sessionID: session.id,
                    summary: "Working again.",
                    phase: .running,
                    timestamp: now.addingTimeInterval(2)
                )
            ),
            updateLastActionMessage: false,
            ingress: .bridge
        )
        let approval = AgentEvent.permissionRequested(
            PermissionRequested(
                sessionID: session.id,
                request: PermissionRequest(
                    title: "Run command",
                    summary: "Allow the hidden conversation to continue?",
                    affectedPath: "/tmp/hidden-action"
                ),
                timestamp: now.addingTimeInterval(3)
            )
        )
        model.applyTrackedEvent(approval, updateLastActionMessage: false, ingress: .bridge)

        #expect(model.notchStatus == .opened)
        #expect(model.notchOpenReason == .notification)
        #expect(model.islandSurface == .sessionList(actionableSessionID: session.id))
        #expect(model.surfacedSessions.map(\.id) == [session.id])
        #expect(model.hiddenIslandSessions.isEmpty)
        #expect(model.shouldExposeEventFromHiddenSession(
            approval,
            session: model.state.session(id: session.id)
        ))

        model.applyTrackedEvent(
            .actionableStateResolved(
                ActionableStateResolved(
                    sessionID: session.id,
                    summary: "Approval resolved.",
                    timestamp: now.addingTimeInterval(4)
                )
            ),
            updateLastActionMessage: false,
            ingress: .bridge
        )

        #expect(model.surfacedSessions.isEmpty)
        #expect(model.hiddenIslandSessions.map(\.id) == [session.id])
    }

    @Test
    func hiddenApprovalSurvivesCodexIdleUpdateAndUnhide() {
        let storage = makeHiddenSessionStorage()
        defer {
            storage.defaults.removePersistentDomain(forName: storage.suiteName)
        }

        let now = Date(timeIntervalSince1970: 4_000)
        var session = listSession(id: "hidden-codex-approval", phase: .running, updatedAt: now)
        session.isProcessAlive = true

        let model = AppModel(
            isNotificationSessionAlreadyFrontmost: { _ in false },
            hiddenSessionStore: storage.store
        )
        model.suppressFrontmostNotifications = false
        model.state = SessionState(sessions: [session])
        model.hideSession(session)

        let request = PermissionRequest(
            title: "Apply code patch",
            summary: "Codex wants to update AppModel.swift.",
            detail: "*** Begin Patch\n*** Update File: AppModel.swift",
            affectedPath: "AppModel.swift"
        )
        model.applyTrackedEvent(
            .permissionRequested(
                PermissionRequested(
                    sessionID: session.id,
                    request: request,
                    timestamp: now.addingTimeInterval(1)
                )
            ),
            updateLastActionMessage: false,
            ingress: .bridge
        )

        // Codex Desktop may report idle/turn-completed while its blocking
        // hook is still awaiting Open Island's approval response.
        model.applyTrackedEvent(
            .activityUpdated(
                SessionActivityUpdated(
                    sessionID: session.id,
                    summary: "Turn completed.",
                    phase: .completed,
                    timestamp: now.addingTimeInterval(2)
                )
            ),
            updateLastActionMessage: false,
            ingress: .bridge
        )

        let pending = model.state.session(id: session.id)
        #expect(model.isSessionHidden(pending!))
        #expect(pending?.phase == .waitingForApproval)
        #expect(pending?.permissionRequest == request)
        #expect(model.surfacedSessions.map(\.id) == [session.id])
        #expect(model.hiddenIslandSessions.isEmpty)
        #expect(model.notchStatus == .opened)
        #expect(model.islandSurface == .sessionList(actionableSessionID: session.id))

        model.unhideSession(pending!)

        #expect(!model.isSessionHidden(model.state.session(id: session.id)!))
        #expect(model.activeIslandCardSession?.permissionRequest == request)
        #expect(model.islandSurface == .sessionList(actionableSessionID: session.id))
    }

    @Test
    func hiddenConversationDoesNotSurfaceQuestionNotifications() {
        let storage = makeHiddenSessionStorage()
        defer {
            storage.defaults.removePersistentDomain(forName: storage.suiteName)
        }

        var session = listSession(id: "hidden-question", phase: .running, updatedAt: .now)
        session.isProcessAlive = true

        let model = AppModel(hiddenSessionStore: storage.store)
        model.suppressFrontmostNotifications = false
        model.state = SessionState(sessions: [session])
        model.hideSession(session)

        model.applyTrackedEvent(
            .questionAsked(
                QuestionAsked(
                    sessionID: session.id,
                    prompt: QuestionPrompt(
                        title: "Choose an option",
                        options: ["A", "B"]
                    ),
                    timestamp: .now
                )
            ),
            updateLastActionMessage: false,
            ingress: .bridge
        )

        #expect(model.notchStatus == .closed)
        #expect(model.surfacedSessions.isEmpty)
        #expect(model.hiddenIslandSessions.map(\.id) == [session.id])
    }

    @Test
    func islandSessionListCanSortByLastUpdate() {
        let now = Date()
        let model = AppModel()
        model.islandSessionSort = .lastUpdate

        var olderRunning = listSession(id: "older-running", phase: .running, updatedAt: now.addingTimeInterval(-120))
        var newerCompleted = listSession(id: "newer-completed", phase: .completed, updatedAt: now.addingTimeInterval(-10))
        olderRunning.isProcessAlive = true
        newerCompleted.isProcessAlive = true

        model.state = SessionState(sessions: [olderRunning, newerCompleted])

        #expect(model.islandListSessions.map(\.id) == ["newer-completed", "older-running"])
    }

    @Test
    func islandAppearancePreferencesPersistPerDisplayProfile() {
        let model = AppModel()
        #expect(model.appearancePreferences(for: .notch).closedPresentation == .ghost)
        #expect(model.appearancePreferences(for: .topBar).closedPresentation == .alwaysVisible)

        model.updateAppearancePreferences(for: .notch) {
            $0.closedPresentation = .minimal
            $0.usageDisplay = .hidden
            $0.sessionGroup = .state
            $0.sessionStateIndicator = .bar
            $0.completedStaleThreshold = .twoMinutes
        }
        model.updateAppearancePreferences(for: .topBar) {
            $0.closedPresentation = .activityOnly
            $0.usageDisplay = .compact
            $0.sessionGroup = .project
            $0.sessionStateIndicator = .tint
            $0.completedStaleThreshold = .never
        }

        model.overlayPlacementDiagnostics = placementDiagnostics(mode: .notch)
        #expect(model.islandClosedPresentation == .minimal)
        #expect(model.islandUsageDisplay == .hidden)
        #expect(model.islandSessionGroup == .state)
        #expect(model.islandSessionStateIndicator == .bar)
        #expect(model.completedStaleThreshold == .twoMinutes)

        model.overlayPlacementDiagnostics = placementDiagnostics(mode: .topBar)
        #expect(model.islandClosedPresentation == .activityOnly)
        #expect(model.islandUsageDisplay == .compact)
        #expect(model.islandSessionGroup == .project)
        #expect(model.islandSessionStateIndicator == .tint)
        #expect(model.completedStaleThreshold == .never)

        let reloaded = AppModel()
        reloaded.overlayPlacementDiagnostics = placementDiagnostics(mode: .notch)
        #expect(reloaded.islandClosedPresentation == .minimal)
        #expect(reloaded.islandUsageDisplay == .hidden)
        #expect(reloaded.islandSessionGroup == .state)
        #expect(reloaded.islandSessionStateIndicator == .bar)
        reloaded.overlayPlacementDiagnostics = placementDiagnostics(mode: .topBar)
        #expect(reloaded.islandClosedPresentation == .activityOnly)
        #expect(reloaded.islandUsageDisplay == .compact)
        #expect(reloaded.islandSessionGroup == .project)
        #expect(reloaded.islandSessionStateIndicator == .tint)
        #expect(reloaded.completedStaleThreshold == .never)
    }

    @Test
    func jumpToSessionClosesOverlayBeforeTerminalJumpFinishes() async throws {
        let now = Date(timeIntervalSince1970: 2_000)
        let model = AppModel { _ in
            Thread.sleep(forTimeInterval: 0.25)
            return "Focused the matching Ghostty terminal."
        }
        model.notchStatus = .opened
        model.notchOpenReason = .click
        model.islandSurface = .sessionList()

        let session = AgentSession(
            id: "live-session",
            title: "Codex · agent-island",
            tool: .codex,
            origin: .live,
            attachmentState: .attached,
            phase: .running,
            summary: "Running",
            updatedAt: now,
            jumpTarget: JumpTarget(
                terminalApp: "Ghostty",
                workspaceName: "agent-island",
                paneTitle: "codex ~/p/agent-island",
                workingDirectory: "/tmp/agent-island",
                terminalSessionID: "ghostty-1"
            )
        )

        model.jumpToSession(session)

        #expect(model.notchStatus == .closed)
        #expect(model.notchOpenReason == nil)
        #expect(model.islandSurface == .sessionList())

        let expected = "Focused the matching Ghostty terminal."
        for _ in 0..<20 {
            if model.lastActionMessage == expected { break }
            try await Task.sleep(for: .milliseconds(100))
        }

        #expect(model.lastActionMessage == expected)
    }

    @Test
    func rolloutEventsDoNotPromoteRecoveredSessionsToAttachedDuringColdStart() {
        let now = Date(timeIntervalSince1970: 2_000)
        let model = AppModel()
        model.isResolvingInitialLiveSessions = true
        model.state = SessionState(
            sessions: [
                AgentSession(
                    id: "recovered-session",
                    title: "Codex · agent-island",
                    tool: .codex,
                    origin: .live,
                    attachmentState: .stale,
                    phase: .running,
                    summary: "Recovered from cache",
                    updatedAt: now
                ),
            ]
        )

        model.applyTrackedEvent(
            .activityUpdated(
                SessionActivityUpdated(
                    sessionID: "recovered-session",
                    summary: "Reading recent rollout lines.",
                    phase: .running,
                    timestamp: now.addingTimeInterval(1)
                )
            ),
            updateLastActionMessage: false,
            ingress: .rollout
        )

        #expect(model.liveSessionCount == 0)
        #expect(model.state.session(id: "recovered-session")?.attachmentState == .stale)
        #expect(model.shouldShowSessionBootstrapPlaceholder)
    }

    @Test
    func bridgeEventsStillPromoteSessionsToAttached() {
        let now = Date(timeIntervalSince1970: 2_000)
        let model = AppModel()
        model.state = SessionState(
            sessions: [
                AgentSession(
                    id: "live-session",
                    title: "Codex · agent-island",
                    tool: .codex,
                    origin: .live,
                    attachmentState: .stale,
                    phase: .running,
                    summary: "Recovered from cache",
                    updatedAt: now
                ),
            ]
        )

        model.applyTrackedEvent(
            .activityUpdated(
                SessionActivityUpdated(
                    sessionID: "live-session",
                    summary: "Bridge says the agent is running.",
                    phase: .running,
                    timestamp: now.addingTimeInterval(1)
                )
            ),
            updateLastActionMessage: false,
            ingress: .bridge
        )

        #expect(model.liveSessionCount == 1)
        #expect(model.state.session(id: "live-session")?.attachmentState == .attached)
    }

    @Test
    func rolloutCompletionDoesNotPresentNotificationDuringColdStart() {
        let now = Date(timeIntervalSince1970: 2_000)
        let model = AppModel()
        model.isResolvingInitialLiveSessions = true
        model.notchStatus = .closed
        model.notchOpenReason = nil
        model.state = SessionState(
            sessions: [
                AgentSession(
                    id: "recovered-session",
                    title: "Codex · agent-island",
                    tool: .codex,
                    origin: .live,
                    attachmentState: .stale,
                    phase: .running,
                    summary: "Recovered from cache",
                    updatedAt: now
                ),
            ]
        )

        model.applyTrackedEvent(
            .sessionCompleted(
                SessionCompleted(
                    sessionID: "recovered-session",
                    summary: "Recovered rollout finished.",
                    timestamp: now.addingTimeInterval(1)
                )
            ),
            updateLastActionMessage: false,
            ingress: .rollout
        )

        #expect(model.notchStatus == .closed)
        #expect(model.notchOpenReason == nil)
        #expect(model.islandSurface == .sessionList())
    }

    @Test
    func staleRolloutCompletionDoesNotReplaceNewerRunningState() {
        let older = Date(timeIntervalSince1970: 2_000)
        let newer = older.addingTimeInterval(5)
        let model = AppModel()
        model.suppressFrontmostNotifications = false
        model.state = SessionState(
            sessions: [
                AgentSession(
                    id: "current-session",
                    title: "Codex · open-island",
                    tool: .codex,
                    origin: .live,
                    attachmentState: .attached,
                    phase: .running,
                    summary: "Working on the next turn.",
                    updatedAt: newer
                ),
            ]
        )

        model.applyTrackedEvent(
            .sessionCompleted(
                SessionCompleted(
                    sessionID: "current-session",
                    summary: "An older turn finished.",
                    timestamp: older
                )
            ),
            updateLastActionMessage: false,
            ingress: .rollout
        )

        #expect(model.state.session(id: "current-session")?.phase == .running)
        #expect(model.state.session(id: "current-session")?.summary == "Working on the next turn.")
        #expect(model.notchStatus == .closed)
        #expect(model.notchOpenReason == nil)
    }

    @Test
    func bridgeNotificationIsSuppressedWhenSessionIsAlreadyFrontmost() async throws {
        let now = Date(timeIntervalSince1970: 2_000)
        let model = AppModel(
            isNotificationSessionAlreadyFrontmost: { session in
                session.id == "frontmost-session"
            }
        )
        model.notchStatus = .closed
        model.notchOpenReason = nil
        model.state = SessionState(
            sessions: [
                AgentSession(
                    id: "frontmost-session",
                    title: "Codex · agent-island",
                    tool: .codex,
                    origin: .live,
                    attachmentState: .attached,
                    phase: .running,
                    summary: "Already focused in the front terminal.",
                    updatedAt: now
                ),
            ]
        )

        model.applyTrackedEvent(
            .permissionRequested(
                PermissionRequested(
                    sessionID: "frontmost-session",
                    request: PermissionRequest(
                        title: "Edit",
                        summary: "main.swift",
                        affectedPath: "/tmp/main.swift"
                    ),
                    timestamp: now.addingTimeInterval(1)
                )
            ),
            updateLastActionMessage: false,
            ingress: .bridge
        )

        for _ in 0..<20 {
            await Task.yield()
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(model.notchStatus == .closed)
        #expect(model.notchOpenReason == nil)
        #expect(model.islandSurface == .sessionList())
    }

    @Test
    func bridgeNotificationStillPresentsWhenSessionIsNotFrontmost() async throws {
        let now = Date(timeIntervalSince1970: 2_000)
        let model = AppModel(
            isNotificationSessionAlreadyFrontmost: { _ in false }
        )
        model.notchStatus = .closed
        model.notchOpenReason = nil
        model.state = SessionState(
            sessions: [
                AgentSession(
                    id: "background-session",
                    title: "Codex · agent-island",
                    tool: .codex,
                    origin: .live,
                    attachmentState: .attached,
                    phase: .running,
                    summary: "Needs approval.",
                    updatedAt: now
                ),
            ]
        )

        model.applyTrackedEvent(
            .permissionRequested(
                PermissionRequested(
                    sessionID: "background-session",
                    request: PermissionRequest(
                        title: "Edit",
                        summary: "main.swift",
                        affectedPath: "/tmp/main.swift"
                    ),
                    timestamp: now.addingTimeInterval(1)
                )
            ),
            updateLastActionMessage: false,
            ingress: .bridge
        )

        for _ in 0..<20 {
            if model.notchStatus == .opened {
                break
            }
            await Task.yield()
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(model.notchStatus == .opened)
        #expect(model.notchOpenReason == .notification)
        #expect(model.islandSurface == .sessionList(actionableSessionID: "background-session"))
    }

    @Test
    func hoverOpenedSessionListAutoCollapsesOnPointerExit() {
        let model = AppModel()
        model.notchStatus = .opened
        model.notchOpenReason = .hover
        model.islandSurface = .sessionList()

        #expect(model.shouldAutoCollapseOnMouseLeave)

        model.handlePointerExitedIslandSurface()

        #expect(model.notchStatus == .closed)
        #expect(model.notchOpenReason == nil)
        #expect(model.islandSurface == .sessionList())
    }

    @Test
    func closeTransitionSetsStateImmediatelyAndClearsPending() {
        let model = AppModel()
        model.notchStatus = .opened
        model.notchOpenReason = .hover
        model.islandSurface = .sessionList()

        model.notchClose()

        // State changes immediately; pending clears synchronously in tests
        // (no panel → fadeOutAndClose calls completion inline).
        #expect(model.notchStatus == .closed)
        #expect(model.notchOpenReason == nil)
        #expect(!model.isOverlayCloseTransitionPending)
    }

    @Test
    func clickedSessionListDoesNotAutoCollapseOnPointerExit() {
        let model = AppModel()
        model.notchStatus = .opened
        model.notchOpenReason = .click
        model.islandSurface = .sessionList()

        #expect(!model.shouldAutoCollapseOnMouseLeave)

        model.notePointerInsideIslandSurface()
        model.handlePointerExitedIslandSurface()

        #expect(model.notchStatus == .opened)
        #expect(model.notchOpenReason == .click)
        #expect(model.islandSurface == .sessionList())
    }

    @Test
    func completionNotificationRequiresSurfaceEntryBeforePointerExitCollapse() {
        let model = AppModel()
        // Add a completed session so autoDismissesWhenPresentedAsNotification can check phase
        model.applyTrackedEvent(
            .sessionStarted(SessionStarted(
                sessionID: "session-1",
                title: "Test",
                tool: .codex,
                summary: "Done",
                timestamp: .now
            )),
            updateLastActionMessage: false
        )
        model.applyTrackedEvent(
            .sessionCompleted(SessionCompleted(
                sessionID: "session-1",
                summary: "Done",
                timestamp: .now
            )),
            updateLastActionMessage: false
        )
        model.notchStatus = .opened
        model.notchOpenReason = .notification
        model.islandSurface = .sessionList(actionableSessionID: "session-1")

        #expect(model.shouldAutoCollapseOnMouseLeave)

        model.handlePointerExitedIslandSurface()

        #expect(model.notchStatus == .opened)
        #expect(model.notchOpenReason == .notification)

        model.notePointerInsideIslandSurface()
        model.handlePointerExitedIslandSurface()

        #expect(model.notchStatus == .closed)
        #expect(model.notchOpenReason == nil)
    }

    @Test
    func completionNotificationDefersTimedCollapseWhilePointerIsInside() {
        let model = AppModel()
        model.applyTrackedEvent(
            .sessionStarted(SessionStarted(
                sessionID: "session-1",
                title: "Test",
                tool: .codex,
                summary: "Done",
                timestamp: .now
            )),
            updateLastActionMessage: false
        )
        model.applyTrackedEvent(
            .sessionCompleted(SessionCompleted(
                sessionID: "session-1",
                summary: "Done",
                timestamp: .now
            )),
            updateLastActionMessage: false
        )
        model.notchStatus = .opened
        model.notchOpenReason = .notification
        model.islandSurface = .sessionList(actionableSessionID: "session-1")

        #expect(model.shouldAutoCollapseOnMouseLeave)
        #expect(!model.shouldDeferTimedNotificationAutoCollapse)

        model.notePointerInsideIslandSurface()

        #expect(model.shouldDeferTimedNotificationAutoCollapse)

        model.handlePointerExitedIslandSurface()

        #expect(model.notchStatus == .closed)
        #expect(model.notchOpenReason == nil)
    }

    @Test
    func completionNotificationHoverCancelsPendingTimedCollapse() {
        let model = AppModel()
        model.state = SessionState(
            sessions: [
                AgentSession(
                    id: "session-1",
                    title: "Test",
                    tool: .codex,
                    attachmentState: .attached,
                    phase: .completed,
                    summary: "Done",
                    updatedAt: .now
                )
            ]
        )

        model.notchOpen(reason: .notification, surface: .sessionList(actionableSessionID: "session-1"))

        #expect(model.hasPendingNotificationAutoCollapse)

        model.notePointerInsideIslandSurface()

        #expect(!model.hasPendingNotificationAutoCollapse)
        #expect(model.shouldDeferTimedNotificationAutoCollapse)
        #expect(model.notchStatus == .opened)
        #expect(model.notchOpenReason == .notification)
    }

    @Test
    func mergeDiscoveredClaudeSessionsPreservesRegistryJumpTargetAndAddsTranscriptMetadata() {
        let now = Date(timeIntervalSince1970: 2_000)
        let model = AppModel()
        model.state = SessionState(
            sessions: [
                AgentSession(
                    id: "claude-session",
                    title: "Claude · agent-island",
                    tool: .claudeCode,
                    origin: .live,
                    attachmentState: .stale,
                    phase: .completed,
                    summary: "Recovered from registry",
                    updatedAt: now.addingTimeInterval(-60),
                    jumpTarget: JumpTarget(
                        terminalApp: "Ghostty",
                        workspaceName: "agent-island",
                        paneTitle: "claude ~/agent-island",
                        workingDirectory: "/tmp/agent-island",
                        terminalSessionID: "ghostty-claude",
                        terminalTTY: "/dev/ttys002"
                    )
                ),
            ]
        )

        let merged = model.discovery.mergeDiscoveredSessions([
            AgentSession(
                id: "claude-session",
                title: "Claude · agent-island",
                tool: .claudeCode,
                origin: .live,
                attachmentState: .stale,
                phase: .running,
                summary: "Recovered from transcript",
                updatedAt: now,
                jumpTarget: JumpTarget(
                    terminalApp: "Unknown",
                    workspaceName: "agent-island",
                    paneTitle: "Claude deadbeef",
                    workingDirectory: "/tmp/agent-island"
                ),
                claudeMetadata: ClaudeSessionMetadata(
                    transcriptPath: "/tmp/claude.jsonl",
                    lastUserPrompt: "Check the Claude session registry.",
                    currentTool: "Task"
                )
            ),
        ])

        #expect(merged.count == 1)
        #expect(merged.first?.jumpTarget?.terminalApp == "Ghostty")
        #expect(merged.first?.jumpTarget?.terminalSessionID == "ghostty-claude")
        #expect(merged.first?.claudeMetadata?.transcriptPath == "/tmp/claude.jsonl")
        #expect(merged.first?.claudeMetadata?.lastUserPrompt == "Check the Claude session registry.")
        #expect(merged.first?.phase == .running)
    }

    @Test
    func mergeDiscoveredSessionPreservesFirstClassLiveTitle() {
        let now = Date(timeIntervalSince1970: 2_000)
        let model = AppModel()
        model.state = SessionState(sessions: [
            AgentSession(
                id: "codex-session",
                title: "Investigate approval notifications",
                tool: .codex,
                attachmentState: .attached,
                phase: .running,
                summary: "Working",
                updatedAt: now,
                jumpTarget: JumpTarget(
                    terminalApp: "Codex.app",
                    workspaceName: "open-island",
                    paneTitle: "Investigate approval notifications"
                )
            ),
        ])

        let merged = model.discovery.mergeDiscoveredSessions([
            AgentSession(
                id: "codex-session",
                title: "Codex · open-island",
                tool: .codex,
                attachmentState: .stale,
                phase: .running,
                summary: "Recovered",
                updatedAt: now.addingTimeInterval(1),
                jumpTarget: JumpTarget(
                    terminalApp: "Codex.app",
                    workspaceName: "open-island",
                    paneTitle: "Codex · open-island"
                )
            ),
        ])

        #expect(merged.first?.title == "Investigate approval notifications")
        #expect(merged.first?.spotlightHeadlineText == "open-island · Investigate approval notifications")
    }

    @Test
    func codexSessionIndexNamesUpdateExistingCodexSessionsOnly() {
        let now = Date(timeIntervalSince1970: 2_000)
        let state = SessionState(sessions: [
            AgentSession(
                id: "codex-session",
                title: "Old Codex name",
                tool: .codex,
                phase: .running,
                summary: "Working",
                updatedAt: now,
                jumpTarget: JumpTarget(
                    terminalApp: "Codex.app",
                    workspaceName: "open-island",
                    paneTitle: "Old Codex name"
                )
            ),
            AgentSession(
                id: "claude-session",
                title: "Claude name",
                tool: .claudeCode,
                phase: .running,
                summary: "Working",
                updatedAt: now
            ),
        ])

        let result = SessionDiscoveryCoordinator.applyingCodexSessionNames(
            [
                "codex-session": "Renamed Codex thread",
                "claude-session": "Incorrect cross-provider name",
            ],
            to: state
        )

        #expect(result.updatedCount == 1)
        #expect(result.state.session(id: "codex-session")?.title == "Renamed Codex thread")
        #expect(result.state.session(id: "codex-session")?.jumpTarget?.paneTitle == "Renamed Codex thread")
        #expect(result.state.session(id: "claude-session")?.title == "Claude name")
    }

    @Test
    func mergeDiscoveredSessionDoesNotResolvePendingApproval() {
        let now = Date(timeIntervalSince1970: 2_000)
        let request = PermissionRequest(
            title: "Run command",
            summary: "Allow the build command?",
            affectedPath: "/tmp/open-island"
        )
        let model = AppModel()
        model.state = SessionState(sessions: [
            AgentSession(
                id: "codex-session",
                title: "Approval reliability",
                tool: .codex,
                attachmentState: .attached,
                phase: .waitingForApproval,
                summary: request.summary,
                updatedAt: now,
                permissionRequest: request
            ),
        ])

        let merged = model.discovery.mergeDiscoveredSessions([
            AgentSession(
                id: "codex-session",
                title: "Codex · open-island",
                tool: .codex,
                attachmentState: .stale,
                phase: .completed,
                summary: "Recovered completion",
                updatedAt: now.addingTimeInterval(1)
            ),
        ])

        #expect(merged.first?.phase == .waitingForApproval)
        #expect(merged.first?.permissionRequest == request)
        #expect(merged.first?.summary == request.summary)
    }

    @Test
    func mergeDiscoveredCodexSessionReplacesRootWorkspaceWithRolloutWorkspace() {
        let now = Date(timeIntervalSince1970: 2_000)
        let model = AppModel()
        model.state = SessionState(
            sessions: [
                AgentSession(
                    id: "codex-thread",
                    title: "Codex · open-island",
                    tool: .codex,
                    origin: .live,
                    attachmentState: .attached,
                    phase: .running,
                    summary: "Working",
                    updatedAt: now,
                    jumpTarget: JumpTarget(
                        terminalApp: "Codex.app",
                        workspaceName: "/",
                        paneTitle: "Codex",
                        workingDirectory: "/",
                        codexThreadID: "codex-thread"
                    )
                ),
            ]
        )

        let merged = model.discovery.mergeDiscoveredSessions([
            AgentSession(
                id: "codex-thread",
                title: "Codex · open-island",
                tool: .codex,
                origin: .live,
                attachmentState: .stale,
                phase: .running,
                summary: "Working",
                updatedAt: now,
                jumpTarget: JumpTarget(
                    terminalApp: "Codex.app",
                    workspaceName: "open-island",
                    paneTitle: "Codex · open-island",
                    workingDirectory: "/tmp/open-island",
                    codexThreadID: "codex-thread"
                )
            ),
        ])

        #expect(merged.first?.jumpTarget?.workspaceName == "open-island")
        #expect(merged.first?.jumpTarget?.workingDirectory == "/tmp/open-island")
    }

    @Test
    func mergedWithSyntheticClaudeSessionsAddsGhosttyClaudeProcessWhenNoTrackedSessionExists() {
        let now = Date(timeIntervalSince1970: 2_000)
        let model = AppModel()

        let merged = model.monitoring.mergedWithSyntheticClaudeSessions(
            existingSessions: [],
            activeProcesses: [
                .init(
                    tool: .claudeCode,
                    sessionID: nil,
                    workingDirectory: "/tmp/agent-island",
                    terminalTTY: "/dev/ttys002",
                    terminalApp: "Ghostty"
                ),
            ],
            now: now
        )

        #expect(merged.count == 1)
        #expect(merged.first?.id.hasPrefix("claude-process:") == true)
        #expect(merged.first?.attachmentState == .attached)
        #expect(merged.first?.jumpTarget?.terminalApp == "Ghostty")
        #expect(merged.first?.jumpTarget?.terminalTTY == "/dev/ttys002")
    }

    @Test
    func sanitizeCrossToolGhosttyJumpTargetsClearsClaudeMisbinding() {
        let now = Date(timeIntervalSince1970: 2_000)
        let model = AppModel()
        let misboundClaudeSession = AgentSession(
            id: "e45d5e87-66d0-4f67-8399-6ebc02f3d453",
            title: "Claude · agent-island",
            tool: .claudeCode,
            origin: .live,
            attachmentState: .stale,
            phase: .running,
            summary: "Running",
            updatedAt: now,
            jumpTarget: JumpTarget(
                terminalApp: "Ghostty",
                workspaceName: "agent-island",
                paneTitle: "codex ~/p/agent-island",
                workingDirectory: "/tmp/agent-island",
                terminalSessionID: "ghostty-codex"
            )
        )

        let sanitized = model.monitoring.sanitizeCrossToolGhosttyJumpTargets(in: [misboundClaudeSession])

        #expect(sanitized.first?.jumpTarget?.terminalSessionID == nil)
        #expect(sanitized.first?.jumpTarget?.paneTitle == "Claude e45d5e87")
    }

    @Test
    func mergedWithSyntheticClaudeSessionsSkipsSyntheticWhenAttachedClaudeAlreadyRepresentsGroup() {
        let now = Date(timeIntervalSince1970: 2_000)
        let model = AppModel()
        let existing = AgentSession(
            id: "e45d5e87-66d0-4f67-8399-6ebc02f3d453",
            title: "Claude · agent-island",
            tool: .claudeCode,
            origin: .live,
            attachmentState: .attached,
            phase: .running,
            summary: "Running",
            updatedAt: now,
            jumpTarget: JumpTarget(
                terminalApp: "Ghostty",
                workspaceName: "agent-island",
                paneTitle: "agent-island · hi · e45d5e87",
                workingDirectory: "/tmp/agent-island",
                terminalSessionID: "ghostty-claude"
            )
        )

        let merged = model.monitoring.mergedWithSyntheticClaudeSessions(
            existingSessions: [existing],
            activeProcesses: [
                .init(
                    tool: .claudeCode,
                    sessionID: nil,
                    workingDirectory: "/tmp/agent-island",
                    terminalTTY: "/dev/ttys002",
                    terminalApp: "Ghostty"
                ),
            ],
            now: now
        )

        #expect(merged.map(\.id) == [existing.id])
    }

    @Test
    func mergedWithSyntheticClaudeSessionsSkipsSyntheticWhenStaleClaudeSessionMatchesActiveProcess() {
        let now = Date(timeIntervalSince1970: 2_000)
        let model = AppModel()
        let existing = AgentSession(
            id: "e45d5e87-66d0-4f67-8399-6ebc02f3d453",
            title: "Claude · agent-island-readme",
            tool: .claudeCode,
            origin: .live,
            attachmentState: .stale,
            phase: .completed,
            summary: "Recovered transcript",
            updatedAt: now.addingTimeInterval(-120),
            jumpTarget: JumpTarget(
                terminalApp: "Ghostty",
                workspaceName: "agent-island-readme",
                paneTitle: "Claude e45d5e87",
                workingDirectory: "/tmp/agent-island-readme"
            ),
            claudeMetadata: ClaudeSessionMetadata(
                transcriptPath: "/tmp/claude-session.jsonl",
                lastUserPrompt: "整理 readme。"
            )
        )

        let merged = model.monitoring.mergedWithSyntheticClaudeSessions(
            existingSessions: [existing],
            activeProcesses: [
                .init(
                    tool: .claudeCode,
                    sessionID: existing.id,
                    workingDirectory: "/tmp/agent-island-readme",
                    terminalTTY: "/dev/ttys008",
                    terminalApp: "Ghostty"
                ),
            ],
            now: now
        )

        #expect(merged.map(\.id) == [existing.id])
    }

    @Test
    func mergedWithSyntheticCursorSessionsAddsCursorAgentWhenNoTrackedSessionExists() {
        let now = Date(timeIntervalSince1970: 2_000)
        let model = AppModel()

        let merged = model.monitoring.mergedWithSyntheticCursorSessions(
            existingSessions: [],
            activeProcesses: [
                .init(
                    tool: .cursor,
                    sessionID: "6f7b9f8a-2bd0-48b4-a497-9801dd191d03",
                    workingDirectory: "/tmp/simple-agent-lab",
                    terminalTTY: "/dev/ttys003",
                    terminalApp: "Ghostty"
                ),
            ],
            now: now
        )

        #expect(merged.count == 1)
        #expect(merged.first?.id == "6f7b9f8a-2bd0-48b4-a497-9801dd191d03")
        #expect(merged.first?.tool == .cursor)
        #expect(merged.first?.attachmentState == .attached)
        #expect(merged.first?.jumpTarget?.terminalApp == "Ghostty")
        #expect(merged.first?.jumpTarget?.terminalTTY == "/dev/ttys003")
        #expect(merged.first?.cursorMetadata?.conversationId == "6f7b9f8a-2bd0-48b4-a497-9801dd191d03")
    }

    @Test
    func mergedWithSyntheticCursorSessionsSkipsSyntheticWhenHookSessionMatchesConversation() {
        let now = Date(timeIntervalSince1970: 2_000)
        let model = AppModel()
        let existing = AgentSession(
            id: "6f7b9f8a-2bd0-48b4-a497-9801dd191d03",
            title: "Cursor · simple-agent-lab",
            tool: .cursor,
            origin: .live,
            attachmentState: .attached,
            phase: .running,
            summary: "Running",
            updatedAt: now,
            jumpTarget: JumpTarget(
                terminalApp: "Cursor",
                workspaceName: "simple-agent-lab",
                paneTitle: "Cursor 6f7b9f8a",
                workingDirectory: "/tmp/simple-agent-lab"
            ),
            cursorMetadata: CursorSessionMetadata(
                conversationId: "6f7b9f8a-2bd0-48b4-a497-9801dd191d03"
            )
        )

        let merged = model.monitoring.mergedWithSyntheticCursorSessions(
            existingSessions: [existing],
            activeProcesses: [
                .init(
                    tool: .cursor,
                    sessionID: "6f7b9f8a-2bd0-48b4-a497-9801dd191d03",
                    workingDirectory: "/tmp/simple-agent-lab",
                    terminalTTY: "/dev/ttys003",
                    terminalApp: "Ghostty"
                ),
            ],
            now: now
        )

        #expect(merged.map(\.id) == [existing.id])
    }

    @Test
    func mergedWithSyntheticCursorSessionsDeduplicatesRepeatedConversationProcesses() {
        let now = Date(timeIntervalSince1970: 2_000)
        let model = AppModel()

        let merged = model.monitoring.mergedWithSyntheticCursorSessions(
            existingSessions: [],
            activeProcesses: [
                .init(
                    tool: .cursor,
                    sessionID: "6f7b9f8a-2bd0-48b4-a497-9801dd191d03",
                    workingDirectory: "/tmp/simple-agent-lab",
                    terminalTTY: "/dev/ttys003",
                    terminalApp: "Ghostty"
                ),
                .init(
                    tool: .cursor,
                    sessionID: "6f7b9f8a-2bd0-48b4-a497-9801dd191d03",
                    workingDirectory: "/tmp/simple-agent-lab",
                    terminalTTY: "/dev/ttys004",
                    terminalApp: "Ghostty"
                ),
            ],
            now: now
        )

        #expect(merged.map(\.id) == ["6f7b9f8a-2bd0-48b4-a497-9801dd191d03"])
    }


    /// Regression test: `measuredNotificationContentHeight` MUST be cleared when the
    /// surface changes to a different session, to avoid sizing the new card with stale
    /// measurements from the previous one.
    @Test
    @MainActor
    func approvalCardMeasuredHeightClearedWhenSurfaceSessionChanges() {
        let model = AppModel()

        var sessionA = AgentSession(
            id: "approval-session-A",
            title: "Claude · proj-A",
            tool: .claudeCode,
            attachmentState: .attached,
            phase: .waitingForApproval,
            summary: "Approve edit A",
            updatedAt: .now,
            permissionRequest: PermissionRequest(
                title: "Edit",
                summary: "file_a.swift",
                affectedPath: "/tmp/file_a.swift"
            )
        )
        sessionA.isProcessAlive = true

        var sessionB = AgentSession(
            id: "approval-session-B",
            title: "Claude · proj-B",
            tool: .claudeCode,
            attachmentState: .attached,
            phase: .waitingForApproval,
            summary: "Approve edit B",
            updatedAt: .now,
            permissionRequest: PermissionRequest(
                title: "Edit",
                summary: "file_b.swift",
                affectedPath: "/tmp/file_b.swift"
            )
        )
        sessionB.isProcessAlive = true

        model.state = SessionState(sessions: [sessionA, sessionB])

        let surfaceA = IslandSurface.sessionList(actionableSessionID: "approval-session-A")
        model.notchStatus = .opened
        model.notchOpenReason = .notification
        model.islandSurface = surfaceA
        model.measuredNotificationContentHeight = 320

        model.notchClose()

        let surfaceB = IslandSurface.sessionList(actionableSessionID: "approval-session-B")
        model.notchOpen(reason: .notification, surface: surfaceB)

        #expect(
            model.measuredNotificationContentHeight == 0,
            "Switching to a different session's card must clear the stale measurement from the previous session to prevent wrong initial panel sizing."
        )
    }

    @Test
    @MainActor
    func notificationMeasuredHeightClearedWhenSameSessionCardContentChanges() {
        let model = AppModel()

        var session = AgentSession(
            id: "same-session",
            title: "Codex · proj",
            tool: .codex,
            attachmentState: .attached,
            phase: .waitingForApproval,
            summary: "Approve edit",
            updatedAt: .now,
            permissionRequest: PermissionRequest(
                title: "Edit",
                summary: "A longer approval card",
                affectedPath: "/tmp/long-file-name.swift"
            )
        )
        session.isProcessAlive = true
        session.phase = .completed
        session.permissionRequest = nil
        session.summary = "Done"
        model.state = SessionState(sessions: [session])

        let surface = IslandSurface.sessionList(actionableSessionID: "same-session")
        model.notchStatus = .opened
        model.notchOpenReason = .notification
        model.islandSurface = surface
        model.measuredNotificationContentHeight = 360

        model.overlay.presentNotificationSurface(surface)

        #expect(model.notchStatus == .opened)
        #expect(model.notchOpenReason == .notification)
        #expect(model.islandSurface == surface)
        #expect(model.activeIslandCardSession?.phase == .completed)
        #expect(
            model.measuredNotificationContentHeight == 0,
            "Replacing a notification with different content for the same session must discard the previous card's measured height."
        )
    }

    @Test
    @MainActor
    func hoveredNotificationCardIsNotReplacedByAnotherNotification() {
        let model = AppModel()

        var currentSession = AgentSession(
            id: "current-session",
            title: "Claude · current",
            tool: .claudeCode,
            attachmentState: .attached,
            phase: .waitingForApproval,
            summary: "Approve current edit",
            updatedAt: .now,
            permissionRequest: PermissionRequest(
                title: "Edit",
                summary: "current.swift",
                affectedPath: "/tmp/current.swift"
            )
        )
        currentSession.isProcessAlive = true

        var incomingSession = AgentSession(
            id: "incoming-session",
            title: "Codex · incoming",
            tool: .codex,
            attachmentState: .attached,
            phase: .running,
            summary: "Working",
            updatedAt: .now
        )
        incomingSession.isProcessAlive = true

        let currentSurface = IslandSurface.sessionList(actionableSessionID: "current-session")
        model.state = SessionState(sessions: [currentSession, incomingSession])
        model.notchStatus = .opened
        model.notchOpenReason = .notification
        model.islandSurface = currentSurface
        model.measuredNotificationContentHeight = 280

        model.notePointerInsideIslandSurface()

        model.applyTrackedEvent(
            .permissionRequested(PermissionRequested(
                sessionID: "incoming-session",
                request: PermissionRequest(
                    title: "Edit",
                    summary: "incoming.swift",
                    affectedPath: "/tmp/incoming.swift"
                ),
                timestamp: .now
            )),
            updateLastActionMessage: false,
            ingress: .bridge
        )

        #expect(model.state.session(id: "incoming-session")?.phase == .waitingForApproval)
        #expect(model.notchStatus == .opened)
        #expect(model.notchOpenReason == .notification)
        #expect(model.islandSurface == currentSurface)
        #expect(model.activeIslandCardSession?.id == "current-session")
        #expect(model.measuredNotificationContentHeight == 280)
    }

    @Test
    func recoveredSessionMatchesLiveGhosttyProcessByCWDWhenMultipleCandidatesExist() {
        let now = Date(timeIntervalSince1970: 2_000)
        let model = AppModel()
        let recoveredSessions = [
            AgentSession(
                id: "e45d5e87-66d0-4f67-8399-6ebc02f3d453",
                title: "Claude · agent-island",
                tool: .claudeCode,
                origin: .live,
                attachmentState: .stale,
                phase: .completed,
                summary: "Recovered transcript",
                updatedAt: now.addingTimeInterval(-10_800),
                jumpTarget: JumpTarget(
                    terminalApp: "Unknown",
                    workspaceName: "agent-island",
                    paneTitle: "Claude e45d5e87",
                    workingDirectory: "/tmp/agent-island"
                )
            ),
            AgentSession(
                id: "c9a48d05-c1f9-4e39-ab66-19edef0c2bc9",
                title: "Claude · agent-island",
                tool: .claudeCode,
                origin: .live,
                attachmentState: .stale,
                phase: .completed,
                summary: "Recovered transcript",
                updatedAt: now.addingTimeInterval(-64_800),
                jumpTarget: JumpTarget(
                    terminalApp: "Unknown",
                    workspaceName: "agent-island",
                    paneTitle: "Claude c9a48d05",
                    workingDirectory: "/tmp/agent-island"
                )
            ),
        ]
        let activeProcesses: [ActiveProcessSnapshot] = [
            .init(
                tool: .claudeCode,
                sessionID: nil,
                workingDirectory: "/tmp/agent-island",
                terminalTTY: "/dev/ttys002",
                terminalApp: "Ghostty"
            ),
        ]

        let merged = model.monitoring.mergedWithSyntheticClaudeSessions(
            existingSessions: recoveredSessions,
            activeProcesses: activeProcesses,
            now: now
        )

        // With relaxed CWD matching, recovered session matches the process
        // so no synthetic session is created.
        #expect(merged.count == 2)
        #expect(merged.allSatisfy { !$0.id.hasPrefix("claude-process:") })

        let probe = TerminalSessionAttachmentProbe()
        let resolutions = probe.sessionResolutions(
            for: merged,
            ghosttyAvailability: .unavailable(appIsRunning: true),
            terminalAvailability: .available([] as [TerminalSessionAttachmentProbe.TerminalTabSnapshot], appIsRunning: false),
            activeProcesses: activeProcesses,
            now: now
        )

        model.state = SessionState(sessions: merged)
        _ = model.state.reconcileAttachmentStates(resolutions.mapValues(\.attachmentState))
        _ = model.state.reconcileJumpTargets(
            resolutions.reduce(into: [String: JumpTarget]()) { partialResult, entry in
                if let correctedJumpTarget = entry.value.correctedJumpTarget {
                    partialResult[entry.key] = correctedJumpTarget
                }
            }
        )

        let claudeSessions = model.state.sessions.filter { $0.tool == .claudeCode }
        #expect(claudeSessions.count == 2)
    }

    private func listSession(id: String, phase: SessionPhase, updatedAt: Date) -> AgentSession {
        AgentSession(
            id: id,
            title: "Codex · \(id)",
            tool: .codex,
            origin: .live,
            attachmentState: .attached,
            phase: phase,
            summary: phase.displayName,
            updatedAt: updatedAt,
            jumpTarget: JumpTarget(
                terminalApp: "Ghostty",
                workspaceName: id,
                paneTitle: "codex ~/\(id)",
                workingDirectory: "/tmp/\(id)",
                terminalSessionID: "ghostty-\(id)"
            )
        )
    }

    private func makeHiddenSessionStorage() -> (
        store: HiddenSessionStore,
        defaults: UserDefaults,
        suiteName: String
    ) {
        let suiteName = "AppModelSessionListTests.Hidden.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return (
            HiddenSessionStore(defaults: defaults),
            defaults,
            suiteName
        )
    }

    private func placementDiagnostics(mode: OverlayPlacementMode) -> OverlayPlacementDiagnostics {
        OverlayPlacementDiagnostics(
            targetScreenID: mode == .notch ? "display-notch" : "display-topbar",
            targetScreenName: mode == .notch ? "Built-in Display" : "External Display",
            selectionSummary: "test",
            mode: mode,
            screenFrame: NSRect(x: 0, y: 0, width: 1512, height: 982),
            visibleFrame: NSRect(x: 0, y: 0, width: 1512, height: 944),
            safeAreaInsets: NSEdgeInsets(top: mode == .notch ? 37 : 0, left: 0, bottom: 0, right: 0),
            overlayFrame: NSRect(x: 400, y: 820, width: 700, height: 160)
        )
    }
}
