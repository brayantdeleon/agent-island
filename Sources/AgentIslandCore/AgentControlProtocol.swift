import Foundation

public enum AgentControlProtocolV1 {
    public static let commandFamily: UInt8 = 0xAC
    public static let magic: (UInt8, UInt8) = (0x41, 0x49)
    public static let majorVersion: UInt8 = 1
    public static let minorVersion: UInt8 = 0
    public static let reportSize = 32
    public static let payloadCapacity = 22
    public static let slotCount = 10
    public static let requestedWatchdogSeconds: UInt8 = 6
    public static let heartbeatInterval: TimeInterval = 2
}

public enum AgentControlMessageType: UInt8, Sendable {
    case hello = 0x01
    case stateSnapshot = 0x02
    case heartbeat = 0x03
    case selectionAcknowledgement = 0x04
    case actionResult = 0x05
    case capabilities = 0x81
    case slotSelected = 0x82
    case actionInvoked = 0x83
    case layerChanged = 0x84
}

public struct AgentControlPacketFlags: OptionSet, Equatable, Sendable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    public static let response = Self(rawValue: 1 << 0)
    public static let error = Self(rawValue: 1 << 1)
    public static let knownMask: UInt8 = response.rawValue | error.rawValue
}

public struct AgentControlPacket: Equatable, Sendable {
    public var messageTypeRawValue: UInt8
    public var flags: AgentControlPacketFlags
    public var sequence: UInt16
    public var payload: Data

    public init(
        messageTypeRawValue: UInt8,
        flags: AgentControlPacketFlags = [],
        sequence: UInt16,
        payload: Data
    ) {
        self.messageTypeRawValue = messageTypeRawValue
        self.flags = flags
        self.sequence = sequence
        self.payload = payload
    }

    public init(
        messageType: AgentControlMessageType,
        flags: AgentControlPacketFlags = [],
        sequence: UInt16,
        payload: Data
    ) {
        self.init(
            messageTypeRawValue: messageType.rawValue,
            flags: flags,
            sequence: sequence,
            payload: payload
        )
    }

    public var messageType: AgentControlMessageType? {
        AgentControlMessageType(rawValue: messageTypeRawValue)
    }
}

public enum AgentControlPacketCodecError: Error, Equatable, Sendable {
    case invalidReportLength(Int)
    case foreignCommandFamily(UInt8)
    case invalidMagic(UInt8, UInt8)
    case incompatibleMajorVersion(UInt8)
    case reservedFlags(UInt8)
    case payloadTooLarge(Int)
    case invalidPayloadLength(UInt8)
    case nonzeroPadding
    case crcMismatch(expected: UInt8, actual: UInt8)
}

public enum AgentControlPacketCodec {
    public static func encode(_ packet: AgentControlPacket) throws -> Data {
        guard packet.payload.count <= AgentControlProtocolV1.payloadCapacity else {
            throw AgentControlPacketCodecError.payloadTooLarge(packet.payload.count)
        }
        guard packet.flags.rawValue & ~AgentControlPacketFlags.knownMask == 0 else {
            throw AgentControlPacketCodecError.reservedFlags(packet.flags.rawValue)
        }

        var report = [UInt8](
            repeating: 0,
            count: AgentControlProtocolV1.reportSize
        )
        report[0] = AgentControlProtocolV1.commandFamily
        report[1] = AgentControlProtocolV1.magic.0
        report[2] = AgentControlProtocolV1.magic.1
        report[3] = AgentControlProtocolV1.majorVersion
        report[4] = packet.messageTypeRawValue
        report[5] = packet.flags.rawValue
        writeUInt16(packet.sequence, to: &report, at: 6)
        report[8] = UInt8(packet.payload.count)
        report.replaceSubrange(
            9..<(9 + packet.payload.count),
            with: packet.payload
        )
        report[AgentControlProtocolV1.reportSize - 1] = crc8(
            report.dropLast()
        )
        return Data(report)
    }

