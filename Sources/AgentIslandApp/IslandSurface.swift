import Foundation
import AgentIslandCore

enum IslandSurface: Equatable {
    case sessionList(actionableSessionID: String? = nil)
    case notification(sessionID: String)
    case singleTask(sessionID: String)
    case expanded(selectedSessionID: String? = nil)

    var sessionID: String? {
        switch self {
        case let .sessionList(actionableSessionID):
            actionableSessionID
        case let .notification(sessionID),
             let .singleTask(sessionID):
            sessionID
        case let .expanded(selectedSessionID):
            selectedSessionID
        }
    }

    var isNotificationCard: Bool {
        if case .notification = self {
            return true
        }
        return false
    }

    var isSingleTask: Bool {
        if case .singleTask = self {
            return true
        }
        return false
    }

    var isExpanded: Bool {
        if case .expanded = self {
            return true
        }
        return false
    }

    func autoDismissesWhenPresentedAsNotification(session: AgentSession?) -> Bool {
        guard sessionID != nil else { return false }
        return session?.phase == .completed
    }

    static func notificationSurface(for event: AgentEvent) -> IslandSurface? {
        switch event {
        case let .permissionRequested(payload):
            .notification(sessionID: payload.sessionID)
        case let .questionAsked(payload):
            .notification(sessionID: payload.sessionID)
        case let .sessionCompleted(payload):
            payload.isInterrupt == true ? nil : .notification(sessionID: payload.sessionID)
        default:
            nil
        }
    }

    func matchesCurrentState(of session: AgentSession?) -> Bool {
        guard sessionID != nil else {
            return true
        }

        guard let session else {
            return false
        }

        switch session.phase {
        case .waitingForApproval:
            return session.permissionRequest != nil
        case .waitingForAnswer:
            return session.questionPrompt != nil
        case .completed:
            return true
        case .running:
            return false
        }
    }
}
