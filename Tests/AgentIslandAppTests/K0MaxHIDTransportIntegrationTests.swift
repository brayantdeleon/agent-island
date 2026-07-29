import XCTest
@testable import AgentIslandApp
import AgentIslandCore

final class K0MaxHIDTransportIntegrationTests: XCTestCase {
    @MainActor
    func testConnectedDiagnosticFirmwareHandshakeAndHostRestart() async throws {
        guard ProcessInfo.processInfo.environment[
            "AGENT_ISLAND_RUN_K0_MAX_HID_INTEGRATION"
        ] == "1" else {
            throw XCTSkip(
                "Set AGENT_ISLAND_RUN_K0_MAX_HID_INTEGRATION=1 to run the live K0 Max HID test."
            )
        }

        let first = makeLiveCoordinator()
        first.start()
        defer { first.stop() }
        let firstBecameReady = await waitForReady(first, timeout: 5)
        XCTAssertTrue(firstBecameReady)
        XCTAssertEqual(first.diagnostics.activeTransport, .usb)
        XCTAssertEqual(first.diagnostics.matchingDeviceCount, 1)

        first.setSnapshot(
            AgentControlSnapshotContent(
                slots: [
                    AgentControlSnapshotSlot(
                        identity: "integration-slot",
                        lightState: .running
                    ),
                ],
                overflowCount: 0
            )
        )
        let firstSnapshotSent = await wait(timeout: 2) {
            first.diagnostics.snapshotGeneration == 1
        }
        XCTAssertTrue(firstSnapshotSent)
        first.stop()

        let restarted = makeLiveCoordinator()
        restarted.start()
        defer { restarted.stop() }
        let restartedBecameReady = await waitForReady(restarted, timeout: 5)
        XCTAssertTrue(restartedBecameReady)
        restarted.setSnapshot(.empty)
        let emptySnapshotSent = await wait(timeout: 2) {
            restarted.diagnostics.snapshotGeneration == 1
        }
        XCTAssertTrue(emptySnapshotSent)
    }

    @MainActor
    func testLiveUnplugAndReplugRecovery() async throws {
        guard ProcessInfo.processInfo.environment[
            "AGENT_ISLAND_RUN_K0_MAX_HID_REPLUG_INTEGRATION"
        ] == "1" else {
            throw XCTSkip(
                "Set AGENT_ISLAND_RUN_K0_MAX_HID_REPLUG_INTEGRATION=1 for the manual unplug/replug test."
            )
        }

        let coordinator = makeLiveCoordinator()
        coordinator.start()
        defer { coordinator.stop() }
        let initiallyReady = await waitForReady(coordinator, timeout: 5)
        XCTAssertTrue(initiallyReady)

        print("K0 Max replug test: unplug the USB cable now.")
        let disconnected = await wait(timeout: 30) {
            coordinator.diagnostics.state == .searching
        }
        XCTAssertTrue(disconnected)
        guard disconnected else { return }
        print("K0 Max replug test: reconnect the USB cable now.")
        let reconnected = await waitForReady(coordinator, timeout: 30)
        XCTAssertTrue(reconnected)
        XCTAssertGreaterThanOrEqual(coordinator.diagnostics.sentReportCount, 2)
    }

    @MainActor
    private func makeLiveCoordinator() -> AgentControlDeviceCoordinator {
        AgentControlDeviceCoordinator(
            transport: K0MaxHIDTransport(),
            powerEventSource: FakeAgentControlPowerEventSource()
        )
    }

    @MainActor
    private func waitForReady(
        _ coordinator: AgentControlDeviceCoordinator,
        timeout: TimeInterval
    ) async -> Bool {
        await wait(timeout: timeout) {
            coordinator.diagnostics.state == .ready
        }
    }

    @MainActor
    private func wait(
        timeout: TimeInterval,
        predicate: @escaping @MainActor () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() {
                return true
            }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return predicate()
    }
}
