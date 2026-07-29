import Foundation
import Testing
@testable import AgentIslandCore

struct AgentControlProtocolTests {
    @Test
    func goldenHelloVectorMatchesFirmwareSpike() throws {
        let payload = AgentControlMessageCodec.helloPayload(
            connectionNonce: 0x0123_4567_89AB_CDEF,
            capabilities: .allV1
        )
        let report = try AgentControlPacketCodec.encode(
            AgentControlPacket(
                messageType: .hello,
                sequence: 1,
                payload: payload
            )
        )

        #expect(
            report.hexString
                == "ac414901010001000c00efcdab8967452301061f000000000000000000000097"
        )
        #expect(report.last == 0x97)
        #expect(try AgentControlPacketCodec.decode(report).payload == payload)
    }

    @Test
    func packetCodecRejectsMalformedReports() throws {
        let valid = try AgentControlPacketCodec.encode(
            AgentControlPacket(
                messageType: .heartbeat,
                sequence: 4,
                payload: AgentControlMessageCodec.heartbeatPayload(
                    connectionNonce: 9
                )
            )
        )

        #expect(throws: AgentControlPacketCodecError.invalidReportLength(31)) {
            try AgentControlPacketCodec.decode(valid.dropLast())
        }

        var foreign = [UInt8](valid)
        foreign[0] = 0xA0
        #expect(throws: AgentControlPacketCodecError.foreignCommandFamily(0xA0)) {
            try AgentControlPacketCodec.decode(Data(foreign))
        }

        var badMagic = [UInt8](valid)
        badMagic[1] = 0
        #expect(throws: AgentControlPacketCodecError.invalidMagic(0, 0x49)) {
            try AgentControlPacketCodec.decode(Data(badMagic))
        }

        var badMajor = [UInt8](valid)
        badMajor[3] = 2
        badMajor[31] = AgentControlPacketCodec.crc8(badMajor.dropLast())
        #expect(throws: AgentControlPacketCodecError.incompatibleMajorVersion(2)) {
            try AgentControlPacketCodec.decode(Data(badMajor))
        }

        var badFlags = [UInt8](valid)
        badFlags[5] = 0x80
        badFlags[31] = AgentControlPacketCodec.crc8(badFlags.dropLast())
        #expect(throws: AgentControlPacketCodecError.reservedFlags(0x80)) {
            try AgentControlPacketCodec.decode(Data(badFlags))
        }

        var badLength = [UInt8](valid)
        badLength[8] = 23
        #expect(throws: AgentControlPacketCodecError.invalidPayloadLength(23)) {
            try AgentControlPacketCodec.decode(Data(badLength))
        }

        var badCRC = [UInt8](valid)
        badCRC[10] ^= 1
        do {
            _ = try AgentControlPacketCodec.decode(Data(badCRC))
            Issue.record("Expected CRC mismatch")
        } catch let error as AgentControlPacketCodecError {
            guard case .crcMismatch = error else {
                Issue.record("Expected CRC mismatch, received \(error)")
                return
            }
        }

        var badPadding = [UInt8](valid)
        badPadding[30] = 1
        badPadding[31] = AgentControlPacketCodec.crc8(badPadding.dropLast())
        #expect(throws: AgentControlPacketCodecError.nonzeroPadding) {
            try AgentControlPacketCodec.decode(Data(badPadding))
        }
    }

    @Test
    func packetCodecRoundTripsUnknownMessageTypesForForwardCompatibility() throws {
        let report = try AgentControlPacketCodec.encode(
            AgentControlPacket(
                messageTypeRawValue: 0xFE,
                sequence: .max,
                payload: Data([1, 2, 3])
            )
        )
        let decoded = try AgentControlPacketCodec.decode(report)

        #expect(decoded.messageType == nil)
        #expect(decoded.messageTypeRawValue == 0xFE)
        #expect(decoded.sequence == .max)
        #expect(
            try AgentControlMessageCodec.decodeDeviceMessage(decoded) == nil
        )
    }

    @Test
    func snapshotPayloadCarriesOnlyAnonymousStatesAndClampedOverflow() {
        let content = AgentControlSnapshotContent(
            slots: [
                AgentControlSnapshotSlot(identity: "private-session-a", lightState: .running),
                AgentControlSnapshotSlot(identity: "private-session-b", lightState: .recentlyCompleted),
            ],
            overflowCount: 999
        )
        let payload = [UInt8](
            AgentControlMessageCodec.stateSnapshotPayload(
                connectionNonce: 0x0102_0304_0506_0708,
                generation: 0x1234,
                content: content
            )
        )

        #expect(payload.count == 21)
        #expect(Array(payload[0..<8]) == [8, 7, 6, 5, 4, 3, 2, 1])
        #expect(Array(payload[8..<10]) == [0x34, 0x12])
        #expect(payload[10] == 255)
        #expect(Array(payload[11..<21]) == [2, 6, 0, 0, 0, 0, 0, 0, 0, 0])
        #expect(
            Data(payload).range(of: Data("private-session".utf8)) == nil
        )
    }

    @Test
    func navigationResponsePayloadsMatchTheWireContract() {
        let nonce: UInt64 = 0x0102_0304_0506_0708
        let selection = [UInt8](
            AgentControlMessageCodec.selectionAcknowledgementPayload(
                connectionNonce: nonce,
                slotIndex: 4,
                result: .accepted,
                slotEpoch: 0x1234,
                selectionToken: 0xA8A7_A6A5_A4A3_A2A1,
                allowedActions: [.jump],
                lifetimeSeconds: 15
            )
        )
        let action = [UInt8](
            AgentControlMessageCodec.actionResultPayload(
                connectionNonce: nonce,
                slotIndex: 4,
                action: .jump,
                result: .acceptedForDispatch
            )
        )

        #expect(selection.count == 22)
        #expect(
            selection == [
                8, 7, 6, 5, 4, 3, 2, 1,
                4, 0, 0x34, 0x12,
                0xA1, 0xA2, 0xA3, 0xA4,
                0xA5, 0xA6, 0xA7, 0xA8,
                1, 15,
            ]
        )
        #expect(
            action == [
                8, 7, 6, 5, 4, 3, 2, 1,
                4, AgentControlAction.jump.rawValue,
                AgentControlActionResult.acceptedForDispatch.rawValue,
            ]
        )
    }

    @Test
    func capabilitiesPayloadDecodesAllNegotiatedFields() throws {
        let nonce: UInt64 = 0x0123_4567_89AB_CDEF
        let packet = try AgentControlPacketCodec.decode(
            try makeCapabilitiesReport(
                nonce: nonce,
                sequence: 9,
                transport: .usb,
                buildIdentifier: 0x4103_537D
            )
        )
        let message = try AgentControlMessageCodec.decodeDeviceMessage(packet)

        guard case let .capabilities(capabilities) = message else {
            Issue.record("Expected capabilities message")
            return
        }
        #expect(capabilities.connectionNonce == nonce)
        #expect(capabilities.protocolMinor == 0)
        #expect(capabilities.slotCount == 10)
        #expect(capabilities.capabilities == .allV1)
        #expect(capabilities.activeTransport == .usb)
        #expect(capabilities.effectiveWatchdogSeconds == 6)
        #expect(capabilities.firmwareBuildIdentifier == 0x4103_537D)
    }

    @Test
    func deviceIntentPayloadsDecodeAndValidateTheirEnums() throws {
        let nonce: UInt64 = 0x1111_2222_3333_4444
        let slotMessage = try AgentControlMessageCodec.decodeDeviceMessage(
            AgentControlPacket(
                messageType: .slotSelected,
                sequence: 1,
                payload: Data(
                    littleEndianBytes(nonce)
                        + [4, 0x34, 0x12]
                )
            )
        )
        #expect(
            slotMessage == .slotSelected(
                connectionNonce: nonce,
                slotIndex: 4,
                snapshotGeneration: 0x1234
            )
        )

        let actionMessage = try AgentControlMessageCodec.decodeDeviceMessage(
            AgentControlPacket(
                messageType: .actionInvoked,
                sequence: 2,
                payload: Data(
                    littleEndianBytes(nonce)
                        + [4, AgentControlAction.deny.rawValue]
                        + littleEndianBytes(0xA8A7_A6A5_A4A3_A2A1)
                )
            )
        )
        #expect(
            actionMessage == .actionInvoked(
                connectionNonce: nonce,
                slotIndex: 4,
                action: .deny,
                selectionToken: 0xA8A7_A6A5_A4A3_A2A1
            )
        )

        let layerMessage = try AgentControlMessageCodec.decodeDeviceMessage(
            AgentControlPacket(
                messageType: .layerChanged,
                sequence: 3,
                payload: Data(
                    littleEndianBytes(nonce)
                        + [1, AgentControlLayerChangeReason.controlKey.rawValue]
                )
            )
        )
        #expect(
            layerMessage == .layerChanged(
                connectionNonce: nonce,
                enabled: true,
                reason: .controlKey
            )
        )
    }

    private func makeCapabilitiesReport(
        nonce: UInt64,
        sequence: UInt16,
        transport: AgentControlActiveTransport,
        buildIdentifier: UInt32
    ) throws -> Data {
        var payload = littleEndianBytes(nonce)
        payload += [0, 10]
        payload += [0x1F, 0]
        payload += [transport.rawValue, 6]
        payload += [
            UInt8(truncatingIfNeeded: buildIdentifier),
            UInt8(truncatingIfNeeded: buildIdentifier >> 8),
            UInt8(truncatingIfNeeded: buildIdentifier >> 16),
            UInt8(truncatingIfNeeded: buildIdentifier >> 24),
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

    private func littleEndianBytes(_ value: UInt64) -> [UInt8] {
        stride(from: 0, through: 56, by: 8).map {
            UInt8(truncatingIfNeeded: value >> UInt64($0))
        }
    }
}

private extension Data {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
