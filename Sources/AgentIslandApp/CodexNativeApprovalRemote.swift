import AppKit
import ApplicationServices
import Foundation
import AgentIslandCore

enum CodexNativeApprovalRemoteError: Error, LocalizedError {
    case missingThread
    case appUnavailable
    case appDidNotActivate
    case approvalControlUnavailable
    case approvalControlFailed(AXError)

    var errorDescription: String? {
        switch self {
        case .missingThread:
            "The Codex task does not have a thread identifier."
        case .appUnavailable:
            "Codex Desktop is not running."
        case .appDidNotActivate:
            "Codex Desktop did not become active."
        case .approvalControlUnavailable:
            "Codex's native approval control was not available."
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
    private static let codexBundleIdentifier = "com.openai.codex"
    private static let activationTimeout: Duration = .seconds(2)
    private static let controlTimeout: Duration = .seconds(2)
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

        let preferredLabel = approved
            ? session.permissionRequest?.primaryActionTitle
            : session.permissionRequest?.secondaryActionTitle
        let labels = Self.controlLabels(
            approved: approved,
            preferredLabel: preferredLabel
        )

        var control: AXUIElement?
        _ = await waitUntil(timeout: Self.controlTimeout) {
            control = Self.findApprovalControl(
                in: applicationElement,
                matching: labels
            )
            return control != nil
        }

        guard let control else {
            throw CodexNativeApprovalRemoteError.approvalControlUnavailable
        }
        let result = AXUIElementPerformAction(control, kAXPressAction as CFString)
        guard result == .success else {
            throw CodexNativeApprovalRemoteError.approvalControlFailed(result)
        }
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

    private static func findApprovalControl(
        in application: AXUIElement,
        matching labels: Set<String>
    ) -> AXUIElement? {
        var queue: [AXUIElement] = [application]
        var cursor = 0

        while cursor < queue.count,
              cursor < maximumVisitedElements {
            let element = queue[cursor]
            cursor += 1

            if isPressableControl(element),
               !labels.isDisjoint(with: accessibleLabels(for: element)) {
                return element
            }

            queue.append(contentsOf: childElements(of: element))
        }
        return nil
    }

    private static func isPressableControl(_ element: AXUIElement) -> Bool {
        guard let role = stringAttribute(kAXRoleAttribute, of: element) else {
            return false
        }
        return role == kAXButtonRole as String
            || role == kAXRadioButtonRole as String
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
