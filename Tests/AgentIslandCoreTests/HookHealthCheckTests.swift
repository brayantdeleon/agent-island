import Foundation
import Testing
@testable import AgentIslandCore

/// Coverage for the health check's handling of hooks left behind by a previous
/// name of this project. `installSettingsJSON` only sanitizes on an explicit
/// reinstall, and `repairHooksIfNeeded` only reinstalls when something reports
/// a repairable issue — so without `legacyHooksDetected` an already-installed
/// machine keeps running every Claude hook twice forever.
struct HookHealthCheckTests {
    private func makeClaudeDirectory(settings: String) throws -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("hook-health-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try settings.write(
            to: directory.appendingPathComponent("settings.json"),
            atomically: true,
            encoding: .utf8
        )
        return directory
    }

    private static let duplicatedSettings = """
    {
      "hooks": {
        "Stop": [
          {
            "matcher": "*",
            "hooks": [
              {
                "type": "command",
                "command": "'/Users/test/Library/Application Support/OpenIsland/bin/OpenIslandHooks' --source claude"
              }
            ]
          },
          {
            "matcher": "*",
            "hooks": [
              {
                "type": "command",
                "command": "'/Users/test/Library/Application Support/AgentIsland/bin/AgentIslandHooks' --source claude"
              }
            ]
          }
        ]
      }
    }
    """

    @Test
    func checkClaudeReportsLegacyOpenIslandHooksAsRepairable() throws {
        let directory = try makeClaudeDirectory(settings: Self.duplicatedSettings)
        defer { try? FileManager.default.removeItem(at: directory) }

        let report = HookHealthCheck.checkClaude(claudeDirectory: directory)

        let legacy = report.issues.compactMap { issue -> [String]? in
            guard case let .legacyHooksDetected(names, _) = issue else { return nil }
            return names
        }
        #expect(legacy == [["OpenIslandHooks"]])
        #expect(report.repairableIssues.contains {
            if case .legacyHooksDetected = $0 { return true }
            return false
        })
    }

    /// Informational, not an error: the legacy binary writes to a socket this
    /// app no longer binds and hooks fail open, so the only cost is latency.
    /// Surfacing it as an error would put the UI in a permanent red state for
    /// something that still works.
    @Test
    func legacyHooksAreInformationalSoTheReportStaysHealthy() throws {
        let directory = try makeClaudeDirectory(settings: Self.duplicatedSettings)
        defer { try? FileManager.default.removeItem(at: directory) }

        let issue = HookHealthReport.Issue.legacyHooksDetected(
            names: ["OpenIslandHooks"],
            configPath: directory.appendingPathComponent("settings.json").path
        )

        #expect(issue.severity == .info)
        #expect(issue.isAutoRepairable)
    }

    /// The legacy hook is this project's own lineage, so it must not be
    /// reported to the user as a third-party integration coexisting with us.
    @Test
    func checkClaudeDoesNotReportOpenIslandHooksAsThirdParty() throws {
        let directory = try makeClaudeDirectory(settings: Self.duplicatedSettings)
        defer { try? FileManager.default.removeItem(at: directory) }

        let report = HookHealthCheck.checkClaude(claudeDirectory: directory)

        let otherNames = report.issues.compactMap { issue -> [String]? in
            guard case let .otherHooksDetected(names) = issue else { return nil }
            return names
        }.flatMap { $0 }
        #expect(!otherNames.contains { $0.lowercased().contains("openisland") })
    }

    @Test
    func checkClaudeReportsNoLegacyIssueForACleanInstall() throws {
        let settings = """
        {
          "hooks": {
            "Stop": [
              {
                "matcher": "*",
                "hooks": [
                  {
                    "type": "command",
                    "command": "'/Users/test/Library/Application Support/AgentIsland/bin/AgentIslandHooks' --source claude"
                  }
                ]
              }
            ]
          }
        }
        """
        let directory = try makeClaudeDirectory(settings: settings)
        defer { try? FileManager.default.removeItem(at: directory) }

        let report = HookHealthCheck.checkClaude(claudeDirectory: directory)

        #expect(!report.issues.contains {
            if case .legacyHooksDetected = $0 { return true }
            return false
        })
    }

    /// A genuine third-party hook must still be reported.
    @Test
    func checkClaudeStillReportsGenuineThirdPartyHooks() throws {
        let settings = """
        {
          "hooks": {
            "Stop": [
              {
                "matcher": "*",
                "hooks": [
                  { "type": "command", "command": "/opt/homebrew/bin/some-other-tool --notify" }
                ]
              }
            ]
          }
        }
        """
        let directory = try makeClaudeDirectory(settings: settings)
        defer { try? FileManager.default.removeItem(at: directory) }

        let report = HookHealthCheck.checkClaude(claudeDirectory: directory)

        #expect(report.issues.contains {
            if case .otherHooksDetected = $0 { return true }
            return false
        })
    }
}
