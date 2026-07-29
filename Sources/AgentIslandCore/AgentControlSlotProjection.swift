import Foundation

/// Device-facing state for one assigned Agent Control slot.
///
/// Raw values intentionally match the version 1 K0 Max snapshot protocol.
/// An unassigned physical slot is encoded separately as `0`.
public enum AgentControlLightState: UInt8, Codable, Equatable, Sendable {
    case idle = 1
    case running = 2
    case waitingForActionableApproval = 3
    case waitingForObservedApproval = 4
    case waitingForAnswer = 5
    case recentlyCompleted = 6

    public static func project(
        phase: SessionPhase?,
        hasPermissionRequest: Bool = false,
        requiresTerminalApproval: Bool = false,
        canResolveExactPermissionRequest: Bool = false
    ) -> Self {
        switch phase {
        case .running:
            .running
        case .waitingForApproval:
            hasPermissionRequest
                && !requiresTerminalApproval
                && canResolveExactPermissionRequest
                ? .waitingForActionableApproval
                : .waitingForObservedApproval
        case .waitingForAnswer:
            .waitingForAnswer
        case .completed:
            .recentlyCompleted
        case nil:
            .idle
        }
    }
}

/// Minimal, device-independent input to the stable slot allocator.
public struct AgentControlSlotCandidate: Equatable, Sendable {
    public var sessionID: String
    public var firstSeenAt: Date
    public var lightState: AgentControlLightState

    public init(
        sessionID: String,
        firstSeenAt: Date,
        lightState: AgentControlLightState
    ) {
        self.sessionID = sessionID
        self.firstSeenAt = firstSeenAt
        self.lightState = lightState
    }
}

public struct AgentControlSlot: Identifiable, Equatable, Sendable {
    public var id: Int { index }
    public var index: Int
    public var sessionID: String
    public var lightState: AgentControlLightState

    public init(
        index: Int,
        sessionID: String,
        lightState: AgentControlLightState
    ) {
        self.index = index
        self.sessionID = sessionID
        self.lightState = lightState
    }

    /// Physical numpad label for this zero-based slot.
    public var keyLabel: String {
        String(index + 1)
    }
}

public struct AgentControlSlotProjection: Equatable, Sendable {
    public var slots: [AgentControlSlot?]
    public var overflowCount: Int

    public init(slots: [AgentControlSlot?], overflowCount: Int) {
        self.slots = slots
        self.overflowCount = max(overflowCount, 0)
    }

    public var assignedSlots: [AgentControlSlot] {
        slots.compactMap { $0 }
    }

    public var hasOverflow: Bool {
        overflowCount > 0
    }

    public func slot(for sessionID: String) -> AgentControlSlot? {
        assignedSlots.first { $0.sessionID == sessionID }
    }

    public func keyLabel(for sessionID: String) -> String? {
        slot(for: sessionID)?.keyLabel
    }
}

/// Pure nine-agent-slot allocator for physical keys 1–9.
///
/// `activeSlots` protects live assignments from renumbering within a process.
/// `preferredSlots` is the persisted history used to reclaim the same number
/// after a temporary disappearance or app restart. Inactive preferred slots
/// do not reserve hardware capacity: a newcomer may use one, and a returning
/// session falls back to the first free slot when its preference is occupied.
public struct AgentControlSlotAllocator: Equatable, Sendable {
    public static let capacity = AgentControlProtocolV1.agentSlotCount

    public private(set) var preferredSlots: [String: Int]
    private var activeSlots: [String: Int] = [:]

    public init(preferredSlots: [String: Int] = [:]) {
        self.preferredSlots = preferredSlots.filter {
            !$0.key.isEmpty && (0..<Self.capacity).contains($0.value)
        }
    }

    public mutating func reconcile(
        candidates: [AgentControlSlotCandidate]
    ) -> AgentControlSlotProjection {
        let candidatesByID = Self.uniqueCandidatesByID(candidates)
        let orderedCandidates = candidatesByID.values.sorted(by: Self.candidateOrder)
        let eligibleIDs = Set(candidatesByID.keys)

        activeSlots = activeSlots.filter {
            eligibleIDs.contains($0.key)
                && (0..<Self.capacity).contains($0.value)
        }

        var occupiedSlots = Set(activeSlots.values)
        let unassigned = orderedCandidates.filter { activeSlots[$0.sessionID] == nil }

        // Returning or restored sessions get first claim on a remembered slot.
        for candidate in unassigned {
            guard let preferred = preferredSlots[candidate.sessionID],
                  (0..<Self.capacity).contains(preferred),
                  !occupiedSlots.contains(preferred) else {
                continue
            }

            activeSlots[candidate.sessionID] = preferred
            occupiedSlots.insert(preferred)
        }

        // New sessions and remembered-slot conflicts take the first free slot.
        for candidate in unassigned where activeSlots[candidate.sessionID] == nil {
            guard let slot = (0..<Self.capacity).first(where: { !occupiedSlots.contains($0) }) else {
                break
            }

            activeSlots[candidate.sessionID] = slot
            preferredSlots[candidate.sessionID] = slot
            occupiedSlots.insert(slot)
        }

        var slots = [AgentControlSlot?](repeating: nil, count: Self.capacity)
        for (sessionID, index) in activeSlots {
            guard let candidate = candidatesByID[sessionID] else { continue }
            slots[index] = AgentControlSlot(
                index: index,
                sessionID: sessionID,
                lightState: candidate.lightState
            )
        }

        return AgentControlSlotProjection(
            slots: slots,
            overflowCount: max(orderedCandidates.count - activeSlots.count, 0)
        )
    }

    private static func uniqueCandidatesByID(
        _ candidates: [AgentControlSlotCandidate]
    ) -> [String: AgentControlSlotCandidate] {
        var result: [String: AgentControlSlotCandidate] = [:]

        for candidate in candidates where !candidate.sessionID.isEmpty {
            guard let existing = result[candidate.sessionID] else {
                result[candidate.sessionID] = candidate
                continue
            }

            if candidateOrder(candidate, existing) {
                result[candidate.sessionID] = candidate
            }
        }

        return result
    }

    private static func candidateOrder(
        _ lhs: AgentControlSlotCandidate,
        _ rhs: AgentControlSlotCandidate
    ) -> Bool {
        if lhs.firstSeenAt != rhs.firstSeenAt {
            return lhs.firstSeenAt < rhs.firstSeenAt
        }
        if lhs.sessionID != rhs.sessionID {
            return lhs.sessionID < rhs.sessionID
        }
        return lhs.lightState.rawValue < rhs.lightState.rawValue
    }
}
