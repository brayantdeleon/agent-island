import Foundation

@MainActor
struct AgentControlDeviceSettingsStore {
    static let defaultsKey = "device.keychronK0Max.enabled"
    static let approvalActionsDefaultsKey =
        "device.keychronK0Max.approvalActions.enabled"

    static var standard: Self {
        Self(defaults: .standard)
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    func loadEnabled() -> Bool {
        guard defaults.object(forKey: Self.defaultsKey) != nil else {
            return true
        }
        return defaults.bool(forKey: Self.defaultsKey)
    }

    func saveEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: Self.defaultsKey)
    }

    func loadApprovalActionsEnabled() -> Bool {
        defaults.bool(forKey: Self.approvalActionsDefaultsKey)
    }

    func saveApprovalActionsEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: Self.approvalActionsDefaultsKey)
    }
}
