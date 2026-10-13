import Foundation

/// Associates identity replies and deadlines with the device explicitly selected by the user.
struct PairingAttemptState {
    enum Phase: Equatable {
        case idle
        case waitingForIdentity
        case binding
    }

    private(set) var generation = 0
    private(set) var peripheralID: UUID?
    private(set) var phase: Phase = .idle

    mutating func begin(peripheralID: UUID) -> Int {
        generation += 1
        self.peripheralID = peripheralID
        phase = .waitingForIdentity
        return generation
    }

    func isCurrent(_ token: Int) -> Bool {
        token == generation && phase != .idle
    }

    mutating func beginBinding(token: Int, peripheralID: UUID) -> Bool {
        guard isCurrent(token), phase == .waitingForIdentity,
              self.peripheralID == peripheralID else { return false }
        phase = .binding
        return true
    }

    /// The identity deadline never interrupts a server bind already in progress.
    mutating func expireIdentityWait(token: Int) -> Bool {
        guard isCurrent(token), phase == .waitingForIdentity else { return false }
        cancel()
        return true
    }

    mutating func cancel() {
        generation += 1
        peripheralID = nil
        phase = .idle
    }
}
