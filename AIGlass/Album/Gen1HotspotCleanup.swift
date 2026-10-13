import Foundation

/// Owns the physical AP shutdown beyond an album task's lifetime. A queued 0x38
/// is not completion: field logs show its reply arriving 30–33 seconds later.
@MainActor
final class Gen1HotspotCleanup {
    nonisolated struct Timing: Sendable {
        var timeout: TimeInterval = 75
        var pollInterval: TimeInterval = 0.25
        var queryInterval: TimeInterval = 2
        var queryTimeout: TimeInterval = 5
        // An initial standby was followed by SHUTTING_DOWN ~13 seconds after
        // the close reply. Do not release on that transient standby.
        var replySettleInterval: TimeInterval = 20
        var idleInterval: TimeInterval = 5
    }

    enum Outcome: Equatable { case settled, pending }
    private struct Pending {
        let identity: Gen1APImportIdentity
        var queuedAt: TimeInterval?
        var replyAt: TimeInterval?
        var idleSince: TimeInterval?
        var querySentAt: TimeInterval?
        var lastQueryAt: TimeInterval?
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
        // An unstructured worker does not inherit cancellation from the import.
        // Multiple callers await the same close; never enqueue another 0x38.
        return await worker(for: identity.targetID).value
    }

    /// A retry resumes observation of the old shutdown, not a second shutdown.
    func resume(_ targetID: UUID) {
        guard isPending(targetID) else { return }
        _ = worker(for: targetID)
    }

    func connectionInterrupted() {
        for id in Array(pending.keys) {
            pending[id]?.idleSince = nil
            pending[id]?.querySentAt = nil
            pending[id]?.lastQueryAt = nil
        }
    }

    func receive(targetID: UUID, command: UInt8, payload: Data) {
        guard var state = pending[targetID], state.queuedAt != nil else { return }
        guard isAuthorized(state.identity), canSend(targetID) else {
            pending[targetID]?.idleSince = nil
            pending[targetID]?.querySentAt = nil
            return
        }
        let time = now()
        if command == Gen1Commands.closeHotspot {
            guard payload.count == 1 else { return }
            // 0x02 is deliberately NOT decoded as success. It is only evidence
            // that firmware has responded; fresh stable idle is also required.
            state.replyAt = payload.first == 0xE3 ? nil : time
            state.idleSince = nil
            state.querySentAt = nil
            state.lastQueryAt = nil
            log("一代：收到热点关闭回包，继续等待稳定空闲",
                "target=\(targetID) code=\(String(format: "0x%02X", payload[0])) elapsed=\(time - state.queuedAt!); reply_is_not_close_success")
        } else if command == Gen1Commands.deviceStatusQuery || command == Gen1Commands.deviceStatusChanged {
            guard payload.count == 1 else { return }
            if payload[0] != 0 {
                state.idleSince = nil
                state.querySentAt = nil
            } else if command == Gen1Commands.deviceStatusQuery,
                      let replyAt = state.replyAt, let queryAt = state.querySentAt,
                      queryAt >= replyAt, time - queryAt <= timing.queryTimeout {
                state.querySentAt = nil
                if state.idleSince == nil { state.idleSince = time }
                if queryAt - replyAt >= timing.replySettleInterval,
                   queryAt - state.idleSince! >= timing.idleInterval {
                    pending[targetID] = nil
                    log("一代：热点收尾等待结束，允许下一次导入",
                        "target=\(targetID) elapsed=\(time - state.queuedAt!) evidence=close_reply_then_fresh_stable_idle")
                    return
                }
            }
        }
        pending[targetID] = state
    }

    private func worker(for targetID: UUID) -> Task<Outcome, Never> {
        if let task = workers[targetID] { return task }
        // A paused/timed-out observer cannot count the unobserved gap as idle.
        pending[targetID]?.idleSince = nil
        pending[targetID]?.querySentAt = nil
        pending[targetID]?.lastQueryAt = nil
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
            guard let state = pending[targetID] else { return .settled }
            guard isAuthorized(state.identity) else {
                pending[targetID]?.idleSince = nil
                pending[targetID]?.querySentAt = nil
                log("一代：热点收尾暂停，保留重试阻断", "target=\(targetID) reason=account_or_target_changed")
                return .pending
            }
            if canSend(targetID) {
                if state.queuedAt == nil {
                    // Install before sending so even an immediate reply is owned.
                    pending[targetID]?.queuedAt = now()
                    if !send(targetID, Gen1Commands.closeHotspot) {
                        pending[targetID]?.queuedAt = nil
                    } else {
                        log("一代：请求关闭热点，等待设备收尾", "target=\(targetID) queued=true; queued_is_not_device_ack")
                    }
                } else if state.replyAt != nil,
                          state.lastQueryAt.map({ now() - $0 >= timing.queryInterval }) ?? true,
                          state.querySentAt.map({ now() - $0 > timing.queryTimeout }) ?? true {
                    if state.querySentAt != nil { pending[targetID]?.idleSince = nil }
                    pending[targetID]?.querySentAt = now()
                    pending[targetID]?.lastQueryAt = now()
                    if !send(targetID, Gen1Commands.deviceStatusQuery) {
                        pending[targetID]?.querySentAt = nil
                        pending[targetID]?.idleSince = nil
                    }
                }
            } else {
                pending[targetID]?.idleSince = nil
                pending[targetID]?.querySentAt = nil
                pending[targetID]?.lastQueryAt = nil
            }
            do { try await sleep(timing.pollInterval) }
            catch { return .pending } // Keep the barrier even if the worker is cancelled.
        }
        if !isPending(targetID) { return .settled }
        log("一代：热点收尾超时，禁止再次开启热点", "target=\(targetID) timeout=\(timing.timeout); retry_resumes_observation_without_resending_close")
        return .pending
    }
}
