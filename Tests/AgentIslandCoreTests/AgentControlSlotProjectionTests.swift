import Foundation
import Testing
@testable import AgentIslandCore

struct AgentControlSlotProjectionTests {
    @Test
    func startupAssignmentUsesHistoricalOrderThenSessionID() {
        let start = Date(timeIntervalSince1970: 1_000)
        var allocator = AgentControlSlotAllocator()

        let projection = allocator.reconcile(candidates: [
            candidate("C", at: start.addingTimeInterval(2)),
            candidate("B", at: start.addingTimeInterval(1)),
            candidate("A", at: start),
            candidate("A2", at: start),
        ])

        #expect(projection.assignedSlots.map(\.sessionID) == ["A", "A2", "B", "C"])
        #expect(projection.assignedSlots.map(\.keyLabel) == ["1", "2", "3", "4"])
    }

    @Test
    func newlyObservedSessionTakesFirstFreeSlotWithoutRenumberingLiveSessions() {
        let start = Date(timeIntervalSince1970: 2_000)
        var allocator = AgentControlSlotAllocator()
        let initial = [
            candidate("A", at: start),
            candidate("B", at: start.addingTimeInterval(1)),
            candidate("C", at: start.addingTimeInterval(2)),
        ]
        _ = allocator.reconcile(candidates: initial)

        let projection = allocator.reconcile(candidates: initial + [
            candidate("D", at: start.addingTimeInterval(-100)),
        ])

        #expect(slotMap(projection) == ["A": 0, "B": 1, "C": 2, "D": 3])
    }

    @Test
    func temporarilyMissingSessionReclaimsItsPreferredSlotWhenFree() {
        let start = Date(timeIntervalSince1970: 3_000)
        var allocator = AgentControlSlotAllocator()
        let all = [
            candidate("A", at: start),
            candidate("B", at: start.addingTimeInterval(1)),
            candidate("C", at: start.addingTimeInterval(2)),
        ]
        _ = allocator.reconcile(candidates: all)
        _ = allocator.reconcile(candidates: [all[0], all[2]])

        let projection = allocator.reconcile(candidates: Array(all.reversed()))

        #expect(slotMap(projection) == ["A": 0, "B": 1, "C": 2])
    }

    @Test
    func returningSessionUsesFirstFreeSlotWhenItsPreferenceWasReused() {
        let start = Date(timeIntervalSince1970: 4_000)
        var allocator = AgentControlSlotAllocator()
        let a = candidate("A", at: start)
        let b = candidate("B", at: start.addingTimeInterval(1))
        let c = candidate("C", at: start.addingTimeInterval(2))
        let d = candidate("D", at: start.addingTimeInterval(3))
        _ = allocator.reconcile(candidates: [a, b, c])
        _ = allocator.reconcile(candidates: [a, c, d])

        let projection = allocator.reconcile(candidates: [a, b, c, d])

        #expect(slotMap(projection) == ["A": 0, "D": 1, "C": 2, "B": 3])
    }

    @Test
    func persistedPreferencesRestoreSlotNumbersAfterRestart() {
        let start = Date(timeIntervalSince1970: 5_000)
        let candidates = (0..<5).map {
            candidate("session-\($0)", at: start.addingTimeInterval(Double($0)))
        }
        var originalAllocator = AgentControlSlotAllocator()
        let original = originalAllocator.reconcile(candidates: candidates)

        var restartedAllocator = AgentControlSlotAllocator(
            preferredSlots: originalAllocator.preferredSlots
        )
        let restarted = restartedAllocator.reconcile(candidates: Array(candidates.reversed()))

        #expect(slotMap(restarted) == slotMap(original))
    }

