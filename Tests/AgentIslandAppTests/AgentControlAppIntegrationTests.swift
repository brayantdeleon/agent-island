import Foundation
import Testing
@testable import AgentIslandApp
import AgentIslandCore

@MainActor
@Suite(.serialized)
struct AgentControlAppIntegrationTests {
    private let nonce: UInt64 = 0x0123_4567_89AB_CDEF
    private typealias Harness = (
        model: AppModel,
        transport: FakeAgentControlHIDTransport,
        defaults: UserDefaults
    )

    @Test
    func optInProjectsLiveSessionsAndDisableClearsTheKeyboard() throws {
        let harness = makeHarness(enabled: true)
        defer {
            harness.model.agentControlKeyboardEnabled = false
        }
        let now = Date()
        harness.model.state = SessionState(
            sessions: [
                makeSession(
                    id: "running",
                    firstSeenAt: now,
                    updatedAt: now,
                    phase: .running
                ),
                makeSession(
                    id: "approval",
                    firstSeenAt: now.addingTimeInterval(1),
                    updatedAt: now,
                    phase: .waitingForApproval,
                    permissionRequest: PermissionRequest(
                        title: "Edit",
                        summary: "Edit a file",
                        affectedPath: "/tmp/file"
                    )
                ),
                makeSession(
                    id: "answer",
                    firstSeenAt: now.addingTimeInterval(2),
                    updatedAt: now,
                    phase: .waitingForAnswer
                ),
                makeSession(
                    id: "completed",
                    firstSeenAt: now.addingTimeInterval(3),
                    updatedAt: now,
                    phase: .completed
                ),
            ]
        )

        #expect(harness.model.agentControlKeyboardEnabled)
        #expect(harness.transport.startCount == 0)
        #expect(
            harness.model.agentControlHardwareBadgeLabel(
                for: "running",
                at: now
            ) == "K0 · 1"
        )

        harness.model.startAgentControlDeviceIntegrationIfNeeded()

        let hello = try AgentControlPacketCodec.decode(
            harness.transport.sentReports[0]
        )
        #expect(hello.messageType == .hello)
        #expect(readUInt16(hello.payload, at: 10) == 7)

        harness.transport.emit(
            .report(try capabilitiesReport(sequence: hello.sequence))
        )

