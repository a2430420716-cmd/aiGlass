import Foundation

/// Media notifications control this app's guide player; only a matching 0x81
/// completion advances the tutorial. Both notifications may describe one gesture.
struct Gen1GuideStepState {
    enum MediaAction: String, Equatable {
        case play, pause, next, previous

        init?(command: UInt8) {
            switch command {
            case Gen1Commands.mediaPlay: self = .play
            case Gen1Commands.mediaPause: self = .pause
            case Gen1Commands.mediaNext: self = .next
            case Gen1Commands.mediaPrevious: self = .previous
            default: return nil
            }
        }
    }

    enum Decision: Equatable {
        case ignored(String)
        case media(MediaAction)
        case completed(MediaAction?)
    }

    private(set) var waitingStep = 0
    private var actionHandled = false
    private var completionHandled = false

    mutating func waitForStep(_ step: Int) {
        waitingStep = (1...9).contains(step) ? step : 0
        actionHandled = false
        completionHandled = false
    }

    mutating func receiveMedia(command: UInt8) -> Decision {
        guard waitingStep != 0, !completionHandled else { return .ignored("no_pending_step") }
        guard let action = MediaAction(command: command) else { return .ignored("unknown_media_command") }
        guard action == expectedMediaAction else { return .ignored("media_does_not_match_step") }
        guard !actionHandled else { return .ignored("media_action_already_handled") }
        actionHandled = true
        return .media(action)
    }

    mutating func receiveAcknowledgement(step: Int, result: Int) -> Decision {
        guard waitingStep != 0 else { return .ignored("no_pending_step") }
        guard step == waitingStep else { return .ignored("step_mismatch") }
        guard result == 1 else { return .ignored("step_not_completed") }
        guard !completionHandled else { return .ignored("completion_already_handled") }
        let action = actionHandled ? nil : expectedMediaAction
        completionHandled = true
        actionHandled = true
        return .completed(action)
    }

    private var expectedMediaAction: MediaAction? {
        switch waitingStep {
        case 4: return .play
        case 6: return .next
        case 7: return .previous
        case 8: return .pause
        default: return nil
        }
    }
}
