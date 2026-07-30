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
    private static let controlTimeout: Duration = .seconds(2)
    private static let responseTimeout: Duration = .seconds(1)
    private static let pollInterval: Duration = .milliseconds(50)
    private static let maximumVisitedElements = 4_096

    @MainActor
    func resolve(_ session: AgentSession, approved: Bool) async throws {
        guard let threadID = session.jumpTarget?.codexThreadID?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !threadID.isEmpty,
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
        AXUIElementSetAttributeValue(
            applicationElement,
            "AXManualAccessibility" as CFString,
            kCFBooleanTrue
        )

        let searchRoot = Self.elementAttribute(
            kAXFocusedWindowAttribute,
            of: applicationElement
        ) ?? applicationElement
        let searchRootTitle =
            Self.stringAttribute(kAXTitleAttribute, of: searchRoot)
                ?? "<untitled>"
        Self.logger.notice(
            "Searching focused Codex window: \(searchRootTitle, privacy: .public)"
        )
        let preferredLabel = approved
            ? session.permissionRequest?.primaryActionTitle
            : session.permissionRequest?.secondaryActionTitle
        let labels = Self.controlLabels(
            approved: approved,
            preferredLabel: preferredLabel
        )

        var controls: [AXUIElement] = []
        _ = await waitUntil(timeout: Self.controlTimeout) {
            controls = Self.findApprovalControls(
                in: searchRoot,
                matching: labels
            )
            return !controls.isEmpty
        }

        guard !controls.isEmpty else {
            let visibleLabels = Self.pressableControlLabels(in: searchRoot)
                .joined(separator: " | ")
            Self.logger.error(
                "No approval control matched. Pressable labels: \(visibleLabels, privacy: .public)"
            )
            throw CodexNativeApprovalRemoteError.approvalControlUnavailable
        }

        var lastFailure: AXError?
        for control in controls {
            let candidateLabels = Self.accessibleLabels(for: control)
                .sorted()
                .joined(separator: " | ")
            Self.logger.notice(
                "Pressing Codex candidate: \(candidateLabels, privacy: .public)"
            )
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
