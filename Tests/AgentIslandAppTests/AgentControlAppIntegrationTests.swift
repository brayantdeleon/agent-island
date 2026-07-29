import Foundation
import Testing
@testable import AgentIslandApp
import AgentIslandCore

@MainActor
@Suite(.serialized)
struct AgentControlAppIntegrationTests {
    private let nonce: UInt64 = 0x0123_4567_89AB_CDEF

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
        #expect(readUInt16(hello.payload, at: 10) == 1)

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
    func deviceIntentsAreProcessedButHaveNoAppActionRoute() throws {
        let harness = makeHarness(enabled: true)
        defer {
            harness.model.agentControlKeyboardEnabled = false
        }
        let now = Date()
        let approval = makeSession(
            id: "approval",
            firstSeenAt: now,
            updatedAt: now,
            phase: .waitingForApproval,
            permissionRequest: PermissionRequest(
                title: "Edit",
                summary: "Edit a file",
                affectedPath: "/tmp/file"
            )
        )
        harness.model.state = SessionState(sessions: [approval])
        let originalMessage = harness.model.lastActionMessage
        harness.model.startAgentControlDeviceIntegrationIfNeeded()
        let hello = try AgentControlPacketCodec.decode(
            harness.transport.sentReports[0]
        )
        harness.transport.emit(
            .report(try capabilitiesReport(sequence: hello.sequence))
        )
        let reportCountBeforeIntents = harness.transport.sentReports.count

        harness.transport.emit(
            .report(
                try deviceReport(
                    type: .slotSelected,
                    sequence: 1,
                    payload: littleEndianBytes(nonce)
                        + [0, 1, 0]
                )
            )
        )
        for (offset, action) in AgentControlAction.allTestCases.enumerated() {
            harness.transport.emit(
                .report(
                    try deviceReport(
                        type: .actionInvoked,
                        sequence: UInt16(offset + 2),
                        payload: littleEndianBytes(nonce)
                            + [0, action.rawValue]
                            + littleEndianBytes(UInt64(77 + offset))
                    )
                )
            )
        }
        harness.transport.emit(
            .report(
                try deviceReport(
                    type: .layerChanged,
                    sequence: 5,
                    payload: littleEndianBytes(nonce)
                        + [
                            1,
                            AgentControlLayerChangeReason
                                .controlKey.rawValue,
                        ]
                )
            )
        )

        #expect(harness.model.selectedSessionID == nil)
        #expect(
            harness.model.state.session(id: "approval")?.phase
                == .waitingForApproval
        )
        #expect(harness.model.lastActionMessage == originalMessage)
        #expect(harness.transport.sentReports.count == reportCountBeforeIntents)
        #expect(
            harness.model.agentControlDeviceDiagnostics.lastLayerEnabled
                == true
        )
        #expect(
            harness.model.agentControlDeviceDiagnostics
                .duplicateOrOutOfOrderReportCount == 0
        )
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
        enabled: Bool
    ) -> (
        model: AppModel,
        transport: FakeAgentControlHIDTransport,
        defaults: UserDefaults
    ) {
        let suiteName =
            "agent-island-control-app-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set(
            enabled,
            forKey: AgentControlDeviceSettingsStore.defaultsKey
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
            hiddenSessionStore: HiddenSessionStore(defaults: defaults),
            agentControlSlotAssignmentStore:
                AgentControlSlotAssignmentStore(defaults: defaults),
            agentControlDeviceCoordinator: coordinator,
            agentControlDeviceSettingsStore:
                AgentControlDeviceSettingsStore(defaults: defaults)
        )
        return (model, transport, defaults)
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

private extension AgentControlAction {
    static let allTestCases: [Self] = [
        .jump,
        .allowOnce,
        .deny,
    ]
}
