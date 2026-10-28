import Foundation

/// Tracks one recording across optimistic writes, device reports and rejected stop requests.
/// The glasses own the recording duration; no local deadline sends STOP.
/// A write or a timeout is never proof that the device finished recording.
struct HomeVideoCaptureState {
    static let minimumDuration: TimeInterval = 3

    private(set) var startedAt: TimeInterval?
    private(set) var hasConfirmedRecording = false
    private(set) var isStopPending = false

    mutating func startSent(at uptime: TimeInterval) {
        startedAt = uptime
        hasConfirmedRecording = false
        isStopPending = false
    }

    func stopDelayRemaining(at uptime: TimeInterval) -> TimeInterval {
        guard let startedAt else { return 0 }
        return max(0, Self.minimumDuration - max(0, uptime - startedAt))
    }

    mutating func stopSent() { isStopPending = true }
    mutating func stopRejectedOrUnconfirmed() { isStopPending = false }

    /// Only a device standby report can complete a recording. Repeated recording
    /// reports neither restart the minimum-duration clock nor unlock a pending stop.
    mutating func receive(
        _ status: AstraA1BleProtocol.DeviceRuntimeStatus,
        at uptime: TimeInterval,
        allowsCompletion: Bool = true
    ) -> Bool {
        switch status {
        case .videoRecording:
            // BLE writes can precede actual recording. Anchor the minimum duration
            // at the first device confirmation; repeated reports must not reset it.
            if !hasConfirmedRecording { startedAt = uptime }
            hasConfirmedRecording = true
        case .standby:
            let completed = allowsCompletion && (hasConfirmedRecording || isStopPending)
            reset()
            return completed
        default:
            break
        }
        return false
    }

    mutating func reset() {
        startedAt = nil
        hasConfirmedRecording = false
        isStopPending = false
    }
}