        let snapshot = try latestSnapshotPacket(
            in: harness.transport.sentReports
        )
        #expect(
            Array(snapshot.payload[11..<21])
                == [
                    AgentControlLightState.running.rawValue,
                    AgentControlLightState.waitingForObservedApproval.rawValue,
                    AgentControlLightState.waitingForAnswer.rawValue,
                    AgentControlLightState.recentlyCompleted.rawValue,
                    0, 0, 0, 0, 0, 0,
                ]
        )
        #expect(snapshot.payload[10] == 0)
        #expect(harness.model.agentControlDeviceDiagnostics.state == .ready)
        #expect(
            harness.model.agentControlDeviceDiagnostics
                .firmwareBuildIdentifier == 0xA41C_FB54
        )

        harness.model.agentControlKeyboardEnabled = false

        let clearingSnapshot = try latestSnapshotPacket(
            in: harness.transport.sentReports
        )
        #expect(Array(clearingSnapshot.payload[11..<21]).allSatisfy { $0 == 0 })
        #expect(harness.transport.stopCount == 1)
        #expect(harness.model.agentControlDeviceDiagnostics.state == .stopped)
        #expect(
            harness.defaults.bool(
                forKey: AgentControlDeviceSettingsStore.defaultsKey
            ) == false
        )
        #expect(
            harness.model.agentControlHardwareBadgeLabel(
                for: "running",
                at: now
            ) == nil
        )
    }

    @Test
    func digitSelectionRevealsExactSessionAndEnterJumps() async throws {
        let token: UInt64 = 0xA8A7_A6A5_A4A3_A2A1
        let harness = makeHarness(enabled: true, selectionToken: token)
        defer {
            harness.model.agentControlKeyboardEnabled = false
        }
        let now = Date()
        harness.model.state = SessionState(
            sessions: [
                makeSession(
                    id: "first",
                    firstSeenAt: now,
                    updatedAt: now,
                    phase: .running
                ),
                makeSession(
                    id: "second",
                    firstSeenAt: now.addingTimeInterval(1),
                    updatedAt: now,
                    phase: .running
                ),
            ]
        )
        harness.model.startAgentControlDeviceIntegrationIfNeeded()
        let hello = try AgentControlPacketCodec.decode(
            harness.transport.sentReports[0]
        )
        harness.transport.emit(
            .report(try capabilitiesReport(sequence: hello.sequence))
        )
        let snapshot = try latestSnapshotPacket(
            in: harness.transport.sentReports
        )
        let generation = readUInt16(snapshot.payload, at: 8)

        harness.transport.emit(
            .report(
                try deviceReport(
                    type: .slotSelected,
                    sequence: 1,
                    payload: littleEndianBytes(nonce)
                        + [
                            1,
                            UInt8(truncatingIfNeeded: generation),
                            UInt8(truncatingIfNeeded: generation >> 8),
                        ]
                )
            )
        )
        let selectionResponse = try AgentControlPacketCodec.decode(
            harness.transport.sentReports.last!
        )
        #expect(selectionResponse.messageType == .selectionAcknowledgement)
        #expect(selectionResponse.sequence == 1)
        #expect(selectionResponse.flags == [.response])
        #expect(
            selectionResponse.payload[9]
                == AgentControlSelectionResult.accepted.rawValue
        )
        #expect(readUInt64(selectionResponse.payload, at: 12) == token)
        #expect(
            selectionResponse.payload[20]
                == AgentControlAllowedActionSet.jump.rawValue
        )
        #expect(selectionResponse.payload[21] == 15)
        #expect(harness.model.selectedSessionID == "second")
        #expect(harness.model.agentControlSelectedSessionID == "second")
        #expect(harness.model.notchStatus == .opened)
        #expect(harness.model.notchOpenReason == .click)
        #expect(
            harness.model.islandSurface
                == .sessionList(actionableSessionID: "second")
        )
        #expect(harness.model.lastActionMessage != "Jumped to second.")

        harness.transport.emit(
            .report(
                try deviceReport(
                    type: .actionInvoked,
                    sequence: 2,
                    payload: littleEndianBytes(nonce)
                        + [1, AgentControlAction.jump.rawValue]
                        + littleEndianBytes(token)
                )
            )
        )
        let actionResponse = try AgentControlPacketCodec.decode(
            harness.transport.sentReports.last!
        )
        #expect(actionResponse.messageType == .actionResult)
        #expect(actionResponse.sequence == 2)
        #expect(actionResponse.flags == [.response])
        #expect(
            actionResponse.payload[10]
                == AgentControlActionResult.acceptedForDispatch.rawValue
        )

        await waitUntil {
            harness.model.lastActionMessage == "Jumped to second."
        }
        #expect(harness.model.notchStatus == .closed)
    }

    @Test
    func repeatedSelectedDigitPressesToggleItsDetailPresentation() throws {
        let harness = makeHarness(enabled: true)
        defer {
            harness.model.agentControlKeyboardEnabled = false
        }
        let now = Date()
        harness.model.state = SessionState(
            sessions: [
                makeSession(
                    id: "first",
                    firstSeenAt: now,
                    updatedAt: now,
                    phase: .running
                ),
            ]
        )
        harness.model.startAgentControlDeviceIntegrationIfNeeded()
        let hello = try AgentControlPacketCodec.decode(
            harness.transport.sentReports[0]
        )
        harness.transport.emit(
            .report(try capabilitiesReport(sequence: hello.sequence))
        )
        let snapshot = try latestSnapshotPacket(
            in: harness.transport.sentReports
        )
        let generation = readUInt16(snapshot.payload, at: 8)

        harness.transport.emit(
            .report(
                try slotSelectionReport(
                    sequence: 1,
                    slotIndex: 0,
                    generation: generation
                )
            )
        )

        #expect(harness.model.agentControlSelectedSessionID == "first")
        #expect(
            harness.model.agentControlDetailPresentationRequests["first"]
                == AgentControlDetailPresentationRequest(
                    sessionID: "first",
                    generation: 1,
                    isExpanded: false
                )
        )

        harness.transport.emit(
            .report(
                try slotSelectionReport(
                    sequence: 2,
                    slotIndex: 0,
                    generation: generation
                )
            )
        )

        #expect(
            harness.model.agentControlDetailPresentationRequests["first"]
                == AgentControlDetailPresentationRequest(
                    sessionID: "first",
                    generation: 2,
                    isExpanded: true
                )
        )

        harness.transport.emit(
            .report(
                try slotSelectionReport(
                    sequence: 3,
                    slotIndex: 0,
                    generation: generation
                )
            )
        )

        #expect(
            harness.model.agentControlDetailPresentationRequests["first"]
                == AgentControlDetailPresentationRequest(
                    sessionID: "first",
                    generation: 3,
                    isExpanded: false
                )
        )
        #expect(harness.model.agentControlSelectedSessionID == "first")
        #expect(harness.model.notchStatus == .opened)
        #expect(
            harness.model.islandSurface
                == .sessionList(actionableSessionID: "first")
        )
    }

    @Test
    func detailStatesSurviveSwitchingSessionsAndIslandReopening() throws {
        let harness = makeHarness(enabled: true)
        defer {
            harness.model.agentControlKeyboardEnabled = false
        }
        let now = Date()
        harness.model.state = SessionState(
            sessions: [
                makeSession(
                    id: "first",
                    firstSeenAt: now,
                    updatedAt: now,
                    phase: .running
                ),
                makeSession(
                    id: "second",
                    firstSeenAt: now.addingTimeInterval(1),
                    updatedAt: now,
                    phase: .running
                ),
            ]
        )
        harness.model.startAgentControlDeviceIntegrationIfNeeded()
        let hello = try AgentControlPacketCodec.decode(
            harness.transport.sentReports[0]
        )
        harness.transport.emit(
            .report(try capabilitiesReport(sequence: hello.sequence))
        )
        let snapshot = try latestSnapshotPacket(
            in: harness.transport.sentReports
        )
        let generation = readUInt16(snapshot.payload, at: 8)

        for (sequence, slotIndex) in [
            (UInt16(1), UInt8(0)),
            (UInt16(2), UInt8(0)),
            (UInt16(3), UInt8(1)),
            (UInt16(4), UInt8(1)),
        ] {
            harness.transport.emit(
                .report(
                    try slotSelectionReport(
                        sequence: sequence,
                        slotIndex: slotIndex,
                        generation: generation
                    )
                )
            )
        }

        #expect(
            harness.model.agentControlDetailPresentationRequests["first"]?
                .isExpanded == true
        )
        #expect(
            harness.model.agentControlDetailPresentationRequests["second"]?
                .isExpanded == true
        )

        harness.transport.emit(
            .report(
                try slotSelectionReport(
                    sequence: 5,
                    slotIndex: AgentControlProtocolV1.toggleSlotIndex,
                    generation: generation
                )
            )
        )
        #expect(harness.model.notchStatus == .closed)
        #expect(
            harness.model.agentControlDetailPresentationRequests["first"]?
                .isExpanded == true
        )
        #expect(
            harness.model.agentControlDetailPresentationRequests["second"]?
                .isExpanded == true
        )

        harness.transport.emit(
            .report(
                try slotSelectionReport(
                    sequence: 6,
                    slotIndex: 0,
                    generation: generation
                )
            )
        )
        #expect(harness.model.selectedSessionID == "first")
        #expect(
            harness.model.agentControlDetailPresentationRequests["first"]?
                .isExpanded == true
        )

        harness.transport.emit(
            .report(
                try slotSelectionReport(
                    sequence: 7,
                    slotIndex: 0,
                    generation: generation
                )
            )
        )
        #expect(
            harness.model.agentControlDetailPresentationRequests["first"]?
                .isExpanded == false
        )
        #expect(
            harness.model.agentControlDetailPresentationRequests["second"]?
                .isExpanded == true
        )
    }

    @Test
    func zeroClosesAndReopensTheIslandWithoutSelectingAnAgent() throws {
        let harness = makeHarness(enabled: true)
        defer {
            harness.model.agentControlKeyboardEnabled = false
        }
        let now = Date()
        harness.model.state = SessionState(
            sessions: [
                makeSession(
                    id: "selected",
                    firstSeenAt: now,
                    updatedAt: now,
                    phase: .running
                ),
            ]
        )
        harness.model.startAgentControlDeviceIntegrationIfNeeded()
        let hello = try AgentControlPacketCodec.decode(
            harness.transport.sentReports[0]
        )
        harness.transport.emit(
            .report(try capabilitiesReport(sequence: hello.sequence))
        )
        let snapshot = try latestSnapshotPacket(
            in: harness.transport.sentReports
        )
        let generation = readUInt16(snapshot.payload, at: 8)
        #expect(snapshot.payload[20] == 0)

        harness.transport.emit(
            .report(
                try slotSelectionReport(
                    sequence: 1,
                    slotIndex: 0,
                    generation: generation
                )
            )
        )
        #expect(harness.model.notchStatus == .opened)
        #expect(harness.model.agentControlSelectedSessionID == "selected")

        harness.transport.emit(
            .report(
                try slotSelectionReport(
                    sequence: 2,
                    slotIndex: AgentControlProtocolV1.toggleSlotIndex,
                    generation: generation
                )
            )
        )
        var response = try AgentControlPacketCodec.decode(
            harness.transport.sentReports.last!
        )
        #expect(response.messageType == .selectionAcknowledgement)
        #expect(response.sequence == 2)
        #expect(response.flags == [.response])
        #expect(
            response.payload[9]
                == AgentControlSelectionResult.accepted.rawValue
        )
        #expect(response.payload[20] == 0)
        #expect(response.payload[21] == 1)
        #expect(harness.model.notchStatus == .closed)
        #expect(harness.model.agentControlSelectedSessionID == nil)

        harness.transport.emit(
            .report(
                try slotSelectionReport(
                    sequence: 3,
                    slotIndex: AgentControlProtocolV1.toggleSlotIndex,
                    generation: generation
                )
            )
        )
        response = try AgentControlPacketCodec.decode(
            harness.transport.sentReports.last!
        )
        #expect(response.sequence == 3)
        #expect(response.flags == [.response])
        #expect(harness.model.notchStatus == .opened)
        #expect(harness.model.islandSurface == .sessionList())
        #expect(harness.model.agentControlSelectedSessionID == nil)
    }

    @Test
    func staleSnapshotAndReusedSlotAreRejectedWithoutJumping() async throws {
        let token: UInt64 = 0x0102_0304_0506_0708
        let harness = makeHarness(enabled: true, selectionToken: token)
        defer {
            harness.model.agentControlKeyboardEnabled = false
        }
        let now = Date()
        harness.model.state = SessionState(
            sessions: [
                makeSession(
                    id: "original",
                    firstSeenAt: now,
                    updatedAt: now,
                    phase: .running
                ),
            ]
        )
        harness.model.startAgentControlDeviceIntegrationIfNeeded()
        let hello = try AgentControlPacketCodec.decode(
            harness.transport.sentReports[0]
        )
        harness.transport.emit(
            .report(try capabilitiesReport(sequence: hello.sequence))
        )
        let firstSnapshot = try latestSnapshotPacket(
            in: harness.transport.sentReports
        )
        let generation = readUInt16(firstSnapshot.payload, at: 8)

        harness.transport.emit(
            .report(
                try slotSelectionReport(
                    sequence: 1,
                    slotIndex: 0,
                    generation: generation &+ 1
                )
            )
        )
        var response = try AgentControlPacketCodec.decode(
            harness.transport.sentReports.last!
        )
        #expect(response.flags == [.response, .error])
        #expect(
            response.payload[9]
                == AgentControlSelectionResult.staleSnapshot.rawValue
        )
        #expect(harness.model.selectedSessionID == nil)

        harness.transport.emit(
            .report(
                try slotSelectionReport(
                    sequence: 2,
                    slotIndex: 0,
                    generation: generation
                )
            )
        )
        response = try AgentControlPacketCodec.decode(
            harness.transport.sentReports.last!
        )
        #expect(
            response.payload[9]
                == AgentControlSelectionResult.accepted.rawValue
        )

        harness.model.state = SessionState(
            sessions: [
                makeSession(
                    id: "replacement",
                    firstSeenAt: now.addingTimeInterval(2),
                    updatedAt: now.addingTimeInterval(2),
                    phase: .running
                ),
            ]
        )
        harness.transport.emit(
            .report(
                try deviceReport(
                    type: .actionInvoked,
                    sequence: 3,
                    payload: littleEndianBytes(nonce)
                        + [0, AgentControlAction.jump.rawValue]
                        + littleEndianBytes(token)
                )
            )
        )
        response = try AgentControlPacketCodec.decode(
            harness.transport.sentReports.last!
        )
        #expect(response.flags == [.response, .error])
        #expect(
            response.payload[10]
                == AgentControlActionResult.slotUnassignedOrReused.rawValue
        )

        try? await Task.sleep(for: .milliseconds(30))
        #expect(harness.model.lastActionMessage != "Jumped to original.")
        #expect(harness.model.lastActionMessage != "Jumped to replacement.")
    }

    @Test
    func approvalKeysRemainUnsupportedUntilSeparateOptIn() throws {
        let harness = makeHarness(enabled: true)
        defer {
            harness.model.agentControlKeyboardEnabled = false
        }
        let now = Date()
        harness.model.state = SessionState(
            sessions: [
                makeSession(
                    id: "approval",
                    firstSeenAt: now,
                    updatedAt: now,
                    phase: .waitingForApproval,
                    permissionRequest: PermissionRequest(
                        title: "Edit",
                        summary: "Edit a file",
                        affectedPath: "/tmp/file"
                    )
                ),
            ]
        )
        harness.model.startAgentControlDeviceIntegrationIfNeeded()
        let hello = try AgentControlPacketCodec.decode(
            harness.transport.sentReports[0]
        )
        #expect(
            readUInt16(hello.payload, at: 10)
                == AgentControlCapabilitySet([
                    .stateSnapshots,
                    .selection,
                    .jump,
                ]).rawValue
        )
        harness.transport.emit(
            .report(try capabilitiesReport(sequence: hello.sequence))
        )
        harness.transport.emit(
            .report(
                try deviceReport(
                    type: .actionInvoked,
                    sequence: 1,
                    payload: littleEndianBytes(nonce)
                        + [0, AgentControlAction.allowOnce.rawValue]
                        + littleEndianBytes(99)
                )
            )
        )

        let response = try AgentControlPacketCodec.decode(
            harness.transport.sentReports.last!
        )
        #expect(response.messageType == .actionResult)
        #expect(response.flags == [.response, .error])
        #expect(
            response.payload[10]
                == AgentControlActionResult.unsupported.rawValue
        )
        #expect(
            harness.model.state.session(id: "approval")?.phase
                == .waitingForApproval
        )
    }

    @Test
    func changingApprovalOptInRenegotiatesCapabilitiesAndPersists() throws {
        let harness = makeHarness(enabled: true)
        defer {
            harness.model.agentControlKeyboardEnabled = false
        }
        harness.model.startAgentControlDeviceIntegrationIfNeeded()
        let navigationHello = try AgentControlPacketCodec.decode(
            harness.transport.sentReports[0]
        )
        harness.transport.emit(
            .report(
                try capabilitiesReport(
                    sequence: navigationHello.sequence
                )
            )
        )
        #expect(
            harness.model.agentControlDeviceDiagnostics.state == .ready
        )

        harness.model.agentControlKeyboardApprovalsEnabled = true

        let approvalHello = try AgentControlPacketCodec.decode(
            harness.transport.sentReports.last!
        )
        #expect(approvalHello.messageType == .hello)
        #expect(
            readUInt16(approvalHello.payload, at: 10)
                == AgentControlCapabilitySet.allV1.rawValue
        )
        #expect(
            harness.model.agentControlDeviceDiagnostics.state
                == .handshaking
        )
        #expect(
            harness.defaults.bool(
                forKey:
                    AgentControlDeviceSettingsStore
                        .approvalActionsDefaultsKey
            )
        )

        harness.transport.emit(
            .report(
                try capabilitiesReport(
                    sequence: approvalHello.sequence
                )
            )
        )
        #expect(
            harness.model.agentControlDeviceDiagnostics.state == .ready
        )
    }

    @Test
    func approvalOptInAdvertisesExactActionsAndAllowsOnce() throws {
        let spy = AgentControlPermissionResolutionSpy()
        let harness = makeHarness(
            enabled: true,
            approvalActionsEnabled: true,
            permissionResolver: spy.resolve
        )
        defer {
            harness.model.agentControlKeyboardEnabled = false
        }
        let request = PermissionRequest(
            title: "Edit",
            summary: "Edit a file",
            affectedPath: "/tmp/file"
        )
        let now = Date()
        harness.model.state = SessionState(
            sessions: [
                makeSession(
                    id: "approval",
                    firstSeenAt: now,
                    updatedAt: now,
                    phase: .waitingForApproval,
                    permissionRequest: request
                ),
            ]
        )
        harness.model.isBridgeReady = true
        harness.model.startAgentControlDeviceIntegrationIfNeeded()

        let hello = try AgentControlPacketCodec.decode(
            harness.transport.sentReports[0]
        )
        #expect(
            readUInt16(hello.payload, at: 10)
                == AgentControlCapabilitySet.allV1.rawValue
        )
        harness.transport.emit(
            .report(try capabilitiesReport(sequence: hello.sequence))
        )
        let snapshot = try latestSnapshotPacket(
            in: harness.transport.sentReports
        )
        #expect(
            snapshot.payload[11]
                == AgentControlLightState.waitingForActionableApproval.rawValue
        )
        let generation = readUInt16(snapshot.payload, at: 8)
        harness.transport.emit(
            .report(
                try slotSelectionReport(
                    sequence: 1,
                    slotIndex: 0,
                    generation: generation
                )
            )
        )
        let selection = try AgentControlPacketCodec.decode(
            harness.transport.sentReports.last!
        )
        #expect(
            selection.payload[20]
                == AgentControlAllowedActionSet([
                    .jump,
                    .allowOnce,
                    .deny,
                ]).rawValue
        )
        let token = readUInt64(selection.payload, at: 12)
        let actionReport = try deviceReport(
            type: .actionInvoked,
            sequence: 2,
            payload: littleEndianBytes(nonce)
                + [0, AgentControlAction.allowOnce.rawValue]
                + littleEndianBytes(token)
        )
        harness.transport.emit(.report(actionReport))

        var response = try AgentControlPacketCodec.decode(
            harness.transport.sentReports.last!
        )
        #expect(response.flags == [.response])
        #expect(
            response.payload[10]
                == AgentControlActionResult.acceptedForDispatch.rawValue
        )
        #expect(spy.calls.count == 1)
        #expect(spy.calls.first?.sessionID == "approval")
        #expect(spy.calls.first?.requestID == request.id)
        #expect(spy.calls.first?.resolution.isApproved == true)
        #expect(
            harness.model.state.session(id: "approval")?.phase == .running
        )

        harness.transport.emit(.report(actionReport))
        response = try AgentControlPacketCodec.decode(
            harness.transport.sentReports.last!
        )
        #expect(spy.calls.count == 1)
        #expect(
            harness.model.agentControlDeviceDiagnostics
                .duplicateOrOutOfOrderReportCount == 1
        )
        #expect(
            response.payload[10]
                == AgentControlActionResult.acceptedForDispatch.rawValue
        )
    }

    @Test
    func denialUsesTheSelectedRequestAndCompletesTheSession() throws {
        let spy = AgentControlPermissionResolutionSpy()
        let harness = makeHarness(
            enabled: true,
            approvalActionsEnabled: true,
            permissionResolver: spy.resolve
        )
        defer {
            harness.model.agentControlKeyboardEnabled = false
        }
        let request = PermissionRequest(
            title: "Delete",
            summary: "Delete a file",
            affectedPath: "/tmp/file"
        )
        let now = Date()
        harness.model.state = SessionState(
            sessions: [
                makeSession(
                    id: "approval",
                    firstSeenAt: now,
                    updatedAt: now,
                    phase: .waitingForApproval,
                    permissionRequest: request
                ),
            ]
        )
        harness.model.isBridgeReady = true
        let token = try connectAndSelectFirstSlot(harness)

        harness.transport.emit(
            .report(
                try actionReport(
                    sequence: 2,
                    action: .deny,
                    token: token
                )
            )
        )

        let response = try AgentControlPacketCodec.decode(
            harness.transport.sentReports.last!
        )
        #expect(response.flags == [.response])
        #expect(spy.calls.count == 1)
        #expect(spy.calls.first?.requestID == request.id)
        #expect(spy.calls.first?.resolution.isApproved == false)
        #expect(
            harness.model.state.session(id: "approval")?.phase == .completed
        )
    }

    @Test
    func replacedPermissionRequestFailsClosedWithoutCallingResolver() throws {
        let spy = AgentControlPermissionResolutionSpy()
        let harness = makeHarness(
            enabled: true,
            approvalActionsEnabled: true,
            permissionResolver: spy.resolve
        )
        defer {
            harness.model.agentControlKeyboardEnabled = false
        }
        let firstRequest = PermissionRequest(
            title: "First",
            summary: "First request",
            affectedPath: "/tmp/first"
        )
        let now = Date()
        harness.model.state = SessionState(
            sessions: [
                makeSession(
                    id: "approval",
                    firstSeenAt: now,
                    updatedAt: now,
                    phase: .waitingForApproval,
                    permissionRequest: firstRequest
                ),
            ]
        )
        harness.model.isBridgeReady = true
        let token = try connectAndSelectFirstSlot(harness)
        let replacement = PermissionRequest(
            title: "Replacement",
            summary: "Replacement request",
            affectedPath: "/tmp/replacement"
        )
        harness.model.state = SessionState(
            sessions: [
                makeSession(
                    id: "approval",
                    firstSeenAt: now,
                    updatedAt: now.addingTimeInterval(1),
                    phase: .waitingForApproval,
                    permissionRequest: replacement
                ),
            ]
        )

        harness.transport.emit(
            .report(
                try actionReport(
                    sequence: 2,
                    action: .allowOnce,
                    token: token
                )
            )
        )

        let response = try AgentControlPacketCodec.decode(
            harness.transport.sentReports.last!
        )
        #expect(response.flags == [.response, .error])
        #expect(
            response.payload[10]
                == AgentControlActionResult
                    .permissionRequestChangedOrExpired.rawValue
        )
        #expect(spy.calls.isEmpty)
        #expect(
            harness.model.state.session(id: "approval")?
                .permissionRequest?.id == replacement.id
        )
    }

    @Test
    func questionsObserverWaitsAndTerminalApprovalsNeverExposeActions() throws {
        let spy = AgentControlPermissionResolutionSpy()
        let harness = makeHarness(
            enabled: true,
            approvalActionsEnabled: true,
            permissionResolver: spy.resolve
        )
        defer {
            harness.model.agentControlKeyboardEnabled = false
        }
        let now = Date()
        harness.model.state = SessionState(
            sessions: [
                makeSession(
                    id: "observer",
                    firstSeenAt: now,
                    updatedAt: now,
                    phase: .waitingForApproval
                ),
                makeSession(
                    id: "question",
                    firstSeenAt: now.addingTimeInterval(1),
                    updatedAt: now,
                    phase: .waitingForAnswer
                ),
                makeSession(
                    id: "terminal",
                    firstSeenAt: now.addingTimeInterval(2),
                    updatedAt: now,
                    phase: .waitingForApproval,
                    permissionRequest: PermissionRequest(
                        title: "Terminal only",
                        summary: "Approve in terminal",
                        affectedPath: "/tmp/terminal",
                        requiresTerminalApproval: true
                    )
                ),
            ]
        )
        harness.model.isBridgeReady = true
        harness.model.startAgentControlDeviceIntegrationIfNeeded()
        let hello = try AgentControlPacketCodec.decode(
            harness.transport.sentReports[0]
        )
        harness.transport.emit(
            .report(try capabilitiesReport(sequence: hello.sequence))
        )
        let snapshot = try latestSnapshotPacket(
            in: harness.transport.sentReports
        )
        let generation = readUInt16(snapshot.payload, at: 8)

        for (index, sequence) in [(0, 1), (1, 3), (2, 5)] {
            harness.transport.emit(
                .report(
                    try slotSelectionReport(
                        sequence: UInt16(sequence),
                        slotIndex: UInt8(index),
                        generation: generation
                    )
                )
            )
            let selection = try AgentControlPacketCodec.decode(
                harness.transport.sentReports.last!
            )
            #expect(
                selection.payload[20]
                    == AgentControlAllowedActionSet.jump.rawValue
            )
            let token = readUInt64(selection.payload, at: 12)
            harness.transport.emit(
                .report(
                    try actionReport(
                        sequence: UInt16(sequence + 1),
                        slotIndex: UInt8(index),
                        action: .allowOnce,
                        token: token
                    )
                )
            )
            let response = try AgentControlPacketCodec.decode(
                harness.transport.sentReports.last!
            )
            #expect(
                response.payload[10]
                    == AgentControlActionResult.actionUnavailable.rawValue
            )
        }
        #expect(spy.calls.isEmpty)
    }

    @Test
    func expiredSelectionAndBridgeDisconnectBothFailClosed() throws {
        let spy = AgentControlPermissionResolutionSpy()
        let clock = AgentControlMutableClock(now: Date())
        let harness = makeHarness(
            enabled: true,
            approvalActionsEnabled: true,
            permissionResolver: spy.resolve,
            dateProvider: { clock.now }
        )
        defer {
            harness.model.agentControlKeyboardEnabled = false
        }
        let request = PermissionRequest(
            title: "Edit",
            summary: "Edit a file",
            affectedPath: "/tmp/file"
        )
        harness.model.state = SessionState(
            sessions: [
                makeSession(
                    id: "approval",
                    firstSeenAt: clock.now,
                    updatedAt: clock.now,
                    phase: .waitingForApproval,
                    permissionRequest: request
                ),
            ]
        )
        harness.model.isBridgeReady = true
        var token = try connectAndSelectFirstSlot(harness)
        clock.now = clock.now.addingTimeInterval(16)
        harness.transport.emit(
            .report(
                try actionReport(
                    sequence: 2,
                    action: .allowOnce,
                    token: token
                )
            )
        )
        var response = try AgentControlPacketCodec.decode(
            harness.transport.sentReports.last!
        )
        #expect(
            response.payload[10]
                == AgentControlActionResult.staleOrUnknownToken.rawValue
        )
        #expect(spy.calls.isEmpty)

        token = try selectFirstSlot(
            harness,
            sequence: 3
        )
        harness.model.isBridgeReady = false
        harness.transport.emit(
            .report(
                try actionReport(
                    sequence: 4,
                    action: .allowOnce,
                    token: token
                )
            )
        )
        response = try AgentControlPacketCodec.decode(
            harness.transport.sentReports.last!
        )
        #expect(
            response.payload[10]
                == AgentControlActionResult.noValidSelection.rawValue
        )
        #expect(spy.calls.isEmpty)
    }

    @Test
    func completedSlotIsClearedWhenItsConfiguredWindowExpires() async throws {
        let harness = makeHarness(enabled: true)
        let previousThreshold = harness.model.completedStaleThreshold
        defer {
            harness.model.completedStaleThreshold = previousThreshold
            harness.model.agentControlKeyboardEnabled = false
        }
        harness.model.completedStaleThreshold = .twoMinutes
        let now = Date()
        harness.model.state = SessionState(
            sessions: [
                makeSession(
                    id: "completed",
                    firstSeenAt: now.addingTimeInterval(-121),
                    updatedAt: now.addingTimeInterval(-119.8),
                    phase: .completed
                ),
            ]
        )
        harness.model.startAgentControlDeviceIntegrationIfNeeded()
        let hello = try AgentControlPacketCodec.decode(
            harness.transport.sentReports[0]
        )
        harness.transport.emit(
            .report(try capabilitiesReport(sequence: hello.sequence))
        )

        let initialSnapshot = try latestSnapshotPacket(
            in: harness.transport.sentReports
        )
        #expect(
            initialSnapshot.payload[11]
                == AgentControlLightState.recentlyCompleted.rawValue
        )

        await waitUntil {
            guard let packet = try? latestSnapshotPacket(
                in: harness.transport.sentReports
            ) else {
                return false
            }
            return packet.payload[11] == 0
        }

        let expiredSnapshot = try latestSnapshotPacket(
            in: harness.transport.sentReports
        )
        #expect(expiredSnapshot.payload[11] == 0)
    }

    private func makeHarness(
        enabled: Bool,
        approvalActionsEnabled: Bool = false,
        selectionToken: UInt64 = 0x1122_3344_5566_7788,
        permissionResolver: ((
            String,
            UUID,
            PermissionResolution
        ) -> BridgePermissionResolutionResult)? = nil,
        dateProvider: @escaping () -> Date = Date.init
    ) -> Harness {
        let suiteName =
            "agent-island-control-app-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set(
            enabled,
            forKey: AgentControlDeviceSettingsStore.defaultsKey
        )
        defaults.set(
            approvalActionsEnabled,
            forKey:
                AgentControlDeviceSettingsStore.approvalActionsDefaultsKey
        )
        let transport = FakeAgentControlHIDTransport(
            automaticallyConnectedDevice: AgentControlHIDDeviceDescriptor(
                registryEntryID: 42,
                locationID: 7
            )
        )
        let coordinator = AgentControlDeviceCoordinator(
            transport: transport,
            powerEventSource: FakeAgentControlPowerEventSource(),
            nonceGenerator: { nonce },
            heartbeatInterval: .seconds(60),
            handshakeTimeout: .seconds(60),
            reconnectDelay: .seconds(60)
        )
        let model = AppModel(
            terminalJumpAction: { target in
                "Jumped to \(target.workspaceName)."
            },
            hiddenSessionStore: HiddenSessionStore(defaults: defaults),
            agentControlSlotAssignmentStore:
                AgentControlSlotAssignmentStore(defaults: defaults),
            agentControlDeviceCoordinator: coordinator,
            agentControlDeviceSettingsStore:
                AgentControlDeviceSettingsStore(defaults: defaults),
            agentControlPermissionResolver: permissionResolver,
            agentControlSelectionTokenGenerator: { selectionToken },
            agentControlDateProvider: dateProvider
        )
        return (model, transport, defaults)
    }

    private func connectAndSelectFirstSlot(
        _ harness: Harness
    ) throws -> UInt64 {
        harness.model.startAgentControlDeviceIntegrationIfNeeded()
        let hello = try AgentControlPacketCodec.decode(
            harness.transport.sentReports[0]
        )
        harness.transport.emit(
            .report(try capabilitiesReport(sequence: hello.sequence))
        )
        return try selectFirstSlot(harness, sequence: 1)
    }

    private func selectFirstSlot(
        _ harness: Harness,
        sequence: UInt16
    ) throws -> UInt64 {
        let snapshot = try latestSnapshotPacket(
            in: harness.transport.sentReports
        )
        let generation = readUInt16(snapshot.payload, at: 8)
        harness.transport.emit(
            .report(
                try slotSelectionReport(
                    sequence: sequence,
                    slotIndex: 0,
                    generation: generation
                )
            )
        )
        let selection = try AgentControlPacketCodec.decode(
            harness.transport.sentReports.last!
        )
        return readUInt64(selection.payload, at: 12)
    }

    private func makeSession(
        id: String,
        firstSeenAt: Date,
        updatedAt: Date,
        phase: SessionPhase,
        permissionRequest: PermissionRequest? = nil
    ) -> AgentSession {
        var session = AgentSession(
            id: id,
            title: "Claude · \(id)",
            tool: .claudeCode,
            origin: .live,
            attachmentState: .attached,
            phase: phase,
            summary: "",
            updatedAt: updatedAt,
            firstSeenAt: firstSeenAt,
            permissionRequest: permissionRequest,
            jumpTarget: JumpTarget(
                terminalApp: "Ghostty",
                workspaceName: id,
                paneTitle: "claude ~/\(id)",
                workingDirectory: "/tmp/\(id)",
                terminalSessionID: "ghostty-\(id)"
            ),
            claudeMetadata: ClaudeSessionMetadata(
                transcriptPath: "/tmp/\(id).jsonl",
                currentTool: "Task"
            )
        )
        session.isProcessAlive = true
        session.isHookManaged = true
        return session
    }

    private func capabilitiesReport(sequence: UInt16) throws -> Data {
        var payload = littleEndianBytes(nonce)
        payload += [
            AgentControlProtocolV1.minorVersion,
            UInt8(AgentControlProtocolV1.slotCount),
        ]
        payload += [
            UInt8(
                truncatingIfNeeded:
                    AgentControlCapabilitySet.allV1.rawValue
            ),
            UInt8(
                truncatingIfNeeded:
                    AgentControlCapabilitySet.allV1.rawValue >> 8
            ),
            AgentControlActiveTransport.usb.rawValue,
            6,
            0x54, 0xFB, 0x1C, 0xA4,
        ]
        return try AgentControlPacketCodec.encode(
            AgentControlPacket(
                messageType: .capabilities,
                flags: [.response],
                sequence: sequence,
                payload: Data(payload)
            )
        )
    }

    private func deviceReport(
        type: AgentControlMessageType,
        sequence: UInt16,
        payload: [UInt8]
    ) throws -> Data {
        try AgentControlPacketCodec.encode(
            AgentControlPacket(
                messageType: type,
                sequence: sequence,
                payload: Data(payload)
            )
        )
    }

    private func slotSelectionReport(
        sequence: UInt16,
        slotIndex: UInt8,
        generation: UInt16
    ) throws -> Data {
        try deviceReport(
            type: .slotSelected,
            sequence: sequence,
            payload: littleEndianBytes(nonce)
                + [
                    slotIndex,
                    UInt8(truncatingIfNeeded: generation),
                    UInt8(truncatingIfNeeded: generation >> 8),
                ]
        )
    }

    private func actionReport(
        sequence: UInt16,
        slotIndex: UInt8 = 0,
        action: AgentControlAction,
        token: UInt64
    ) throws -> Data {
        try deviceReport(
            type: .actionInvoked,
            sequence: sequence,
            payload: littleEndianBytes(nonce)
                + [slotIndex, action.rawValue]
                + littleEndianBytes(token)
        )
    }

    private func latestSnapshotPacket(
        in reports: [Data]
    ) throws -> AgentControlPacket {
        let packets = try reports.map(AgentControlPacketCodec.decode)
        return try #require(
            packets.last { $0.messageType == .stateSnapshot }
        )
    }

    private func littleEndianBytes(_ value: UInt64) -> [UInt8] {
        stride(from: 0, through: 56, by: 8).map {
            UInt8(truncatingIfNeeded: value >> UInt64($0))
        }
    }

    private func readUInt16(_ data: Data, at offset: Int) -> UInt16 {
        let bytes = [UInt8](data)
        return UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
    }

    private func readUInt64(_ data: Data, at offset: Int) -> UInt64 {
        let bytes = [UInt8](data)
        var value: UInt64 = 0
        for byteOffset in 0..<8 {
            value |= UInt64(bytes[offset + byteOffset])
                << UInt64(byteOffset * 8)
        }
        return value
    }

    private func waitUntil(
        _ predicate: @escaping @MainActor () -> Bool
    ) async {
        for _ in 0..<100 {
            if predicate() {
                return
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Timed out waiting for Agent Control snapshot update")
    }
}

@MainActor
private final class AgentControlPermissionResolutionSpy {
    struct Call {
        let sessionID: String
        let requestID: UUID
        let resolution: PermissionResolution
    }

    var result: BridgePermissionResolutionResult = .resolved
    private(set) var calls: [Call] = []

    func resolve(
        sessionID: String,
        requestID: UUID,
        resolution: PermissionResolution
    ) -> BridgePermissionResolutionResult {
        calls.append(
            Call(
                sessionID: sessionID,
                requestID: requestID,
                resolution: resolution
            )
        )
        return result
    }
}

@MainActor
private final class AgentControlMutableClock {
    var now: Date

    init(now: Date) {
        self.now = now
    }
}