    public static func decode(_ report: Data) throws -> AgentControlPacket {
        guard report.count == AgentControlProtocolV1.reportSize else {
            throw AgentControlPacketCodecError.invalidReportLength(report.count)
        }
        let bytes = [UInt8](report)
        guard bytes[0] == AgentControlProtocolV1.commandFamily else {
            throw AgentControlPacketCodecError.foreignCommandFamily(bytes[0])
        }
        guard bytes[1] == AgentControlProtocolV1.magic.0,
              bytes[2] == AgentControlProtocolV1.magic.1 else {
            throw AgentControlPacketCodecError.invalidMagic(bytes[1], bytes[2])
        }
        let payloadLength = bytes[8]
        guard payloadLength <= AgentControlProtocolV1.payloadCapacity else {
            throw AgentControlPacketCodecError.invalidPayloadLength(payloadLength)
        }

        let expectedCRC = crc8(bytes.dropLast())
        let actualCRC = bytes[AgentControlProtocolV1.reportSize - 1]
        guard expectedCRC == actualCRC else {
            throw AgentControlPacketCodecError.crcMismatch(
                expected: expectedCRC,
                actual: actualCRC
            )
        }
        guard bytes[3] == AgentControlProtocolV1.majorVersion else {
            throw AgentControlPacketCodecError.incompatibleMajorVersion(bytes[3])
        }
        guard bytes[5] & ~AgentControlPacketFlags.knownMask == 0 else {
            throw AgentControlPacketCodecError.reservedFlags(bytes[5])
        }

        let paddingStart = 9 + Int(payloadLength)
        guard bytes[paddingStart..<(AgentControlProtocolV1.reportSize - 1)]
            .allSatisfy({ $0 == 0 }) else {
            throw AgentControlPacketCodecError.nonzeroPadding
        }

        return AgentControlPacket(
            messageTypeRawValue: bytes[4],
            flags: AgentControlPacketFlags(rawValue: bytes[5]),
            sequence: readUInt16(bytes, at: 6),
            payload: Data(bytes[9..<paddingStart])
        )
    }

    public static func crc8<C: Collection>(_ bytes: C) -> UInt8
    where C.Element == UInt8 {
        var crc: UInt8 = 0
        for byte in bytes {
            crc ^= byte
            for _ in 0..<8 {
                crc = crc & 0x80 != 0
                    ? (crc << 1) ^ 0x07
                    : crc << 1
            }
        }
        return crc
    }

    private static func writeUInt16(
        _ value: UInt16,
        to bytes: inout [UInt8],
        at offset: Int
    ) {
        bytes[offset] = UInt8(truncatingIfNeeded: value)
        bytes[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
    }

    private static func readUInt16(_ bytes: [UInt8], at offset: Int) -> UInt16 {
        UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
    }
}

public struct AgentControlCapabilitySet: OptionSet, Equatable, Sendable {
    public let rawValue: UInt16

    public init(rawValue: UInt16) {
        self.rawValue = rawValue
    }

    public static let stateSnapshots = Self(rawValue: 1 << 0)
    public static let selection = Self(rawValue: 1 << 1)
    public static let jump = Self(rawValue: 1 << 2)
    public static let allowOnce = Self(rawValue: 1 << 3)
    public static let deny = Self(rawValue: 1 << 4)
    public static let allV1: Self = [
        .stateSnapshots,
        .selection,
        .jump,
        .allowOnce,
        .deny,
    ]
}

public enum AgentControlActiveTransport: UInt8, Equatable, Sendable {
    case unknown = 0
    case usb = 1
    case twoPointFourGHz = 2
    case bluetooth = 3
}

public struct AgentControlDeviceCapabilities: Equatable, Sendable {
    public var connectionNonce: UInt64
    public var protocolMinor: UInt8
    public var slotCount: UInt8
    public var capabilities: AgentControlCapabilitySet
    public var activeTransport: AgentControlActiveTransport
    public var effectiveWatchdogSeconds: UInt8
    public var firmwareBuildIdentifier: UInt32

