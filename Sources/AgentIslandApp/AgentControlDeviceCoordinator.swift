import Foundation
import Observation
import AgentIslandCore

enum AgentControlDeviceConnectionState: String, Equatable, Sendable {
    case stopped
    case searching
    case handshaking
    case ready
    case reconnecting
    case incompatible
    case sleeping
    case failed
}

struct AgentControlDeviceDiagnostics: Equatable, Sendable {
    var state: AgentControlDeviceConnectionState = .stopped
    var selectedDevice: AgentControlHIDDeviceDescriptor?
    var matchingDeviceCount = 0
    var activeTransport: AgentControlActiveTransport?
    var protocolMinor: UInt8?
    var effectiveWatchdogSeconds: UInt8?
    var firmwareBuildIdentifier: UInt32?
    var snapshotGeneration: UInt16?
    var lastLayerEnabled: Bool?
    var sentReportCount = 0
    var receivedReportCount = 0
    var invalidReportCount = 0
    var ignoredReportCount = 0
    var duplicateOrOutOfOrderReportCount = 0
    var reconnectCount = 0
    var lastError: String?

    var summary: String {
        switch state {
        case .stopped:
            return "K0 Max transport stopped."
        case .searching:
            return "Searching for a compatible K0 Max Raw HID interface."
        case .handshaking:
            return "Negotiating Agent Control protocol capabilities."
        case .ready:
            let transportName = switch activeTransport {
            case .usb: "USB"
            case .twoPointFourGHz: "2.4 GHz"
            case .bluetooth: "Bluetooth"
            case .unknown, nil: "unknown transport"
            }
            return "K0 Max connected over \(transportName)."
        case .reconnecting:
            return "Reconnecting to the K0 Max."
        case .incompatible:
            return lastError ?? "The connected K0 Max firmware is incompatible."
        case .sleeping:
            return "K0 Max transport paused while the Mac sleeps."
        case .failed:
            return lastError ?? "The K0 Max transport failed."
        }
    }
}

struct AgentControlDeviceEvent: Equatable, Sendable {
    let message: AgentControlDeviceMessage
    let sequence: UInt16
}

struct AgentControlDeviceSnapshot: Equatable, Sendable {
    let connectionNonce: UInt64
    let generation: UInt16
    let content: AgentControlSnapshotContent
    let slotEpochs: [UInt16]
}

@MainActor
@Observable
final class AgentControlDeviceCoordinator {
    private(set) var diagnostics = AgentControlDeviceDiagnostics()

    @ObservationIgnored
    var onDeviceMessage: ((AgentControlDeviceEvent) -> Void)?

    @ObservationIgnored
    private(set) var currentSnapshot: AgentControlDeviceSnapshot?

    @ObservationIgnored
    private let transport: any AgentControlHIDTransport

    @ObservationIgnored
    private let powerEventSource: any AgentControlPowerEventSource

    @ObservationIgnored
    private let nonceGenerator: () -> UInt64

    @ObservationIgnored
    private let heartbeatInterval: Duration

    @ObservationIgnored
    private let handshakeTimeout: Duration

    @ObservationIgnored
    private let reconnectDelay: Duration

    @ObservationIgnored
    private var heartbeatTask: Task<Void, Never>?

    @ObservationIgnored
    private var handshakeTimeoutTask: Task<Void, Never>?

    @ObservationIgnored
    private var reconnectTask: Task<Void, Never>?

    @ObservationIgnored
    private var isRunning = false

    @ObservationIgnored
    private var isSleeping = false

    @ObservationIgnored
    private var approvalActionsEnabled = false

    @ObservationIgnored
    private var connectionNonce: UInt64?

    @ObservationIgnored
    private var helloSequence: UInt16?

    @ObservationIgnored
    private var nextHostSequence: UInt16 = 1

    @ObservationIgnored
    private var lastDeviceSequence: UInt16?

    @ObservationIgnored
    private var desiredSnapshot: AgentControlSnapshotContent?

    @ObservationIgnored
    private var lastSentSnapshot: AgentControlSnapshotContent?

    @ObservationIgnored
    private var snapshotGeneration: UInt16 = 0

    @ObservationIgnored
    private var slotEpochs = [UInt16](
        repeating: 0,
        count: AgentControlProtocolV1.slotCount
    )

