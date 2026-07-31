import AppKit
import ApplicationServices
import Foundation
import OSLog
import AgentIslandCore

enum CodexNativeApprovalRemoteError: Error, LocalizedError {
    case missingThread
    case appUnavailable
    case appDidNotActivate
    case accessibilityPermissionRequired
    case approvalControlUnavailable
    case approvalControlDidNotRespond
    case approvalControlFailed(AXError)

    var errorDescription: String? {
        switch self {
        case .missingThread:
            "The Codex task does not have a thread identifier."
        case .appUnavailable:
            "Codex Desktop is not running."
        case .appDidNotActivate:
            "Codex Desktop did not become active."
        case .accessibilityPermissionRequired:
            "Agent Island needs Accessibility permission to control Codex."
        case .approvalControlUnavailable:
            "Codex's native approval control was not available."
        case .approvalControlDidNotRespond:
            "Codex's native approval control did not dismiss the prompt."
        case let .approvalControlFailed(error):
            "Codex's native approval control could not be pressed (\(error.rawValue))."
        }
    }
}

/// Resolves an approval by pressing the control owned by Codex Desktop.
///
/// This intentionally does not answer an app-server request or return a hook
/// decision. Codex remains authoritative for policy and auto-review; Agent
/// Island only focuses the exact task and invokes the visible native control.
struct CodexNativeApprovalRemote {
    private static let logger = Logger(
        subsystem: "app.agentisland.dev",
        category: "CodexNativeApprovalRemote"
    )
    private static let codexBundleIdentifier = "com.openai.codex"
    private static let activationTimeout: Duration = .seconds(2)
    private static let crossAppSettleDelay: Duration = .milliseconds(400)
    private static let controlTimeout: Duration = .seconds(4)
    private static let pointerAttemptTimeout: Duration = .milliseconds(500)
    private static let responseTimeout: Duration = .seconds(2)
    private static let pollInterval: Duration = .milliseconds(50)
    private static let maximumPointerAttempts = 3
    private static let maximumVisitedElements = 4_096