    public init(
        connectionNonce: UInt64,
        protocolMinor: UInt8,
        slotCount: UInt8,
        capabilities: AgentControlCapabilitySet,
        activeTransport: AgentControlActiveTransport,
        effectiveWatchdogSeconds: UInt8,
        firmwareBuildIdentifier: UInt32
    ) {
        self.connectionNonce = connectionNonce
        self.protocolMinor = protocolMinor
        self.slotCount = slotCount
        self.capabilities = capabilities
        self.activeTransport = activeTransport
        self.effectiveWatchdogSeconds = effectiveWatchdogSeconds
        self.firmwareBuildIdentifier = firmwareBuildIdentifier
    }
}

public struct AgentControlSnapshotSlot: Equatable, Sendable {
    /// Host-only identity used to detect slot reuse. It is never encoded.
    public var identity: String
    public var lightState: AgentControlLightState

    public init(identity: String, lightState: AgentControlLightState) {
        self.identity = identity
        self.lightState = lightState
    }
}

public struct AgentControlSnapshotContent: Equatable, Sendable {
    public let slots: [AgentControlSnapshotSlot?]
    public let overflowCount: Int

    public init(
        slots: [AgentControlSnapshotSlot?],
        overflowCount: Int
    ) {
        var normalized = Array(slots.prefix(AgentControlProtocolV1.slotCount))
        if normalized.count < AgentControlProtocolV1.slotCount {
            normalized.append(
                contentsOf: repeatElement(
                    nil,
                    count: AgentControlProtocolV1.slotCount - normalized.count
                )
            )
        }
        self.slots = normalized
        self.overflowCount = max(overflowCount, 0)
    }

    public static let empty = AgentControlSnapshotContent(
        slots: [],
        overflowCount: 0
    )
}

public enum AgentControlAction: UInt8, Equatable, Sendable {
    case jump = 1
    case allowOnce = 2
    case deny = 3
}

public enum AgentControlLayerChangeReason: UInt8, Equatable, Sendable {
    case controlKey = 0
    case watchdogExpired = 1
    case hostDisconnected = 2
    case firmwareReset = 3
    case incompatibleHost = 4
}

public enum AgentControlDeviceMessage: Equatable, Sendable {
    case capabilities(AgentControlDeviceCapabilities)
    case slotSelected(
        connectionNonce: UInt64,
        slotIndex: UInt8,
        snapshotGeneration: UInt16
    )
    case actionInvoked(
        connectionNonce: UInt64,
        slotIndex: UInt8,
        action: AgentControlAction,
        selectionToken: UInt64
    )
    case layerChanged(
        connectionNonce: UInt64,
        enabled: Bool,
        reason: AgentControlLayerChangeReason
    )
}

public enum AgentControlMessageCodecError: Error, Equatable, Sendable {
    case unexpectedMessageType(UInt8)
    case invalidFlags(UInt8)
    case payloadTooShort(expected: Int, actual: Int)
    case invalidValue(field: String, value: UInt8)
}

public enum AgentControlMessageCodec {
    public static func helloPayload(
        connectionNonce: UInt64,
        requestedWatchdogSeconds: UInt8 = AgentControlProtocolV1.requestedWatchdogSeconds,
        capabilities: AgentControlCapabilitySet
    ) -> Data {
        var payload: [UInt8] = [AgentControlProtocolV1.minorVersion]
        appendUInt64(connectionNonce, to: &payload)
        payload.append(requestedWatchdogSeconds)
        appendUInt16(capabilities.rawValue, to: &payload)
        return Data(payload)
    }

    public static func stateSnapshotPayload(
        connectionNonce: UInt64,
        generation: UInt16,
        content: AgentControlSnapshotContent
    ) -> Data {
        var payload: [UInt8] = []
        appendUInt64(connectionNonce, to: &payload)
        appendUInt16(generation, to: &payload)
        payload.append(UInt8(clamping: content.overflowCount))
        payload.append(contentsOf: content.slots.map {
            $0?.lightState.rawValue ?? 0
        })
        return Data(payload)
    }

    public static func heartbeatPayload(connectionNonce: UInt64) -> Data {
        var payload: [UInt8] = []
        appendUInt64(connectionNonce, to: &payload)
        return Data(payload)
    }

