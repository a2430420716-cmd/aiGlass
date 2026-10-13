import Foundation

/// Verifies a fresh Bluetooth firmware version after the vendor OTA transport finishes.
/// Reconnection has its own budget so a slow reboot cannot consume the query window.
@MainActor
final class Gen1OtaVersionVerificationSession {
    enum Failure: Error, Equatable {
        case reconnectTimedOut
        case versionTimedOut(String?)
    }

    nonisolated struct Timing: Sendable {
        var reboot: TimeInterval = 3
        var reconnect: TimeInterval = 90
        var version: TimeInterval = 30
        var poll: TimeInterval = 0.2
        var queryInterval: TimeInterval = 3
        var reconnectInterval: TimeInterval = 2
    }

    private let timing: Timing
    private let send: () -> Bool
    private let validate: () throws -> Void
    private let isReady: () -> Bool
    private let reconnect: () -> Void
    private let now: () -> TimeInterval
    private let sleep: (TimeInterval) async throws -> Void
    private let log: (String) -> Void
    private var started = false
    private var active = false
    private var targetVersion = ""
    private var versionStartedAt: TimeInterval?
    private var hasQueuedQuery = false
    private var lastVersion: String?
    private var matchedVersion: String?

    init(timing: Timing = Timing(), send: @escaping () -> Bool,
         validate: @escaping () throws -> Void, isReady: @escaping () -> Bool,
         reconnect: @escaping () -> Void,
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         sleep: @escaping (TimeInterval) async throws -> Void = {
             try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000))
         }, log: @escaping (String) -> Void) {
        self.timing = timing
        self.send = send
        self.validate = validate
        self.isReady = isReady
        self.reconnect = reconnect
        self.now = now
        self.sleep = sleep
        self.log = log
    }

    /// The caller routes only the requested version command from the target peripheral.
    func receive(payload: Data) {
        guard active, hasQueuedQuery, let versionStartedAt else { return }
        guard (try? validate()) != nil, isReady() else {
            log("version reply ignored reason=target_unavailable")
            return
        }
        guard now() <= versionStartedAt + timing.version else {
            log("version reply ignored reason=after_deadline")
            return
        }
        guard let value = String(data: payload, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters)), !value.isEmpty else {
            log("version reply ignored reason=empty_or_invalid_utf8 bytes=\(payload.count)")
            return
        }
        lastVersion = value
        let matches = Gen1FirmwareUpdateProtocol.versionsMatch(value, target: targetVersion)
        if matches { matchedVersion = value }
        log("version reply actual=\(value.debugDescription) target=\(targetVersion.debugDescription) matches=\(matches) queryElapsed=\(now() - versionStartedAt)")
    }

    func run(targetVersion: String) async throws {
        precondition(!started, "A version verification session cannot be reused")
        started = true
        active = true
        self.targetVersion = targetVersion
        defer { active = false }
        try check()
        let startedAt = now()
        let rebootDeadline = startedAt + timing.reboot
        log("phase=reboot_wait seconds=\(timing.reboot) target=\(targetVersion.debugDescription)")
        while now() < rebootDeadline {
            try check()
            try await sleep(max(0, min(timing.poll, rebootDeadline - now())))
        }
        try check()
        let reconnectStartedAt = now()
        let reconnectDeadline = reconnectStartedAt + timing.reconnect
        var lastQueryAt = -Double.infinity
        var lastReconnectAt = -Double.infinity
        log("phase=reconnecting timeoutSeconds=\(timing.reconnect)")

        while true {
            try check()
            // A valid reply may arrive during the final sleep before the next poll
            // crosses the deadline. Consume that reply before evaluating a timeout.
            if let matchedVersion {
                log("phase=confirmed actual=\(matchedVersion.debugDescription) elapsed=\(now() - startedAt)")
                return
            }
            let current = now()
            let ready = isReady()
            if ready, versionStartedAt == nil {
                versionStartedAt = current
                log("phase=verifying timeoutSeconds=\(timing.version) reconnectElapsed=\(current - reconnectStartedAt)")
            }
            if let versionStartedAt {
                if current >= versionStartedAt + timing.version {
                    log("phase=timeout stage=version lastVersion=\(lastVersion?.debugDescription ?? "nil") queryElapsed=\(current - versionStartedAt) elapsed=\(current - startedAt)")
                    throw Failure.versionTimedOut(lastVersion)
                }
            } else if current >= reconnectDeadline {
                log("phase=timeout stage=reconnect lastVersion=nil reconnectElapsed=\(current - reconnectStartedAt) elapsed=\(current - startedAt)")
                throw Failure.reconnectTimedOut
            }

            if ready, current - lastQueryAt >= timing.queryInterval {
                lastQueryAt = current
                // Set eligibility before sending to support synchronous replies.
                // A rejected send must not make its synchronous reply authoritative.
                let previousQueued = hasQueuedQuery
                let previousVersion = lastVersion
                let previousMatchedVersion = matchedVersion
                hasQueuedQuery = true
                let queued = send()
                if !queued {
                    hasQueuedQuery = previousQueued
                    lastVersion = previousVersion
                    matchedVersion = previousMatchedVersion
                }
                log("version query queued=\(queued) elapsed=\(now() - startedAt)")
                try check()
                if matchedVersion != nil { continue }
            } else if !ready, current - lastReconnectAt >= timing.reconnectInterval {
                lastReconnectAt = current
                log("reconnect requested phase=\(versionStartedAt == nil ? "reconnecting" : "verifying") elapsed=\(current - startedAt)")
                reconnect()
            }
            try await sleep(timing.poll)
        }
    }

    private func check() throws {
        try Task.checkCancellation()
        try validate()
    }
}
