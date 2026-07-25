import Foundation

public struct ClaudeUsageWindow: Equatable, Codable, Sendable {
    public var usedPercentage: Double
    public var resetsAt: Date?

    public init(usedPercentage: Double, resetsAt: Date?) {
        self.usedPercentage = usedPercentage
        self.resetsAt = resetsAt
    }

    public var roundedUsedPercentage: Int {
        Int(usedPercentage.rounded())
    }
}

public struct ClaudeUsageSnapshot: Equatable, Codable, Sendable {
    public var fiveHour: ClaudeUsageWindow?
    public var sevenDay: ClaudeUsageWindow?
    public var cachedAt: Date?

    public init(
        fiveHour: ClaudeUsageWindow?,
        sevenDay: ClaudeUsageWindow?,
        cachedAt: Date? = nil
    ) {
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
        self.cachedAt = cachedAt
    }

    public var isEmpty: Bool {
        fiveHour == nil && sevenDay == nil
    }
}

public enum ClaudeUsageLoader {
    public static let defaultCacheURL = URL(fileURLWithPath: "/tmp/agent-island-rl.json")
    public static let legacyCacheURL = URL(fileURLWithPath: "/tmp/vibe-island-rl.json")
    public static let defaultDesktopPlanUsageHistoryURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Claude", isDirectory: true)
        .appendingPathComponent("plan-usage-history.json")

    public static func load() throws -> ClaudeUsageSnapshot? {
        try load(
            from: [defaultCacheURL, legacyCacheURL],
            desktopPlanUsageHistoryURL: defaultDesktopPlanUsageHistoryURL
        )
    }

    public static func load(from url: URL) throws -> ClaudeUsageSnapshot? {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }

        let data = try Data(contentsOf: url)
        let object = try JSONSerialization.jsonObject(with: data)
        guard let payload = object as? [String: Any] else {
            return nil
        }

        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let cachedAt = attributes?[.modificationDate] as? Date
        let snapshot = ClaudeUsageSnapshot(
            fiveHour: usageWindow(for: "five_hour", in: payload),
            sevenDay: usageWindow(for: "seven_day", in: payload),
            cachedAt: cachedAt
        )

        return snapshot.isEmpty ? nil : snapshot
    }

    public static func load(
        from urls: [URL],
        desktopPlanUsageHistoryURL: URL? = nil
    ) throws -> ClaudeUsageSnapshot? {
        enum Source {
            case rateLimits
            case desktopPlanHistory
        }

        var candidates = urls.map { ($0, Source.rateLimits) }
        if let desktopPlanUsageHistoryURL {
            candidates.append((desktopPlanUsageHistoryURL, .desktopPlanHistory))
        }

        let existingCandidates = candidates
            .filter { FileManager.default.fileExists(atPath: $0.0.path) }
            .map { url, source in
                let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
                let modificationDate = attributes?[.modificationDate] as? Date ?? .distantPast
                return (url, source, modificationDate)
            }
            .sorted { lhs, rhs in lhs.2 > rhs.2 }

        for (url, source, _) in existingCandidates {
            let snapshot = switch source {
            case .rateLimits:
                try load(from: url)
            case .desktopPlanHistory:
                try loadDesktopPlanUsageHistory(from: url)
            }
            if let snapshot {
                return snapshot
            }
        }

        return nil
    }

    private static func loadDesktopPlanUsageHistory(from url: URL) throws -> ClaudeUsageSnapshot? {
        let data = try Data(contentsOf: url)
        let object = try JSONSerialization.jsonObject(with: data)
        guard let payload = object as? [String: Any],
              let samples = payload["samples"] as? [[String: Any]],
              let latest = samples.max(by: { timestamp(from: $0) < timestamp(from: $1) }),
              let usage = latest["u"] as? [String: Any],
              let fiveHour = number(from: usage["fh"]) else {
            return nil
        }

        let latestTimestamp = timestamp(from: latest)
        return ClaudeUsageSnapshot(
            fiveHour: ClaudeUsageWindow(usedPercentage: fiveHour, resetsAt: nil),
            sevenDay: nil,
            cachedAt: latestTimestamp > 0 ? Date(timeIntervalSince1970: latestTimestamp / 1_000) : nil
        )
    }

    private static func timestamp(from sample: [String: Any]) -> Double {
        number(from: sample["t"]) ?? 0
    }

    private static func usageWindow(for key: String, in payload: [String: Any]) -> ClaudeUsageWindow? {
        guard let window = payload[key] as? [String: Any],
              let rawPercentage = number(from: window["used_percentage"]) ?? number(from: window["utilization"]) else {
            return nil
        }

        return ClaudeUsageWindow(
            usedPercentage: rawPercentage,
            resetsAt: date(from: window["resets_at"])
        )
    }

    private static func number(from value: Any?) -> Double? {
        switch value {
        case let value as NSNumber:
            value.doubleValue
        case let value as String:
            Double(value)
        default:
            nil
        }
    }

    private static func date(from value: Any?) -> Date? {
        switch value {
        case let value as NSNumber:
            return Date(timeIntervalSince1970: value.doubleValue)
        case let value as String:
            if let seconds = Double(value) {
                return Date(timeIntervalSince1970: seconds)
            }
            let formatterWithFractionalSeconds = ISO8601DateFormatter()
            formatterWithFractionalSeconds.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatterWithFractionalSeconds.date(from: value) {
                return date
            }
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime]
            if let date = formatter.date(from: value) {
                return date
            }
            return nil
        default:
            return nil
        }
    }
}