    @MainActor
    func resolve(_ session: AgentSession, approved: Bool) async throws {
        guard let threadID = Self.threadID(for: session),
            let threadURL = URL(string: "codex://threads/\(threadID)")
        else {
            throw CodexNativeApprovalRemoteError.missingThread
        }

        guard let app = NSRunningApplication.runningApplications(
            withBundleIdentifier: Self.codexBundleIdentifier
        ).first else {
            throw CodexNativeApprovalRemoteError.appUnavailable
        }
        guard AXIsProcessTrusted() else {
            Self.logger.error("Accessibility permission is not trusted.")
            throw CodexNativeApprovalRemoteError.accessibilityPermissionRequired
        }

        let previousFrontmostApp = NSWorkspace.shared.frontmostApplication
        let wasCodexFrontmost =
            previousFrontmostApp?.bundleIdentifier
                == Self.codexBundleIdentifier
        NSWorkspace.shared.open(threadURL)
        app.activate()

        guard await waitUntil(
            timeout: Self.activationTimeout,
            condition: {
                NSWorkspace.shared.frontmostApplication?.bundleIdentifier
                    == Self.codexBundleIdentifier
            }
        ) else {
            throw CodexNativeApprovalRemoteError.appDidNotActivate
        }

        let applicationElement = AXUIElementCreateApplication(app.processIdentifier)
        // Electron exposes its web accessibility tree on demand. This is a
        // process-local accessibility flag and does not change Codex policy.
        let accessibilityResult = AXUIElementSetAttributeValue(
            applicationElement,
            "AXManualAccessibility" as CFString,
            kCFBooleanTrue
        )
        Self.logger.notice(
            "Enabled Electron accessibility with result \(accessibilityResult.rawValue, privacy: .public)."
        )
        Self.focusActiveWindow(in: applicationElement)
        if !wasCodexFrontmost {
            // A window or full-screen Space can be frontmost before it is ready
            // to receive the first pointer event. Let that transition settle
            // once; retries below remain guarded by the exact matched control.
            try? await Task.sleep(for: Self.crossAppSettleDelay)
        }
        let preferredLabel = approved
            ? session.permissionRequest?.primaryActionTitle
            : session.permissionRequest?.secondaryActionTitle
        let labels = Self.controlLabels(
            approved: approved,
            preferredLabel: preferredLabel
        )

        var controls: [AXUIElement] = []
        _ = await waitUntil(timeout: Self.controlTimeout) {
            // Enabling Electron accessibility can rebuild its AX hierarchy.
            // Recreate the application element and reacquire the focused
            // window on every poll instead of traversing a stale snapshot.
            let currentApplication = AXUIElementCreateApplication(
                app.processIdentifier
            )
            _ = AXUIElementSetAttributeValue(
                currentApplication,
                "AXManualAccessibility" as CFString,
                kCFBooleanTrue
            )
            controls = Self.findApprovalControls(
                inApplication: currentApplication,
                matching: labels
            )
            return !controls.isEmpty
        }

        guard !controls.isEmpty else {
            let currentApplication = AXUIElementCreateApplication(
                app.processIdentifier
            )
            let focusedWindow = Self.elementAttribute(
                kAXFocusedWindowAttribute,
                of: currentApplication
            )
            let focusedWindowTitle = focusedWindow.flatMap {
                Self.stringAttribute(kAXTitleAttribute, of: $0)
            } ?? "<untitled>"
            let visibleLabels = Self.pressableControlLabels(
                in: currentApplication
            )
                .joined(separator: " | ")
            Self.logger.error(
                "No approval control matched in Codex window \(focusedWindowTitle, privacy: .public). Web area exposed: \(Self.containsWebArea(in: currentApplication), privacy: .public). Pressable labels: \(visibleLabels, privacy: .public)"
            )
            throw CodexNativeApprovalRemoteError.approvalControlUnavailable
        }

        var lastFailure: AXError?
        for initialControl in controls {
            var fallbackControl = initialControl
            // Electron currently advertises AXPress but does not dispatch its
            // DOM click. Prefer a real pointer click at the center of the exact
            // accessibility-matched Allow/Deny control. Reacquire and retry
            // that exact control when macOS swallows the first cross-app click.
            for attempt in 1 ... Self.maximumPointerAttempts {
                let currentApplication = AXUIElementCreateApplication(
                    app.processIdentifier
                )
                Self.focusActiveWindow(in: currentApplication)
                let control = Self.findApprovalControls(
                    inApplication: currentApplication,
                    matching: labels
                ).first ?? fallbackControl
                fallbackControl = control

                let candidateLabels = Self.accessibleLabels(for: control)
                    .sorted()
                    .joined(separator: " | ")
                Self.logger.notice(
                    "Activating Codex candidate \(candidateLabels, privacy: .public), pointer attempt \(attempt, privacy: .public)."
                )
                guard Self.clickCenter(of: control) else {
                    break
                }
                if await waitUntil(
                    timeout: Self.pointerAttemptTimeout,
                    condition: {
                        !Self.isAvailable(control)
                    }
                ) {
                    Self.logger.notice(
                        "Codex approval control disappeared after pointer activation."
                    )
                    await Self.restorePreviousApp(previousFrontmostApp)
                    return
                }
                Self.logger.error(
                    "Pointer attempt \(attempt, privacy: .public) completed but the candidate remained available."
                )
            }

            // Keep AXPress as a fallback in case a future Codex build exposes
            // a working native accessibility action.
            let control = fallbackControl
            Self.logger.notice("Trying AXPress fallback.")
            let result = AXUIElementPerformAction(
                control,
                kAXPressAction as CFString
            )
            guard result == .success else {
                Self.logger.error(
                    "AXPress failed with error \(result.rawValue, privacy: .public)."
                )
                lastFailure = result
                continue
            }

            if await waitUntil(
                timeout: Self.responseTimeout,
                condition: {
                    !Self.isAvailable(control)
                }
            ) {
                Self.logger.notice("Codex approval control disappeared.")
                await Self.restorePreviousApp(previousFrontmostApp)
                return
            }
            Self.logger.error(
                "AXPress returned success but the candidate remained available."
            )
        }

        if let lastFailure {
            throw CodexNativeApprovalRemoteError.approvalControlFailed(
                lastFailure
            )
        }
        throw CodexNativeApprovalRemoteError.approvalControlDidNotRespond
    }

