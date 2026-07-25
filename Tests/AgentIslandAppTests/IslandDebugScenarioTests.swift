import Testing
@testable import AgentIslandApp

struct IslandDebugScenarioTests {
    @Test
    func allDebugScenarioSessionsAreDemoSessions() {
        for scenario in IslandDebugScenario.allCases {
            let snapshot = scenario.snapshot()
            #expect(snapshot.sessions.allSatisfy { $0.origin == .demo })
        }
    }

    @Test
    func completionCardExercisesMathAndMarkdownTableRendering() {
        let snapshot = IslandDebugScenario.completionCard.snapshot()
        let session = snapshot.sessions.first { $0.id == snapshot.selectedSessionID }
        let message = session?.codexMetadata?.lastAssistantMessage

        #expect(message?.contains("\\(E = mc^2\\)") == true)
        #expect(message?.contains("$$\\int_0^1 x^2\\,dx = \\frac{1}{3}$$") == true)
        #expect(message?.contains("| Check | Result |") == true)
    }
}
