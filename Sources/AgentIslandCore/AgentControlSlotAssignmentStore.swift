import Foundation

/// Persists each session's preferred Agent Control number across app launches.
public final class AgentControlSlotAssignmentStore {
    public static let defaultsKey = "agentControl.slotAssignments.v1"

    private struct Payload: Codable {
        let version: Int
        let assignments: [String: Int]
    }

    private let defaults: UserDefaults
    private let key: String

    public static var standard: AgentControlSlotAssignmentStore {
        AgentControlSlotAssignmentStore(defaults: .standard)
    }

    public init(
        defaults: UserDefaults,
        key: String = AgentControlSlotAssignmentStore.defaultsKey
    ) {
        self.defaults = defaults
        self.key = key
    }

    public func load() -> [String: Int] {
        guard let data = defaults.data(forKey: key),
              let payload = try? JSONDecoder().decode(Payload.self, from: data),
              payload.version == 1 else {
            return [:]
        }

        return payload.assignments.filter {
            !$0.key.isEmpty && (0..<AgentControlSlotAllocator.capacity).contains($0.value)
        }
    }

    public func save(_ assignments: [String: Int]) {
        let validAssignments = assignments.filter {
            !$0.key.isEmpty && (0..<AgentControlSlotAllocator.capacity).contains($0.value)
        }

        guard !validAssignments.isEmpty else {
            defaults.removeObject(forKey: key)
            return
        }

        let payload = Payload(version: 1, assignments: validAssignments)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(payload) else { return }
        defaults.set(data, forKey: key)
    }
}