    static func threadID(for session: AgentSession) -> String? {
        if let threadID = session.jumpTarget?.codexThreadID?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !threadID.isEmpty {
            return threadID
        }

        // Codex Desktop's session ID is its thread ID. During startup, a hook
        // can create the session before rollout discovery enriches the jump
        // target. The runtime flag remains sufficient evidence to route the
        // native approval to that exact thread.
        guard session.isCodexAppSession
                || session.jumpTarget?.terminalApp == "Codex.app" else {
            return nil
        }
        let sessionID = session.id.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        return sessionID.isEmpty ? nil : sessionID
    }

    private static func controlLabels(
        approved: Bool,
        preferredLabel: String?
    ) -> Set<String> {
        let defaults = approved
            ? ["allow once", "approve", "allow"]
            : ["deny", "decline"]
        var labels = Set(defaults)
        if let preferredLabel = preferredLabel?.normalizedApprovalLabel {
            labels.insert(preferredLabel)
        }
        return labels
    }

    private static func findApprovalControls(
        inApplication application: AXUIElement,
        matching labels: Set<String>
    ) -> [AXUIElement] {
        if let focusedWindow = elementAttribute(
            kAXFocusedWindowAttribute,
            of: application
        ) {
            let focusedMatches = findApprovalControls(
                in: focusedWindow,
                matching: labels
            )
            if !focusedMatches.isEmpty {
                return focusedMatches
            }
        }
        return findApprovalControls(in: application, matching: labels)
    }

    private static func findApprovalControls(
        in root: AXUIElement,
        matching labels: Set<String>
    ) -> [AXUIElement] {
        var queue: [AXUIElement] = [root]
        var cursor = 0
        var matches: [(element: AXUIElement, score: Int)] = []

        while cursor < queue.count,
              cursor < maximumVisitedElements {
            let element = queue[cursor]
            cursor += 1

            if isPressableControl(element),
               let score = matchScore(
                   accessibleLabels(for: element),
                   expected: labels
               ) {
                matches.append((element, score))
            }

            queue.append(contentsOf: childElements(of: element))
        }
        return matches
            .sorted { $0.score > $1.score }
            .map(\.element)
    }

    private static func pressableControlLabels(
        in root: AXUIElement
    ) -> [String] {
        var queue: [AXUIElement] = [root]
        var cursor = 0
        var labels: [String] = []

        while cursor < queue.count,
              cursor < maximumVisitedElements {
            let element = queue[cursor]
            cursor += 1

            if isPressableControl(element) {
                let text = accessibleLabels(for: element)
                    .sorted()
                    .joined(separator: " / ")
                if !text.isEmpty {
                    labels.append(text)
                }
            }
            queue.append(contentsOf: childElements(of: element))
        }
        return labels
    }

    private static func containsWebArea(in root: AXUIElement) -> Bool {
        var queue: [AXUIElement] = [root]
        var cursor = 0

        while cursor < queue.count,
              cursor < maximumVisitedElements {
            let element = queue[cursor]
            cursor += 1
            if stringAttribute(kAXRoleAttribute, of: element) == "AXWebArea" {
                return true
            }
            queue.append(contentsOf: childElements(of: element))
        }
        return false
    }

