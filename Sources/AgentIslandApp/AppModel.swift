import AppKit
import Foundation
import Observation
import AgentIslandCore
import SwiftUI

extension Notification.Name {
    /// Posted by `AppModel.showOnboarding()` to ask `SettingsView` to
    /// switch to the Setup tab. Lets the empty-state CTAs deliver the
    /// user to the right place without `SettingsView`'s `@State` having
    /// to leak into `AppModel`.
    static let agentIslandSelectSetupTab = Notification.Name("agentIslandSelectSetupTab")
}

private struct AgentControlSelectionContext {
    let connectionNonce: UInt64
    let slotIndex: UInt8
    let slotEpoch: UInt16
    let sessionID: String
    let selectionToken: UInt64
    let allowedActions: AgentControlAllowedActionSet
    let expiresAt: Date
}

@MainActor
@Observable
final class AppModel {
    private static let showDockIconDefaultsKey = "app.showDockIcon"
    private static let hapticFeedbackEnabledDefaultsKey = "app.hapticFeedbackEnabled"
    private static let islandRightSlotDefaultsKey = "appearance.island.v6.rightSlot"
    private static let islandCenterLabelDefaultsKey = "appearance.island.v6.centerLabel"
    private static let showCodexUsageDefaultsKey = "app.showCodexUsage"
    private static let completionReplyEnabledDefaultsKey = "feature.completionReply.enabled"
    private static let suppressFrontmostNotificationsDefaultsKey = "app.suppressFrontmostNotifications"
    private static let legacyIslandSessionStateIndicatorDefaultsKey = "appearance.island.v8.stateIndicator"
    private static let legacyIslandSessionGroupDefaultsKey = "appearance.island.v8.sessionGroup"
    private static let legacyIslandSessionSortDefaultsKey = "appearance.island.v8.sessionSort"
    private static let legacyCompletedStaleThresholdDefaultsKey = "appearance.island.v8.completedStaleThreshold"
    private static let appearanceProfileSettingsDefaultsKey = "appearance.island.v8.settingsProfile"
    private static let agentControlSelectionLifetimeSeconds: UInt8 = 15

    private static let syntheticClaudeSessionPrefix = "claude-process:"
    private static let liveSessionStalenessWindow: TimeInterval = 15 * 60
    private static let jumpOverlayDismissLeadTime: Duration = .milliseconds(20)
    /// The pointer must remain continuously inside the closed island before a
    /// passive hover may open it. This keeps ordinary menu-bar navigation from
    /// expanding the island while preserving immediate click-to-open behavior.
    static let hoverOpenDelay: TimeInterval = 1.0

    struct AcceptanceStep: Identifiable {
        let id: String
        let title: String
        let detail: String
        let isComplete: Bool
    }

    let lang = LanguageManager.shared

    var state = SessionState() {
        didSet {
            _cachedSessionBuckets = nil
            bridgeServer.updateStateSnapshot(state)
            updateAgentControlDeviceSnapshot()
        }
    }
    @ObservationIgnored private var _cachedSessionBuckets: SessionBucketCache?

    @ObservationIgnored
    private let hiddenSessionStore: HiddenSessionStore

    @ObservationIgnored
    private let agentControlSlotCoordinator: AgentControlSlotCoordinator

    @ObservationIgnored
    private let agentControlDeviceCoordinator: AgentControlDeviceCoordinator

    @ObservationIgnored
    private let agentControlDeviceSettingsStore: AgentControlDeviceSettingsStore

    @ObservationIgnored
    private var agentControlSnapshotRefreshTask: Task<Void, Never>?

    @ObservationIgnored
    private var isAgentControlDeviceIntegrationStarted = false

    @ObservationIgnored
    private var agentControlSelection: AgentControlSelectionContext?

    @ObservationIgnored
    private let agentControlSelectionTokenGenerator: () -> UInt64

    @ObservationIgnored
    private let agentControlDateProvider: () -> Date

    private var hiddenSessionIdentifiers: Set<HiddenSessionIdentifier> = []

    var isHiddenSessionSectionExpanded = false {
        didSet {
            guard isHiddenSessionSectionExpanded != oldValue else { return }
            refreshOverlayPlacementIfVisible()
        }
    }

    private struct SessionBucketCache {
        let primary: [AgentSession]
        let overflow: [AgentSession]
        let validThrough: Date?
    }

    var selectedSessionID: String?
    let hooks = HookInstallationCoordinator()
    let overlay = OverlayUICoordinator()
    let discovery = SessionDiscoveryCoordinator()
    let monitoring = ProcessMonitoringCoordinator()
    let codexAppServer = CodexAppServerCoordinator()
    let updateChecker = UpdateChecker()

    var notchStatus: NotchStatus {
        get { overlay.notchStatus }
        set { overlay.notchStatus = newValue }
    }
    var notchOpenReason: NotchOpenReason? {
        get { overlay.notchOpenReason }
        set { overlay.notchOpenReason = newValue }
    }
    var islandSurface: IslandSurface {
        get { overlay.islandSurface }
        set { overlay.islandSurface = newValue }
    }
    var isOverlayVisible: Bool { overlay.isOverlayVisible }
    var isOverlayCloseTransitionPending: Bool { overlay.isCloseTransitionPending }
    var isCodexSetupBusy: Bool { hooks.isCodexSetupBusy }
    var isClaudeHookSetupBusy: Bool { hooks.isClaudeHookSetupBusy }
    var isClaudeUsageSetupBusy: Bool { hooks.isClaudeUsageSetupBusy }
    var codexHookStatus: CodexHookInstallationStatus? { hooks.codexHookStatus }
    var claudeHookStatus: ClaudeHookInstallationStatus? { hooks.claudeHookStatus }
    var claudeStatusLineStatus: ClaudeStatusLineInstallationStatus? { hooks.claudeStatusLineStatus }
    var claudeUsageSnapshot: ClaudeUsageSnapshot? { hooks.claudeUsageSnapshot }
    var codexUsageSnapshot: CodexUsageSnapshot? { hooks.codexUsageSnapshot }
    var hooksBinaryURL: URL? { hooks.hooksBinaryURL }
    var codexHooksInstalled: Bool { hooks.codexHooksInstalled }
    var claudeHooksInstalled: Bool { hooks.claudeHooksInstalled }
    var qoderHooksInstalled: Bool { hooks.qoderHooksInstalled }
    var qwenCodeHooksInstalled: Bool { hooks.qwenCodeHooksInstalled }
    var factoryHooksInstalled: Bool { hooks.factoryHooksInstalled }
    var codebuddyHooksInstalled: Bool { hooks.codebuddyHooksInstalled }
    var qoderHookStatus: ClaudeHookInstallationStatus? { hooks.qoderHookStatus }
    var qwenCodeHookStatus: ClaudeHookInstallationStatus? { hooks.qwenCodeHookStatus }
    var factoryHookStatus: ClaudeHookInstallationStatus? { hooks.factoryHookStatus }
    var codebuddyHookStatus: ClaudeHookInstallationStatus? { hooks.codebuddyHookStatus }
    var isQoderHookSetupBusy: Bool { hooks.isQoderHookSetupBusy }
    var isQwenCodeHookSetupBusy: Bool { hooks.isQwenCodeHookSetupBusy }
    var isFactoryHookSetupBusy: Bool { hooks.isFactoryHookSetupBusy }
    var isCodebuddyHookSetupBusy: Bool { hooks.isCodebuddyHookSetupBusy }
    var openCodePluginInstalled: Bool { hooks.openCodePluginInstalled }
    var claudeUsageInstalled: Bool { hooks.claudeUsageInstalled }
    var claudeHookStatusTitle: String { hooks.claudeHookStatusTitle }
    var claudeHookStatusSummary: String { hooks.claudeHookStatusSummary }
    var claudeUsageStatusTitle: String { hooks.claudeUsageStatusTitle }
    var claudeUsageStatusSummary: String { hooks.claudeUsageStatusSummary }
    var claudeUsageSummaryText: String? { hooks.claudeUsageSummaryText }
    var codexUsageStatusTitle: String { hooks.codexUsageStatusTitle }
    var codexUsageStatusSummary: String { hooks.codexUsageStatusSummary }
    var codexUsageSummaryText: String? { hooks.codexUsageSummaryText }
    var openCodePluginStatus: OpenCodePluginInstallationStatus? { hooks.openCodePluginStatus }
    var isOpenCodeSetupBusy: Bool { hooks.isOpenCodeSetupBusy }
    var openCodePluginStatusTitle: String { hooks.openCodePluginStatusTitle }
    var openCodePluginStatusSummary: String { hooks.openCodePluginStatusSummary }
    var claudeHealthReport: HookHealthReport? { hooks.claudeHealthReport }
    var codexHealthReport: HookHealthReport? { hooks.codexHealthReport }
    var cursorHooksInstalled: Bool { hooks.cursorHooksInstalled }
    var isCursorHookSetupBusy: Bool { hooks.isCursorHookSetupBusy }
    var cursorHookStatus: CursorHookInstallationStatus? { hooks.cursorHookStatus }
    var cursorHookStatusTitle: String { hooks.cursorHookStatusTitle }
    var cursorHookStatusSummary: String { hooks.cursorHookStatusSummary }
    var geminiHooksInstalled: Bool { hooks.geminiHooksInstalled }
    var isGeminiHookSetupBusy: Bool { hooks.isGeminiHookSetupBusy }
    var geminiHookStatus: GeminiHookInstallationStatus? { hooks.geminiHookStatus }
    var geminiHookStatusTitle: String { hooks.geminiHookStatusTitle }
    var geminiHookStatusSummary: String { hooks.geminiHookStatusSummary }
    var kimiHooksInstalled: Bool { hooks.kimiHooksInstalled }
    var isKimiHookSetupBusy: Bool { hooks.isKimiHookSetupBusy }
    var kimiHookStatus: KimiHookInstallationStatus? { hooks.kimiHookStatus }
    var kimiHookStatusTitle: String { hooks.kimiHookStatusTitle }
    var kimiHookStatusSummary: String { hooks.kimiHookStatusSummary }
    var codexHookStatusTitle: String { hooks.codexHookStatusTitle }
    var codexHookStatusSummary: String { hooks.codexHookStatusSummary }

    /// Mirrors `AgentIntentStore.firstLaunchCompleted`. Onboarding sets this
    /// to true after the user completes (or explicitly skips) the flow;
    /// legacy migration also flips it for users upgrading with existing
    /// hooks.
    var firstLaunchCompleted: Bool {
        get { hooks.intentStore.firstLaunchCompleted }
        set { hooks.intentStore.firstLaunchCompleted = newValue }
    }

