import Foundation

/// The first transfer installs the loader. After its requested reconnect, the
/// device pulls the firmware through the SDK's second-stage transfer command.
struct Gen1BluetoothOtaSessionState {
    enum Phase: Equatable {
        case transferringLoader(Int)
        case reconnecting
        case transferringFirmware(Int)
        case awaitingResult
        case completed

        var overallProgress: Int {
            switch self {
            case .transferringLoader(let percent): return 20 + percent * 15 / 100
            case .reconnecting: return 35
            case .transferringFirmware(let percent): return 35 + percent * 59 / 100
            case .awaitingResult: return 94
            case .completed: return 95 // The control connection still verifies the version.
            }
        }
    }

    enum ImageCommand: Equatable { case start, resume }

    private(set) var phase: Phase = .transferringLoader(0)
    private var imageSubmitted = false
    private var resumePending = false
    private var firmwareStarted = false

    mutating func imageCommandAfterFeature() -> ImageCommand? {
        guard phase != .completed else { return nil }
        if resumePending {
            resumePending = false
            firmwareStarted = true
            phase = .transferringFirmware(0)
            return .resume
        }
        guard !imageSubmitted else { return nil }
        imageSubmitted = true
        return .start
    }

    @discardableResult
    mutating func requestReconnect() -> Bool {
        guard imageSubmitted, !resumePending, phase != .completed else { return false }
        resumePending = true
        phase = .reconnecting
        return true
    }

    mutating func receiveLoaderProgress(_ percent: Int) {
        guard imageSubmitted, !resumePending, !firmwareStarted,
              case .transferringLoader(let previous) = phase else { return }
        phase = .transferringLoader(max(previous, min(100, max(0, percent))))
    }

    mutating func receiveFirmwareProgress(_ percent: Int) {
        guard imageSubmitted, !resumePending, phase != .completed else { return }
        firmwareStarted = true // Also supports a device already in loader/recovery mode.
        let previous: Int
        switch phase {
        case .transferringFirmware(let value): previous = value
        case .awaitingResult: previous = 100
        default: previous = 0
        }
        let value = max(previous, min(100, max(0, percent)))
        phase = value == 100 ? .awaitingResult : .transferringFirmware(value)
    }

    /// A percentage alone never completes OTA. Only a final SDK result can do so.
    mutating func receiveSuccess() -> Bool {
        guard imageSubmitted, firmwareStarted, !resumePending, phase != .completed else { return false }
        phase = .completed
        return true
    }

    /// A reboot after the second transfer still needs a fresh matching version.
    var canVerifyAfterReboot: Bool { phase == .awaitingResult }
}

/// Bounds initial service acquisition and each SDK-requested loader reconnect.
/// A stalled native connect must release before exact-target rediscovery.
struct Gen1BluetoothOtaConnectionPolicy {
    static let totalTimeout: TimeInterval = 90
    static let attemptTimeout: TimeInterval = 25
    static let maximumAttempts = 3

    struct Attempt: Equatable {
        let generation: UInt64
        let peripheralID: UUID
        let deadline: TimeInterval
    }

    private(set) var deadline: TimeInterval?
    private(set) var attempts = 0
    private(set) var active: Attempt?
    private var generation: UInt64 = 0

    var isActive: Bool { deadline != nil }

    /// Retrieve once for a fast initial connection. Retrying the same cached
    /// native request without a fresh advertisement can reproduce its stall.
    var shouldRetrieveCachedPeripheral: Bool { isActive && attempts == 0 }

    mutating func begin(now: TimeInterval) {
        stop()
        deadline = now + Self.totalTimeout
        attempts = 0
    }

    func canAttempt(now: TimeInterval) -> Bool {
        guard let deadline else { return false }
        return now < deadline && attempts < Self.maximumAttempts && active == nil
    }

    mutating func claim(peripheralID: UUID, isConnectable: Bool, now: TimeInterval) -> Attempt? {
        guard isConnectable, canAttempt(now: now), let deadline else { return nil }
        attempts += 1
        generation &+= 1
        let attempt = Attempt(generation: generation, peripheralID: peripheralID,
                              deadline: min(deadline, now + Self.attemptTimeout))
        active = attempt
        return attempt
    }

    mutating func expire(_ attempt: Attempt, now: TimeInterval) -> Bool {
        guard active == attempt, now >= attempt.deadline else { return false }
        cancelAttempt()
        return true
    }

    mutating func cancelAttempt() {
        generation &+= 1
        active = nil
    }

    mutating func stop() {
        cancelAttempt()
        deadline = nil
    }
}
