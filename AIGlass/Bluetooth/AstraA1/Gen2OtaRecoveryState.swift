import Foundation

/// Tracks ownership of a second-generation OTA preparation session.
/// Preparation cleanup and confirmed-failure cleanup use separate authorization.
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
    private(set) var failureConfirmed = false
    private(set) var upgradeCompleted = false

    mutating func begin(targetID: UUID) {
        self.targetID = targetID
        preparationAccepted = false
        upgradeSubmitted = false
        algorithmInstallInFlight = false
        failureConfirmed = false
        upgradeCompleted = false
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
        targetID != nil && preparationAccepted && !upgradeSubmitted && !algorithmInstallInFlight && !upgradeCompleted
    }

    func canCancelPreparation(for peripheralID: UUID) -> Bool {
        targetID == peripheralID && canCancelPreparation
    }

    var hasOwnedAttempt: Bool {
        preparationAccepted || upgradeSubmitted || algorithmInstallInFlight
    }

    @discardableResult
    mutating func confirmFailure(for peripheralID: UUID) -> Bool {
        guard targetID == peripheralID, hasOwnedAttempt, !upgradeCompleted else { return false }
        failureConfirmed = true
        return true
    }

    func canCancelFailedAttempt(for peripheralID: UUID) -> Bool {
        targetID == peripheralID && failureConfirmed && hasOwnedAttempt && !upgradeCompleted
    }

    mutating func markUpgradeCompleted(from peripheralID: UUID) {
        guard targetID == peripheralID else { return }
        upgradeCompleted = true
        failureConfirmed = false
    }

    mutating func receiveProgress(from peripheralID: UUID, percent: Int) {
        guard targetID == peripheralID else { return }
        upgradeSubmitted = true
        // A restarted stream of progress invalidates earlier failure evidence,
        // including while cleanup is waiting for Bluetooth to recover.
        failureConfirmed = false
        if percent >= 100 { upgradeCompleted = true }
    }

    mutating func finish() {
        targetID = nil
        preparationAccepted = false
        upgradeSubmitted = false
        algorithmInstallInFlight = false
        failureConfirmed = false
        upgradeCompleted = false
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

struct Gen2OtaVersionReport {
    let targetID: UUID
    let version: String
    let sequence: Int
}

/// Missing progress is not failure evidence. Only a fresh version plus a fresh
/// idle report from the original target may establish a failed upgrade.
enum Gen2OtaResultDecision: Equatable {
    case completed
    case failed
    case unconfirmed

    static func evaluate(targetVersion: String, previousVersion: String? = nil, freshVersion: String?, freshIdle: Bool,
                         receivedCompletion: Bool) -> Self {
        if receivedCompletion { return .completed }
        guard let version = freshVersion?.trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters)),
              !version.isEmpty, !targetVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              version.rangeOfCharacter(from: .decimalDigits) != nil,
              targetVersion.rangeOfCharacter(from: .decimalDigits) != nil,
              !["n/a", "unknown", "--"].contains(version.lowercased()) else { return .unconfirmed }
        if FirmwareVersionComparator.versionsMatch(version, target: targetVersion) { return .completed }
        // A different, newly installed version is not proof that flashing failed.
        guard freshIdle, let previousVersion,
              FirmwareVersionComparator.versionsMatch(version, target: previousVersion) else { return .unconfirmed }
        return .failed
    }
}

/// Repeated/late progress cannot extend the hard upper bound indefinitely.
struct Gen2OtaProgressDeadline {
    let startedAt: TimeInterval
    private(set) var lastProgressAt: TimeInterval

    init(now: TimeInterval) {
        startedAt = now
        lastProgressAt = now
    }

    mutating func receivedProgress(now: TimeInterval) { lastProgressAt = now }

    func hasExpired(now: TimeInterval, inactivity: TimeInterval, maximum: TimeInterval = 900) -> Bool {
        now - lastProgressAt >= inactivity || now - startedAt >= maximum
    }
}