    /// True if at least one managed hook is currently present on disk.
    /// Drives the "configure agents" empty-state prompts in the island and
    /// the settings window.
    var hasAnyInstalledAgent: Bool {
        hooks.claudeHooksInstalled
            || hooks.codexHooksInstalled
            || hooks.cursorHooksInstalled
            || hooks.qoderHooksInstalled
            || hooks.qwenCodeHooksInstalled
            || hooks.factoryHooksInstalled
            || hooks.codebuddyHooksInstalled
            || hooks.openCodePluginInstalled
            || hooks.geminiHooksInstalled
            || hooks.kimiHooksInstalled
    }
    func refreshCodexHookStatus() { hooks.refreshCodexHookStatus() }
    func refreshClaudeHookStatus() { hooks.refreshClaudeHookStatus() }
    func refreshOpenCodePluginStatus() { hooks.refreshOpenCodePluginStatus() }
    func refreshCursorHookStatus() { hooks.refreshCursorHookStatus() }
    func refreshClaudeUsageState() { hooks.refreshClaudeUsageState() }
    func refreshCodexUsageState() { hooks.refreshCodexUsageState() }
    func installCodexHooks() { hooks.installCodexHooks() }
    func uninstallCodexHooks() { hooks.uninstallCodexHooks() }
    func installClaudeHooks() { hooks.installClaudeHooks() }
    func uninstallClaudeHooks() { hooks.uninstallClaudeHooks() }
    func installQoderHooks() { hooks.installQoderHooks() }
    func uninstallQoderHooks() { hooks.uninstallQoderHooks() }
    func installQwenCodeHooks() { hooks.installQwenCodeHooks() }
    func uninstallQwenCodeHooks() { hooks.uninstallQwenCodeHooks() }
    func installFactoryHooks() { hooks.installFactoryHooks() }
    func uninstallFactoryHooks() { hooks.uninstallFactoryHooks() }
    func installCodebuddyHooks() { hooks.installCodebuddyHooks() }
    func uninstallCodebuddyHooks() { hooks.uninstallCodebuddyHooks() }
    func refreshCCForkHookStatuses() { hooks.refreshCCForkHookStatuses() }
    func installOpenCodePlugin() { hooks.installOpenCodePlugin() }
    func uninstallOpenCodePlugin() { hooks.uninstallOpenCodePlugin() }
    func installCursorHooks() { hooks.installCursorHooks() }
    func uninstallCursorHooks() { hooks.uninstallCursorHooks() }
    func refreshGeminiHookStatus() { hooks.refreshGeminiHookStatus() }
    func installGeminiHooks() { hooks.installGeminiHooks() }
    func uninstallGeminiHooks() { hooks.uninstallGeminiHooks() }
    func refreshKimiHookStatus() { hooks.refreshKimiHookStatus() }
    func installKimiHooks() { hooks.installKimiHooks() }
    func uninstallKimiHooks() { hooks.uninstallKimiHooks() }
    func installClaudeUsageBridge() { hooks.installClaudeUsageBridge() }
    func uninstallClaudeUsageBridge() { hooks.uninstallClaudeUsageBridge() }
    func updateClaudeConfigDirectory(to newDirectory: URL?) { hooks.updateClaudeConfigDirectory(to: newDirectory) }
    func runHealthChecks() { hooks.runHealthChecks() }
    func repairHooks() {
        Task { @MainActor in
            await hooks.repairHooksIfNeeded()
        }
    }
    var isBridgeReady = false
    var lastActionMessage = "Waiting for agent hook events..." {
        didSet {
            guard lastActionMessage != oldValue else {
                return
            }

            harnessRuntimeMonitor?.recordLog(lastActionMessage)
        }
    }
    var isResolvingInitialLiveSessions: Bool {
        get { monitoring.isResolvingInitialLiveSessions }
        set { monitoring.isResolvingInitialLiveSessions = newValue }
    }
    var overlayDisplayOptions: [OverlayDisplayOption] {
        get { overlay.overlayDisplayOptions }
        set { overlay.overlayDisplayOptions = newValue }
    }
    var overlayPlacementDiagnostics: OverlayPlacementDiagnostics? {
        get { overlay.overlayPlacementDiagnostics }
        set { overlay.overlayPlacementDiagnostics = newValue }
    }
    var showDockIcon: Bool = false {
        didSet {
            guard hasFinishedInit, showDockIcon != oldValue else { return }
            UserDefaults.standard.set(showDockIcon, forKey: Self.showDockIconDefaultsKey)
            NSApp.setActivationPolicy(showDockIcon ? .regular : .accessory)
            if !showDockIcon {
                // macOS does not immediately refresh the Dock when switching to
                // .accessory at runtime. Briefly activating another app forces
                // the Dock to drop the icon.
                NSApp.hide(nil)
                DispatchQueue.main.async {
                    NSApp.unhide(nil)
                }
            }
        }
    }
    var hapticFeedbackEnabled: Bool = false {
        didSet {
            guard hasFinishedInit, hapticFeedbackEnabled != oldValue else { return }
            UserDefaults.standard.set(hapticFeedbackEnabled, forKey: Self.hapticFeedbackEnabledDefaultsKey)
        }
    }
    var showCodexUsage: Bool = false {
        didSet {
            guard hasFinishedInit, showCodexUsage != oldValue else { return }
            UserDefaults.standard.set(showCodexUsage, forKey: Self.showCodexUsageDefaultsKey)
        }
    }
    var completionReplyEnabled: Bool = false {
        didSet {
            guard hasFinishedInit, completionReplyEnabled != oldValue else { return }
            UserDefaults.standard.set(completionReplyEnabled, forKey: Self.completionReplyEnabledDefaultsKey)
            refreshOverlayPlacementIfVisible()
        }
    }
    var suppressFrontmostNotifications: Bool = true {
        didSet {
            guard hasFinishedInit, suppressFrontmostNotifications != oldValue else { return }
            UserDefaults.standard.set(suppressFrontmostNotifications, forKey: Self.suppressFrontmostNotificationsDefaultsKey)
        }
    }
    var agentControlKeyboardEnabled: Bool = false {
        didSet {
            guard hasFinishedInit,
                  agentControlKeyboardEnabled != oldValue else {
                return
            }

            agentControlDeviceSettingsStore.saveEnabled(
                agentControlKeyboardEnabled
            )
            if agentControlKeyboardEnabled {
                if hasStarted {
                    startAgentControlDeviceIntegrationIfNeeded()
                }
            } else {
                stopAgentControlDeviceIntegration()
            }
        }
    }
    var launchAtLoginEnabled: Bool = false {
        didSet {
            guard !isApplyingLaunchAtLogin, hasFinishedInit, launchAtLoginEnabled != oldValue else { return }
            do {
                try LaunchAtLoginService.shared.setEnabled(launchAtLoginEnabled)
            } catch {
                isApplyingLaunchAtLogin = true
                launchAtLoginEnabled = oldValue
                isApplyingLaunchAtLogin = false
                presentLaunchAtLoginError(error)
            }
        }
    }
    private func presentLaunchAtLoginError(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = lang.t("settings.general.launchAtLogin")
        alert.informativeText = error.localizedDescription
        alert.runModal()
    }
    @ObservationIgnored
    private var isApplyingLaunchAtLogin = false
    var overlayDisplaySelectionID: String {
        get { overlay.overlayDisplaySelectionID }
        set { overlay.overlayDisplaySelectionID = newValue }
    }

    // MARK: - Appearance

    var appearanceSettingsProfile: IslandAppearanceDisplayProfile = .topBar {
        didSet {
            guard appearanceSettingsProfile != oldValue else { return }
            UserDefaults.standard.set(appearanceSettingsProfile.rawValue, forKey: Self.appearanceProfileSettingsDefaultsKey)
        }
    }

    private var notchAppearancePreferences = IslandAppearancePreferences() {
        didSet {
            guard notchAppearancePreferences != oldValue else { return }
            persistAppearancePreferences(notchAppearancePreferences, for: .notch)
            if activeAppearanceProfile == .notch { appearancePreferencesDidChange(oldValue: oldValue, newValue: notchAppearancePreferences) }
        }
    }

    private var topBarAppearancePreferences = IslandAppearancePreferences() {
        didSet {
            guard topBarAppearancePreferences != oldValue else { return }
            persistAppearancePreferences(topBarAppearancePreferences, for: .topBar)
            if activeAppearanceProfile == .topBar { appearancePreferencesDidChange(oldValue: oldValue, newValue: topBarAppearancePreferences) }
        }
    }

    /// Runtime profile selected from current overlay placement. External
    /// displays use the top-bar presentation; built-in notch displays keep
    /// notch-aware geometry and their own persisted appearance choices.
    var activeAppearanceProfile: IslandAppearanceDisplayProfile {
        overlayPlacementDiagnostics?.mode == .notch ? .notch : .topBar
    }

    var islandRightSlot: IslandRightSlot {
        get { appearancePreferences(for: activeAppearanceProfile).rightSlot }
        set { updateAppearancePreferences(for: activeAppearanceProfile) { $0.rightSlot = newValue } }
    }

    var islandClosedPresentation: IslandClosedPresentation {
        get { appearancePreferences(for: activeAppearanceProfile).closedPresentation }
        set { updateAppearancePreferences(for: activeAppearanceProfile) { $0.closedPresentation = newValue } }
    }

    var islandCenterLabel: IslandCenterLabel {
        get { appearancePreferences(for: activeAppearanceProfile).centerLabel }
        set { updateAppearancePreferences(for: activeAppearanceProfile) { $0.centerLabel = newValue } }
    }

    var islandUsageDisplay: IslandUsageDisplay {
        get { appearancePreferences(for: activeAppearanceProfile).usageDisplay }
        set { updateAppearancePreferences(for: activeAppearanceProfile) { $0.usageDisplay = newValue } }
    }

    var islandSessionStateIndicator: IslandSessionStateIndicator {
        get { appearancePreferences(for: activeAppearanceProfile).sessionStateIndicator }
        set { updateAppearancePreferences(for: activeAppearanceProfile) { $0.sessionStateIndicator = newValue } }
    }

    var islandSessionGroup: IslandSessionGroup {
        get { appearancePreferences(for: activeAppearanceProfile).sessionGroup }
        set { updateAppearancePreferences(for: activeAppearanceProfile) { $0.sessionGroup = newValue } }
    }

    var islandSessionSort: IslandSessionSort {
        get { appearancePreferences(for: activeAppearanceProfile).sessionSort }
        set { updateAppearancePreferences(for: activeAppearanceProfile) { $0.sessionSort = newValue } }
    }

    var completedStaleThreshold: IslandCompletedStaleThreshold {
        get { appearancePreferences(for: activeAppearanceProfile).completedStaleThreshold }
        set { updateAppearancePreferences(for: activeAppearanceProfile) { $0.completedStaleThreshold = newValue } }
    }

    @ObservationIgnored
    var openSettingsWindow: (() -> Void)?

    @ObservationIgnored
    private var hasFinishedInit = false

    func appearancePreferences(for profile: IslandAppearanceDisplayProfile) -> IslandAppearancePreferences {
        switch profile {
        case .notch: notchAppearancePreferences
        case .topBar: topBarAppearancePreferences
        }
    }

    func updateAppearancePreferences(
        for profile: IslandAppearanceDisplayProfile,
        _ update: (inout IslandAppearancePreferences) -> Void
    ) {
        switch profile {
        case .notch:
            update(&notchAppearancePreferences)
        case .topBar:
            update(&topBarAppearancePreferences)
        }
    }

    private func appearancePreferencesDidChange(
        oldValue: IslandAppearancePreferences,
        newValue: IslandAppearancePreferences
    ) {
        if oldValue.sessionGroup != newValue.sessionGroup ||
            oldValue.sessionSort != newValue.sessionSort ||
            oldValue.completedStaleThreshold != newValue.completedStaleThreshold {
            _cachedSessionBuckets = nil
        }
        if oldValue.completedStaleThreshold
            != newValue.completedStaleThreshold {
            updateAgentControlDeviceSnapshot()
        }
        refreshOverlayPlacementIfVisible()
    }

