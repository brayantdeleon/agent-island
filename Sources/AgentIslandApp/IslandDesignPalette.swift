import SwiftUI
import AgentIslandCore

enum IslandDesignPalette {
    enum Glass {
        /// Cool-neutral ink laid over the system material. Keeping the tint
        /// separate from the material lets wallpaper color register without
        /// losing the notch's dark hardware character.
        static let inkTint = Color(
            red: 10.0 / 255.0,
            green: 11.0 / 255.0,
            blue: 15.0 / 255.0
        )
        static let opaqueFallback = Color(
            red: 18.0 / 255.0,
            green: 19.0 / 255.0,
            blue: 23.0 / 255.0
        )
        static let edge = V6Palette.paper.opacity(0.10)
        static let controlFill = Color.white.opacity(0.075)
        static let controlStroke = Color.white.opacity(0.07)
        static let calloutFill = Color.white.opacity(0.045)
        static let calloutStroke = V6Palette.paper.opacity(0.11)
    }

    enum Status {
        static let waitingAggregate = Color(red: 231.0 / 255.0, green: 167.0 / 255.0, blue: 98.0 / 255.0)
        static let waitingForApproval = Color(red: 244.0 / 255.0, green: 164.0 / 255.0, blue: 164.0 / 255.0)
        static let waitingForAnswer = Color(red: 184.0 / 255.0, green: 120.0 / 255.0, blue: 255.0 / 255.0)
        static let running = Color(red: 110.0 / 255.0, green: 167.0 / 255.0, blue: 255.0 / 255.0)
        static let completed = Color(red: 111.0 / 255.0, green: 185.0 / 255.0, blue: 130.0 / 255.0)
        static let inactive = V6Palette.paper.opacity(0.38)
        static let idle = V6Palette.paper.opacity(0.35)

        static func tint(for phase: SessionPhase) -> Color {
            switch phase {
            case .waitingForApproval:
                waitingForApproval
            case .waitingForAnswer:
                waitingForAnswer
            case .running:
                running
            case .completed:
                completed
            }
        }

        static func tint(for phase: SessionPhase, presence: IslandSessionPresence) -> Color {
            if phase == .waitingForApproval || phase == .waitingForAnswer {
                return tint(for: phase)
            }

            switch presence {
            case .running:
                return running
            case .active:
                return completed
            case .inactive:
                return inactive
            }
        }
    }
}
