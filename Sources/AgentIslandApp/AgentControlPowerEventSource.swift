import AppKit

@MainActor
protocol AgentControlPowerEventSource: AnyObject {
    var onSleep: (() -> Void)? { get set }
    var onWake: (() -> Void)? { get set }

    func start()
    func stop()
}

@MainActor
final class WorkspaceAgentControlPowerEventSource: NSObject, AgentControlPowerEventSource {
    var onSleep: (() -> Void)?
    var onWake: (() -> Void)?

    private var isStarted = false

    func start() {
        guard !isStarted else { return }
        isStarted = true
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(
            self,
            selector: #selector(workspaceWillSleep(_:)),
            name: NSWorkspace.willSleepNotification,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(workspaceDidWake(_:)),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
    }

    func stop() {
        guard isStarted else { return }
        isStarted = false
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    @objc
    private func workspaceWillSleep(_ notification: Notification) {
        onSleep?()
    }

    @objc
    private func workspaceDidWake(_ notification: Notification) {
        onWake?()
    }

    deinit {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }
}

@MainActor
final class FakeAgentControlPowerEventSource: AgentControlPowerEventSource {
    var onSleep: (() -> Void)?
    var onWake: (() -> Void)?

    private(set) var startCount = 0
    private(set) var stopCount = 0

    func start() {
        startCount += 1
    }

    func stop() {
        stopCount += 1
    }

    func emitSleep() {
        onSleep?()
    }

    func emitWake() {
        onWake?()
    }
}
