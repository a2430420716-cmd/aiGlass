import Foundation

/// Uses the existing Gen1 0x06 request and accepts only its one-byte device result.
/// Queuing a BLE write does not confirm that the glasses joined the network.
@MainActor
final class Gen1WifiProvisionSession {
    enum Failure: Error, Equatable {
        case unavailable, sendFailed, disconnected, timedOut, malformedReply, rejected, unexpectedReply(UInt8)
    }

    private let send: (UInt8, Data) -> Bool
    private let validate: () -> Bool
    private let isConnected: () -> Bool
    private let now: () -> TimeInterval
    private let sleep: (TimeInterval) async throws -> Void
    private let timeout: TimeInterval
    private var isWaiting = false
    private var deadline: TimeInterval?
    private var reply: Result<Void, Failure>?

    init(timeout: TimeInterval = 30,
         send: @escaping (UInt8, Data) -> Bool,
         validate: @escaping () -> Bool,
         isConnected: @escaping () -> Bool,
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         sleep: @escaping (TimeInterval) async throws -> Void = {
             try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000))
         }) {
        self.timeout = timeout
        self.send = send
        self.validate = validate
        self.isConnected = isConnected
        self.now = now
        self.sleep = sleep
    }

    func receive(command: UInt8, payload: Data) {
        guard isWaiting, reply == nil, command == 0x06,
              validate(), isConnected() else { return }
        guard let deadline, now() < deadline else {
            reply = .failure(.timedOut)
            return
        }
        guard payload.count == 1, let status = payload.first else {
            reply = .failure(.malformedReply)
            return
        }
        switch status {
        case 1: reply = .success(())
        case 0: reply = .failure(.rejected)
        default: reply = .failure(.unexpectedReply(status))
        }
    }

    func run(payload: Data) async throws {
        guard !isWaiting else { throw Failure.unavailable }
        try check()
        reply = nil
        let deadline = now() + timeout
        self.deadline = deadline
        isWaiting = true
        defer {
            isWaiting = false
            self.deadline = nil
        }
        guard send(0x06, payload) else { throw Failure.sendFailed }
        while true {
            try check()
            // receive() already rejected responses arriving at/after the deadline.
            // A timely response remains valid if the main actor resumes later.
            if let reply {
                try reply.get()
                return
            }
            guard now() < deadline else { throw Failure.timedOut }
            try await sleep(0.2)
        }
    }

    private func check() throws {
        try Task.checkCancellation()
        guard isConnected() else { throw Failure.disconnected }
        guard validate() else { throw Failure.unavailable }
    }
}


/// Gen1 0x06 responses have no request identifier. An unconfirmed queued request
/// therefore fences its physical connection across pages, cancellation, and timeouts.
/// Only a real disconnect followed by a new connection can retire that fence.
@MainActor
final class Gen1WifiProvisionCoordinator {
    static let shared = Gen1WifiProvisionCoordinator()

    struct Lease: Equatable {
        let targetID: UUID
        let connectionGeneration: UInt64
        fileprivate let token: UUID
    }

    private struct Connection {
        var generation: UInt64 = 1
        var connected = true
        var observedDisconnect = false
        var pending: Lease?
        var quarantined = false
    }

    private var connections: [UUID: Connection] = [:]

    /// Called only from the BLE central's physical connection callbacks.
    /// Duplicate didConnect callbacks on the same link cannot clear a fence.
    func didConnect(targetID: UUID) {
        guard var connection = connections[targetID] else {
            connections[targetID] = Connection()
            return
        }
        guard !connection.connected else { return }
        if connection.observedDisconnect {
            connection.generation &+= 1
            connection.pending = nil
            connection.quarantined = false
            connection.observedDisconnect = false
        }
        connection.connected = true
        connections[targetID] = connection
    }

    /// The target ID matters: disconnecting another peripheral never clears this one.
    func didDisconnect(targetID: UUID) {
        var connection = connections[targetID] ?? Connection()
        connection.connected = false
        connection.observedDisconnect = true
        if connection.pending != nil { connection.quarantined = true }
        connections[targetID] = connection
    }

    func isNetworkOperationBlocked(targetID: UUID) -> Bool {
        guard let connection = connections[targetID] else { return false }
        return connection.pending != nil || connection.quarantined
    }

    /// A ready system-restored connection may be registered once. This bootstrap
    /// never resets any existing record, so an isReady flip cannot bypass a fence.
    func acquire(targetID: UUID, bootstrapConnected: Bool) -> Lease? {
        if connections[targetID] == nil, bootstrapConnected {
            connections[targetID] = Connection()
        }
        guard var connection = connections[targetID], connection.connected,
              connection.pending == nil, !connection.quarantined else { return nil }
        let lease = Lease(targetID: targetID, connectionGeneration: connection.generation, token: UUID())
        connection.pending = lease
        connections[targetID] = connection
        return lease
    }

    func isCurrent(_ lease: Lease) -> Bool {
        guard let connection = connections[lease.targetID] else { return false }
        return connection.connected && !connection.quarantined
            && connection.generation == lease.connectionGeneration && connection.pending == lease
    }

    /// An acknowledged success/rejection can release its slot. Anything queued
    /// without a confirmed result stays fenced, even after its UI task disappears.
    func finish(_ lease: Lease, wasQueued: Bool, acknowledged: Bool) {
        guard var connection = connections[lease.targetID],
              connection.generation == lease.connectionGeneration,
              connection.pending == lease else { return }
        if !wasQueued || (acknowledged && connection.connected && !connection.quarantined) {
            connection.pending = nil
            connection.quarantined = false
        } else {
            connection.quarantined = true
        }
        connections[lease.targetID] = connection
    }
}