    init(
        transport: any AgentControlHIDTransport = K0MaxHIDTransport(),
        powerEventSource: any AgentControlPowerEventSource = WorkspaceAgentControlPowerEventSource(),
        nonceGenerator: @escaping () -> UInt64 = {
            UInt64.random(in: 1...UInt64.max)
        },
        heartbeatInterval: Duration = .seconds(
            AgentControlProtocolV1.heartbeatInterval
        ),
        handshakeTimeout: Duration = .seconds(2),
        reconnectDelay: Duration = .seconds(1)
    ) {
        self.transport = transport
        self.powerEventSource = powerEventSource
        self.nonceGenerator = nonceGenerator
        self.heartbeatInterval = heartbeatInterval
        self.handshakeTimeout = handshakeTimeout
        self.reconnectDelay = reconnectDelay

        transport.eventHandler = { [weak self] event in
            self?.handleTransportEvent(event)
        }
        powerEventSource.onSleep = { [weak self] in
            self?.prepareForSleep()
        }
        powerEventSource.onWake = { [weak self] in
            self?.resumeAfterWake()
        }
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        isSleeping = false
        diagnostics.state = .searching
        diagnostics.lastError = nil
        powerEventSource.start()
        startTransport()
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        isSleeping = false
        cancelConnectionTasks()
        powerEventSource.stop()
        transport.stop()
        clearConnectionState()
        diagnostics.state = .stopped
        diagnostics.selectedDevice = nil
        diagnostics.matchingDeviceCount = 0
    }

    func setApprovalActionsEnabled(_ enabled: Bool) {
        guard approvalActionsEnabled != enabled else { return }
        approvalActionsEnabled = enabled

        guard isRunning,
              !isSleeping,
              diagnostics.selectedDevice != nil else {
            return
        }
        beginHandshake()
    }

    /// Stores the latest desired device state and transmits it only when its
    /// slot identity, projected light state, or overflow count changes.
    func setSnapshot(_ content: AgentControlSnapshotContent) {
        desiredSnapshot = content
        guard diagnostics.state == .ready,
              content != lastSentSnapshot else {
            return
        }
        sendSnapshot(content)
    }

    func prepareForSleep() {
        guard isRunning, !isSleeping else { return }
        isSleeping = true
        cancelConnectionTasks()
        transport.stop()
        clearConnectionState()
        diagnostics.state = .sleeping
        diagnostics.selectedDevice = nil
        diagnostics.matchingDeviceCount = 0
    }

    func resumeAfterWake() {
        guard isRunning, isSleeping else { return }
        isSleeping = false
        diagnostics.reconnectCount += 1
        diagnostics.state = .searching
        startTransport()
    }

    private func startTransport() {
        guard isRunning, !isSleeping else { return }
        do {
            try transport.start()
        } catch {
            scheduleTransportRestart(after: error)
        }
    }

    private func handleTransportEvent(
        _ event: AgentControlHIDTransportEvent
    ) {
        guard isRunning, !isSleeping else { return }

        switch event {
        case let .connected(device, matchingDeviceCount):
            diagnostics.selectedDevice = device
            diagnostics.matchingDeviceCount = matchingDeviceCount
            beginHandshake()

        case let .disconnected(device, matchingDeviceCount):
            guard diagnostics.selectedDevice?.registryEntryID
                    == device.registryEntryID else {
                diagnostics.matchingDeviceCount = matchingDeviceCount
                return
            }
            cancelConnectionTasks()
            clearConnectionState()
            diagnostics.selectedDevice = nil
            diagnostics.matchingDeviceCount = matchingDeviceCount
            diagnostics.state = .searching

        case let .matchingDeviceCountChanged(count):
            diagnostics.matchingDeviceCount = count

        case let .report(report):
            handleInputReport(report)

        case let .failure(message):
            diagnostics.lastError = message
        }
    }