    @Test
    func overflowWaitsWithoutRotatingAndTakesAReleasedSlot() {
        let start = Date(timeIntervalSince1970: 6_000)
        let candidates = (0..<12).map {
            candidate("session-\($0)", at: start.addingTimeInterval(Double($0)))
        }
        var allocator = AgentControlSlotAllocator()

        let full = allocator.reconcile(candidates: candidates)
        #expect(full.assignedSlots.count == 9)
        #expect(full.overflowCount == 3)

        let afterRelease = allocator.reconcile(candidates: Array(candidates.dropFirst()))
        #expect(afterRelease.slot(for: "session-9")?.index == 0)
        #expect(afterRelease.slot(for: "session-1")?.index == 1)
        #expect(afterRelease.overflowCount == 2)
    }

    @Test
    func phaseProjectionDistinguishesActionableAndObservedApprovals() {
        #expect(AgentControlLightState.project(phase: nil) == .idle)
        #expect(AgentControlLightState.project(phase: .running) == .running)
        #expect(AgentControlLightState.project(phase: .waitingForAnswer) == .waitingForAnswer)
        #expect(AgentControlLightState.project(phase: .completed) == .recentlyCompleted)

        #expect(
            AgentControlLightState.project(
                phase: .waitingForApproval,
                hasPermissionRequest: true,
                canResolveExactPermissionRequest: true
            ) == .waitingForActionableApproval
        )
        #expect(
            AgentControlLightState.project(
                phase: .waitingForApproval,
                hasPermissionRequest: true,
                requiresTerminalApproval: true,
                canResolveExactPermissionRequest: true
            ) == .waitingForObservedApproval
        )
        #expect(
            AgentControlLightState.project(
                phase: .waitingForApproval,
                hasPermissionRequest: false,
                canResolveExactPermissionRequest: true
            ) == .waitingForObservedApproval
        )
        #expect(
            AgentControlLightState.project(
                phase: .waitingForApproval,
                hasPermissionRequest: true,
                canResolveExactPermissionRequest: false
            ) == .waitingForObservedApproval
        )
    }

    @Test
    func agentSlotsMapToKeysOneThroughNineAndReserveZero() {
        let labels = (0..<AgentControlSlotAllocator.capacity).map {
            AgentControlSlot(
                index: $0,
                sessionID: "session-\($0)",
                lightState: .running
            ).keyLabel
        }
        #expect(labels == ["1", "2", "3", "4", "5", "6", "7", "8", "9"])
        #expect(
            AgentControlProtocolV1.toggleSlotIndex
                == UInt8(AgentControlSlotAllocator.capacity)
        )
    }

    private func candidate(
        _ sessionID: String,
        at firstSeenAt: Date,
        state: AgentControlLightState = .running
    ) -> AgentControlSlotCandidate {
        AgentControlSlotCandidate(
            sessionID: sessionID,
            firstSeenAt: firstSeenAt,
            lightState: state
        )
    }

    private func slotMap(_ projection: AgentControlSlotProjection) -> [String: Int] {
        Dictionary(
            uniqueKeysWithValues: projection.assignedSlots.map { ($0.sessionID, $0.index) }
        )
    }
}

struct AgentControlSlotAssignmentStoreTests {
    @Test
    func assignmentsRoundTripAndInvalidEntriesAreDiscarded() {
        let (store, defaults) = makeStore()

        store.save(["A": 0, "B": 8, "reserved-zero": 9, "": 4, "too-high": 10, "negative": -1])

        #expect(store.load() == ["A": 0, "B": 8])
        #expect(defaults.data(forKey: AgentControlSlotAssignmentStore.defaultsKey) != nil)
    }

    @Test
    func emptyAndCorruptPayloadsLoadSafely() {
        let (store, defaults) = makeStore()
        #expect(store.load().isEmpty)

        defaults.set(
            Data("not-json".utf8),
            forKey: AgentControlSlotAssignmentStore.defaultsKey
        )
        #expect(store.load().isEmpty)

        store.save([:])
        #expect(defaults.object(forKey: AgentControlSlotAssignmentStore.defaultsKey) == nil)
    }

    private func makeStore() -> (AgentControlSlotAssignmentStore, UserDefaults) {
        let suiteName = "agent-island-slot-store-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return (AgentControlSlotAssignmentStore(defaults: defaults), defaults)
    }
}
