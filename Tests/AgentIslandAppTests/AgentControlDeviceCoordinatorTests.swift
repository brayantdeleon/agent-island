import Foundation
import Testing
@testable import AgentIslandApp
import AgentIslandCore

@MainActor
@Suite(.serialized)
struct AgentControlDeviceCoordinatorTests {
    private let firstNonce: UInt64 = 0x0123_4567_89AB_CDEF

    @Test
    func successfulHandshakeNegotiatesCapabilitiesAndStructuredDiagnostics() throws {
        let harness = makeHarness()
        defer { harness.coordinator.stop() }

        harness.coordinator.start()

        #expect(harness.transport.startCount == 1)
        #expect(harness.transport.sentReports.count == 1)
        let hello = try AgentControlPacketCodec.decode(
            harness.transport.sentReports[0]
        )
        #expect(hello.messageType == .hello)
        #expect(hello.sequence == 1)
        #expect(
            [UInt8](hello.payload)
                == [0, 0xEF, 0xCD, 0xAB, 0x89, 0x67, 0x45, 0x23, 0x01, 6, 7, 0]
        )

        harness.transport.emit(
            .report(try capabilitiesReport(nonce: firstNonce, sequence: 1))
        )

        #expect(harness.coordinator.diagnostics.state == .ready)
        #expect(harness.coordinator.diagnostics.activeTransport == .usb)
        #expect(harness.coordinator.diagnostics.protocolMinor == 0)
        #expect(harness.coordinator.diagnostics.effectiveWatchdogSeconds == 6)
        #expect(
            harness.coordinator.diagnostics.firmwareBuildIdentifier
                == 0x4103_537D
        )
        #expect(harness.coordinator.diagnostics.matchingDeviceCount == 1)
        #expect(harness.coordinator.diagnostics.summary.contains("USB"))
    }

    @Test
    func handshakeRejectsUnsupportedCapabilityCombinations() throws {
        struct Scenario {
            let name: String
            var minor: UInt8 = 0
            var slotCount: UInt8 = 10
            var capabilities: AgentControlCapabilitySet = .allV1
            var transport: AgentControlActiveTransport = .usb
            var watchdog: UInt8 = 6
        }
        let scenarios = [
            Scenario(name: "minor", minor: 1),
            Scenario(name: "slot count", slotCount: 9),
            Scenario(name: "snapshots", capabilities: [.selection]),
            Scenario(
                name: "reserved capabilities",
                capabilities: AgentControlCapabilitySet(rawValue: 0x21)
            ),
            Scenario(name: "Bluetooth", transport: .bluetooth),
            Scenario(name: "watchdog", watchdog: 2),
        ]

        for scenario in scenarios {
            let harness = makeHarness()
            harness.coordinator.start()
            harness.transport.emit(
                .report(
                    try capabilitiesReport(
                        nonce: firstNonce,
                        sequence: 1,
                        minor: scenario.minor,
                        slotCount: scenario.slotCount,
                        capabilities: scenario.capabilities,
                        transport: scenario.transport,
                        watchdog: scenario.watchdog
                    )
                )
            )

            #expect(
                harness.coordinator.diagnostics.state == .incompatible,
                "Scenario: \(scenario.name)"
            )
            #expect(
                harness.coordinator.diagnostics.lastError != nil,
                "Scenario: \(scenario.name)"
            )
            harness.coordinator.stop()
        }
    }

    @Test
    func incompatibleMajorVersionStopsHandshakeWithoutReconnectChurn() throws {
        let harness = makeHarness(
            handshakeTimeout: .milliseconds(10),
            reconnectDelay: .milliseconds(10)
        )
        defer { harness.coordinator.stop() }
        harness.coordinator.start()
        var report = [UInt8](
            try capabilitiesReport(nonce: firstNonce, sequence: 1)
        )
        report[3] = 2
        report[31] = AgentControlPacketCodec.crc8(report.dropLast())

        harness.transport.emit(.report(Data(report)))

        #expect(harness.coordinator.diagnostics.state == .incompatible)
        #expect(harness.coordinator.diagnostics.lastError?.contains("major") == true)
        #expect(harness.coordinator.diagnostics.reconnectCount == 0)
    }

    @Test
    func heartbeatUsesMonotonicHostSequences() async throws {
        let harness = makeHarness(heartbeatInterval: .milliseconds(15))
        defer { harness.coordinator.stop() }
        harness.coordinator.start()
        harness.transport.emit(
            .report(try capabilitiesReport(nonce: firstNonce, sequence: 1))
        )

        try await waitUntil {
            harness.transport.sentReports.count >= 3
        }

        let packets = try harness.transport.sentReports.map(
            AgentControlPacketCodec.decode
        )
        let heartbeatPackets = packets.filter {
            $0.messageType == .heartbeat
        }
        #expect(heartbeatPackets.count >= 2)
        #expect(packets.map(\.sequence) == Array(1...UInt16(packets.count)))
        #expect(
            heartbeatPackets.allSatisfy {
                $0.payload
                    == AgentControlMessageCodec.heartbeatPayload(
                        connectionNonce: firstNonce
                    )
            }
        )
    }

    @Test
    func snapshotDedupIncludesSlotIdentityAndResetsOnReconnect() throws {
        let harness = makeHarness()
        defer { harness.coordinator.stop() }
        let first = AgentControlSnapshotContent(
            slots: [
                AgentControlSnapshotSlot(identity: "A", lightState: .running),
            ],
            overflowCount: 0
        )
        harness.coordinator.setSnapshot(first)
        harness.coordinator.start()
        harness.transport.emit(
            .report(try capabilitiesReport(nonce: firstNonce, sequence: 1))
        )

        harness.coordinator.setSnapshot(first)
        let reused = AgentControlSnapshotContent(
            slots: [
                AgentControlSnapshotSlot(identity: "B", lightState: .running),
            ],
            overflowCount: 0
        )
        harness.coordinator.setSnapshot(reused)

        let snapshotPackets = try harness.transport.sentReports
            .map(AgentControlPacketCodec.decode)
            .filter { $0.messageType == .stateSnapshot }

        #expect(snapshotPackets.count == 2)
        #expect(snapshotPackets.map(\.sequence) == [2, 3])
        #expect(snapshotPackets.map { readUInt16($0.payload, at: 8) } == [1, 2])
        var normalizedSecondPayload = snapshotPackets[1].payload
        normalizedSecondPayload.replaceSubrange(8..<10, with: [1, 0])
        #expect(snapshotPackets[0].payload == normalizedSecondPayload)
        #expect(harness.coordinator.diagnostics.snapshotGeneration == 2)
    }

    @Test
    func slotEpochChangesOnlyWhenThatSlotChanges() throws {
        let harness = makeHarness()
        defer { harness.coordinator.stop() }
        harness.coordinator.setSnapshot(
            AgentControlSnapshotContent(
                slots: [
                    AgentControlSnapshotSlot(identity: "A", lightState: .running),
                    AgentControlSnapshotSlot(identity: "B", lightState: .running),
                ],
                overflowCount: 0
            )
        )
        harness.coordinator.start()
        harness.transport.emit(
            .report(try capabilitiesReport(nonce: firstNonce, sequence: 1))
        )
        #expect(
            Array(harness.coordinator.currentSnapshot?.slotEpochs.prefix(2) ?? [])
                == [1, 1]
        )

        harness.coordinator.setSnapshot(
            AgentControlSnapshotContent(
                slots: [
                    AgentControlSnapshotSlot(identity: "A", lightState: .running),
                    AgentControlSnapshotSlot(identity: "B", lightState: .recentlyCompleted),
                ],
                overflowCount: 0
            )
        )
        #expect(
            Array(harness.coordinator.currentSnapshot?.slotEpochs.prefix(2) ?? [])
                == [1, 2]
        )

        harness.coordinator.setSnapshot(
            AgentControlSnapshotContent(
                slots: [
                    AgentControlSnapshotSlot(identity: "C", lightState: .running),
                    AgentControlSnapshotSlot(identity: "B", lightState: .recentlyCompleted),
                ],
                overflowCount: 0
            )
        )
        #expect(
            Array(harness.coordinator.currentSnapshot?.slotEpochs.prefix(2) ?? [])
                == [2, 2]
        )
    }

    @Test
    func navigationResponsesEchoRequestSequenceAndSetResponseFlags() throws {
        let harness = makeHarness()
        defer { harness.coordinator.stop() }
        harness.coordinator.start()
        harness.transport.emit(
            .report(try capabilitiesReport(nonce: firstNonce, sequence: 1))
        )

        #expect(
            harness.coordinator.sendSelectionAcknowledgement(
                requestSequence: 41,
                connectionNonce: firstNonce,
                slotIndex: 2,
                result: .accepted,
                slotEpoch: 7,
                selectionToken: 99,
                allowedActions: [.jump],
                lifetimeSeconds: 15
            )
        )
        #expect(
            harness.coordinator.sendActionResult(
                requestSequence: 42,
                connectionNonce: firstNonce,
                slotIndex: 2,
                action: .jump,
                result: .staleOrUnknownToken
            )
        )

        let selection = try AgentControlPacketCodec.decode(
            harness.transport.sentReports[harness.transport.sentReports.count - 2]
        )
        let action = try AgentControlPacketCodec.decode(
            harness.transport.sentReports.last!
        )
        #expect(selection.messageType == .selectionAcknowledgement)
        #expect(selection.sequence == 41)
        #expect(selection.flags == [.response])
        #expect(selection.payload[9] == AgentControlSelectionResult.accepted.rawValue)
        #expect(action.messageType == .actionResult)
        #expect(action.sequence == 42)
        #expect(action.flags == [.response, .error])
        #expect(
            action.payload[10]
                == AgentControlActionResult.staleOrUnknownToken.rawValue
        )
    }

    @Test
    func sendFailureRestartsTransportWithNewNonceAndResendsDesiredSnapshot() async throws {
        var nonce = firstNonce
        let harness = makeHarness(
            nonceGenerator: {
                defer { nonce &+= 1 }
                return nonce
            },
            reconnectDelay: .milliseconds(10)
        )
        defer { harness.coordinator.stop() }
        harness.coordinator.start()
        harness.transport.emit(
            .report(try capabilitiesReport(nonce: firstNonce, sequence: 1))
        )

        harness.transport.nextSendError = AgentControlHIDTransportError.notConnected
        harness.coordinator.setSnapshot(
            AgentControlSnapshotContent(
                slots: [
                    AgentControlSnapshotSlot(identity: "A", lightState: .running),
                ],
                overflowCount: 0
            )
        )

        try await waitUntil {
            harness.transport.startCount >= 2
                && harness.coordinator.diagnostics.state == .handshaking
        }
        #expect(harness.coordinator.diagnostics.reconnectCount == 1)

        let secondNonce = firstNonce + 1
        harness.transport.emit(
            .report(try capabilitiesReport(nonce: secondNonce, sequence: 1))
        )

        #expect(harness.coordinator.diagnostics.state == .ready)
        let packets = try harness.transport.sentReports.map(
            AgentControlPacketCodec.decode
        )
        #expect(packets.filter { $0.messageType == .hello }.count == 2)
        #expect(packets.last?.messageType == .stateSnapshot)
        #expect(readUInt64(packets.last!.payload, at: 0) == secondNonce)
    }

    @Test
    func disconnectAndReplugPerformFreshHandshakeWithoutRestartingManager() throws {
        var nonce = firstNonce
        let harness = makeHarness(nonceGenerator: {
            defer { nonce &+= 1 }
            return nonce
        })
        defer { harness.coordinator.stop() }
        harness.coordinator.start()
        harness.transport.emit(
            .report(try capabilitiesReport(nonce: firstNonce, sequence: 1))
        )
        #expect(harness.coordinator.diagnostics.state == .ready)

        harness.transport.emit(
            .disconnected(
                device: harness.device,
                matchingDeviceCount: 0
            )
        )
        #expect(harness.coordinator.diagnostics.state == .searching)
        #expect(harness.coordinator.diagnostics.selectedDevice == nil)

        harness.transport.emit(
            .connected(device: harness.device, matchingDeviceCount: 1)
        )
        #expect(harness.coordinator.diagnostics.state == .handshaking)
        harness.transport.emit(
            .report(
                try capabilitiesReport(
                    nonce: firstNonce + 1,
                    sequence: 1
                )
            )
        )

        #expect(harness.coordinator.diagnostics.state == .ready)
        #expect(harness.transport.startCount == 1)
        let helloPackets = try harness.transport.sentReports
            .map(AgentControlPacketCodec.decode)
            .filter { $0.messageType == .hello }
        #expect(helloPackets.count == 2)
        #expect(helloPackets.allSatisfy { $0.sequence == 1 })
    }

    @Test
    func staleCapabilitiesAndPreNegotiationEventsDoNotPoisonReconnect() throws {
        var nonce = firstNonce
        let harness = makeHarness(nonceGenerator: {
            defer { nonce &+= 1 }
            return nonce
        })
        defer { harness.coordinator.stop() }
        harness.coordinator.start()
        harness.transport.emit(
            .disconnected(
                device: harness.device,
                matchingDeviceCount: 0
            )
        )
        harness.transport.emit(
            .connected(device: harness.device, matchingDeviceCount: 1)
        )

        harness.transport.emit(
            .report(
                try layerChangedReport(
                    nonce: firstNonce + 1,
                    sequence: 1,
                    enabled: true
                )
            )
        )
        harness.transport.emit(
            .report(try capabilitiesReport(nonce: firstNonce, sequence: 1))
        )

        #expect(harness.coordinator.diagnostics.state == .handshaking)
        #expect(harness.coordinator.diagnostics.ignoredReportCount == 2)

        harness.transport.emit(
            .report(
                try capabilitiesReport(
                    nonce: firstNonce + 1,
                    sequence: 1
                )
            )
        )
        #expect(harness.coordinator.diagnostics.state == .ready)
    }

    @Test
    func sleepAndWakeCloseAndReopenTransportWithFreshConnection() throws {
        var nonce = firstNonce
        let harness = makeHarness(nonceGenerator: {
            defer { nonce &+= 1 }
            return nonce
        })
        defer { harness.coordinator.stop() }
        harness.coordinator.start()
        harness.transport.emit(
            .report(try capabilitiesReport(nonce: firstNonce, sequence: 1))
        )

        harness.power.emitSleep()
        #expect(harness.coordinator.diagnostics.state == .sleeping)
        #expect(harness.transport.stopCount == 1)

        harness.power.emitWake()
        #expect(harness.transport.startCount == 2)
        #expect(harness.coordinator.diagnostics.state == .handshaking)
        #expect(harness.coordinator.diagnostics.reconnectCount == 1)
        harness.transport.emit(
            .report(
                try capabilitiesReport(
                    nonce: firstNonce + 1,
                    sequence: 1
                )
            )
        )
        #expect(harness.coordinator.diagnostics.state == .ready)
    }

    @Test
    func malformedForeignDuplicateAndOutOfOrderReportsAreContained() throws {
        let harness = makeHarness()
        defer { harness.coordinator.stop() }
        var messages: [AgentControlDeviceMessage] = []
        harness.coordinator.onDeviceMessage = { messages.append($0.message) }
        harness.coordinator.start()
        harness.transport.emit(
            .report(try capabilitiesReport(nonce: firstNonce, sequence: 1))
        )

        var launcherReport = Data(repeating: 0, count: 32)
        launcherReport[0] = 0xA0
        harness.transport.emit(.report(launcherReport))

        var malformed = Data(repeating: 0, count: 32)
        malformed[0] = AgentControlProtocolV1.commandFamily
        harness.transport.emit(.report(malformed))

        let firstLayer = try layerChangedReport(
            nonce: firstNonce,
            sequence: 1,
            enabled: true
        )
        harness.transport.emit(.report(firstLayer))
        harness.transport.emit(.report(firstLayer))
        harness.transport.emit(
            .report(
                try layerChangedReport(
                    nonce: firstNonce,
                    sequence: 0,
                    enabled: false
                )
            )
        )
        harness.transport.emit(
            .report(
                try layerChangedReport(
                    nonce: firstNonce + 99,
                    sequence: 2,
                    enabled: false
                )
            )
        )
        harness.transport.emit(
            .report(
                try layerChangedReport(
                    nonce: firstNonce,
                    sequence: 2,
                    enabled: false
                )
            )
        )

        #expect(messages.count == 2)
        #expect(harness.coordinator.diagnostics.ignoredReportCount == 2)
        #expect(harness.coordinator.diagnostics.invalidReportCount == 1)
        #expect(
            harness.coordinator.diagnostics
                .duplicateOrOutOfOrderReportCount == 2
        )
        #expect(harness.coordinator.diagnostics.lastLayerEnabled == false)
    }

    @Test
    func handshakeTimeoutAutomaticallyRetries() async {
        let harness = makeHarness(
            handshakeTimeout: .milliseconds(10),
            reconnectDelay: .milliseconds(10)
        )
        defer { harness.coordinator.stop() }
        harness.coordinator.start()

        try? await waitUntil {
            harness.transport.startCount >= 2
        }

        #expect(harness.transport.startCount >= 2)
        #expect(harness.coordinator.diagnostics.reconnectCount >= 1)
        #expect(harness.coordinator.diagnostics.state == .handshaking)
    }

    @Test
    func multipleMatchingDevicesUseLocationThenRegistryID() {
        let highLocation = AgentControlHIDDeviceDescriptor(
            registryEntryID: 1,
            locationID: 200
        )
        let lowLocationHighRegistry = AgentControlHIDDeviceDescriptor(
            registryEntryID: 10,
            locationID: 100
        )
        let lowLocationLowRegistry = AgentControlHIDDeviceDescriptor(
            registryEntryID: 2,
            locationID: 100
        )

        #expect(
            AgentControlHIDDeviceDescriptor.preferred(
                from: [
                    highLocation,
                    lowLocationHighRegistry,
                    lowLocationLowRegistry,
                ]
            ) == lowLocationLowRegistry
        )
    }

    private func makeHarness(
        nonceGenerator: @escaping () -> UInt64 = {
            0x0123_4567_89AB_CDEF
        },
        heartbeatInterval: Duration = .seconds(60),
        handshakeTimeout: Duration = .seconds(60),
        reconnectDelay: Duration = .seconds(60)
    ) -> (
        coordinator: AgentControlDeviceCoordinator,
        transport: FakeAgentControlHIDTransport,
        power: FakeAgentControlPowerEventSource,
        device: AgentControlHIDDeviceDescriptor
    ) {
        let device = AgentControlHIDDeviceDescriptor(
            registryEntryID: 42,
            locationID: 7
        )
        let transport = FakeAgentControlHIDTransport(
            automaticallyConnectedDevice: device
        )
        let power = FakeAgentControlPowerEventSource()
        let coordinator = AgentControlDeviceCoordinator(
            transport: transport,
            powerEventSource: power,
            nonceGenerator: nonceGenerator,
            heartbeatInterval: heartbeatInterval,
            handshakeTimeout: handshakeTimeout,
            reconnectDelay: reconnectDelay
        )
        return (coordinator, transport, power, device)
    }

    private func capabilitiesReport(
        nonce: UInt64,
        sequence: UInt16,
        minor: UInt8 = 0,
        slotCount: UInt8 = 10,
        capabilities: AgentControlCapabilitySet = .allV1,
        transport: AgentControlActiveTransport = .usb,
        watchdog: UInt8 = 6
    ) throws -> Data {
        var payload = littleEndianBytes(nonce)
        payload += [minor, slotCount]
        payload += [
            UInt8(truncatingIfNeeded: capabilities.rawValue),
            UInt8(truncatingIfNeeded: capabilities.rawValue >> 8),
        ]
        payload += [transport.rawValue, watchdog]
        payload += [0x7D, 0x53, 0x03, 0x41]
        return try AgentControlPacketCodec.encode(
            AgentControlPacket(
                messageType: .capabilities,
                flags: [.response],
                sequence: sequence,
                payload: Data(payload)
            )
        )
    }

    private func layerChangedReport(
        nonce: UInt64,
        sequence: UInt16,
        enabled: Bool
    ) throws -> Data {
        try AgentControlPacketCodec.encode(
            AgentControlPacket(
                messageType: .layerChanged,
                sequence: sequence,
                payload: Data(
                    littleEndianBytes(nonce)
                        + [
                            enabled ? 1 : 0,
                            AgentControlLayerChangeReason.controlKey.rawValue,
                        ]
                )
            )
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
            value |= UInt64(bytes[offset + byteOffset]) << UInt64(byteOffset * 8)
        }
        return value
    }

    private func waitUntil(
        _ predicate: @escaping @MainActor () -> Bool
    ) async throws {
        for _ in 0..<100 {
            if predicate() {
                return
            }
            try await Task.sleep(for: .milliseconds(2))
        }
        Issue.record("Timed out waiting for coordinator state")
    }
}
