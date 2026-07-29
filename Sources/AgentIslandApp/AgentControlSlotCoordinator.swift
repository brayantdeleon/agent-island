import Foundation
import AgentIslandCore

/// Main-actor bridge between Agent Island sessions and the device-independent
/// Agent Control slot allocator.
///
/// The coordinator owns the allocator's process-lifetime active assignments
/// and persists only preferred assignments. Inactive preferences therefore
/// survive an app restart without reserving scarce hardware slots.
@MainActor
final class AgentControlSlotCoordinator {
    private let store: AgentControlSlotAssignmentStore
    private var allocator: AgentControlSlotAllocator

    init(store: AgentControlSlotAssignmentStore) {
        self.store = store
        self.allocator = AgentControlSlotAllocator(preferredSlots: store.load())
    }

    func projection(
        for sessions: [AgentSession],
        at referenceDate: Date,
        completedStaleThreshold: TimeInterval,
        canResolveExactPermissionRequest: (AgentSession) -> Bool = { _ in false }
    ) -> AgentControlSlotProjection {
        let candidates = candidates(
            for: sessions,
            at: referenceDate,
            completedStaleThreshold: completedStaleThreshold,
            canResolveExactPermissionRequest:
                canResolveExactPermissionRequest
        )

        let previousPreferredSlots = allocator.preferredSlots
        let projection = allocator.reconcile(candidates: candidates)
        if allocator.preferredSlots != previousPreferredSlots {
            store.save(allocator.preferredSlots)
        }
        return projection
    }

    func compactAssignments(
        for sessions: [AgentSession],
        at referenceDate: Date,
        completedStaleThreshold: TimeInterval,
        canResolveExactPermissionRequest: (AgentSession) -> Bool = { _ in false }
    ) -> AgentControlSlotProjection {
        let candidates = candidates(
            for: sessions,
            at: referenceDate,
            completedStaleThreshold: completedStaleThreshold,
            canResolveExactPermissionRequest:
                canResolveExactPermissionRequest
        )
        let previousPreferredSlots = allocator.preferredSlots
        let projection = allocator.compact(candidates: candidates)
        if allocator.preferredSlots != previousPreferredSlots {
            store.save(allocator.preferredSlots)
        }
        return projection
    }

    private func candidates(
        for sessions: [AgentSession],
        at referenceDate: Date,
        completedStaleThreshold: TimeInterval,
        canResolveExactPermissionRequest: (AgentSession) -> Bool
    ) -> [AgentControlSlotCandidate] {
        sessions.compactMap { session in
            guard !session.isSubagentSession,
                  !session.isRealtimeVoiceChatSession,
                  !session.isStaleCompletedForIsland(
                      at: referenceDate,
                      threshold: completedStaleThreshold
                  ) else {
                return nil
            }

            return AgentControlSlotCandidate(
                sessionID: session.id,
                firstSeenAt: session.firstSeenAt,
                lightState: AgentControlLightState.project(
                    phase: session.phase,
                    hasPermissionRequest: session.permissionRequest != nil,
                    requiresTerminalApproval:
                        session.permissionRequest?
                            .requiresTerminalApproval ?? false,
                    canResolveExactPermissionRequest:
                        canResolveExactPermissionRequest(session)
                )
            )
        }
    }
}
