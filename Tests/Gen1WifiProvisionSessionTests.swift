import Foundation

@main
@MainActor
enum Gen1WifiProvisionSessionTests {
    private typealias Session = Gen1WifiProvisionSession
    private static var assertions = 0

    private static func check(_ value: Bool, _ message: String) {
        assertions += 1
        precondition(value, message)
    }

    private final class Harness {
        var clock: TimeInterval = 0
        var valid = true
        var connected = true
        var acceptsWrite = true
        var commands: [UInt8] = []
        var replyOnSend: (UInt8, Data)?
        var onSleep: (() -> Void)?
        var timeout: TimeInterval = 1
        lazy var session: Session = Session(timeout: timeout,
            send: { [unowned self] command, _ in
                commands.append(command)
                if let (code, payload) = replyOnSend {
                    session.receive(command: code, payload: payload)
                }
                return acceptsWrite
            },
            validate: { [unowned self] in valid },
            isConnected: { [unowned self] in connected },
            now: { [unowned self] in clock },
            sleep: { [unowned self] interval in
                await MainActor.run {
                    clock += interval
                    onSleep?()
                }
                await Task.yield()
            })
    }

    private static func expect(_ failure: Session.Failure, from harness: Harness) async {
        do {
            try await harness.session.run(payload: Data("Example/open-network".utf8))
            check(false, "Expected \(failure), but the request succeeded")
        } catch let actual as Session.Failure {
            check(actual == failure, "Expected \(failure), got \(actual)")
        } catch {
            check(false, "Unexpected error \(error)")
        }
    }

