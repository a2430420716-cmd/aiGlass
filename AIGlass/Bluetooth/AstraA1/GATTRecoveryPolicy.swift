import Foundation

/// Rate limits missing-cache scans and actual connection failures separately.
/// Polling and foreground refreshes must not postpone either deadline.
struct BoundBLEReconnectPolicy {
    static let maxAttempts = 3
    private(set) var failedAttempts = 0
    private var retryAvailableAt: TimeInterval = 0
    private var scanAvailableAt: TimeInterval = 0

    var isExhausted: Bool { failedAttempts >= Self.maxAttempts }

    /// Only a fresh system event for the bound target may reopen a stopped cycle.
    mutating func resumeOnSystemConnection(targetMatches: Bool) -> Bool {
        guard targetMatches, isExhausted else { return false }
        reset()
        return true
    }

    func canRetry(now: TimeInterval) -> Bool {
        !isExhausted && now >= retryAvailableAt
    }

    mutating func claimScan(now: TimeInterval) -> Bool {
        guard canRetry(now: now), now >= scanAvailableAt else { return false }
        scanAvailableAt = now + 30
        return true
    }

    mutating func noteConnectionFailure(now: TimeInterval) {
        if !isExhausted { failedAttempts += 1 }
        retryAvailableAt = max(retryAvailableAt, now + 30)
    }

    mutating func reset() {
        failedAttempts = 0
        retryAvailableAt = 0
        scanAvailableAt = 0
    }
}

enum GATTRecoveryPhase: Equatable {
    case connecting
    case discoveringServices
    case enablingNotifications
}

struct GATTWatchdogToken: Equatable {
    let generation: UInt64
    let peripheralID: UUID
    let phase: GATTRecoveryPhase
    let deadline: TimeInterval
}

/// Gives each connection phase its own timeout and rejects obsolete timer callbacks.
struct GATTWatchdogPolicy {
    private(set) var active: GATTWatchdogToken?
    private var generation: UInt64 = 0

    @discardableResult
    mutating func arm(
        peripheralID: UUID,
        phase: GATTRecoveryPhase,
        now: TimeInterval,
        timeout: TimeInterval
    ) -> GATTWatchdogToken {
        generation &+= 1
        let token = GATTWatchdogToken(
            generation: generation,
            peripheralID: peripheralID,
            phase: phase,
            deadline: now + timeout
        )
        active = token
        return token
    }

    mutating func cancel() {
        generation &+= 1
        active = nil
    }

    func accepts(
        _ token: GATTWatchdogToken,
        peripheralID: UUID,
        phase: GATTRecoveryPhase,
        now: TimeInterval
    ) -> Bool {
        active == token && token.peripheralID == peripheralID
            && token.phase == phase && now >= token.deadline
    }
}

/// A failure authorizes one retry after a cooldown. Polling cannot move its deadline.
struct GATTRecoveryRetryGate {
    private(set) var attempts: Int = 0
    private var retryAvailableAt: TimeInterval?

    mutating func noteFailure(now: TimeInterval) {
        guard retryAvailableAt == nil else { return }
        let cooldown: TimeInterval
        switch attempts {
        case 0: cooldown = 30
        case 1: cooldown = 60
        case 2: cooldown = 120
        case 3: cooldown = 240
        default: cooldown = 300
        }
        retryAvailableAt = now + cooldown
    }

    mutating func claimRetry(now: TimeInterval) -> Bool {
        guard let retryAvailableAt, now >= retryAvailableAt else { return false }
        self.retryAvailableAt = nil
        if attempts < Int.max { attempts += 1 }
        return true
    }

    mutating func reset() {
        attempts = 0
        retryAvailableAt = nil
    }
}
