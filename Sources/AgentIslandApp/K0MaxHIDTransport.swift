import CoreFoundation
import Foundation
import IOKit
import IOKit.hid
import AgentIslandCore

/// IOHID-backed transport for the K0 Max Raw HID interface.
///
/// Matching includes VID, PID, primary usage page, and primary usage so the
/// keyboard's ordinary key interfaces never reach the Agent Control codec.
/// If multiple matching devices are present, the lowest location ID and then
/// registry-entry ID wins deterministically.
@MainActor
final class K0MaxHIDTransport: AgentControlHIDTransport {
    var eventHandler: ((AgentControlHIDTransportEvent) -> Void)?

    private var manager: IOHIDManager?
    private var matchingDevices: [UInt64: IOHIDDevice] = [:]
    private var selectedDevice: IOHIDDevice?
    private var selectedDescriptor: AgentControlHIDDeviceDescriptor?
    private let inputBuffer = AgentControlHIDInputBuffer()

    func start() throws {
        guard manager == nil else {
            throw AgentControlHIDTransportError.alreadyStarted
        }
        let manager = IOHIDManagerCreate(
            kCFAllocatorDefault,
            IOOptionBits(kIOHIDOptionsTypeNone)
        )
        self.manager = manager

        let matching: [String: Any] = [
            kIOHIDVendorIDKey: AgentControlHIDDeviceDescriptor.keychronVendorID,
            kIOHIDProductIDKey: AgentControlHIDDeviceDescriptor.k0MaxProductID,
            kIOHIDPrimaryUsagePageKey: AgentControlHIDDeviceDescriptor.rawHIDUsagePage,
            kIOHIDPrimaryUsageKey: AgentControlHIDDeviceDescriptor.rawHIDUsage,
        ]
        IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)

        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(
            manager,
            { context, result, _, device in
                guard let context else { return }
                let transport = Unmanaged<K0MaxHIDTransport>
                    .fromOpaque(context)
                    .takeUnretainedValue()
                MainActor.assumeIsolated {
                    transport.handleDeviceMatched(device, result: result)
                }
            },
            context
        )
        IOHIDManagerRegisterDeviceRemovalCallback(
            manager,
            { context, result, _, device in
                guard let context else { return }
                let transport = Unmanaged<K0MaxHIDTransport>
                    .fromOpaque(context)
                    .takeUnretainedValue()
                MainActor.assumeIsolated {
                    transport.handleDeviceRemoved(device, result: result)
                }
            },
            context
        )

        IOHIDManagerScheduleWithRunLoop(
            manager,
            CFRunLoopGetMain(),
            CFRunLoopMode.defaultMode.rawValue
        )
        let result = IOHIDManagerOpen(
            manager,
            IOOptionBits(kIOHIDOptionsTypeNone)
        )
        guard result == kIOReturnSuccess else {
            IOHIDManagerUnscheduleFromRunLoop(
                manager,
                CFRunLoopGetMain(),
                CFRunLoopMode.defaultMode.rawValue
            )
            self.manager = nil
            throw AgentControlHIDTransportError.managerOpenFailed(result)
        }

