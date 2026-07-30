import AppKit
import Foundation
import AgentIslandCore

/// Manages the lifecycle of the Codex app-server connection.
///
/// Automatically starts the app-server subprocess when Codex.app is
/// detected, and tears it down when the app quits.  Converts incoming
/// app-server notifications into `AgentEvent`s that flow through the
/// standard `SessionState` reducer.
@Observable
@MainActor
final class CodexAppServerCoordinator {
    typealias ThreadStatusReader =
        @MainActor (String) async throws -> CodexThreadStatus?

    @ObservationIgnored
    private var client: CodexAppServerClient?

    @ObservationIgnored
    private var connectTask: Task<Void, Never>?

    @ObservationIgnored
    private var nativeApprovalMonitorTasks: [String: Task<Void, Never>] = [:]

    @ObservationIgnored
    private let injectedThreadStatusReader: ThreadStatusReader?

    @ObservationIgnored
    private let nativeApprovalPollInterval: Duration

    @ObservationIgnored
    private let nativeApprovalInitialGracePeriod: Duration

    /// Callback to emit AgentEvents into AppModel.
    @ObservationIgnored
    var onEvent: ((AgentEvent) -> Void)?

    /// Callback to log status messages.
    @ObservationIgnored
    var onStatusMessage: ((String) -> Void)?

    /// Returns `true` if a session with the given id is already tracked.
    /// Used to avoid re-emitting `sessionStarted` (which rebuilds the
    /// session and wipes richer state from hooks/rediscovery).
    @ObservationIgnored
    var isSessionTracked: ((String) -> Bool)?

    private(set) var isConnected = false

    init(
        threadStatusReader: ThreadStatusReader? = nil,
        nativeApprovalPollInterval: Duration = .milliseconds(200),
        nativeApprovalInitialGracePeriod: Duration = .seconds(2)
    ) {
        injectedThreadStatusReader = threadStatusReader
        self.nativeApprovalPollInterval = nativeApprovalPollInterval
        self.nativeApprovalInitialGracePeriod =
            nativeApprovalInitialGracePeriod
    }

    // MARK: - Public API

    /// Ensure a connection exists.  Called from the monitoring loop when
    /// Codex.app is detected as running.  Idempotent — does nothing if
    /// already connected or a connection attempt is in progress.
    func ensureConnected() {
        guard !isConnected, connectTask == nil else { return }

        // Resolve the Codex.app bundle location dynamically — users may
        // have installed Codex outside `/Applications` (e.g. ~/Applications).
        guard let bundleURL = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: "com.openai.codex"
        ) else {
            return
        }
        let codexPath = bundleURL
            .appendingPathComponent("Contents/Resources/codex")
            .path
        guard FileManager.default.isExecutableFile(atPath: codexPath) else {
            return
        }

