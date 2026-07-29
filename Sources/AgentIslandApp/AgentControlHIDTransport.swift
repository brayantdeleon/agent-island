import Foundation

struct AgentControlHIDDeviceDescriptor: Equatable, Hashable, Sendable {
    static let keychronVendorID = 0x3434
    static let k0MaxProductID = 0x0A06
    static let rawHIDUsagePage = 0xFF60
    static let rawHIDUsage = 0x61

    var registryEntryID: UInt64
    var locationID: UInt32?
    var productName: String
    var serialNumber: String?

    init(
        registryEntryID: UInt64,
        locationID: UInt32? = nil,
        productName: String = "Keychron K0 Max RGB",
        serialNumber: String? = nil
    ) {
        self.registryEntryID = registryEntryID
        self.locationID = locationID
        self.productName = productName
        self.serialNumber = serialNumber
    }

    static func preferred(
        from devices: [Self]
    ) -> Self? {
        devices.min(by: precedes)
    }

    static func precedes(_ lhs: Self, _ rhs: Self) -> Bool {
        let lhsLocation = lhs.locationID ?? .max
        let rhsLocation = rhs.locationID ?? .max
        if lhsLocation != rhsLocation {
            return lhsLocation < rhsLocation
        }
        return lhs.registryEntryID < rhs.registryEntryID
    }
}

enum AgentControlHIDTransportEvent: Equatable, Sendable {
    case connected(
        device: AgentControlHIDDeviceDescriptor,
        matchingDeviceCount: Int
    )
    case disconnected(
        device: AgentControlHIDDeviceDescriptor,
        matchingDeviceCount: Int
    )
    case matchingDeviceCountChanged(Int)
    case report(Data)
    case failure(String)
}

enum AgentControlHIDTransportError: Error, Equatable, LocalizedError {
    case notConnected
    case alreadyStarted
    case invalidReportLength(Int)
    case managerCreationFailed
    case managerOpenFailed(Int32)
    case deviceOpenFailed(Int32)
    case reportWriteFailed(Int32)

    var errorDescription: String? {
        switch self {
        case .notConnected:
            "No K0 Max Raw HID interface is connected."
        case .alreadyStarted:
            "The K0 Max HID transport is already running."
        case let .invalidReportLength(length):
            "Expected a 32-byte HID report; received \(length) bytes."
        case .managerCreationFailed:
            "Unable to create the macOS HID manager."
        case let .managerOpenFailed(code):
            "Unable to open the macOS HID manager (0x\(String(UInt32(bitPattern: code), radix: 16)))."
        case let .deviceOpenFailed(code):
            "Unable to open the K0 Max Raw HID interface (0x\(String(UInt32(bitPattern: code), radix: 16)))."
        case let .reportWriteFailed(code):
            "Unable to write to the K0 Max Raw HID interface (0x\(String(UInt32(bitPattern: code), radix: 16)))."
        }
    }
}

@MainActor
protocol AgentControlHIDTransport: AnyObject {
    var eventHandler: ((AgentControlHIDTransportEvent) -> Void)? { get set }

    func start() throws
    func stop()
    func send(report: Data) throws
}

/// Deterministic transport used by coordinator tests and diagnostic tooling.
@MainActor
final class FakeAgentControlHIDTransport: AgentControlHIDTransport {
    var eventHandler: ((AgentControlHIDTransportEvent) -> Void)?
    var automaticallyConnectedDevice: AgentControlHIDDeviceDescriptor?
    var matchingDeviceCount = 1
    var nextStartError: Error?
    var nextSendError: Error?

    private(set) var isStarted = false
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var sentReports: [Data] = []

    init(
        automaticallyConnectedDevice: AgentControlHIDDeviceDescriptor? = nil
    ) {
        self.automaticallyConnectedDevice = automaticallyConnectedDevice
    }

    func start() throws {
        startCount += 1
        if let error = nextStartError {
            nextStartError = nil
            throw error
        }
        isStarted = true
        if let device = automaticallyConnectedDevice {
            eventHandler?(
                .connected(
                    device: device,
                    matchingDeviceCount: matchingDeviceCount
                )
            )
        }
    }

    func stop() {
        stopCount += 1
        isStarted = false
    }

    func send(report: Data) throws {
        if let error = nextSendError {
            nextSendError = nil
            throw error
        }
        guard isStarted else {
            throw AgentControlHIDTransportError.notConnected
        }
        sentReports.append(report)
    }

    func emit(_ event: AgentControlHIDTransportEvent) {
        eventHandler?(event)
    }

    func removeAllSentReports() {
        sentReports.removeAll()
    }
}