    private func persistAppearancePreferences(
        _ preferences: IslandAppearancePreferences,
        for profile: IslandAppearanceDisplayProfile
    ) {
        let defaults = UserDefaults.standard
        defaults.set(preferences.closedPresentation.rawValue, forKey: Self.appearanceDefaultsKey(profile, "closedPresentation"))
        defaults.set(preferences.rightSlot.rawValue, forKey: Self.appearanceDefaultsKey(profile, "rightSlot"))
        defaults.set(preferences.centerLabel.rawValue, forKey: Self.appearanceDefaultsKey(profile, "centerLabel"))
        defaults.set(preferences.usageDisplay.rawValue, forKey: Self.appearanceDefaultsKey(profile, "usageDisplay"))
        defaults.set(preferences.sessionStateIndicator.rawValue, forKey: Self.appearanceDefaultsKey(profile, "stateIndicator"))
        defaults.set(preferences.sessionGroup.rawValue, forKey: Self.appearanceDefaultsKey(profile, "sessionGroup"))
        defaults.set(preferences.sessionSort.rawValue, forKey: Self.appearanceDefaultsKey(profile, "sessionSort"))
        defaults.set(preferences.completedStaleThreshold.rawValue, forKey: Self.appearanceDefaultsKey(profile, "completedStaleThreshold"))
    }

    // MARK: - Watch Notification

    private static let watchNotificationEnabledKey = "watch.notification.enabled"

    var watchNotificationEnabled: Bool = false {
        didSet {
            guard watchNotificationEnabled != oldValue else { return }
            UserDefaults.standard.set(watchNotificationEnabled, forKey: Self.watchNotificationEnabledKey)
            if watchNotificationEnabled {
                startWatchRelay()
            } else {
                stopWatchRelay()
            }
        }
    }

    @ObservationIgnored
    private(set) var watchRelay: WatchNotificationRelay?

    /// Current pairing code for display in the settings UI.
    var watchPairingCode: String {
        watchRelay?.endpoint.currentCode() ?? "----"
    }

    /// Number of currently connected iPhone SSE clients.
    var watchConnectedDevices: Int {
        // Placeholder — endpoint doesn't expose count yet
        0
    }

    private func startWatchRelay() {
        guard watchRelay == nil else { return }
        let relay = WatchNotificationRelay()
        setupWatchRelayCallbacks(relay)
        relay.start()
        self.watchRelay = relay
    }

    /// Wire up resolution callbacks so Watch/iPhone actions flow back to the bridge.
    private func setupWatchRelayCallbacks(_ relay: WatchNotificationRelay) {
        relay.onResolvePermission = { [weak self] sessionID, approved in
            Task { @MainActor [weak self] in
                self?.approvePermission(for: sessionID, approved: approved)
            }
        }

        relay.onAnswerQuestion = { [weak self] sessionID, answer in
            Task { @MainActor [weak self] in
                self?.answerQuestion(
                    for: sessionID,
                    answer: QuestionPromptResponse(answer: answer)
                )
            }
        }

        relay.endpoint.activeSessionCountProvider = { [weak self] in
            // Safe to call from any queue — reads a snapshot count.
            guard let self else { return 0 }
            return MainActor.assumeIsolated {
                self.state.sessions.count
            }
        }
    }

    private func stopWatchRelay() {
        watchRelay?.stop()
        watchRelay = nil
    }

    var ignoresPointerExitDuringHarness = false
    var disablesOverlayEventMonitoringDuringHarness = false

    @ObservationIgnored
    private var bridgeTask: Task<Void, Never>?

    @ObservationIgnored
    private var bridgeReconnectTask: Task<Void, Never>?

    @ObservationIgnored
    private var hasStarted = false

    @ObservationIgnored
    private let bridgeServer = BridgeServer()

    @ObservationIgnored
    private var bridgeClient = LocalBridgeClient()

    @ObservationIgnored
    private let terminalJumpAction: @Sendable (JumpTarget) throws -> String

    @ObservationIgnored
    private let isNotificationSessionAlreadyFrontmost: @Sendable (AgentSession) async -> Bool


    @ObservationIgnored
    var harnessRuntimeMonitor: HarnessRuntimeMonitor? {
        didSet {
            overlay.harnessRuntimeMonitor = harnessRuntimeMonitor
        }
    }


    @ObservationIgnored
    private var jumpTask: Task<Void, Never>?

    @ObservationIgnored
    private var notificationPresentationTask: Task<Void, Never>?

    private static func appearanceDefaultsKey(_ profile: IslandAppearanceDisplayProfile, _ name: String) -> String {
        "appearance.island.v8.\(profile.rawValue).\(name)"
    }

    private static func loadAppearancePreferences(for profile: IslandAppearanceDisplayProfile) -> IslandAppearancePreferences {
        let defaults = UserDefaults.standard
        return IslandAppearancePreferences(
            closedPresentation: IslandClosedPresentation(
                rawValue: defaults.string(forKey: appearanceDefaultsKey(profile, "closedPresentation")) ?? ""
            ) ?? (profile == .notch ? .ghost : .alwaysVisible),
            rightSlot: IslandRightSlot(
                rawValue: defaults.string(forKey: appearanceDefaultsKey(profile, "rightSlot"))
                    ?? defaults.string(forKey: islandRightSlotDefaultsKey)
                    ?? ""
            ) ?? .count,
            centerLabel: IslandCenterLabel(
                rawValue: defaults.string(forKey: appearanceDefaultsKey(profile, "centerLabel"))
                    ?? defaults.string(forKey: islandCenterLabelDefaultsKey)
                    ?? ""
            ) ?? .agentAction,
            usageDisplay: IslandUsageDisplay(
                rawValue: defaults.string(forKey: appearanceDefaultsKey(profile, "usageDisplay"))
                    ?? ""
            ) ?? .compact,
            sessionStateIndicator: IslandSessionStateIndicator(
                rawValue: defaults.string(forKey: appearanceDefaultsKey(profile, "stateIndicator"))
                    ?? defaults.string(forKey: legacyIslandSessionStateIndicatorDefaultsKey)
                    ?? ""
            ) ?? .animatedDot,
            sessionGroup: IslandSessionGroup(
                rawValue: defaults.string(forKey: appearanceDefaultsKey(profile, "sessionGroup"))
                    ?? defaults.string(forKey: legacyIslandSessionGroupDefaultsKey)
                    ?? ""
            ) ?? .none,
            sessionSort: IslandSessionSort(
                rawValue: defaults.string(forKey: appearanceDefaultsKey(profile, "sessionSort"))
                    ?? defaults.string(forKey: legacyIslandSessionSortDefaultsKey)
                    ?? ""
            ) ?? .attention,
            completedStaleThreshold: IslandCompletedStaleThreshold(
                rawValue: defaults.string(forKey: appearanceDefaultsKey(profile, "completedStaleThreshold"))
                    ?? defaults.string(forKey: legacyCompletedStaleThresholdDefaultsKey)
                    ?? ""
            ) ?? .fiveMinutes
        )
    }

    init(
        terminalJumpAction: @escaping @Sendable (JumpTarget) throws -> String = { target in
            try TerminalJumpService().jump(to: target)
        },
        isNotificationSessionAlreadyFrontmost: @escaping @Sendable (AgentSession) async -> Bool = { session in
            await ForegroundTerminalSessionProbe().matches(session: session)
        },
        hiddenSessionStore: HiddenSessionStore = .standard,
        agentControlSlotAssignmentStore: AgentControlSlotAssignmentStore = .standard,
        agentControlDeviceCoordinator: AgentControlDeviceCoordinator = AgentControlDeviceCoordinator(),
        agentControlDeviceSettingsStore: AgentControlDeviceSettingsStore = .standard,
        agentControlSelectionTokenGenerator: @escaping () -> UInt64 = {
            UInt64.random(in: 1...UInt64.max)
        },
        agentControlDateProvider: @escaping () -> Date = Date.init
    ) {
        self.terminalJumpAction = terminalJumpAction
        self.isNotificationSessionAlreadyFrontmost = isNotificationSessionAlreadyFrontmost
        self.hiddenSessionStore = hiddenSessionStore
        self.agentControlSlotCoordinator = AgentControlSlotCoordinator(
            store: agentControlSlotAssignmentStore
        )
        self.agentControlDeviceCoordinator = agentControlDeviceCoordinator
        self.agentControlDeviceSettingsStore = agentControlDeviceSettingsStore
        self.agentControlSelectionTokenGenerator =
            agentControlSelectionTokenGenerator
        self.agentControlDateProvider = agentControlDateProvider
        self.hiddenSessionIdentifiers = hiddenSessionStore.load()
        UserDefaults.standard.register(defaults: [
            Self.showDockIconDefaultsKey: true,
            Self.hapticFeedbackEnabledDefaultsKey: false,
            Self.completionReplyEnabledDefaultsKey: false,
            Self.suppressFrontmostNotificationsDefaultsKey: true,
        ])
        showDockIcon = UserDefaults.standard.bool(forKey: Self.showDockIconDefaultsKey)
        hapticFeedbackEnabled = UserDefaults.standard.bool(forKey: Self.hapticFeedbackEnabledDefaultsKey)
        suppressFrontmostNotifications = UserDefaults.standard.bool(forKey: Self.suppressFrontmostNotificationsDefaultsKey)
        if UserDefaults.standard.object(forKey: Self.showCodexUsageDefaultsKey) != nil {
            showCodexUsage = UserDefaults.standard.bool(forKey: Self.showCodexUsageDefaultsKey)
        } else {
            showCodexUsage = FileManager.default.fileExists(
                atPath: CodexRolloutDiscovery.defaultRootURL.path
            )
        }
        completionReplyEnabled = UserDefaults.standard.bool(forKey: Self.completionReplyEnabledDefaultsKey)
        agentControlKeyboardEnabled =
            agentControlDeviceSettingsStore.loadEnabled()
        launchAtLoginEnabled = LaunchAtLoginService.shared.isEnabled
        appearanceSettingsProfile = IslandAppearanceDisplayProfile(
            rawValue: UserDefaults.standard.string(forKey: Self.appearanceProfileSettingsDefaultsKey) ?? ""
        ) ?? .topBar
        notchAppearancePreferences = Self.loadAppearancePreferences(for: .notch)
        topBarAppearancePreferences = Self.loadAppearancePreferences(for: .topBar)
        watchNotificationEnabled = UserDefaults.standard.bool(forKey: Self.watchNotificationEnabledKey)
        if watchNotificationEnabled {
            startWatchRelay()
        }

        overlay.appModel = self
        overlay.onPlacementDiagnosticsChanged = { [weak self] in
            self?._cachedSessionBuckets = nil
            self?.updateAgentControlDeviceSnapshot()
        }
        overlay.restoreDisplayPreference()
        overlay.startObservingDisplayChanges()
        overlay.onStatusMessage = { [weak self] message in
            self?.lastActionMessage = message
        }
        overlay.activeIslandCardSessionAccessor = { [weak self] in
            self?.activeIslandCardSession
        }
        overlay.ignoresPointerExitAccessor = { [weak self] in
            self?.ignoresPointerExitDuringHarness ?? false
        }

        hooks.onStatusMessage = { [weak self] message in
            self?.lastActionMessage = message
        }

        discovery.syntheticClaudeSessionPrefix = Self.syntheticClaudeSessionPrefix
        discovery.onStatusMessage = { [weak self] message in
            self?.lastActionMessage = message
        }
        discovery.stateAccessor = { [weak self] in self?.state ?? SessionState() }
        discovery.stateUpdater = { [weak self] in self?.state = $0 }
        discovery.onStateChanged = { [weak self] in
            self?.synchronizeSelection()
            self?.refreshOverlayPlacementIfVisible()
        }
        discovery.onAgentEvent = { [weak self] event in
            self?.applyTrackedEvent(
                event,
                updateLastActionMessage: false,
                ingress: .rollout
            )
        }

        discovery.codexRolloutWatcher.eventHandler = { [weak self] event in
            Task { @MainActor [weak self] in
                self?.applyTrackedEvent(
                    event,
                    updateLastActionMessage: false,
                    ingress: .rollout
                )
            }
        }

        codexAppServer.onEvent = { [weak self] event in
            self?.applyTrackedEvent(event, ingress: .bridge)
        }
        codexAppServer.onStatusMessage = { [weak self] message in
            self?.lastActionMessage = message
        }
        codexAppServer.isSessionTracked = { [weak self] id in
            self?.state.session(id: id) != nil
        }

        monitoring.syntheticClaudeSessionPrefix = Self.syntheticClaudeSessionPrefix
        monitoring.stateAccessor = { [weak self] in self?.state ?? SessionState() }
        monitoring.stateUpdater = { [weak self] in self?.state = $0 }
        monitoring.onSessionsReconciled = { [weak self] in
            self?.synchronizeSelection()
            self?.refreshOverlayPlacementIfVisible()
        }
        monitoring.onPersistenceNeeded = { [weak self] in
            self?.discovery.scheduleCodexSessionPersistence()
            self?.discovery.scheduleClaudeSessionPersistence()
            self?.discovery.scheduleOpenCodeSessionPersistence()
            self?.discovery.scheduleCursorSessionPersistence()
        }
        monitoring.onCodexAppRunningChanged = { [weak self] isRunning in
            guard let self else { return }
            if isRunning {
                self.codexAppServer.ensureConnected()
            } else {
                self.codexAppServer.disconnect()
            }
        }
        monitoring.onCodexAppMaintenanceTick = { [weak self] in
            self?.discovery.maintainCodexAppSessionsIfNeeded()
        }
        agentControlDeviceCoordinator.onDeviceMessage = { [weak self] event in
            self?.handleAgentControlDeviceEvent(event)
        }
        refreshOverlayDisplayConfiguration()
        hasFinishedInit = true
    }