        connectTask = Task { [weak self] in
            guard let self else { return }
            do {
                let newClient = CodexAppServerClient(codexPath: codexPath)
                newClient.onNotification = { [weak self] notification in
                    Task { @MainActor [weak self] in
                        self?.handleNotification(notification)
                    }
                }
                try await newClient.start()

                self.client = newClient
                self.isConnected = true
                self.connectTask = nil

                self.onStatusMessage?("Connected to Codex app-server.")

                // Fetch currently loaded threads and create sessions.
                await self.syncLoadedThreads()
            } catch {
                self.connectTask = nil
                self.onStatusMessage?("Failed to connect to Codex app-server: \(error.localizedDescription)")
            }
        }
    }

    /// Disconnect and clean up.  Called when Codex.app is no longer running.
    func disconnect() {
        connectTask?.cancel()
        connectTask = nil
        client?.stop()
        client = nil
        isConnected = false
        nativeApprovalMonitorTasks.values.forEach { $0.cancel() }
        nativeApprovalMonitorTasks.removeAll()
    }

    /// Reconciles a mirrored native approval until Codex reports that the
    /// exact thread has left `waitingOnApproval`. Desktop does not reliably
    /// emit a status-changed notification for that intermediate transition,
    /// so polling prevents a stale card from remaining until turn completion.
    func monitorNativeApprovalResolution(threadID: String) {
        nativeApprovalMonitorTasks[threadID]?.cancel()
        nativeApprovalMonitorTasks[threadID] = Task { @MainActor [weak self] in
            guard let self else { return }
            let clock = ContinuousClock()
            let graceDeadline = clock.now.advanced(
                by: nativeApprovalInitialGracePeriod
            )
            var observedWaiting = false

            while !Task.isCancelled {
                do {
                    if let status = try await readThreadStatus(threadID: threadID) {
                        if status.isWaitingOnApproval {
                            observedWaiting = true
                        } else if observedWaiting || clock.now >= graceDeadline {
                            nativeApprovalMonitorTasks.removeValue(
                                forKey: threadID
                            )
                            onEvent?(
                                .activityUpdated(
                                    SessionActivityUpdated(
                                        sessionID: threadID,
                                        summary: "Codex resumed work.",
                                        phase: .running,
                                        timestamp: .now
                                    )
                                )
                            )
                            return
                        }
                    }
                } catch {
                    // The normal app-server reconnect loop owns connection
                    // diagnostics. Keep this short-lived reconciliation quiet.
                }

                try? await Task.sleep(for: nativeApprovalPollInterval)
            }
        }
    }

    func cancelNativeApprovalMonitor(threadID: String) {
        nativeApprovalMonitorTasks.removeValue(forKey: threadID)?.cancel()
    }

    // MARK: - Thread sync

    private func syncLoadedThreads() async {
        guard let client else { return }
        do {
            let threads = try await client.listLoadedThreads()
            var created = 0
            for thread in threads where !thread.ephemeral {
                // Skip threads already tracked — re-emitting sessionStarted
                // rebuilds the AgentSession and would wipe richer state
                // already accumulated from hooks or rediscovery.
                if isSessionTracked?(thread.id) == true {
                    emitSessionTitleUpdated(threadId: thread.id, name: thread.name)
                    continue
                }
                emitSessionStarted(from: thread)
                created += 1
            }
            if created > 0 {
                onStatusMessage?("Synced \(created) new Codex thread(s) from app-server.")
            }
        } catch {
            onStatusMessage?("Failed to list loaded Codex threads: \(error.localizedDescription)")
        }
    }

    private func readThreadStatus(
        threadID: String
    ) async throws -> CodexThreadStatus? {
        if let injectedThreadStatusReader {
            return try await injectedThreadStatusReader(threadID)
        }
        return try await client?.listLoadedThreads()
            .first(where: { $0.id == threadID })?
            .status
    }

    // MARK: - Notification handling

    /// Internal so tests can pin how observer-only app-server signals map into
    /// actionable Open Island state.
    func handleNotification(_ notification: CodexAppServerNotification) {
        switch notification {
        case .threadStarted(let thread):
            guard !thread.ephemeral else { return }
            guard isSessionTracked?(thread.id) != true else {
                emitSessionTitleUpdated(threadId: thread.id, name: thread.name)
                return
            }
            emitSessionStarted(from: thread)

        case .threadStatusChanged(let threadId, let status):
            switch status.type {
            case .active:
                if status.isWaitingOnApproval {
                    // This coordinator owns a separate app-server subprocess,
                    // not the stdio connection used by Codex Desktop. Its
                    // status can tell us that Desktop is waiting, but it does
                    // not carry an exact request. The PermissionRequest hook
                    // supplies the actionable card in either native-remote or
                    // direct-routing mode.
                    onEvent?(.activityUpdated(
                        SessionActivityUpdated(
                            sessionID: threadId,
                            summary: "Codex is waiting for approval in Codex.",
                            phase: .running,
                            timestamp: .now
                        )
                    ))
                } else if status.isWaitingOnUserInput {
                    onEvent?(.questionAsked(
                        QuestionAsked(
                            sessionID: threadId,
                            prompt: QuestionPrompt(
                                title: "Codex is waiting for input.",
                                options: []
                            ),
                            timestamp: .now
                        )
                    ))
                } else {
                    onEvent?(.activityUpdated(
                        SessionActivityUpdated(
                            sessionID: threadId,
                            summary: "Codex is working…",
                            phase: .running,
                            timestamp: .now
                        )
                    ))
                }
            case .idle:
                // Idle means "between turns" in the same thread — the thread
                // is still open.  Only `thread/closed` truly ends a session.
                onEvent?(.activityUpdated(
                    SessionActivityUpdated(
                        sessionID: threadId,
                        summary: "Idle.",
                        phase: .completed,
                        timestamp: .now
                    )
                ))
            case .systemError:
                // Quota limits and other hard failures can leave the thread in
                // systemError without a turn/completed notification. Mark the
                // turn as finished so the island does not stay stuck running.
                onEvent?(.activityUpdated(
                    SessionActivityUpdated(
                        sessionID: threadId,
                        summary: "Turn failed.",
                        phase: .completed,
                        timestamp: .now
                    )
                ))
            case .notLoaded:
                break
            }

        case .threadClosed(let threadId):
            onEvent?(.sessionCompleted(
                SessionCompleted(
                    sessionID: threadId,
                    summary: "Codex thread closed.",
                    timestamp: .now,
                    isSessionEnd: true
                )
            ))

        case .threadNameUpdated(let threadId, let name):
            emitSessionTitleUpdated(threadId: threadId, name: name)

        case .turnStarted(let threadId, _):
            onEvent?(.activityUpdated(
                SessionActivityUpdated(
                    sessionID: threadId,
                    summary: "Codex is working…",
                    phase: .running,
                    timestamp: .now
                )
            ))

        case .turnCompleted(let threadId, let turn):
            // A turn completing doesn't end the thread — the user can send
            // another message.  Use activityUpdated(phase: .completed) so the
            // session stays visible as "Completed" rather than being torn
            // down.  `thread/closed` is the authoritative end signal.
            let summary: String
            switch turn.status {
            case .completed: summary = "Turn completed."
            case .interrupted: summary = "Turn interrupted."
            case .failed: summary = "Turn failed."
            case .inProgress: summary = "Turn in progress."
            }
            onEvent?(.activityUpdated(
                SessionActivityUpdated(
                    sessionID: threadId,
                    summary: summary,
                    phase: .completed,
                    timestamp: .now
                )
            ))

        case .unknown:
            break
        }
    }

    // MARK: - Helpers

    private func emitSessionStarted(from thread: CodexThread) {
        let workspaceName = URL(fileURLWithPath: thread.cwd).lastPathComponent
        let title = thread.name ?? workspaceName
        let summary = thread.preview.isEmpty ? "Codex session." : String(thread.preview.prefix(120))

        let phase: SessionPhase
        switch thread.status.type {
        case .active: phase = .running
        case .idle: phase = .completed
        case .notLoaded, .systemError: phase = .completed
        }

        onEvent?(.sessionStarted(
            SessionStarted(
                sessionID: thread.id,
                title: title,
                tool: .codex,
                origin: .live,
                initialPhase: phase,
                summary: summary,
                timestamp: .now,
                jumpTarget: JumpTarget(
                    terminalApp: "Codex.app",
                    workspaceName: workspaceName,
                    paneTitle: title,
                    workingDirectory: thread.cwd,
                    codexThreadID: thread.id
                ),
                codexMetadata: CodexSessionMetadata(
                    transcriptPath: thread.path,
                    initialUserPrompt: thread.preview.isEmpty ? nil : thread.preview
                )
            )
        ))
    }

    private func emitSessionTitleUpdated(threadId: String, name: String?) {
        guard let name = name?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty else {
            return
        }

        onEvent?(.sessionTitleUpdated(SessionTitleUpdated(sessionID: threadId, title: name)))
    }
}