    private static func matchScore(
        _ candidateLabels: Set<String>,
        expected: Set<String>
    ) -> Int? {
        var bestScore: Int?
        for candidate in candidateLabels {
            for label in expected {
                let score: Int?
                if candidate == label {
                    score = 1_000 + label.count
                } else if candidate.hasPrefix("\(label) ")
                            || candidate.hasPrefix("\(label)\n")
                            || candidate.hasPrefix("\(label)\t") {
                    score = 500 + label.count
                } else {
                    score = nil
                }
                if let score, score > (bestScore ?? .min) {
                    bestScore = score
                }
            }
        }
        return bestScore
    }

    private static func isPressableControl(_ element: AXUIElement) -> Bool {
        guard let role = stringAttribute(kAXRoleAttribute, of: element) else {
            return false
        }
        guard role == kAXButtonRole as String
                || role == kAXRadioButtonRole as String else {
            return false
        }
        return boolAttribute(kAXEnabledAttribute, of: element) != false
    }

    private static func isAvailable(_ element: AXUIElement) -> Bool {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(
            element,
            kAXRoleAttribute as CFString,
            &value
        ) == .success
    }

    private static func focusActiveWindow(in application: AXUIElement) {
        guard let window = elementAttribute(
            kAXFocusedWindowAttribute,
            of: application
        ) else {
            return
        }
        _ = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        _ = AXUIElementSetAttributeValue(
            window,
            kAXMainAttribute as CFString,
            kCFBooleanTrue
        )
        _ = AXUIElementSetAttributeValue(
            window,
            kAXFocusedAttribute as CFString,
            kCFBooleanTrue
        )
    }

    @MainActor
    private static func restorePreviousApp(
        _ previousApp: NSRunningApplication?
    ) async {
        guard let previousApp,
              previousApp.bundleIdentifier != codexBundleIdentifier,
              !previousApp.isTerminated,
              NSWorkspace.shared.frontmostApplication?.bundleIdentifier
                == codexBundleIdentifier else {
            return
        }
        let restored = previousApp.activate(options: [.activateAllWindows])
        logger.notice(
            "Restored previous app \(previousApp.localizedName ?? previousApp.bundleIdentifier ?? "<unknown>", privacy: .public): \(restored, privacy: .public)."
        )
        guard !restored,
              let bundleURL = previousApp.bundleURL else {
            return
        }

        // Some multi-process apps (notably Chrome) reject direct activation
        // even when their NSRunningApplication is valid. Ask LaunchServices to
        // reuse and activate that existing bundle without creating an instance.
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.addsToRecentItems = false
        configuration.createsNewApplicationInstance = false
        do {
            let reopenedApp = try await NSWorkspace.shared.openApplication(
                at: bundleURL,
                configuration: configuration
            )
            logger.notice(
                "Restored previous app through LaunchServices: \(reopenedApp.localizedName ?? reopenedApp.bundleIdentifier ?? "<unknown>", privacy: .public)."
            )
        } catch {
            logger.error(
                "Could not restore previous app through LaunchServices: \(error.localizedDescription, privacy: .public)."
            )
        }
    }

