import Foundation

struct FactoryResetConfirmation {
    enum Outcome: Equatable { case waiting, succeeded, failed, timedOut }
    let targetID: UUID
    let deadline: TimeInterval
    private var response: Outcome = .waiting

    init(targetID: UUID, deadline: TimeInterval) {
        self.targetID = targetID
        self.deadline = deadline
    }

    mutating func receive(_ result: UInt8, from peripheralID: UUID?, now: TimeInterval) -> Bool {
        guard response == .waiting, peripheralID == targetID, now < deadline else { return false }
        switch result {
        case 1: response = .succeeded
        case 2: break
        default: response = .failed
        }
        return true
    }

    func outcome(now: TimeInterval) -> Outcome {
        response == .waiting && now >= deadline ? .timedOut : response
    }
}