        refreshMatchingDevices()
    }

    func stop() {
        closeSelectedDevice()
        matchingDevices.removeAll()

        guard let manager else { return }
        IOHIDManagerUnscheduleFromRunLoop(
            manager,
            CFRunLoopGetMain(),
            CFRunLoopMode.defaultMode.rawValue
        )
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        self.manager = nil
    }

    func send(report: Data) throws {
        guard report.count == AgentControlProtocolV1.reportSize else {
            throw AgentControlHIDTransportError.invalidReportLength(report.count)
        }
        guard let selectedDevice else {
            throw AgentControlHIDTransportError.notConnected
        }

        let result = report.withUnsafeBytes { bytes in
            IOHIDDeviceSetReport(
                selectedDevice,
                kIOHIDReportTypeOutput,
                0,
                bytes.baseAddress!.assumingMemoryBound(to: UInt8.self),
                report.count
            )
        }
        guard result == kIOReturnSuccess else {
            throw AgentControlHIDTransportError.reportWriteFailed(result)
        }
    }

    private func refreshMatchingDevices() {
        guard let manager,
              let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else {
            eventHandler?(.matchingDeviceCountChanged(0))
            return
        }

        matchingDevices = Dictionary(
            uniqueKeysWithValues: devices.compactMap { device in
                guard let descriptor = descriptor(for: device) else {
                    return nil
                }
                return (descriptor.registryEntryID, device)
            }
        )
        eventHandler?(.matchingDeviceCountChanged(matchingDevices.count))
        connectPreferredDeviceIfNeeded()
    }

    private func handleDeviceMatched(
        _ device: IOHIDDevice,
        result: IOReturn
    ) {
        guard result == kIOReturnSuccess,
              let descriptor = descriptor(for: device) else {
            if result != kIOReturnSuccess {
                eventHandler?(
                    .failure(
                        "K0 Max match callback failed (0x\(String(UInt32(bitPattern: result), radix: 16)))."
                    )
                )
            }
            return
        }

        let wasInserted = matchingDevices.updateValue(
            device,
            forKey: descriptor.registryEntryID
        ) == nil
        if wasInserted {
            eventHandler?(.matchingDeviceCountChanged(matchingDevices.count))
        }
        connectPreferredDeviceIfNeeded()
    }

    private func handleDeviceRemoved(
        _ device: IOHIDDevice,
        result: IOReturn
    ) {
        guard let descriptor = knownDescriptor(for: device) else { return }
        matchingDevices.removeValue(forKey: descriptor.registryEntryID)

        if selectedDescriptor?.registryEntryID == descriptor.registryEntryID {
            closeSelectedDevice()
            eventHandler?(
                .disconnected(
                    device: descriptor,
                    matchingDeviceCount: matchingDevices.count
                )
            )
            connectPreferredDeviceIfNeeded()
        } else {
            eventHandler?(.matchingDeviceCountChanged(matchingDevices.count))
        }

        if result != kIOReturnSuccess {
            eventHandler?(
                .failure(
                    "K0 Max removal callback failed (0x\(String(UInt32(bitPattern: result), radix: 16)))."
                )
            )
        }
    }

    private func connectPreferredDeviceIfNeeded() {
        guard selectedDevice == nil else { return }

        let candidates = matchingDevices.compactMap { id, device in
            descriptor(for: device).map { ($0, id, device) }
        }
        let ordered = candidates.sorted { lhs, rhs in
            AgentControlHIDDeviceDescriptor.precedes(lhs.0, rhs.0)
        }

        for (descriptor, _, device) in ordered {
            let result = IOHIDDeviceOpen(
                device,
                IOOptionBits(kIOHIDOptionsTypeNone)
            )
            guard result == kIOReturnSuccess else {
                eventHandler?(
                    .failure(
                        AgentControlHIDTransportError
                            .deviceOpenFailed(result)
                            .localizedDescription
                    )
                )
                continue
            }

            let context = Unmanaged.passUnretained(self).toOpaque()
            IOHIDDeviceRegisterInputReportCallback(
                device,
                inputBuffer.pointer,
                AgentControlProtocolV1.reportSize,
                { context, result, _, _, _, report, reportLength in
                    guard let context else { return }
                    let transport = Unmanaged<K0MaxHIDTransport>
                        .fromOpaque(context)
                        .takeUnretainedValue()
                    let data = Data(
                        bytes: report,
                        count: max(Int(reportLength), 0)
                    )
                    MainActor.assumeIsolated {
                        transport.handleInputReport(data, result: result)
                    }
                },
                context
            )
            IOHIDDeviceScheduleWithRunLoop(
                device,
                CFRunLoopGetMain(),
                CFRunLoopMode.defaultMode.rawValue
            )
            selectedDevice = device
            selectedDescriptor = descriptor
            eventHandler?(
                .connected(
                    device: descriptor,
                    matchingDeviceCount: matchingDevices.count
                )
            )
            return
        }
    }

    private func closeSelectedDevice() {
        guard let selectedDevice else {
            selectedDescriptor = nil
            return
        }
        IOHIDDeviceUnscheduleFromRunLoop(
            selectedDevice,
            CFRunLoopGetMain(),
            CFRunLoopMode.defaultMode.rawValue
        )
        IOHIDDeviceClose(
            selectedDevice,
            IOOptionBits(kIOHIDOptionsTypeNone)
        )
        self.selectedDevice = nil
        selectedDescriptor = nil
    }

    private func handleInputReport(
        _ report: Data,
        result: IOReturn
    ) {
        guard result == kIOReturnSuccess else {
            eventHandler?(
                .failure(
                    "K0 Max input callback failed (0x\(String(UInt32(bitPattern: result), radix: 16)))."
                )
            )
            return
        }
        eventHandler?(.report(report))
    }

    private func descriptor(
        for device: IOHIDDevice
    ) -> AgentControlHIDDeviceDescriptor? {
        let service = IOHIDDeviceGetService(device)
        var registryEntryID: UInt64 = 0
        guard IORegistryEntryGetRegistryEntryID(
            service,
            &registryEntryID
        ) == kIOReturnSuccess else {
            return nil
        }

        return AgentControlHIDDeviceDescriptor(
            registryEntryID: registryEntryID,
            locationID: numberProperty(
                device,
                key: kIOHIDLocationIDKey as CFString
            ).map { UInt32(truncating: $0) },
            productName: stringProperty(
                device,
                key: kIOHIDProductKey as CFString
            ) ?? "Keychron K0 Max RGB",
            serialNumber: stringProperty(
                device,
                key: kIOHIDSerialNumberKey as CFString
            )
        )
    }

    private func knownDescriptor(
        for device: IOHIDDevice
    ) -> AgentControlHIDDeviceDescriptor? {
        if let descriptor = descriptor(for: device) {
            return descriptor
        }
        if let selectedDevice,
           CFEqual(selectedDevice, device),
           let selectedDescriptor {
            return selectedDescriptor
        }
        guard let knownDevice = matchingDevices.values.first(
            where: { CFEqual($0, device) }
        ) else {
            return nil
        }
        return descriptor(for: knownDevice)
    }

    private func numberProperty(
        _ device: IOHIDDevice,
        key: CFString
    ) -> NSNumber? {
        IOHIDDeviceGetProperty(device, key) as? NSNumber
    }

    private func stringProperty(
        _ device: IOHIDDevice,
        key: CFString
    ) -> String? {
        IOHIDDeviceGetProperty(device, key) as? String
    }

}

private final class AgentControlHIDInputBuffer: @unchecked Sendable {
    let pointer = UnsafeMutablePointer<UInt8>.allocate(
        capacity: AgentControlProtocolV1.reportSize
    )

    init() {
        pointer.initialize(
            repeating: 0,
            count: AgentControlProtocolV1.reportSize
        )
    }

    deinit {
        pointer.deinitialize(count: AgentControlProtocolV1.reportSize)
        pointer.deallocate()
    }
}