    private static func clickCenter(of element: AXUIElement) -> Bool {
        guard CGPreflightPostEventAccess() else {
            _ = CGRequestPostEventAccess()
            logger.error(
                "Input-control permission is unavailable; requested PostEvent access."
            )
            return false
        }
        _ = AXUIElementSetAttributeValue(
            element,
            kAXFocusedAttribute as CFString,
            kCFBooleanTrue
        )
        guard let position = pointAttribute(
            kAXPositionAttribute,
            of: element
        ),
              let size = sizeAttribute(
                  kAXSizeAttribute,
                  of: element
              ),
              size.width > 0,
              size.height > 0 else {
            logger.error(
                "Matched approval control does not expose a clickable frame."
            )
            return false
        }

        let center = CGPoint(
            x: position.x + (size.width / 2),
            y: position.y + (size.height / 2)
        )
        guard center.x.isFinite, center.y.isFinite else {
            logger.error("Matched approval control has an invalid frame.")
            return false
        }

        let source = CGEventSource(stateID: .combinedSessionState)
        let originalPosition = CGEvent(source: nil)?.location
        let events: [CGEvent?] = [
            CGEvent(
                mouseEventSource: source,
                mouseType: .mouseMoved,
                mouseCursorPosition: center,
                mouseButton: .left
            ),
            CGEvent(
                mouseEventSource: source,
                mouseType: .leftMouseDown,
                mouseCursorPosition: center,
                mouseButton: .left
            ),
            CGEvent(
                mouseEventSource: source,
                mouseType: .leftMouseUp,
                mouseCursorPosition: center,
                mouseButton: .left
            ),
        ]
        guard events.allSatisfy({ $0 != nil }) else {
            logger.error("Could not create pointer events for Codex approval.")
            return false
        }
        for event in events.compactMap(\.self) {
            event.post(tap: .cghidEventTap)
        }
        if let originalPosition,
           let restoreEvent = CGEvent(
               mouseEventSource: source,
               mouseType: .mouseMoved,
               mouseCursorPosition: originalPosition,
               mouseButton: .left
           ) {
            restoreEvent.post(tap: .cghidEventTap)
        }
        return true
    }

    private static func accessibleLabels(for element: AXUIElement) -> Set<String> {
        let attributes = [
            kAXTitleAttribute,
            kAXDescriptionAttribute,
            kAXHelpAttribute,
            kAXValueAttribute,
        ]
        var labels = Set(
            attributes.compactMap {
                stringAttribute($0, of: element)?.normalizedApprovalLabel
            }
        )

        // Electron buttons commonly put their text in a static-text child.
        for child in childElements(of: element).prefix(8) {
            for attribute in attributes {
                if let label = stringAttribute(
                    attribute,
                    of: child
                )?.normalizedApprovalLabel {
                    labels.insert(label)
                }
            }
        }
        return labels
    }

    private static func stringAttribute(
        _ attribute: String,
        of element: AXUIElement
    ) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            attribute as CFString,
            &value
        ) == .success else {
            return nil
        }
        return value as? String
    }

    private static func boolAttribute(
        _ attribute: String,
        of element: AXUIElement
    ) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            attribute as CFString,
            &value
        ) == .success else {
            return nil
        }
        return value as? Bool
    }

    private static func pointAttribute(
        _ attribute: String,
        of element: AXUIElement
    ) -> CGPoint? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            attribute as CFString,
            &value
        ) == .success,
              let value,
              CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }
        var point = CGPoint.zero
        guard AXValueGetValue(
            value as! AXValue,
            .cgPoint,
            &point
        ) else {
            return nil
        }
        return point
    }

    private static func sizeAttribute(
        _ attribute: String,
        of element: AXUIElement
    ) -> CGSize? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            attribute as CFString,
            &value
        ) == .success,
              let value,
              CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }
        var size = CGSize.zero
        guard AXValueGetValue(
            value as! AXValue,
            .cgSize,
            &size
        ) else {
            return nil
        }
        return size
    }

    private static func elementAttribute(
        _ attribute: String,
        of element: AXUIElement
    ) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            attribute as CFString,
            &value
        ) == .success,
              let value,
              CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        return (value as! AXUIElement)
    }

    private static func childElements(of element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXChildrenAttribute as CFString,
            &value
        ) == .success else {
            return []
        }
        return value as? [AXUIElement] ?? []
    }

    @MainActor
    private func waitUntil(
        timeout: Duration,
        condition: @escaping @MainActor () -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        repeat {
            if condition() {
                return true
            }
            try? await Task.sleep(for: Self.pollInterval)
        } while clock.now < deadline
        return condition()
    }
}

private extension String {
    var normalizedApprovalLabel: String? {
        let normalized = trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return normalized.isEmpty ? nil : normalized
    }
}