    var sessions: [AgentSession] {
        state.sessions
    }

    var allSessions: [AgentSession] {
        state.sessions
    }

    /// Measured by SwiftUI GeometryReader in notification mode. Used by panel controller for sizing.
    /// Uses a tolerance of 2pt to avoid infinite layout loops caused by floating-point jitter
    /// in GeometryReader measurements across consecutive layout passes.
    var measuredNotificationContentHeight: CGFloat = 0 {
        didSet {
            let delta = abs(measuredNotificationContentHeight - oldValue)
            if delta >= 2, measuredNotificationContentHeight > 0 {
                overlay.refreshOverlayPlacementIfVisible()
            }
        }
    }

    var surfacedSessions: [AgentSession] {
        sessionBuckets.primary.filter(shouldSurfaceSession)
    }

    var recentSessions: [AgentSession] {
        sessionBuckets.overflow.filter(shouldSurfaceSession)
    }

    var hiddenIslandSessions: [AgentSession] {
        sortIslandSessions(
            state.sessions.filter { session in
                isSessionHidden(session)
                    && session.phase != .waitingForApproval
                    && !session.isSubagentSession
                    && !session.isRealtimeVoiceChatSession
            }
        )
    }

    /// Membership of the flattened list is reference-date independent — every
    /// completed session lands in exactly one of the done/idle sections — so
    /// this can keep the `.now` default without drifting from the view's clock.
    var islandListSessions: [AgentSession] {
        islandSessionSections().flatMap(\.sessions)
    }

    var islandRenderedSessions: [AgentSession] {
        islandListSessions + (isHiddenSessionSectionExpanded ? hiddenIslandSessions : [])
    }

    /// Callers inside the island's `TimelineView` should pass its `context.date`
    /// so the sections and the header counters bucket against the same instant.
    func islandSessionSections(at referenceDate: Date = .now) -> [IslandSessionSection] {
        let sessions = sortIslandSessions(surfacedSessions)
        switch islandSessionGroup {
        case .none:
            return [
                IslandSessionSection(
                    id: "all",
                    title: "island.section.sessions",
                    sessions: sessions
                )
            ]
        case .state:
            return stateGroupedSections(for: sessions, at: referenceDate)
        case .agent:
            return AgentTool.allCases.compactMap { tool in
                let list = sessions.filter { $0.tool == tool }
                guard !list.isEmpty else { return nil }
                return IslandSessionSection(id: "agent-\(tool.rawValue)", title: tool.displayName, sessions: list)
            }
        case .project:
            let names = Set(sessions.map(projectGroupName(for:))).sorted {
                $0.localizedStandardCompare($1) == .orderedAscending
            }
            return names.compactMap { name in
                let list = sessions.filter { projectGroupName(for: $0) == name }
                guard !list.isEmpty else { return nil }
                return IslandSessionSection(id: "project-\(name)", title: name, sessions: list)
            }
        }
    }

    /// Counts behind the island's header chips.
    ///
    /// Lives on the model rather than in the view so it shares
    /// ``AgentSession/isIdleForIsland(at:completedStaleThreshold:)`` with
    /// ``islandSessionSections(at:)`` — the header previously had its own
    /// private predicate that also treated a session as idle once
    /// `islandPresence` went `.inactive` at a fixed 20 minutes, so with the
    /// "Done timeout" set to Never the chip said "idle" while the section
    /// heading still said "Just done".
    func islandSessionOverviewCounts(
        at referenceDate: Date
    ) -> (total: Int, waiting: Int, running: Int, done: Int, idle: Int) {
        let sessions = islandListSessions
        let threshold = completedStaleThreshold.seconds

        return (
            total: sessions.count,
            waiting: sessions.filter(\.phase.requiresAttention).count,
            running: sessions.filter { $0.phase == .running }.count,
            done: sessions.filter {
                $0.isJustDoneForIsland(at: referenceDate, completedStaleThreshold: threshold)
            }.count,
            idle: sessions.filter {
                $0.isIdleForIsland(at: referenceDate, completedStaleThreshold: threshold)
            }.count
        )
    }

    var recentSessionCount: Int {
        recentSessions.count
    }

    var liveSessionCount: Int {
        surfacedSessions.count
    }

    var liveAttentionCount: Int {
        surfacedSessions.filter { $0.phase.requiresAttention }.count
    }

    var liveRunningCount: Int {
        surfacedSessions.filter { $0.phase == .running }.count
    }

    private func sortIslandSessions(_ sessions: [AgentSession]) -> [AgentSession] {
        switch islandSessionSort {
        case .attention:
            return sessions
        case .lastUpdate:
            return sessions.sorted { lhs, rhs in
                if lhs.islandActivityDate == rhs.islandActivityDate {
                    return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
                }
                return lhs.islandActivityDate > rhs.islandActivityDate
            }
        }
    }

    private func shouldSurfaceSession(_ session: AgentSession) -> Bool {
        !isSessionHidden(session) || session.phase == .waitingForApproval
    }

    func isSessionHidden(_ session: AgentSession) -> Bool {
        hiddenSessionIdentifiers.contains(HiddenSessionIdentifier(session: session))
    }

    func hideSession(_ session: AgentSession) {
        let identifier = HiddenSessionIdentifier(session: session)
        let hiddenSectionWasEmpty = hiddenIslandSessions.isEmpty
        guard hiddenSessionIdentifiers.insert(identifier).inserted else { return }

        if hiddenSectionWasEmpty {
            isHiddenSessionSectionExpanded = false
        }
        hiddenSessionStore.save(hiddenSessionIdentifiers)
        _cachedSessionBuckets = nil
        if session.phase != .waitingForApproval {
            dismissNotificationSurfaceIfPresent(for: session.id)
        }
        synchronizeSelection()
        refreshOverlayPlacementIfVisible()
        updateAgentControlDeviceSnapshot()
        lastActionMessage = "Hidden conversation: \(session.title)"
    }

    func unhideSession(_ session: AgentSession) {
        let identifier = HiddenSessionIdentifier(session: session)
        guard hiddenSessionIdentifiers.remove(identifier) != nil else { return }

        hiddenSessionStore.save(hiddenSessionIdentifiers)
        _cachedSessionBuckets = nil
        if hiddenIslandSessions.isEmpty {
            isHiddenSessionSectionExpanded = false
        }
        synchronizeSelection()
        refreshOverlayPlacementIfVisible()
        updateAgentControlDeviceSnapshot()
        lastActionMessage = "Unhidden conversation: \(session.title)"
    }

    func toggleHiddenSessionSection() {
        isHiddenSessionSectionExpanded.toggle()
    }

    private func stateGroupedSections(
        for sessions: [AgentSession],
        at referenceDate: Date
    ) -> [IslandSessionSection] {
        let threshold = completedStaleThreshold.seconds
        let definitions: [(id: String, title: String, include: (AgentSession) -> Bool)] = [
            ("approval", "island.section.needsApproval", { $0.phase == .waitingForApproval }),
            ("answer", "island.section.needsAnswer", { $0.phase == .waitingForAnswer }),
            ("running", "island.section.inProgress", { $0.phase == .running }),
            ("done", "island.section.justDone", { session in
                session.isJustDoneForIsland(at: referenceDate, completedStaleThreshold: threshold)
            }),
            ("idle", "island.section.idle", { session in
                session.isIdleForIsland(at: referenceDate, completedStaleThreshold: threshold)
            }),
        ]

        return definitions.compactMap { definition in
            let list = sessions.filter(definition.include)
            guard !list.isEmpty else { return nil }
            return IslandSessionSection(id: "state-\(definition.id)", title: definition.title, sessions: list)
        }
    }

    private func projectGroupName(for session: AgentSession) -> String {
        if let workspace = session.jumpTarget?.workspaceName.trimmingCharacters(in: .whitespacesAndNewlines),
           !workspace.isEmpty {
            return workspace
        }

        let title = session.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return session.tool.displayName }

        let pieces = title.split(separator: "·", maxSplits: 1).map {
            String($0).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return pieces.last?.isEmpty == false ? pieces.last! : title
    }

    // MARK: - v6 closed-island derivation

    /// The aggregate UnifiedBars state for the closed island. Waiting beats
    /// running; everything else is idle. Completed sessions are absorbed
    /// directly into idle so the pill never stops on a tick glyph.
    var islandClosedMode: UnifiedBars.Mode {
        let sessions = surfacedSessions
        if sessions.contains(where: { $0.phase.requiresAttention }) { return .waiting }
        if sessions.contains(where: { $0.phase == .running })       { return .running }
        return .idle
    }

    var hasClosedIslandActivity: Bool {
        surfacedSessions.contains { session in
            session.phase == .running || session.phase.requiresAttention
        }
    }

    /// At most one mascot per provider, regardless of how many tasks that
    /// provider is running. Keep the stable Codex-then-Claude order when both
    /// are active so the leading slot never reshuffles.
    var islandClosedActivePets: [IslandLeadingPet] {
        let runningTools = Set(
            surfacedSessions
                .filter { $0.phase == .running }
                .map(\.tool)
        )

        return [
            runningTools.contains(.codex) ? .codex : nil,
            runningTools.contains(.claudeCode) ? .claude : nil,
        ].compactMap { $0 }
    }

