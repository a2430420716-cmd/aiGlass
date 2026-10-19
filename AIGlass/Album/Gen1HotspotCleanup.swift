import Foundation

/// Only the owning device's single-byte 0x38 acknowledgement completes AP shutdown.
/// Runtime idle/shutdown notifications are not hotspot-close acknowledgements.
@MainActor
final class Gen1HotspotCleanup {
    nonisolated struct Timing: Sendable {
        var timeout: TimeInterval = 75
        var pollInterval: TimeInterval = 0.25
        var acknowledgementTimeout: TimeInterval = 10
        var retryInterval: TimeInterval = 2
        var maxAttempts = 3
    }

    enum Outcome: Equatable { case settled, pending }
    private struct Pending {
        let identity: Gen1APImportIdentity
        var queuedAt: TimeInterval?
        var attempts = 0
        var processFailureRetries = 0
        var missingAcknowledgementRetries = 0
        var awaitingReply = false
        var retryAt: TimeInterval?
        var failed = false
    }

    private let timing: Timing
    private let now: () -> TimeInterval
    private let sleep: (TimeInterval) async throws -> Void
    private let isAuthorized: (Gen1APImportIdentity) -> Bool
    private let canSend: (UUID) -> Bool
    private let send: (UUID, UInt8) -> Bool
    private let log: (String, String) -> Void
    private var pending: [UUID: Pending] = [:]
    private var workers: [UUID: Task<Outcome, Never>] = [:]

    init(timing: Timing = Timing(),
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         sleep: @escaping (TimeInterval) async throws -> Void = { seconds in
             try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
         },
         isAuthorized: @escaping (Gen1APImportIdentity) -> Bool,
         canSend: @escaping (UUID) -> Bool,
         send: @escaping (UUID, UInt8) -> Bool,
         log: @escaping (String, String) -> Void = { _, _ in }) {
        self.timing = timing
        self.now = now
        self.sleep = sleep
        self.isAuthorized = isAuthorized
        self.canSend = canSend
        self.send = send
        self.log = log
    }

    func isPending(_ targetID: UUID) -> Bool { pending[targetID] != nil }

    func close(_ identity: Gen1APImportIdentity) async -> Outcome {
        if pending[identity.targetID] == nil {
            pending[identity.targetID] = Pending(identity: identity)
        }
        return await worker(for: identity.targetID).value
    }

    /// Explicit recovery may retry a device-rejected close. A missing ACK gets
    /// only one retry over the lifetime of this pending shutdown.
    func resume(_ targetID: UUID) {
        guard var state = pending[targetID], workers[targetID] == nil else { return }
        if state.failed {
            state.failed = false
            state.attempts = 0
            state.processFailureRetries = 0
            state.retryAt = now() + timing.retryInterval
            pending[targetID] = state
        }
        _ = worker(for: targetID)
    }

    func connectionInterrupted() {
        // A later 0x38 reply is still required. No cached runtime state is used.
    }

    func receive(targetID: UUID, command: UInt8, payload: Data) {
        guard command == Gen1Commands.closeHotspot,
              payload.count == 1,
              var state = pending[targetID], state.queuedAt != nil,
              isAuthorized(state.identity), canSend(targetID) else { return }
        state.awaitingReply = false
        let code = payload[0]
        log("一代：收到热点关闭回包", "target=\(targetID) code=\(String(format: "0x%02X", code)) attempts=\(state.attempts)")
        if code == 0 {
            pending[targetID] = nil
            log("一代：热点已确认关闭，允许下一次导入", "target=\(targetID) evidence=0x38_payload_00 runtimeStatusNotRequired=true")
            return
        }
        // Duplicate replies while waiting for the retry must not consume its budget.
        pending[targetID] = state
        guard state.retryAt == nil, !state.failed else { return }
        if code == 0x02, state.processFailureRetries < 1, state.attempts < timing.maxAttempts {
            state.processFailureRetries += 1
            state.retryAt = now() + timing.retryInterval
            log("一代：热点进程未退出，将重试关闭一次", "target=\(targetID) code=0x02 retryDelay=\(timing.retryInterval)s")
        } else if code == 0xE3, state.attempts < timing.maxAttempts {
            state.retryAt = now() + timing.retryInterval
            log("一代：设备忙，稍后重试关闭热点", "target=\(targetID) code=0xE3 retryDelay=\(timing.retryInterval)s")
        } else {
            state.failed = true
            log("一代：热点关闭失败，保留阻断", "target=\(targetID) code=\(String(format: "0x%02X", code)) attempts=\(state.attempts)")
        }
        pending[targetID] = state
    }

    private func worker(for targetID: UUID) -> Task<Outcome, Never> {
        if let task = workers[targetID] { return task }
        let task = Task { [self] in
            defer { workers[targetID] = nil }
            return await run(targetID)
        }
        workers[targetID] = task
        return task
    }

    private func run(_ targetID: UUID) async -> Outcome {
        let deadline = now() + timing.timeout
        while now() < deadline {
            guard var state = pending[targetID] else { return .settled }
            guard isAuthorized(state.identity), !state.failed else { return .pending }
            if state.awaitingReply, let sentAt = state.queuedAt,
               now() - sentAt >= timing.acknowledgementTimeout {
                guard state.missingAcknowledgementRetries < 1, state.attempts < timing.maxAttempts else {
                    log("一代：热点关闭补发后仍未收到确认，保留阻断", "target=\(targetID) attempts=\(state.attempts) expected=0x38_payload_00 lateAcknowledgementAccepted=true")
                    return .pending
                }
                state.missingAcknowledgementRetries += 1
                state.awaitingReply = false
                state.retryAt = now()
                pending[targetID] = state
                log("一代：热点关闭回包缺失，补发一次", "target=\(targetID) acknowledgementTimeout=\(timing.acknowledgementTimeout)s retryBudget=1 runtimeStatusNotUsed=true")
            }
            if canSend(targetID), state.queuedAt == nil || state.retryAt.map({ now() >= $0 }) == true {
                let previous = state
                state.queuedAt = now()
                state.retryAt = nil
                state.attempts += 1
                state.awaitingReply = true
                // Install before send so synchronous replies cannot be overwritten.
                pending[targetID] = state
                if !send(targetID, Gen1Commands.closeHotspot) {
                    pending[targetID] = previous
                } else {
                    log("一代：请求关闭热点，等待 0x38 确认", "target=\(targetID) attempt=\(state.attempts) runtimeQueries=false")
                }
            }
            do { try await sleep(timing.pollInterval) }
            catch { return .pending }
        }
        if !isPending(targetID) { return .settled }
        log("一代：热点关闭确认超时，保留阻断", "target=\(targetID) timeout=\(timing.timeout)s expected=0x38_payload_00")
        return .pending
    }
}
