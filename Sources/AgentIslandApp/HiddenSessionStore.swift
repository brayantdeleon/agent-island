import Foundation
import AgentIslandCore

struct HiddenSessionIdentifier: Hashable, Sendable {
    private static let separator = "\u{1F}"

    let toolRawValue: String
    let sessionID: String

    init(session: AgentSession) {
        self.toolRawValue = session.tool.rawValue
        self.sessionID = session.id
    }

    init?(storedValue: String) {
        let pieces = storedValue.split(
            separator: Character(Self.separator),
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        guard pieces.count == 2, !pieces[0].isEmpty, !pieces[1].isEmpty else {
            return nil
        }

        self.toolRawValue = String(pieces[0])
        self.sessionID = String(pieces[1])
    }

    var storedValue: String {
        "\(toolRawValue)\(Self.separator)\(sessionID)"
    }
}

struct HiddenSessionStore {
    static let defaultsKey = "island.hiddenSessions"

    let defaults: UserDefaults
    let key: String

    static var standard: HiddenSessionStore {
        HiddenSessionStore(defaults: .standard, key: defaultsKey)
    }

    init(defaults: UserDefaults, key: String = defaultsKey) {
        self.defaults = defaults
        self.key = key
    }

    func load() -> Set<HiddenSessionIdentifier> {
        Set(
            (defaults.stringArray(forKey: key) ?? [])
                .compactMap(HiddenSessionIdentifier.init(storedValue:))
        )
    }

    func save(_ identifiers: Set<HiddenSessionIdentifier>) {
        defaults.set(
            identifiers.map(\.storedValue).sorted(),
            forKey: key
        )
    }
}
