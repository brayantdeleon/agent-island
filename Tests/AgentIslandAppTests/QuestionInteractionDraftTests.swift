import Foundation
import Testing
@testable import AgentIslandApp
import AgentIslandCore

@Suite
struct QuestionInteractionDraftTests {
    @Test
    func multipleQuestionsAndMultiSelectPreserveEarlierSelections() {
        let staging = QuestionOption(label: "Staging")
        let lint = QuestionOption(label: "Lint")
        let unit = QuestionOption(label: "Unit tests")
        let prompt = QuestionPrompt(
            title: "Release",
            questions: [
                QuestionPromptItem(
                    question: "Environment?",
                    header: "Environment",
                    options: [staging]
                ),
                QuestionPromptItem(
                    question: "Checks?",
                    header: "Checks",
                    options: [lint, unit],
                    multiSelect: true
                ),
            ]
        )
        var draft = QuestionInteractionDraft(promptID: prompt.id)
        draft.selections[0] = [staging.id]
        draft.selections[1] = [lint.id, unit.id]

        let response = draft.response(for: prompt)

        #expect(response?.answers["Environment?"] == "Staging")
        #expect(response?.answers["Checks?"] == "Lint, Unit tests")
    }

    @Test
    func openEndedAndOtherAnswersRequireTypedText() {
        let openPrompt = QuestionPrompt(title: "Explain", options: [])
        var openDraft = QuestionInteractionDraft(promptID: openPrompt.id)
        #expect(openDraft.response(for: openPrompt) == nil)
        openDraft.typedReply = "Use the safer migration."
        #expect(
            openDraft.response(for: openPrompt)?.rawAnswer
                == "Use the safer migration."
        )

        let other = QuestionOption(label: "Other", allowsFreeform: true)
        let otherPrompt = QuestionPrompt(
            title: "Target",
            questions: [
                QuestionPromptItem(
                    question: "Target?",
                    header: "Target",
                    options: [other]
                ),
            ]
        )
        var otherDraft = QuestionInteractionDraft(promptID: otherPrompt.id)
        otherDraft.selections[0] = [other.id]
        #expect(otherDraft.response(for: otherPrompt) == nil)
        otherDraft.freeformTexts[other.id] = "Canary"
        #expect(
            otherDraft.response(for: otherPrompt)?
                .answers["Target?"] == "Canary"
        )
    }
}
