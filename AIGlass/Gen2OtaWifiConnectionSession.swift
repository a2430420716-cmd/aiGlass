import Foundation

/// Owns only hotspot preparation. Firmware upload starts after this session returns.
@MainActor
final class Gen2OtaWifiConnectionSession {
    struct Credential: Equatable {
        let ssid: String
        let password: String
        let httpAddress: String
    }

    enum Phase: Equatable {
        case joining(Int)
        case awaitingManual(Credential, error: String?)
        case checkingManual
        case finished
    }

    enum Failure: Error { case manualConnectionTimedOut }
    private enum Decision { case check, cancel, timeout }

    private let validate: () throws -> Void
    private let open: () async throws -> Credential
    private let restart: () async throws -> Void
    private let join: (Credential) async throws -> Void
    private let verify: (Credential) async throws -> Void
    private let canRetry: (Error) -> Bool
    private let onPhase: (Phase) -> Void
    private let manualTimeout: TimeInterval
    private var decision: CheckedContinuation<Decision, Never>?
    private var decisionTimer: Task<Void, Never>?
    private(set) var phase: Phase = .finished

    init(manualTimeout: TimeInterval = 180,
         validate: @escaping () throws -> Void,
         open: @escaping () async throws -> Credential,
         restart: @escaping () async throws -> Void,
         join: @escaping (Credential) async throws -> Void,
         verify: @escaping (Credential) async throws -> Void,
         canRetry: @escaping (Error) -> Bool,
         onPhase: @escaping (Phase) -> Void) {
        self.manualTimeout = manualTimeout
        self.validate = validate
        self.open = open
        self.restart = restart
        self.join = join
        self.verify = verify
        self.canRetry = canRetry
        self.onPhase = onPhase
    }

    func connect() async throws -> Credential {
        defer {
            resolve(.cancel)
            setPhase(.finished)
        }
        var latest: Credential?
        for attempt in 1...2 {
            try checkSession()
            setPhase(.joining(attempt))
            if attempt > 1 { try await restart() }
            try checkSession()
            let credential = try await open()
            latest = credential
            try checkSession()
            do {
                try await join(credential)
                try checkSession()
                return credential
            } catch {
                try checkSession()
                guard canRetry(error) else { throw error }
                // Only an association/IP failure can reach the next attempt.
                // A denied system prompt is always terminal.
            }
        }

        guard let credential = latest else { throw CancellationError() }
        let deadline = ProcessInfo.processInfo.systemUptime + manualTimeout
        var message: String?
        while true {
            try checkSession()
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                throw Failure.manualConnectionTimedOut
            }
            setPhase(.awaitingManual(credential, error: message))
            let choice = await waitForDecision(deadline: deadline)
            try checkSession()
            switch choice {
            case .cancel: throw CancellationError()
            case .timeout: throw Failure.manualConnectionTimedOut
            case .check: break
            }
            setPhase(.checkingManual)
            do {
                try await verify(credential)
                try checkSession()
                return credential
            } catch {
                try checkSession()
                guard canRetry(error) else { throw error }
                message = error.localizedDescription
            }
        }
    }

    @discardableResult
    func confirmManualConnection() -> Bool {
        guard case .awaitingManual = phase, decision != nil else { return false }
        resolve(.check)
        return true
    }

    func cancel() { resolve(.cancel) }

    private func checkSession() throws {
        try Task.checkCancellation()
        try validate()
    }

    private func setPhase(_ phase: Phase) {
        self.phase = phase
        onPhase(phase)
    }

    private func waitForDecision(deadline: TimeInterval) async -> Decision {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: .cancel)
                    return
                }
                decision = continuation
                decisionTimer = Task { [weak self] in
                    while !Task.isCancelled {
                        let remaining = deadline - ProcessInfo.processInfo.systemUptime
                        guard remaining > 0 else { break }
                        do {
                            try self?.validate()
                            try await Task.sleep(nanoseconds: UInt64(min(0.25, remaining) * 1_000_000_000))
                        } catch {
                            guard !Task.isCancelled else { return }
                            self?.resolve(.cancel)
                            return
                        }
                    }
                    guard !Task.isCancelled else { return }
                    self?.resolve(.timeout)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.resolve(.cancel) }
        }
    }

    private func resolve(_ choice: Decision) {
        decisionTimer?.cancel()
        decisionTimer = nil
        let pending = decision
        decision = nil
        pending?.resume(returning: choice)
    }
}
