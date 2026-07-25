import Testing
@testable import AgentIslandApp
import AgentIslandCore

@MainActor
struct UsageProviderPresentationTests {
    @Test
    func claudeUsagePresentationAlwaysTargetsTheFiveHourWindow() {
        let provider = UsageProviderPresentation.claudeFiveHour(
            ClaudeUsageWindow(usedPercentage: 37.6, resetsAt: nil)
        )

        #expect(provider.title == "Claude")
        #expect(provider.peakWindowLabel == "5h")
        #expect(provider.peakUsageText == "38%")
    }

    @Test
    func claudeUsagePresentationHasAnUnavailableStateBeforeTheFirstRefresh() {
        let provider = UsageProviderPresentation.claudeFiveHour(nil)

        #expect(provider.peakWindowLabel == "5h")
        #expect(provider.peakUsedPercentage == nil)
        #expect(provider.peakUsageText == "—")
    }

    @Test
    func twoUsageProvidersRemainTogetherInTheLeftNotchLane() {
        let claude = UsageProviderPresentation.claudeFiveHour(
            ClaudeUsageWindow(usedPercentage: 4, resetsAt: nil)
        )
        let codex = UsageProviderPresentation(
            id: "codex",
            title: "Codex",
            windows: [
                UsageWindowPresentation(
                    id: "codex-7d",
                    label: "7d",
                    usedPercentage: 28,
                    resetsAt: nil
                )
            ]
        )

        let groups = IslandPanelView(model: AppModel()).splitUsageProviders([codex, claude])

        #expect(groups.left.map(\.id) == ["codex", "claude"])
        #expect(groups.right.isEmpty)
    }
}
