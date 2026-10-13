import Foundation

/// Tracks ownership of a second-generation OTA preparation session.
/// Cancellation is safe only after this attempt was accepted and before an upgrade was submitted.
struct Gen2OtaRecoveryState {
    enum ConnectionDecision: Equatable {
        case ready
        case wait
        case targetChanged
        case timedOut
    }

    private(set) var targetID: UUID?
    private(set) var preparationAccepted = false
    private(set) var upgradeSubmitted = false
    private(set) var algorithmInstallInFlight = false

    mutating func begin(targetID: UUID) {
        self.targetID = targetID
        preparationAccepted = false
        upgradeSubmitted = false
        algorithmInstallInFlight = false
    }

    /// Call only for a successful preparation reply belonging to the active OTA attempt.
    @discardableResult
    mutating func acceptPreparation(from peripheralID: UUID) -> Bool {
        guard targetID == peripheralID, !upgradeSubmitted else { return false }
        preparationAccepted = true
        return true
    }

    @discardableResult
    mutating func markUpgradeSubmitted(to peripheralID: UUID) -> Bool {
        guard targetID == peripheralID else { return false }
        upgradeSubmitted = true
        return true
    }

    @discardableResult
    mutating func markAlgorithmInstallSubmitted(to peripheralID: UUID) -> Bool {
        guard targetID == peripheralID else { return false }
        algorithmInstallInFlight = true
        return true
    }

    /// A local timeout does not prove DLL installation stopped. Call only for an
    /// explicit terminal result from the selected device.
    @discardableResult
    mutating func markAlgorithmInstallFinished(from peripheralID: UUID) -> Bool {
        guard targetID == peripheralID, algorithmInstallInFlight else { return false }
        algorithmInstallInFlight = false
        return true
    }

    var canCancelPreparation: Bool {
        targetID != nil && preparationAccepted && !upgradeSubmitted && !algorithmInstallInFlight
    }

    func canCancelPreparation(for peripheralID: UUID) -> Bool {
        targetID == peripheralID && canCancelPreparation
    }

    mutating func finish() {
        targetID = nil
        preparationAccepted = false
        upgradeSubmitted = false
        algorithmInstallInFlight = false
    }

    /// A hotspot transition may briefly disconnect BLE. Wait for the same bound device,
    /// but never send upgrade or cleanup commands to a replacement device.
    static func connectionDecision(
        targetID: UUID,
        savedID: UUID?,
        connectedID: UUID?,
        isReady: Bool,
        isGen2: Bool,
        elapsed: TimeInterval,
        timeout: TimeInterval
    ) -> ConnectionDecision {
        guard savedID == targetID else { return .targetChanged }
        if let connectedID, connectedID != targetID { return .targetChanged }

        if isReady, connectedID == targetID {
            return isGen2 ? .ready : .targetChanged
        }

        // Generation is unknown during discovery. It cannot disqualify a reconnect.
        return elapsed >= timeout ? .timedOut : .wait
    }
}