    private func beginHandshake() {
        cancelConnectionTasks()
        clearConnectionState()
        diagnostics.state = .handshaking
        diagnostics.lastError = nil

        var nonce = nonceGenerator()
        if nonce == 0 {
            nonce = 1
        }
        connectionNonce = nonce

        var capabilities: AgentControlCapabilitySet = [
            .stateSnapshots,
            .selection,
            .jump,
            .globalControls,
            .questionNavigation,
            .questionSelection,
            .questionSubmission,
        ]
        if approvalActionsEnabled {
            capabilities.formUnion([.allowOnce, .deny])
        }

        do {
            helloSequence = try sendPacket(
                messageType: .hello,
                payload: AgentControlMessageCodec.helloPayload(
                    connectionNonce: nonce,
                    capabilities: capabilities
                )
            )
        } catch {
            scheduleTransportRestart(after: error)
            return
        }

        handshakeTimeoutTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: self?.handshakeTimeout ?? .seconds(2))
            } catch {
                return
            }
            guard let self,
                  self.diagnostics.state == .handshaking else {
                return
            }
            self.scheduleTransportRestart(
                after: AgentControlCoordinatorError.handshakeTimedOut
            )
        }
    }

    private func handleInputReport(_ report: Data) {
        diagnostics.receivedReportCount += 1

        guard report.first == AgentControlProtocolV1.commandFamily else {
            diagnostics.ignoredReportCount += 1
            return
        }

        let packet: AgentControlPacket
        do {
            packet = try AgentControlPacketCodec.decode(report)
        } catch let error as AgentControlPacketCodecError {
            if case let .incompatibleMajorVersion(majorVersion) = error {
                handshakeTimeoutTask?.cancel()
                handshakeTimeoutTask = nil
                diagnostics.state = .incompatible
                diagnostics.lastError =
                    "Unsupported protocol major version \(majorVersion)."
                return
            }
            diagnostics.invalidReportCount += 1
            diagnostics.lastError = "Rejected malformed K0 Max report: \(error)"
            return
        } catch {
            diagnostics.invalidReportCount += 1
            diagnostics.lastError = "Rejected malformed K0 Max report: \(error)"
            return
        }

        let message: AgentControlDeviceMessage?
        do {
            message = try AgentControlMessageCodec.decodeDeviceMessage(packet)
        } catch {
            diagnostics.invalidReportCount += 1
            diagnostics.lastError = "Rejected invalid K0 Max payload: \(error)"
            return
        }

        guard let message else {
            diagnostics.ignoredReportCount += 1
            return
        }

        if case let .capabilities(capabilities) = message {
            handleCapabilities(capabilities, packet: packet)
            return
        }

        guard diagnostics.state == .ready else {
            diagnostics.ignoredReportCount += 1
            return
        }
        guard message.connectionNonce == connectionNonce else {
            diagnostics.ignoredReportCount += 1
            return
        }
        guard acceptsDeviceSequence(packet.sequence) else {
            diagnostics.duplicateOrOutOfOrderReportCount += 1
            return
        }

        if case let .layerChanged(_, enabled, _) = message {
            diagnostics.lastLayerEnabled = enabled
        }
        onDeviceMessage?(
            AgentControlDeviceEvent(
                message: message,
                sequence: packet.sequence
            )
        )
    }

    private func handleCapabilities(
        _ capabilities: AgentControlDeviceCapabilities,
        packet: AgentControlPacket
    ) {
        guard diagnostics.state == .handshaking else {
            diagnostics.ignoredReportCount += 1
            return
        }
        guard packet.sequence == helloSequence,
              capabilities.connectionNonce == connectionNonce else {
            diagnostics.ignoredReportCount += 1
            return
        }

        let incompatibility: String?
        if capabilities.protocolMinor != AgentControlProtocolV1.minorVersion {
            incompatibility = "Unsupported protocol minor version \(capabilities.protocolMinor)."
        } else if capabilities.slotCount != AgentControlProtocolV1.slotCount {
            incompatibility = "Firmware exposes \(capabilities.slotCount) slots instead of 10."
        } else if !capabilities.capabilities.contains(.stateSnapshots) {
            incompatibility = "Firmware does not support state snapshots."
        } else if capabilities.capabilities.rawValue
                    & ~AgentControlCapabilitySet.allV1.rawValue != 0 {
            incompatibility = "Firmware advertises unknown capability bits."
        } else if capabilities.activeTransport == .bluetooth
                    || capabilities.activeTransport == .unknown {
            incompatibility = "The active keyboard transport is unsupported."
        } else if capabilities.effectiveWatchdogSeconds
                    <= UInt8(AgentControlProtocolV1.heartbeatInterval) {
            incompatibility = "Firmware watchdog is too short for the host heartbeat."
        } else {
            incompatibility = nil
        }

        guard incompatibility == nil else {
            handshakeTimeoutTask?.cancel()
            handshakeTimeoutTask = nil
            diagnostics.state = .incompatible
            diagnostics.lastError = incompatibility
            return
        }

        handshakeTimeoutTask?.cancel()
        handshakeTimeoutTask = nil
        diagnostics.state = .ready
        diagnostics.activeTransport = capabilities.activeTransport
        diagnostics.protocolMinor = capabilities.protocolMinor
        diagnostics.effectiveWatchdogSeconds =
            capabilities.effectiveWatchdogSeconds
        diagnostics.firmwareBuildIdentifier =
            capabilities.firmwareBuildIdentifier
        diagnostics.lastError = nil
        startHeartbeat()

        if let desiredSnapshot {
            sendSnapshot(desiredSnapshot)
        }
    }

    private func sendSnapshot(_ content: AgentControlSnapshotContent) {
        guard let connectionNonce else { return }
        snapshotGeneration &+= 1
        var nextSlotEpochs = slotEpochs
        for index in 0..<AgentControlProtocolV1.slotCount
        where lastSentSnapshot?.slots[index] != content.slots[index] {
            nextSlotEpochs[index] &+= 1
            if nextSlotEpochs[index] == 0 {
                nextSlotEpochs[index] = 1
            }
        }

        do {
            _ = try sendPacket(
                messageType: .stateSnapshot,
                payload: AgentControlMessageCodec.stateSnapshotPayload(
                    connectionNonce: connectionNonce,
                    generation: snapshotGeneration,
                    content: content
                )
            )
            slotEpochs = nextSlotEpochs
            lastSentSnapshot = content
            currentSnapshot = AgentControlDeviceSnapshot(
                connectionNonce: connectionNonce,
                generation: snapshotGeneration,
                content: content,
                slotEpochs: slotEpochs
            )
            diagnostics.snapshotGeneration = snapshotGeneration
        } catch {
            scheduleTransportRestart(after: error)
        }
    }

    @discardableResult
    func sendSelectionAcknowledgement(
        requestSequence: UInt16,
        connectionNonce: UInt64,
        slotIndex: UInt8,
        result: AgentControlSelectionResult,
        slotEpoch: UInt16 = 0,
        selectionToken: UInt64 = 0,
        allowedActions: AgentControlAllowedActionSet = [],
        lifetimeSeconds: UInt8 = 0
    ) -> Bool {
        guard diagnostics.state == .ready,
              connectionNonce == self.connectionNonce else {
            return false
        }

        do {
            try sendResponsePacket(
                messageType: .selectionAcknowledgement,
                requestSequence: requestSequence,
                isError: result != .accepted,
                payload: AgentControlMessageCodec
                    .selectionAcknowledgementPayload(
                        connectionNonce: connectionNonce,
                        slotIndex: slotIndex,
                        result: result,
                        slotEpoch: slotEpoch,
                        selectionToken: selectionToken,
                        allowedActions: allowedActions,
                        lifetimeSeconds: lifetimeSeconds
                    )
            )
            return true
        } catch {
            scheduleTransportRestart(after: error)
            return false
        }
    }

    @discardableResult
    func sendActionResult(
        requestSequence: UInt16,
        connectionNonce: UInt64,
        slotIndex: UInt8,
        action: AgentControlAction,
        result: AgentControlActionResult
    ) -> Bool {
        guard diagnostics.state == .ready,
              connectionNonce == self.connectionNonce else {
            return false
        }

        do {
            try sendResponsePacket(
                messageType: .actionResult,
                requestSequence: requestSequence,
                isError: result != .acceptedForDispatch,
                payload: AgentControlMessageCodec.actionResultPayload(
                    connectionNonce: connectionNonce,
                    slotIndex: slotIndex,
                    action: action,
                    result: result
                )
            )
            return true
        } catch {
            scheduleTransportRestart(after: error)
            return false
        }
    }

    @discardableResult
    func sendGlobalControlResult(
        requestSequence: UInt16,
        connectionNonce: UInt64,
        control: AgentControlGlobalControl,
        result: AgentControlGlobalControlResult,
        quitConfirmationActive: Bool
    ) -> Bool {
        guard diagnostics.state == .ready,
              connectionNonce == self.connectionNonce else {
            return false
        }

        do {
            try sendResponsePacket(
                messageType: .globalControlResult,
                requestSequence: requestSequence,
                isError: result != .accepted,
                payload: AgentControlMessageCodec.globalControlResultPayload(
                    connectionNonce: connectionNonce,
                    control: control,
                    result: result,
                    quitConfirmationActive: quitConfirmationActive
                )
            )
            return true
        } catch {
            scheduleTransportRestart(after: error)
            return false
        }
    }

    private func startHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(
                        for: self?.heartbeatInterval ?? .seconds(2)
                    )
                } catch {
                    return
                }
                guard let self,
                      self.diagnostics.state == .ready,
                      let connectionNonce = self.connectionNonce else {
                    return
                }
                do {
                    _ = try self.sendPacket(
                        messageType: .heartbeat,
                        payload: AgentControlMessageCodec.heartbeatPayload(
                            connectionNonce: connectionNonce
                        )
                    )
                } catch {
                    self.scheduleTransportRestart(after: error)
                    return
                }
            }
        }
    }

    @discardableResult
    private func sendPacket(
        messageType: AgentControlMessageType,
        payload: Data
    ) throws -> UInt16 {
        let sequence = nextHostSequence
        nextHostSequence &+= 1
        let report = try AgentControlPacketCodec.encode(
            AgentControlPacket(
                messageType: messageType,
                sequence: sequence,
                payload: payload
            )
        )
        try transport.send(report: report)
        diagnostics.sentReportCount += 1
        return sequence
    }

    private func sendResponsePacket(
        messageType: AgentControlMessageType,
        requestSequence: UInt16,
        isError: Bool,
        payload: Data
    ) throws {
        var flags: AgentControlPacketFlags = [.response]
        if isError {
            flags.insert(.error)
        }
        let report = try AgentControlPacketCodec.encode(
            AgentControlPacket(
                messageType: messageType,
                flags: flags,
                sequence: requestSequence,
                payload: payload
            )
        )
        try transport.send(report: report)
        diagnostics.sentReportCount += 1
    }

    private func scheduleTransportRestart(after error: Error) {
        guard isRunning, !isSleeping else { return }
        cancelConnectionTasks()
        transport.stop()
        clearConnectionState()
        diagnostics.state = .reconnecting
        diagnostics.lastError = error.localizedDescription

        reconnectTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: self?.reconnectDelay ?? .seconds(1))
            } catch {
                return
            }
            guard let self, self.isRunning, !self.isSleeping else { return }
            self.reconnectTask = nil
            self.diagnostics.reconnectCount += 1
            self.diagnostics.state = .searching
            self.startTransport()
        }
    }

    private func acceptsDeviceSequence(_ sequence: UInt16) -> Bool {
        guard let lastDeviceSequence else {
            self.lastDeviceSequence = sequence
            return true
        }
        let distance = sequence &- lastDeviceSequence
        guard distance != 0, distance < 0x8000 else {
            return false
        }
        self.lastDeviceSequence = sequence
        return true
    }

    private func cancelConnectionTasks() {
        heartbeatTask?.cancel()
        heartbeatTask = nil
        handshakeTimeoutTask?.cancel()
        handshakeTimeoutTask = nil
        reconnectTask?.cancel()
        reconnectTask = nil
    }

    private func clearConnectionState() {
        connectionNonce = nil
        helloSequence = nil
        nextHostSequence = 1
        lastDeviceSequence = nil
        lastSentSnapshot = nil
        currentSnapshot = nil
        snapshotGeneration = 0
        slotEpochs = [UInt16](
            repeating: 0,
            count: AgentControlProtocolV1.slotCount
        )
        diagnostics.activeTransport = nil
        diagnostics.protocolMinor = nil
        diagnostics.effectiveWatchdogSeconds = nil
        diagnostics.firmwareBuildIdentifier = nil
        diagnostics.snapshotGeneration = nil
        diagnostics.lastLayerEnabled = nil
    }
}

private enum AgentControlCoordinatorError: LocalizedError {
    case handshakeTimedOut

    var errorDescription: String? {
        switch self {
        case .handshakeTimedOut:
            "Timed out waiting for compatible K0 Max firmware capabilities."
        }
    }
}

private extension AgentControlDeviceMessage {
    var connectionNonce: UInt64 {
        switch self {
        case let .capabilities(capabilities):
            capabilities.connectionNonce
        case let .slotSelected(connectionNonce, _, _),
             let .actionInvoked(connectionNonce, _, _, _),
             let .layerChanged(connectionNonce, _, _),
             let .globalControlRequested(connectionNonce, _):
            connectionNonce
        }
    }
}