    /// The spotlight session powering the center label (if any). Attention
    /// sessions first, then the most recent running one, then whatever's
    /// first.
    var islandClosedSpotlight: AgentSession? {
        surfacedSessions.first(where: { $0.phase.requiresAttention })
            ?? surfacedSessions.first(where: { $0.phase == .running })
            ?? surfacedSessions.first
    }

    /// Text to show in the closed island's center label. Respects the
    /// `islandCenterLabel` user preference.
    func islandClosedLabel() -> String? {
        guard islandCenterLabel != .off,
              let session = islandClosedSpotlight else { return nil }

        switch islandCenterLabel {
        case .off:
            return nil
        case .sessionName:
            let workspace = session.jumpTarget?.workspaceName ?? ""
            if !workspace.isEmpty { return workspace }
            return session.title.isEmpty ? session.tool.displayName : session.title
        case .agentAction:
            let action = session.displayCurrentToolName
            if let action, !action.isEmpty {
                return "\(session.tool.displayName) · \(action)"
            }
            return session.tool.displayName
        }
    }

    /// Right-slot payload derived from the user's `islandRightSlot`
    /// preference and current live state. Returns nil when the preference
    /// is `.none` or there's nothing meaningful to show.
    func agentControlSlotProjection(
        at referenceDate: Date = .now
    ) -> AgentControlSlotProjection {
        agentControlSlotCoordinator.projection(
            for: surfacedSessions,
            at: referenceDate,
            completedStaleThreshold: completedStaleThreshold.seconds
        )
    }

    func agentControlSlotLabel(
        for sessionID: String,
        at referenceDate: Date = .now
    ) -> String? {
        agentControlSlotProjection(at: referenceDate).keyLabel(for: sessionID)
    }

    func agentControlHardwareBadgeLabel(
        for sessionID: String,
        at referenceDate: Date = .now
    ) -> String? {
        guard agentControlKeyboardEnabled,
              let keyLabel = agentControlSlotLabel(
                for: sessionID,
                at: referenceDate
              ) else {
            return nil
        }
        return "K0 · \(keyLabel)"
    }

    var agentControlDeviceDiagnostics: AgentControlDeviceDiagnostics {
        agentControlDeviceCoordinator.diagnostics
    }

    /// Starts K0 Max state projection and navigation intent handling.
    /// Kept internal for deterministic tests.
    func startAgentControlDeviceIntegrationIfNeeded() {
        guard agentControlKeyboardEnabled,
              !isAgentControlDeviceIntegrationStarted else {
            return
        }

        isAgentControlDeviceIntegrationStarted = true
        updateAgentControlDeviceSnapshot()
        agentControlDeviceCoordinator.start()
    }

    private func stopAgentControlDeviceIntegration() {
        agentControlSnapshotRefreshTask?.cancel()
        agentControlSnapshotRefreshTask = nil
        agentControlSelection = nil
        guard isAgentControlDeviceIntegrationStarted else { return }

        // Clear immediately while the connection is still live. Firmware's
        // watchdog remains the fallback if the report cannot be delivered.
        agentControlDeviceCoordinator.setSnapshot(.empty)
        agentControlDeviceCoordinator.stop()
        isAgentControlDeviceIntegrationStarted = false
    }

    private func updateAgentControlDeviceSnapshot(
        at referenceDate: Date = .now
    ) {
        guard agentControlKeyboardEnabled,
              isAgentControlDeviceIntegrationStarted else {
            return
        }

        let projection = agentControlSlotProjection(at: referenceDate)
        agentControlDeviceCoordinator.setSnapshot(
            AgentControlSnapshotContent(
                slots: projection.slots.map { slot in
                    slot.map {
                        AgentControlSnapshotSlot(
                            identity: $0.sessionID,
                            lightState: $0.lightState
                        )
                    }
                },
                overflowCount: projection.overflowCount
            )
        )
        scheduleAgentControlCompletionExpiry(
            after: referenceDate
        )
    }

    private func handleAgentControlDeviceEvent(
        _ event: AgentControlDeviceEvent
    ) {
        switch event.message {
        case let .slotSelected(
            connectionNonce,
            slotIndex,
            snapshotGeneration
        ):
            handleAgentControlSlotSelection(
                requestSequence: event.sequence,
                connectionNonce: connectionNonce,
                slotIndex: slotIndex,
                snapshotGeneration: snapshotGeneration
            )

        case let .actionInvoked(
            connectionNonce,
            slotIndex,
            action,
            selectionToken
        ):
            handleAgentControlAction(
                requestSequence: event.sequence,
                connectionNonce: connectionNonce,
                slotIndex: slotIndex,
                action: action,
                selectionToken: selectionToken
            )

        case .layerChanged:
            agentControlSelection = nil

        case .capabilities:
            break
        }
    }

    private func handleAgentControlSlotSelection(
        requestSequence: UInt16,
        connectionNonce: UInt64,
        slotIndex: UInt8,
        snapshotGeneration: UInt16
    ) {
        agentControlSelection = nil

        guard Int(slotIndex) < AgentControlProtocolV1.slotCount else {
            rejectAgentControlSelection(
                requestSequence: requestSequence,
                connectionNonce: connectionNonce,
                slotIndex: slotIndex,
                result: .unsupported
            )
            return
        }
        guard let snapshot = agentControlDeviceCoordinator.currentSnapshot,
              snapshot.connectionNonce == connectionNonce else {
            rejectAgentControlSelection(
                requestSequence: requestSequence,
                connectionNonce: connectionNonce,
                slotIndex: slotIndex,
                result: .appUnavailable
            )
            return
        }
        guard snapshot.generation == snapshotGeneration else {
            rejectAgentControlSelection(
                requestSequence: requestSequence,
                connectionNonce: connectionNonce,
                slotIndex: slotIndex,
                result: .staleSnapshot
            )
            return
        }

        let index = Int(slotIndex)
        guard let slot = snapshot.content.slots[index] else {
            rejectAgentControlSelection(
                requestSequence: requestSequence,
                connectionNonce: connectionNonce,
                slotIndex: slotIndex,
                result: .unassigned
            )
            return
        }
        guard let session = surfacedSessions.first(
            where: { $0.id == slot.identity }
        ) else {
            rejectAgentControlSelection(
                requestSequence: requestSequence,
                connectionNonce: connectionNonce,
                slotIndex: slotIndex,
                result: .sessionUnavailable
            )
            return
        }

        let slotEpoch = snapshot.slotEpochs[index]
        var selectionToken = agentControlSelectionTokenGenerator()
        if selectionToken == 0 {
            selectionToken = 1
        }
        let allowedActions: AgentControlAllowedActionSet =
            canJumpToAgentControlSession(session) ? [.jump] : []
        let lifetimeSeconds = Self.agentControlSelectionLifetimeSeconds
        let selection = AgentControlSelectionContext(
            connectionNonce: connectionNonce,
            slotIndex: slotIndex,
            slotEpoch: slotEpoch,
            sessionID: session.id,
            selectionToken: selectionToken,
            allowedActions: allowedActions,
            expiresAt: agentControlDateProvider().addingTimeInterval(
                TimeInterval(lifetimeSeconds)
            )
        )

        guard agentControlDeviceCoordinator.sendSelectionAcknowledgement(
            requestSequence: requestSequence,
            connectionNonce: connectionNonce,
            slotIndex: slotIndex,
            result: .accepted,
            slotEpoch: slotEpoch,
            selectionToken: selectionToken,
            allowedActions: allowedActions,
            lifetimeSeconds: lifetimeSeconds
        ) else {
            return
        }

        agentControlSelection = selection
        select(sessionID: session.id)
        notchOpen(
            reason: .click,
            surface: .sessionList(actionableSessionID: session.id)
        )
    }

    private func rejectAgentControlSelection(
        requestSequence: UInt16,
        connectionNonce: UInt64,
        slotIndex: UInt8,
        result: AgentControlSelectionResult
    ) {
        agentControlDeviceCoordinator.sendSelectionAcknowledgement(
            requestSequence: requestSequence,
            connectionNonce: connectionNonce,
            slotIndex: slotIndex,
            result: result
        )
    }

    private func handleAgentControlAction(
        requestSequence: UInt16,
        connectionNonce: UInt64,
        slotIndex: UInt8,
        action: AgentControlAction,
        selectionToken: UInt64
    ) {
        guard action == .jump else {
            sendAgentControlActionResult(
                requestSequence: requestSequence,
                connectionNonce: connectionNonce,
                slotIndex: slotIndex,
                action: action,
                result: .unsupported
            )
            return
        }
        guard let selection = agentControlSelection else {
            sendAgentControlActionResult(
                requestSequence: requestSequence,
                connectionNonce: connectionNonce,
                slotIndex: slotIndex,
                action: action,
                result: .noValidSelection
            )
            return
        }
        guard selection.connectionNonce == connectionNonce,
              selection.slotIndex == slotIndex,
              selection.selectionToken == selectionToken,
              agentControlDateProvider() < selection.expiresAt else {
            agentControlSelection = nil
            sendAgentControlActionResult(
                requestSequence: requestSequence,
                connectionNonce: connectionNonce,
                slotIndex: slotIndex,
                action: action,
                result: .staleOrUnknownToken
            )
            return
        }
        guard selection.allowedActions.contains(.jump) else {
            sendAgentControlActionResult(
                requestSequence: requestSequence,
                connectionNonce: connectionNonce,
                slotIndex: slotIndex,
                action: action,
                result: .actionUnavailable
            )
            return
        }
        let index = Int(slotIndex)
        guard let snapshot = agentControlDeviceCoordinator.currentSnapshot,
              snapshot.connectionNonce == connectionNonce,
              index < snapshot.content.slots.count,
              index < snapshot.slotEpochs.count,
              snapshot.slotEpochs[index] == selection.slotEpoch,
              snapshot.content.slots[index]?.identity
                == selection.sessionID else {
            agentControlSelection = nil
            sendAgentControlActionResult(
                requestSequence: requestSequence,
                connectionNonce: connectionNonce,
                slotIndex: slotIndex,
                action: action,
                result: .slotUnassignedOrReused
            )
            return
        }
        guard let session = surfacedSessions.first(
            where: { $0.id == selection.sessionID }
        ) else {
            agentControlSelection = nil
            sendAgentControlActionResult(
                requestSequence: requestSequence,
                connectionNonce: connectionNonce,
                slotIndex: slotIndex,
                action: action,
                result: .slotUnassignedOrReused
            )
            return
        }
        guard canJumpToAgentControlSession(session) else {
            sendAgentControlActionResult(
                requestSequence: requestSequence,
                connectionNonce: connectionNonce,
                slotIndex: slotIndex,
                action: action,
                result: .transportUnavailable
            )
            return
        }

        guard sendAgentControlActionResult(
            requestSequence: requestSequence,
            connectionNonce: connectionNonce,
            slotIndex: slotIndex,
            action: action,
            result: .acceptedForDispatch
        ) else {
            return
        }
        jumpToSession(session)
    }

    @discardableResult
    private func sendAgentControlActionResult(
        requestSequence: UInt16,
        connectionNonce: UInt64,
        slotIndex: UInt8,
        action: AgentControlAction,
        result: AgentControlActionResult
    ) -> Bool {
        agentControlDeviceCoordinator.sendActionResult(
            requestSequence: requestSequence,
            connectionNonce: connectionNonce,
            slotIndex: slotIndex,
            action: action,
            result: result
        )
    }