    public static func decodeDeviceMessage(
        _ packet: AgentControlPacket
    ) throws -> AgentControlDeviceMessage? {
        guard let messageType = packet.messageType else {
            return nil
        }
        let payload = [UInt8](packet.payload)

        switch messageType {
        case .capabilities:
            guard packet.flags.contains(.response),
                  !packet.flags.contains(.error) else {
                throw AgentControlMessageCodecError.invalidFlags(packet.flags.rawValue)
            }
            try require(payload, count: 18)
            guard let activeTransport = AgentControlActiveTransport(
                rawValue: payload[12]
            ) else {
                throw AgentControlMessageCodecError.invalidValue(
                    field: "activeTransport",
                    value: payload[12]
                )
            }
            return .capabilities(
                AgentControlDeviceCapabilities(
                    connectionNonce: readUInt64(payload, at: 0),
                    protocolMinor: payload[8],
                    slotCount: payload[9],
                    capabilities: AgentControlCapabilitySet(
                        rawValue: readUInt16(payload, at: 10)
                    ),
                    activeTransport: activeTransport,
                    effectiveWatchdogSeconds: payload[13],
                    firmwareBuildIdentifier: readUInt32(payload, at: 14)
                )
            )

        case .slotSelected:
            try requireRequestFlags(packet)
            try require(payload, count: 11)
            return .slotSelected(
                connectionNonce: readUInt64(payload, at: 0),
                slotIndex: payload[8],
                snapshotGeneration: readUInt16(payload, at: 9)
            )

        case .actionInvoked:
            try requireRequestFlags(packet)
            try require(payload, count: 18)
            guard let action = AgentControlAction(rawValue: payload[9]) else {
                throw AgentControlMessageCodecError.invalidValue(
                    field: "action",
                    value: payload[9]
                )
            }
            return .actionInvoked(
                connectionNonce: readUInt64(payload, at: 0),
                slotIndex: payload[8],
                action: action,
                selectionToken: readUInt64(payload, at: 10)
            )

        case .layerChanged:
            try requireRequestFlags(packet)
            try require(payload, count: 10)
            guard payload[8] <= 1 else {
                throw AgentControlMessageCodecError.invalidValue(
                    field: "layerEnabled",
                    value: payload[8]
                )
            }
            guard let reason = AgentControlLayerChangeReason(
                rawValue: payload[9]
            ) else {
                throw AgentControlMessageCodecError.invalidValue(
                    field: "layerChangeReason",
                    value: payload[9]
                )
            }
            return .layerChanged(
                connectionNonce: readUInt64(payload, at: 0),
                enabled: payload[8] == 1,
                reason: reason
            )

        case .hello,
             .stateSnapshot,
             .heartbeat,
             .selectionAcknowledgement,
             .actionResult:
            return nil
        }
    }

    private static func requireRequestFlags(
        _ packet: AgentControlPacket
    ) throws {
        guard packet.flags.isEmpty else {
            throw AgentControlMessageCodecError.invalidFlags(packet.flags.rawValue)
        }
    }

    private static func require(
        _ payload: [UInt8],
        count: Int
    ) throws {
        guard payload.count >= count else {
            throw AgentControlMessageCodecError.payloadTooShort(
                expected: count,
                actual: payload.count
            )
        }
    }

    private static func appendUInt16(_ value: UInt16, to bytes: inout [UInt8]) {
        bytes.append(UInt8(truncatingIfNeeded: value))
        bytes.append(UInt8(truncatingIfNeeded: value >> 8))
    }

    private static func appendUInt64(_ value: UInt64, to bytes: inout [UInt8]) {
        for shift in stride(from: 0, through: 56, by: 8) {
            bytes.append(UInt8(truncatingIfNeeded: value >> UInt64(shift)))
        }
    }

    private static func readUInt16(_ bytes: [UInt8], at offset: Int) -> UInt16 {
        UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
    }

    private static func readUInt32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        UInt32(bytes[offset])
            | UInt32(bytes[offset + 1]) << 8
            | UInt32(bytes[offset + 2]) << 16
            | UInt32(bytes[offset + 3]) << 24
    }

    private static func readUInt64(_ bytes: [UInt8], at offset: Int) -> UInt64 {
        var value: UInt64 = 0
        for byteOffset in 0..<8 {
            value |= UInt64(bytes[offset + byteOffset]) << UInt64(byteOffset * 8)
        }
        return value
    }
}
