import AppKit
import CoreGraphics
import Foundation
import AgentIslandCore

enum NotchStatus: Equatable {
    case closed
    case opened
    case popping
}

enum NotchOpenReason: Equatable {
    case click
    case hover
    case notification
    case boot
}

enum TrackedEventIngress {
    case bridge
    case rollout
}

enum IslandCompactnessMode: String, CaseIterable, Identifiable, Sendable {
    case minimal
    case regular
    case expanded

    var id: String { rawValue }

    var next: Self {
        switch self {
        case .minimal: .regular
        case .regular: .expanded
        case .expanded: .minimal
        }
    }
}

struct QuestionInteractionKey: Hashable, Sendable {
    let sessionID: String
    let promptID: UUID
}

struct QuestionInteractionDraft: Equatable, Sendable {
    let promptID: UUID
    var focusedQuestionIndex = 0
    var focusedOptionIndex = 0
    var selections: [Int: Set<UUID>] = [:]
    var freeformTexts: [UUID: String] = [:]
    var typedReply = ""
    var focusedFreeformOptionID: UUID?
    var focusesOpenEndedText = false

    func response(for prompt: QuestionPrompt) -> QuestionPromptResponse? {
        let reply = typedReply.trimmingCharacters(in: .whitespacesAndNewlines)
        if !reply.isEmpty {
            return QuestionPromptResponse(answer: reply)
        }
        if prompt.questions.isEmpty {
            guard !prompt.options.isEmpty,
                  let selected = selections[0]?.first,
                  let index = prompt.options.indices.first(where: {
                      legacyOptionID(promptID: prompt.id, index: $0) == selected
                  }) else {
                return nil
            }
            return QuestionPromptResponse(answer: prompt.options[index])
        }

        var answers: [String: String] = [:]
        for (questionIndex, question) in prompt.questions.enumerated() {
            guard let selected = selections[questionIndex], !selected.isEmpty else {
                return nil
            }
            let values = question.options.compactMap { option -> String? in
                guard selected.contains(option.id) else { return nil }
                if option.allowsFreeform {
                    let value = freeformTexts[option.id, default: ""]
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    return value.isEmpty ? nil : value
                }
                return option.label
            }
            guard !values.isEmpty else { return nil }
            answers[question.question] = values.joined(separator: ", ")
        }
        let rawAnswer = prompt.questions.count == 1
            ? answers[prompt.questions[0].question]
            : nil
        return QuestionPromptResponse(rawAnswer: rawAnswer, answers: answers)
    }

    func optionID(
        for prompt: QuestionPrompt,
        questionIndex: Int,
        optionIndex: Int
    ) -> UUID? {
        if prompt.questions.isEmpty {
            guard prompt.options.indices.contains(optionIndex) else { return nil }
            return legacyOptionID(promptID: prompt.id, index: optionIndex)
        }
        guard prompt.questions.indices.contains(questionIndex),
              prompt.questions[questionIndex].options.indices.contains(optionIndex) else {
            return nil
        }
        return prompt.questions[questionIndex].options[optionIndex].id
    }

    func legacyOptionID(promptID: UUID, index: Int) -> UUID {
        var bytes = promptID.uuid
        bytes.14 ^= UInt8(truncatingIfNeeded: index >> 8)
        bytes.15 ^= UInt8(truncatingIfNeeded: index)
        return UUID(uuid: bytes)
    }
}

// MARK: - v6 island preferences

/// What the closed island renders in the right slot. Chosen in the
/// Personalization tab; the pill layout only varies by content width.
enum IslandRightSlot: String, CaseIterable, Identifiable, Sendable {
    case count   // "×N" badge
    case agents  // colored dot stack, one per active agent tool
    case none    // pill collapses — useful if you just want the bars

    var id: String { rawValue }
}

/// What the closed island renders in the center label (external displays
/// only — on MacBook the physical notch covers this space so we suppress
/// the label regardless).
enum IslandCenterLabel: String, CaseIterable, Identifiable, Sendable {
    case sessionName  // e.g. "agent-island"
    case agentAction  // e.g. "Claude · editing"
    case off

    var id: String { rawValue }
}

// MARK: - v8 island preferences

enum IslandAppearanceDisplayProfile: String, CaseIterable, Identifiable, Sendable {
    case notch
    case topBar

    var id: String { rawValue }
}

struct IslandAppearancePreferences: Equatable, Sendable {
    var closedPresentation: IslandClosedPresentation = .ghost
    var rightSlot: IslandRightSlot = .count
    var centerLabel: IslandCenterLabel = .agentAction
    var usageDisplay: IslandUsageDisplay = .compact
    var sessionStateIndicator: IslandSessionStateIndicator = .animatedDot
    var sessionGroup: IslandSessionGroup = .none
    var sessionSort: IslandSessionSort = .attention
    var completedStaleThreshold: IslandCompletedStaleThreshold = .fiveMinutes
}

enum IslandClosedPresentation: String, CaseIterable, Identifiable, Sendable {
    case ghost
    case activityOnly
    case minimal
    case menuBarOnly
    case alwaysVisible
    case hidden

    var id: String { rawValue }

    var allowsHoverOpen: Bool {
        self != .hidden
    }

    var usesPhysicalNotchHoverTarget: Bool {
        switch self {
        case .ghost, .minimal, .hidden:
            true
        case .activityOnly, .menuBarOnly, .alwaysVisible:
            false
        }
    }

    func showsClosedSurface(hasActivity: Bool, menuBarVisible: Bool) -> Bool {
        switch self {
        case .ghost, .hidden:
            false
        case .activityOnly:
            hasActivity
        case .minimal, .alwaysVisible:
            true
        case .menuBarOnly:
            menuBarVisible
        }
    }
}

enum IslandUsageDisplay: String, CaseIterable, Identifiable, Sendable {
    case hidden
    case compact

    var id: String { rawValue }
}

enum IslandSessionStateIndicator: String, CaseIterable, Identifiable, Sendable {
    case animatedDot
    case bar
    case glyph
    case tint

    var id: String { rawValue }

    func timelineInterval(presence: IslandSessionPresence, isActionable: Bool) -> TimeInterval? {
        guard self == .animatedDot else { return nil }
        return presence == .running || isActionable ? 1.0 / 15.0 : nil
    }
}

enum IslandSessionGroup: String, CaseIterable, Identifiable, Sendable {
    case none
    case state
    case agent
    case project

    var id: String { rawValue }
}

enum IslandSessionSort: String, CaseIterable, Identifiable, Sendable {
    case attention
    case lastUpdate

    var id: String { rawValue }
}

enum IslandCompletedStaleThreshold: String, CaseIterable, Identifiable, Sendable {
    case twoMinutes
    case fiveMinutes
    case tenMinutes
    case twentyMinutes
    case never

    var id: String { rawValue }

    var seconds: TimeInterval {
        switch self {
        case .twoMinutes:    return 2 * 60
        case .fiveMinutes:   return 5 * 60
        case .tenMinutes:    return 10 * 60
        case .twentyMinutes: return 20 * 60
        case .never:         return .infinity
        }
    }
}

struct IslandSessionSection: Identifiable {
    let id: String
    let title: String
    let sessions: [AgentSession]
}