    private func canJumpToAgentControlSession(
        _ session: AgentSession
    ) -> Bool {
        guard let jumpTarget = session.jumpTarget else { return false }
        return jumpTarget.terminalApp.lowercased() != "unknown"
    }

    private func scheduleAgentControlCompletionExpiry(
        after referenceDate: Date
    ) {
        agentControlSnapshotRefreshTask?.cancel()
        agentControlSnapshotRefreshTask = nil

        let threshold = completedStaleThreshold.seconds
        guard threshold.isFinite else { return }

        let nextExpiry = surfacedSessions.lazy
            .filter { session in
                session.phase == .completed
                    && !session.isSubagentSession
                    && !session.isRealtimeVoiceChatSession
            }
            .map { $0.updatedAt.addingTimeInterval(threshold) }
            .filter { $0 > referenceDate }
            .min()

        guard let nextExpiry else { return }
        let delay = max(
            nextExpiry.timeIntervalSince(referenceDate) + 0.01,
            0.01
        )
        agentControlSnapshotRefreshTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self?.updateAgentControlDeviceSnapshot()
        }
    }

    func islandClosedRightSlotContent(
        at referenceDate: Date = .now
    ) -> IslandRightSlotContent? {
        let sessions = surfacedSessions
        switch islandRightSlot {
        case .none:
            return nil
        case .count:
            let n = sessions.count
            guard n > 0 else { return nil }
            return .count(n)
        case .agents:
            let projection = agentControlSlotProjection(at: referenceDate)
            let sessionsByID = Dictionary(
                uniqueKeysWithValues: sessions.map { ($0.id, $0) }
            )
            let orderedCells = projection.assignedSlots.compactMap { slot in
                sessionsByID[slot.sessionID].map {
                    Self.agentsGridCell(for: $0, lightState: slot.lightState)
                }
            }
            let totalCount = orderedCells.count + projection.overflowCount
            var cells: [AgentGridCell] = []
            if totalCount <= 9 {
                cells = orderedCells
            } else {
                cells = Array(orderedCells.prefix(7))
                cells.append(.overflow(totalCount - 7))
            }
            return cells.isEmpty ? nil : .agents(cells)
        }
    }

    private static func agentsGridCell(
        for session: AgentSession,
        lightState: AgentControlLightState
    ) -> AgentGridCell {
        let color = Color(hex: session.tool.brandColorHex) ?? .gray
        let state: AgentGridCellState
        switch lightState {
        case .running:
            state = .running
        case .waitingForActionableApproval,
             .waitingForObservedApproval,
             .waitingForAnswer:
            state = .waiting
        case .idle, .recentlyCompleted:
            state = .idle
        }
        return .session(color: color, state: state)
    }

    var shouldShowSessionBootstrapPlaceholder: Bool {
        isResolvingInitialLiveSessions
            && liveSessionCount == 0
            && state.sessions.contains(where: \.isTrackedLiveSession)
    }

    var focusedSession: AgentSession? {
        if let selectedSessionID,
           let selectedSession = state.session(id: selectedSessionID),
           shouldSurfaceSession(selectedSession) {
            return selectedSession
        }

        return surfacedSessions.first
    }

    var activeIslandCardSession: AgentSession? {
        guard let sessionID = islandSurface.sessionID else {
            return nil
        }

        return state.session(id: sessionID)
    }

    var hasAnySession: Bool {
        !sessions.isEmpty
    }

    var hasCodexSession: Bool {
        sessions.contains(where: { $0.tool == .codex })
    }

    var hasJumpableSession: Bool {
        sessions.contains(where: { $0.jumpTarget != nil })
    }

    var acceptanceSteps: [AcceptanceStep] {
        [
            AcceptanceStep(
                id: "bridge",
                title: "Bridge ready",
                detail: "The app must own the local socket and register as a bridge observer.",
                isComplete: isBridgeReady
            ),
            AcceptanceStep(
                id: "hooks",
                title: "Codex hooks installed",
                detail: "Managed `hooks.json` entries should be present in `~/.codex`.",
                isComplete: hooks.codexHooksInstalled
            ),
            AcceptanceStep(
                id: "overlay",
                title: "Island visible",
                detail: "Show the overlay at least once so the notch/top-bar surface is visible.",
                isComplete: isOverlayVisible
            ),
            AcceptanceStep(
                id: "session",
                title: "A Codex session is observed",
                detail: "Start Codex in Terminal and wait for the first session row to appear.",
                isComplete: hasCodexSession
            ),
            AcceptanceStep(
                id: "jump",
                title: "Jump target captured",
                detail: "At least one session should include terminal jump metadata.",
                isComplete: hasJumpableSession
            ),
        ]
    }

    var acceptanceCompletedCount: Int {
        acceptanceSteps.filter(\.isComplete).count
    }

    var isReadyForFirstAcceptance: Bool {
        acceptanceSteps.prefix(3).allSatisfy(\.isComplete)
    }

    var hasPassedAcceptanceFlow: Bool {
        acceptanceSteps.allSatisfy(\.isComplete)
    }

    var acceptanceStatusTitle: String {
        if hasPassedAcceptanceFlow {
            return "v0.1 acceptance passed"
        }

        if isReadyForFirstAcceptance {
            return "Ready for v0.1 acceptance"
        }

        return "v0.1 acceptance not ready"
    }

    var acceptanceStatusSummary: String {
        if hasPassedAcceptanceFlow {
            return "The current build has completed the first-run checklist end to end."
        }

        if isReadyForFirstAcceptance {
            return "You can start your first acceptance run now. Launch Codex in Terminal and walk the last two steps."
        }

        return "Finish the setup steps in the left column, then start Codex from Terminal."
    }

    func startIfNeeded(
        startBridge: Bool = true,
        shouldPerformBootAnimation: Bool = true,
        loadRuntimeState: Bool = true
    ) {
        guard !hasStarted else {
            return
        }
        hasStarted = true
        startAgentControlDeviceIntegrationIfNeeded()

        if loadRuntimeState {
            isResolvingInitialLiveSessions = true

            Task.detached(priority: .userInitiated) { [weak self] in
                guard let self else { return }
                let payload = self.discovery.loadStartupDiscoveryPayload()
                await MainActor.run {
                    self.applyStartupDiscoveryPayload(payload)
                }
            }

            // These are already async or lightweight — safe to start immediately.
            hooks.refreshCodexHookStatus()
            hooks.refreshClaudeHookStatus()
            hooks.refreshCCForkHookStatuses()
            hooks.refreshOpenCodePluginStatus()
            hooks.refreshCursorHookStatus()
            hooks.refreshClaudeUsageState()
            hooks.startClaudeUsageMonitoringIfNeeded()
            if showCodexUsage {
                hooks.refreshCodexUsageState()
                hooks.startCodexUsageMonitoringIfNeeded()
            }
            updateChecker.startIfNeeded()

        } else {
            isResolvingInitialLiveSessions = false
        }
        refreshOverlayDisplayConfiguration()
        ensureOverlayPanel()
        if shouldPerformBootAnimation {
            performBootAnimation()
        }

        guard startBridge else {
            isBridgeReady = false
            lastActionMessage = loadRuntimeState
                ? "Harness mode active. Bridge startup skipped."
                : "Deterministic harness mode active. Runtime discovery and bridge startup skipped."
            harnessRuntimeMonitor?.recordMilestone("bridgeSkipped", message: lastActionMessage)
            return
        }

        do {
            try bridgeServer.start()
            connectBridgeObserver()
        } catch {
            isBridgeReady = false
            lastActionMessage = "Failed to start local bridge: \(error.localizedDescription)"
            harnessRuntimeMonitor?.recordMilestone("bridgeStartFailed", message: lastActionMessage)
        }
    }

    // MARK: - Bridge observer connection

    private static let bridgeReconnectDelay: Duration = .seconds(2)
    private static let bridgeMaxReconnectDelay: Duration = .seconds(30)

    private func connectBridgeObserver() {
        bridgeTask?.cancel()
        bridgeReconnectTask?.cancel()

        // Explicitly disconnect the old client so its DispatchSource is
        // cancelled deterministically rather than relying on dealloc timing.
        bridgeClient.disconnect()

        // Create a fresh client for each connection attempt so we don't
        // have to worry about stale file-descriptor state.
        let client = LocalBridgeClient()
        bridgeClient = client

        let stream: AsyncThrowingStream<AgentEvent, Error>
        do {
            stream = try client.connect()
        } catch {
            isBridgeReady = false
            lastActionMessage = "Failed to connect bridge observer: \(error.localizedDescription)"
            scheduleBridgeReconnect()
            return
        }

        // A single task handles both registration and event consumption so
        // there is no untracked task that could race with a reconnect.
        bridgeTask = Task { [weak self] in
            guard let self else { return }

            do {
                try await client.send(.registerClient(role: .observer))
                self.isBridgeReady = true
                self.lastActionMessage = "Bridge ready. Waiting for Claude and Codex hook events."
                self.harnessRuntimeMonitor?.recordMilestone("bridgeReady", message: self.lastActionMessage)
            } catch {
                guard !Task.isCancelled else { return }
                self.isBridgeReady = false
                self.lastActionMessage = "Failed to register bridge observer: \(error.localizedDescription)"
                self.harnessRuntimeMonitor?.recordMilestone(
                    "bridgeRegistrationFailed",
                    message: self.lastActionMessage
                )
                self.scheduleBridgeReconnect()
                return
            }

            do {
                for try await event in stream {
                    self.applyTrackedEvent(event)
                }
            } catch {}

            // Stream ended (server closed our connection or transient error).
            // Mark as disconnected and schedule reconnection.
            guard !Task.isCancelled else { return }
            self.isBridgeReady = false
            self.lastActionMessage = "Bridge observer disconnected. Reconnecting…"
            self.harnessRuntimeMonitor?.recordMilestone("bridgeDisconnected", message: self.lastActionMessage)
            self.scheduleBridgeReconnect()
        }
    }

    private func scheduleBridgeReconnect() {
        bridgeReconnectTask?.cancel()
        bridgeReconnectTask = Task { [weak self] in
            var delay = Self.bridgeReconnectDelay
            while !Task.isCancelled {
                try? await Task.sleep(for: delay)
                guard let self, !Task.isCancelled else { return }
                self.connectBridgeObserver()
                // If we're now connected, stop retrying.
                if self.isBridgeReady { return }
                delay = min(delay * 2, Self.bridgeMaxReconnectDelay)
            }
        }
    }

    func select(sessionID: String) {
        selectedSessionID = sessionID
    }

    // MARK: - Overlay forwarding

    func toggleOverlay() { overlay.toggleOverlay() }
    func notchOpen(reason: NotchOpenReason, surface: IslandSurface = .sessionList()) { overlay.notchOpen(reason: reason, surface: surface) }
    func notchClose() { overlay.notchClose() }
    func notchPop() { overlay.notchPop() }
    func performBootAnimation() { overlay.performBootAnimation() }
    func ensureOverlayPanel() { overlay.ensureOverlayPanel() }
    func showOverlay() { overlay.showOverlay() }
    func hideOverlay() { overlay.hideOverlay() }
    func expandNotificationToSessionList(clearExpansion: Bool = false) {
        overlay.expandNotificationToSessionList(clearExpansion: clearExpansion)
    }
    func refreshOverlayDisplayConfiguration() { overlay.refreshOverlayDisplayConfiguration() }
    func refreshOverlayPlacement() { overlay.refreshOverlayPlacement() }
    private func refreshOverlayPlacementIfVisible() { overlay.refreshOverlayPlacementIfVisible() }
    func notePointerInsideIslandSurface() { overlay.notePointerInsideIslandSurface() }
    func handlePointerExitedIslandSurface() { overlay.handlePointerExitedIslandSurface() }
    private func presentNotificationSurface(_ surface: IslandSurface) { overlay.presentNotificationSurface(surface) }
    private func reconcileIslandSurfaceAfterStateChange() { overlay.reconcileIslandSurfaceAfterStateChange() }
    private func dismissNotificationSurfaceIfPresent(for sessionID: String) { overlay.dismissNotificationSurfaceIfPresent(for: sessionID) }
    private func dismissOverlayForJump() { overlay.dismissOverlayForJump() }

    var shouldAutoCollapseOnMouseLeave: Bool { overlay.shouldAutoCollapseOnMouseLeave }
    var autoCollapseOnMouseLeaveRequiresPriorSurfaceEntry: Bool { overlay.autoCollapseOnMouseLeaveRequiresPriorSurfaceEntry }
    var showsNotificationCard: Bool { overlay.showsNotificationCard }
    var shouldDeferTimedNotificationAutoCollapse: Bool { overlay.shouldDeferTimedNotificationAutoCollapse }
    var hasPendingNotificationAutoCollapse: Bool { overlay.hasPendingNotificationAutoCollapse }

    func loadDebugSnapshot(
        _ snapshot: IslandDebugSnapshot,
        presentOverlay: Bool = false,
        autoCollapseNotificationCards: Bool = false
    ) {
        state = SessionState(sessions: snapshot.sessions)
        selectedSessionID = snapshot.selectedSessionID ?? snapshot.sessions.first?.id
        lastActionMessage = "Loaded debug scenario: \(snapshot.title)."
        harnessRuntimeMonitor?.recordMilestone("scenarioLoaded", message: snapshot.title)

        overlay.applyOverlayState(from: snapshot, presentOverlay: presentOverlay, autoCollapseNotificationCards: autoCollapseNotificationCards)
    }

    func showSettings() {
        if let opener = openSettingsWindow {
            opener()
        } else {
            // First-launch fallback: SwiftUI's `openWindow` closure is registered
            // by `SettingsWindowContent.onAppear`, which doesn't fire until the
            // settings window renders the first time. Send the standard
            // `showSettingsWindow:` responder action (macOS 13+) so it fires
            // the `CommandGroup(.appSettings)` button that opens the window.
            NSApp.sendAction(NSSelectorFromString("showSettingsWindow:"), to: nil, from: nil)
        }
        if let window = NSApp.windows.first(where: { $0.title == "Agent-Island Settings" }) {
            window.orderFrontRegardless()
            window.makeKey()
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Opens Settings on the Setup tab so the user can install hooks.
    /// Used by every "Set up agents" CTA in the empty-state UI. A
    /// dedicated first-run onboarding window will replace this in a
    /// later PR; until then this is the canonical entry point.
    func showOnboarding() {
        showSettings()
        NotificationCenter.default.post(name: .agentIslandSelectSetupTab, object: nil)
    }

    var isSessionRefreshInProgress: Bool {
        discovery.isManualRefreshInProgress
    }

    func refreshSessionsManually() {
        discovery.refreshCodexAppSessions()
    }

    func approveFocusedPermission(_ approved: Bool) {
        guard let session = focusedSession else {
            return
        }

        send(
            .resolvePermission(sessionID: session.id, resolution: permissionResolution(for: approved)),
            userMessage: approved
                ? "Approving permission for \(session.title)."
                : "Denying permission for \(session.title)."
        )
    }

    func answerFocusedQuestion(_ answer: String) {
        guard let session = focusedSession else {
            return
        }

        send(
            .answerQuestion(sessionID: session.id, response: QuestionPromptResponse(answer: answer)),
            userMessage: "Sending answer \"\(answer)\" for \(session.title)."
        )
    }

    func jumpToFocusedSession() {
        jump(to: focusedSession?.jumpTarget)
    }

    func jumpToSession(_ session: AgentSession) {
        guard let jumpTarget = session.jumpTarget,
              jumpTarget.terminalApp.lowercased() != "unknown" else {
            lastActionMessage = "Cannot jump: terminal app is unknown."
            return
        }
        jump(to: jumpTarget)
    }

    private func jump(to jumpTarget: JumpTarget?) {
        guard let jumpTarget else {
            lastActionMessage = "No jump target is available yet."
            return
        }

        let shouldDelayForDismissAnimation = isOverlayVisible
        let jumpAction = terminalJumpAction

        dismissOverlayForJump()
        jumpTask?.cancel()
        jumpTask = Task { [weak self] in
            if shouldDelayForDismissAnimation {
                try? await Task.sleep(for: Self.jumpOverlayDismissLeadTime)
            }

            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try jumpAction(jumpTarget)
                }.value

                guard !Task.isCancelled else {
                    return
                }

                self?.lastActionMessage = result
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else {
                    return
                }

                self?.lastActionMessage = "Jump failed: \(error.localizedDescription)"
            }
        }
    }

    func approvePermission(for sessionID: String, approved: Bool) {
        guard let session = state.session(id: sessionID) else {
            return
        }

        let resolution = permissionResolution(for: approved)
        dismissNotificationSurfaceIfPresent(for: sessionID)
        state.resolvePermission(sessionID: session.id, resolution: resolution)
        synchronizeSelection()
        refreshOverlayPlacementIfVisible()

        send(
            .resolvePermission(sessionID: session.id, resolution: resolution),
            userMessage: approved
                ? "Approving permission for \(session.title)."
                : "Denying permission for \(session.title)."
        )
    }

    func approvePermission(for sessionID: String, action: ApprovalAction) {
        guard let session = state.session(id: sessionID) else {
            return
        }

        let resolution: PermissionResolution
        let message: String

        switch action {
        case .deny:
            resolution = .deny(message: "Permission denied in Agent-Island.", interrupt: false)
            message = "Denying permission for \(session.title)."
        case .allowOnce:
            resolution = .allowOnce()
            message = "Approving permission for \(session.title)."
        case let .allowWithUpdates(updates):
            resolution = .allowOnce(updatedPermissions: updates)
            message = "Always allowing for \(session.title)."
        }

        dismissNotificationSurfaceIfPresent(for: sessionID)
        state.resolvePermission(sessionID: session.id, resolution: resolution)
        synchronizeSelection()
        refreshOverlayPlacementIfVisible()

        send(
            .resolvePermission(sessionID: session.id, resolution: resolution),
            userMessage: message
        )
    }

    func dismissSession(_ sessionID: String) {
        state.dismissSession(id: sessionID)
        dismissNotificationSurfaceIfPresent(for: sessionID)
        synchronizeSelection()
    }

    func answerQuestion(for sessionID: String, answer: QuestionPromptResponse) {
        guard let session = state.session(id: sessionID) else {
            return
        }

        dismissNotificationSurfaceIfPresent(for: sessionID)
        state.answerQuestion(sessionID: session.id, response: answer)
        synchronizeSelection()
        refreshOverlayPlacementIfVisible()

        send(
            .answerQuestion(sessionID: session.id, response: answer),
            userMessage: "Sending answer for \(session.title)."
        )
    }

    func replyToSession(_ session: AgentSession, text: String) {
        dismissNotificationSurfaceIfPresent(for: session.id)
        synchronizeSelection()
        refreshOverlayPlacementIfVisible()

        lastActionMessage = "Sending reply to \(session.title)…"

        Task { [weak self] in
            let success = await Task.detached(priority: .userInitiated) {
                TerminalTextSender.send(text, to: session)
            }.value

            self?.lastActionMessage = success
                ? "Sent reply to \(session.title)."
                : "Failed to send reply to \(session.title)."
        }
    }


    private func send(_ command: BridgeCommand, userMessage: String) {
        lastActionMessage = userMessage

        Task { [weak self] in
            guard let self else {
                return
            }

            do {
                try await self.bridgeClient.send(command)
            } catch {
                self.lastActionMessage = "Failed to send bridge command: \(error.localizedDescription)"
            }
        }
    }

    private func permissionResolution(for approved: Bool) -> PermissionResolution {
        if approved {
            return .allowOnce()
        }

        return .deny(message: "Permission denied in Agent-Island.", interrupt: false)
    }

    func applyTrackedEvent(
        _ event: AgentEvent,
        updateLastActionMessage: Bool = true,
        ingress: TrackedEventIngress = .bridge
    ) {
        // Snapshot whether this session was already completed before applying
        // the event. Used to suppress duplicate/stale completion notifications
        // (e.g. rollout watcher re-discovering an old completion on startup,
        // or producing a duplicate sessionCompleted that races with the bridge).
        let wasAlreadyCompleted: Bool = {
            guard case let .sessionCompleted(payload) = event else { return false }
            return state.session(id: payload.sessionID)?.phase == .completed
        }()

        // Guard: don't let rollout events downgrade a session from completed
        // back to running. The bridge's sessionCompleted is authoritative; the
        // rollout watcher may have read the JSONL before task_complete was
        // flushed, producing a stale activityUpdated(phase: .running).
        if ingress == .rollout,
           case let .activityUpdated(payload) = event,
           payload.phase == .running,
           state.session(id: payload.sessionID)?.phase == .completed {
            return
        }

        // Rollout file notifications may arrive after the app-server has
        // already reported newer activity for the same thread. Applying that
        // stale completion would briefly open a finished card before the
        // current running state closes it again.
        if ingress == .rollout,
           case let .sessionCompleted(payload) = event,
           let current = state.session(id: payload.sessionID),
           current.phase != .completed,
           current.updatedAt > payload.timestamp {
            return
        }

        state.apply(event)
        reconcileIslandSurfaceAfterStateChange()
        if ingress == .bridge {
            monitoring.markSessionAttached(for: event)
            monitoring.markSessionProcessAlive(for: event)
        }
        synchronizeSelection()
        discovery.refreshCodexRolloutTracking()
        refreshOverlayPlacementIfVisible()
        discovery.scheduleCodexSessionPersistence()
        discovery.scheduleClaudeSessionPersistence()
        discovery.scheduleOpenCodeSessionPersistence()
        discovery.scheduleCursorSessionPersistence()

        // Push relevant events to the Watch/iPhone via the relay
        if let relay = watchRelay {
            let eventSessionID: String? = {
                switch event {
                case let .sessionStarted(p): return p.sessionID
                case let .sessionTitleUpdated(p): return p.sessionID
                case let .activityUpdated(p): return p.sessionID
                case let .permissionRequested(p): return p.sessionID
                case let .questionAsked(p): return p.sessionID
                case let .sessionCompleted(p): return p.sessionID
                case let .jumpTargetUpdated(p): return p.sessionID
                case let .sessionMetadataUpdated(p): return p.sessionID
                case let .claudeSessionMetadataUpdated(p): return p.sessionID
                case let .geminiSessionMetadataUpdated(p): return p.sessionID
                case let .openCodeSessionMetadataUpdated(p): return p.sessionID
                case let .cursorSessionMetadataUpdated(p): return p.sessionID
                case let .actionableStateResolved(p): return p.sessionID
                }
            }()
            let session = eventSessionID.flatMap { state.session(id: $0) }
            if shouldExposeEventFromHiddenSession(event, session: session) {
                relay.notifyEvent(event, session: session)
            }
        }

        if updateLastActionMessage {
            lastActionMessage = describe(event)
        }

        if let surface = IslandSurface.notificationSurface(for: event) {
            scheduleNotificationSurfacePresentationIfNeeded(
                surface,
                wasAlreadyCompleted: wasAlreadyCompleted,
                ingress: ingress
            )
        }
    }

    private func scheduleNotificationSurfacePresentationIfNeeded(
        _ surface: IslandSurface,
        wasAlreadyCompleted: Bool,
        ingress: TrackedEventIngress
    ) {
        guard !wasAlreadyCompleted,
              notificationSurfaceIsEligibleForPresentation(surface, ingress: ingress),
              let sessionID = surface.sessionID,
              let session = state.session(id: sessionID) else {
            return
        }

        guard suppressFrontmostNotifications else {
            presentNotificationSurface(surface)
            return
        }

        notificationPresentationTask?.cancel()
        notificationPresentationTask = Task { @MainActor [weak self] in
            guard let self else {
                return
            }

            let shouldSuppress = await self.isNotificationSessionAlreadyFrontmost(session)
            guard !Task.isCancelled,
                  !shouldSuppress,
                  self.notificationSurfaceIsEligibleForPresentation(surface, ingress: ingress) else {
                return
            }

            self.presentNotificationSurface(surface)
        }
    }

    private func notificationSurfaceIsEligibleForPresentation(
        _ surface: IslandSurface,
        ingress: TrackedEventIngress
    ) -> Bool {
        guard let sessionID = surface.sessionID,
              let session = state.session(id: sessionID) else {
            return false
        }

        return (ingress == .bridge || !isResolvingInitialLiveSessions)
            && (!isSessionHidden(session) || session.phase == .waitingForApproval)
            && (notchStatus == .closed || notchOpenReason == .notification)
            && !overlay.shouldPreserveCurrentNotificationSurface(against: surface)
            && surface.matchesCurrentState(of: session)
    }

    func shouldExposeEventFromHiddenSession(
        _ event: AgentEvent,
        session: AgentSession?
    ) -> Bool {
        guard let session, isSessionHidden(session) else { return true }
        if case .permissionRequested = event {
            return true
        }
        return false
    }

    private func synchronizeSelection() {
        let surfacedIDs = Set(surfacedSessions.map(\.id))

        if let activeAction = surfacedSessions.first(where: { $0.phase.requiresAttention }) {
            selectedSessionID = activeAction.id
            return
        }

        guard let selectedSessionID,
              surfacedIDs.contains(selectedSessionID),
              state.session(id: selectedSessionID) != nil else {
            self.selectedSessionID = surfacedSessions.first?.id
            return
        }
    }

    /// Applies startup discovery results on the main thread after background I/O completes.
    private func applyStartupDiscoveryPayload(_ payload: SessionDiscoveryCoordinator.StartupDiscoveryPayload) {
        discovery.applyStartupDiscoveryPayload(payload)

        // Apply hooks binary URL and update the installed copy if the app ships a newer version.
        hooks.hooksBinaryURL = payload.hooksBinaryURL
        hooks.updateHooksBinaryIfNeeded()

        // Auto-install missing hooks and usage bridge, then run health checks.
        if payload.hooksBinaryURL != nil {
            Task { @MainActor [weak self] in
                guard let self else { return }

                // Wait for all status reads to complete before checking install state.
                await self.hooks.refreshAllHookStatusAndWait()

                // Reconcile persisted intent with what is actually on disk. For
                // legacy users this records existing hooks as `.installed` and
                // marks first-launch as complete so onboarding does not appear
                // on upgrade. Must run after status reads and before any
                // install decision.
                self.hooks.migrateIntentStoreIfNeeded()

                // Install only hooks the user has not explicitly opted out of.
                // `shouldAutoInstall` skips `.uninstalled` agents and agents
                // whose hooks are already present — it is the single checkpoint
                // that fixes #324.
                if self.hooks.shouldAutoInstall(.claudeCode) { self.installClaudeHooks() }
                if self.hooks.shouldAutoInstall(.codex) { self.installCodexHooks() }
                if self.hooks.shouldAutoInstall(.qoder) { self.installQoderHooks() }
                if self.hooks.shouldAutoInstall(.qwenCode) { self.installQwenCodeHooks() }
                if self.hooks.shouldAutoInstall(.factory) { self.installFactoryHooks() }
                if self.hooks.shouldAutoInstall(.codebuddy) { self.installCodebuddyHooks() }
                if self.hooks.shouldAutoInstall(.openCode) { self.installOpenCodePlugin() }
                if self.hooks.shouldAutoInstall(.cursor) { self.installCursorHooks() }
                if self.hooks.shouldAutoInstall(.gemini) { self.installGeminiHooks() }
                if self.hooks.shouldAutoInstall(.kimi) { self.installKimiHooks() }
                if self.hooks.shouldAutoInstall(.claudeUsageBridge) { self.installClaudeUsageBridge() }

                // Run health checks after install to detect stale paths, conflicts, etc.
                try? await Task.sleep(for: .milliseconds(500))
                await self.hooks.repairHooksIfNeeded()
            }
        }

        // Reconcile attachments and start monitoring (requires sessions to be loaded).
        monitoring.reconcileSessionAttachments()
        monitoring.startMonitoringIfNeeded()
    }


    private var sessionBuckets: (primary: [AgentSession], overflow: [AgentSession]) {
        let now = Date.now
        if let cached = _cachedSessionBuckets,
           cached.validThrough.map({ now <= $0 }) ?? true {
            return (cached.primary, cached.overflow)
        }
        let result = computeSessionBuckets(at: now)
        let validThrough = result.primary
            .filter { $0.phase == .completed }
            .map { $0.islandActivityDate.addingTimeInterval(AgentSession.islandCompletedVisibilityWindow) }
            .min()
        _cachedSessionBuckets = SessionBucketCache(
            primary: result.primary,
            overflow: result.overflow,
            validThrough: validThrough
        )
        return result
    }

    private func computeSessionBuckets(at now: Date) -> (primary: [AgentSession], overflow: [AgentSession]) {
        let rankedSessions = state.sessions.sorted { lhs, rhs in
            let lhsScore = displayPriority(for: lhs, now: now)
            let rhsScore = displayPriority(for: rhs, now: now)

            if lhsScore == rhsScore {
                if lhs.islandActivityDate == rhs.islandActivityDate {
                    return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
                }

                return lhs.islandActivityDate > rhs.islandActivityDate
            }

            return lhsScore > rhsScore
        }

        var primary: [AgentSession] = []
        var claimedLiveAttachmentKeys: Set<String> = []

        for session in rankedSessions where session.isVisibleInIslandSessionList(at: now) {
            guard !session.isSubagentSession else { continue }

            if let liveAttachmentKey = monitoring.liveAttachmentKey(for: session) {
                guard claimedLiveAttachmentKeys.insert(liveAttachmentKey).inserted else {
                    continue
                }
            }

            primary.append(session)
        }

        let primaryIDs = Set(primary.map(\.id))
        let overflow = rankedSessions.filter {
            !primaryIDs.contains($0.id)
                && !$0.isSubagentSession
                && !$0.isRealtimeVoiceChatSession
        }
        return (primary, overflow)
    }

    private func displayPriority(for session: AgentSession, now: Date) -> Int {
        var score = 0

        let presence = session.islandPresence(at: now)

        if session.isProcessAlive {
            score += presence == .inactive ? 3_000 : 12_000
        } else if session.isDemoSession || session.phase.requiresAttention {
            score += 6_000
        }

        if session.phase.requiresAttention {
            score += 10_000
        }

        if session.currentToolName?.isEmpty == false {
            score += 6_000
        }

        if session.jumpTarget != nil {
            score += 4_000
        }

        switch session.phase {
        case .running:
            score += 2_000
        case .waitingForApproval:
            score += 1_500
        case .waitingForAnswer:
            score += 1_200
        case .completed:
            score += 600
        }

        // `now` here is computeSessionBuckets' own clock, which feeds
        // _cachedSessionBuckets — a ranking clock, not the bucket-membership
        // clock the sections and header share. Threading the view's
        // referenceDate through would defeat that cache for no behavioural gain.
        if session.isIdleForIsland(at: now, completedStaleThreshold: completedStaleThreshold.seconds) {
            score -= 900
        }

        let age = now.timeIntervalSince(session.islandActivityDate)
        switch age {
        case ..<120:
            score += 500
        case ..<900:
            score += 250
        case ..<3_600:
            score += 120
        case ..<21_600:
            score += 40
        default:
            break
        }

        return score
    }

    private func describe(_ event: AgentEvent) -> String {
        switch event {
        case let .sessionStarted(payload):
            return "Session started: \(payload.title)"
        case let .sessionTitleUpdated(payload):
            return "Session renamed: \(payload.title)"
        case let .activityUpdated(payload):
            return payload.summary
        case let .permissionRequested(payload):
            return payload.request.summary
        case let .questionAsked(payload):
            return payload.prompt.title
        case let .sessionCompleted(payload):
            return payload.summary
        case let .jumpTargetUpdated(payload):
            return "Jump target updated to \(payload.jumpTarget.terminalApp)."
        case let .sessionMetadataUpdated(payload):
            if let currentTool = payload.codexMetadata.currentTool {
                return "Codex is running \(currentTool)."
            }

            return payload.codexMetadata.lastAssistantMessage ?? "Codex session metadata updated."
        case let .claudeSessionMetadataUpdated(payload):
            if let currentTool = payload.claudeMetadata.currentTool {
                return "Claude is running \(currentTool)."
            }

            return payload.claudeMetadata.lastAssistantMessage ?? "Claude session metadata updated."
        case let .geminiSessionMetadataUpdated(payload):
            return payload.geminiMetadata.lastAssistantMessage ?? "Gemini session metadata updated."
        case let .openCodeSessionMetadataUpdated(payload):
            if let currentTool = payload.openCodeMetadata.currentTool {
                return "OpenCode is running \(currentTool)."
            }

            return payload.openCodeMetadata.lastAssistantMessage ?? "OpenCode session metadata updated."
        case let .cursorSessionMetadataUpdated(payload):
            if let currentTool = payload.cursorMetadata.currentTool {
                return "Cursor is running \(currentTool)."
            }

            return payload.cursorMetadata.lastAssistantMessage ?? "Cursor session metadata updated."
        case let .actionableStateResolved(payload):
            return "Actionable state resolved for session \(payload.sessionID)."
        }
    }

    func quitApplication() {
        NSApplication.shared.terminate(nil)
    }

}

// MARK: - Hex color helpers

extension String {
    var normalizedHexColorString: String {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        let raw = trimmed.hasPrefix("#") ? String(trimmed.dropFirst()) : trimmed
        guard raw.count == 6, raw.allSatisfy(\.isHexDigit) else { return "#6E9FFF" }
        return "#\(raw.uppercased())"
    }
}

extension Color {
    init?(hex: String) {
        let raw = String(hex.normalizedHexColorString.dropFirst())
        guard let value = Int(raw, radix: 16) else { return nil }
        let red = Double((value >> 16) & 0xFF) / 255
        let green = Double((value >> 8) & 0xFF) / 255
        let blue = Double(value & 0xFF) / 255
        self = Color(red: red, green: green, blue: blue)
    }

    var opaqueHexString: String? {
        guard let nsColor = NSColor(self).usingColorSpace(.deviceRGB) else { return nil }
        let r = Int(round(nsColor.redComponent * 255))
        let g = Int(round(nsColor.greenComponent * 255))
        let b = Int(round(nsColor.blueComponent * 255))
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}