    static func main() async throws {
        let success = Harness()
        success.replyOnSend = (0x06, Data([1]))
        try await success.session.run(payload: Data("Example/open-network".utf8))
        check(success.commands == [0x06], "Standalone provisioning must send only Wi-Fi configuration, never OTA")

        let rejected = Harness()
        rejected.replyOnSend = (0x06, Data([0]))
        await expect(.rejected, from: rejected)

        let unknown = Harness()
        unknown.replyOnSend = (0x06, Data([0xE3]))
        await expect(.unexpectedReply(0xE3), from: unknown)

        let malformed = Harness()
        malformed.replyOnSend = (0x06, Data([1, 0]))
        await expect(.malformedReply, from: malformed)

        let empty = Harness()
        empty.replyOnSend = (0x06, Data())
        await expect(.malformedReply, from: empty)

        let queuedOnly = Harness()
        await expect(.timedOut, from: queuedOnly)
        check(queuedOnly.clock >= 1, "Queued write cannot be reported as device success")

        let unrelatedReply = Harness()
        unrelatedReply.replyOnSend = (0x09, Data([1]))
        await expect(.timedOut, from: unrelatedReply)

        let staleReply = Harness()
        staleReply.session.receive(command: 0x06, payload: Data([1]))
        await expect(.timedOut, from: staleReply)

        let cannotSend = Harness()
        cannotSend.acceptsWrite = false
        cannotSend.replyOnSend = (0x06, Data([1]))
        await expect(.sendFailed, from: cannotSend)

        let switchedAccount = Harness()
        switchedAccount.onSleep = {
            switchedAccount.valid = false
            switchedAccount.session.receive(command: 0x06, payload: Data([1]))
        }
        await expect(.unavailable, from: switchedAccount)
        check(switchedAccount.commands.count == 1, "Ownership changes cannot trigger retries")

        let disconnected = Harness()
        disconnected.onSleep = {
            disconnected.connected = false
            disconnected.session.receive(command: 0x06, payload: Data([1]))
        }
        await expect(.disconnected, from: disconnected)

        let unavailable = Harness()
        unavailable.valid = false
        await expect(.unavailable, from: unavailable)
        check(unavailable.commands.isEmpty, "Unavailable device cannot receive credentials")

        let cancelled = Harness()
        cancelled.timeout = 1000
        let operation = Task { try await cancelled.session.run(payload: Data()) }
        await Task.yield()
        operation.cancel()
        do {
            try await operation.value
            check(false, "Cancelled operation cannot report success")
        } catch is CancellationError {
            check(true, "Cancellation propagated")
        }
        let deadlineACK = Harness()
        deadlineACK.onSleep = {
            deadlineACK.clock = 1
            deadlineACK.session.receive(command: 0x06, payload: Data([1]))
        }
        await expect(.timedOut, from: deadlineACK)

        let afterDeadlineACK = Harness()
        afterDeadlineACK.onSleep = {
            afterDeadlineACK.clock = 2
            afterDeadlineACK.session.receive(command: 0x06, payload: Data([1]))
        }
        await expect(.timedOut, from: afterDeadlineACK)

        let queuedBeforeDeadline = Harness()
        queuedBeforeDeadline.onSleep = {
            queuedBeforeDeadline.clock = 0.9
            queuedBeforeDeadline.session.receive(command: 0x06, payload: Data([1]))
            queuedBeforeDeadline.clock = 1.1
        }
        try await queuedBeforeDeadline.session.run(payload: Data())
        check(queuedBeforeDeadline.clock > 1, "A timely ACK remains valid when the main actor consumes it after the deadline")

        let validBeforeDeadline = Harness()
        validBeforeDeadline.onSleep = {
            validBeforeDeadline.clock = 0.9
            validBeforeDeadline.session.receive(command: 0x06, payload: Data([1]))
        }
        try await validBeforeDeadline.session.run(payload: Data())
        check(validBeforeDeadline.clock < 1, "A valid ACK before the deadline may complete")

        let coordinator = Gen1WifiProvisionCoordinator()
        let targetA = UUID()
        let targetB = UUID()
        let firstPageLease = coordinator.acquire(targetID: targetA, bootstrapConnected: true)!
        check(coordinator.isCurrent(firstPageLease), "A known ready connection can acquire its first lease")
        check(coordinator.isNetworkOperationBlocked(targetID: targetA), "An active lease blocks media import and OTA")
        check(coordinator.acquire(targetID: targetA, bootstrapConnected: true) == nil, "Another page cannot acquire an active request's connection")

        // Page A queued 0x06 and disappeared. A fresh page has no request ID,
        // but the shared physical-connection fence must survive that destruction.
        coordinator.finish(firstPageLease, wasQueued: true, acknowledged: false)
        check(!coordinator.isCurrent(firstPageLease), "An abandoned request cannot accept an ACK")
        check(coordinator.isNetworkOperationBlocked(targetID: targetA), "Cancel and timeout cannot release a queued request")
        let secondPageLease = coordinator.acquire(targetID: targetA, bootstrapConnected: true)
        check(secondPageLease == nil, "Reopening the page cannot send request B that might accept request A's late ACK")
        coordinator.didConnect(targetID: targetA)
        check(coordinator.acquire(targetID: targetA, bootstrapConnected: true) == nil, "A duplicate didConnect cannot clear the same physical link")
        coordinator.didDisconnect(targetID: targetB)
        coordinator.didConnect(targetID: targetB)
        check(coordinator.isNetworkOperationBlocked(targetID: targetA), "Another peripheral's reconnect cannot clear target A")
        coordinator.didDisconnect(targetID: targetA)
        check(coordinator.isNetworkOperationBlocked(targetID: targetA), "Disconnect alone does not retire a pending operation")
        check(coordinator.acquire(targetID: targetA, bootstrapConnected: true) == nil, "isReady/bootstrap cannot bypass a recorded disconnect")
        coordinator.finish(firstPageLease, wasQueued: true, acknowledged: true)
        check(coordinator.isNetworkOperationBlocked(targetID: targetA), "A late completion after disconnect cannot release the fence")
        coordinator.didConnect(targetID: targetA)
        let newConnectionLease = coordinator.acquire(targetID: targetA, bootstrapConnected: true)!
        check(newConnectionLease.connectionGeneration != firstPageLease.connectionGeneration, "Physical reconnect must allocate a new connection generation")
        check(!coordinator.isCurrent(firstPageLease), "Old-page ownership cannot become current again")
        coordinator.finish(firstPageLease, wasQueued: true, acknowledged: true)
        check(coordinator.isCurrent(newConnectionLease), "An old page's cleanup cannot release the new connection's request")
        coordinator.finish(newConnectionLease, wasQueued: true, acknowledged: true)
        check(!coordinator.isNetworkOperationBlocked(targetID: targetA), "A confirmed current ACK releases the network-operation slot")
        let neverQueued = coordinator.acquire(targetID: targetA, bootstrapConnected: true)!
        coordinator.finish(neverQueued, wasQueued: false, acknowledged: false)
        check(!coordinator.isNetworkOperationBlocked(targetID: targetA), "A write that was never queued can release its slot")

        let cancelledPages = Gen1WifiProvisionCoordinator()
        let owner = cancelledPages.acquire(targetID: targetA, bootstrapConnected: true)!
        let requestA = Harness()
        requestA.onSleep = {
            cancelledPages.finish(owner, wasQueued: true, acknowledged: false)
            requestA.valid = cancelledPages.isCurrent(owner)
            requestA.session.receive(command: 0x06, payload: Data([1]))
        }
        await expect(.unavailable, from: requestA)
        check(cancelledPages.acquire(targetID: targetA, bootstrapConnected: true) == nil,
              "A cancelled request followed by late success cannot let a new page send another request")
        check(requestA.commands == [0x06], "Page replacement and late ACKs do not send a second request")

        print("Gen1 Wi-Fi provisioning: \(assertions) assertions passed")
    }
}
