import Foundation

@main
@MainActor
enum Gen1HotspotCleanupTests {
    typealias Cleanup = Gen1HotspotCleanup
    private static var assertions = 0

    private static func check(_ condition: Bool, _ message: String) {
        assertions += 1
        precondition(condition, message)
    }

    @MainActor
    private final class Harness {
        struct Transmission {
            let target: UUID
            let command: UInt8
            let time: TimeInterval
            let cancelled: Bool
        }
        struct Event {
            let time: TimeInterval
            let action: () -> Void
        }

        let identity = Gen1APImportIdentity(targetID: UUID(), token: UUID(), accountID: "account-a")
        var clock: TimeInterval = 0
        var authorized = true
        var connected = true
        var timing = Cleanup.Timing()
        var commands: [Transmission] = []
        var events: [Event] = []
        var logs: [(TimeInterval, String, String)] = []
        var status: UInt8?
        var onSend: ((UUID, UInt8) -> Bool)?
        var onSleep: (() -> Void)?
        lazy var cleanup = Cleanup(
            timing: timing,
            now: { [unowned self] in clock },
            sleep: { [unowned self] interval in
                await MainActor.run { self.advance(interval) }
                await Task.yield()
            },
            isAuthorized: { [unowned self] _ in authorized },
            canSend: { [unowned self] _ in connected },
            send: { [unowned self] target, command in
                commands.append(Transmission(target: target, command: command, time: clock, cancelled: Task.isCancelled))
                if let onSend { return onSend(target, command) }
                if command == Gen1Commands.deviceStatusQuery, let status {
                    reply(command, [status], target: target)
                }
                return true
            },
            log: { [unowned self] message, detail in logs.append((clock, message, detail)) }
        )

        var target: UUID { identity.targetID }
        var closeCommands: [Transmission] { commands.filter { $0.command == Gen1Commands.closeHotspot } }
        var queries: [Transmission] { commands.filter { $0.command == Gen1Commands.deviceStatusQuery } }

        func advance(_ interval: TimeInterval) {
            clock += interval
            let ready = events.filter { $0.time <= clock }.sorted { $0.time < $1.time }
            events.removeAll { $0.time <= clock }
            for event in ready { event.action() }
            onSleep?()
        }

        func at(_ time: TimeInterval, _ action: @escaping () -> Void) {
            events.append(Event(time: time, action: action))
        }

        func reply(_ command: UInt8, _ bytes: [UInt8], target: UUID? = nil) {
            cleanup.receive(targetID: target ?? self.target, command: command, payload: Data(bytes))
        }

        func pending(_ message: String) {
            check(cleanup.isPending(target), message)
        }

        func idleReplies(_ target: UUID, _ command: UInt8) -> Bool {
            if command == Gen1Commands.deviceStatusQuery { reply(command, [0], target: target) }
            return true
        }

        func run() async -> Cleanup.Outcome { await cleanup.close(identity) }
    }

    private static func testFieldTimeline() async {
        // Delays measured in the three September 29 import attempts. A close
        // reply with 0x02 is followed by transient standby and then shutdown.
        for replyDelay in [30.452, 32.691, 32.366] {
            let h = Harness()
            h.status = 3
            h.at(1) { h.pending("Queueing 0x38 must retain the barrier") }
            h.at(replyDelay - 1) { h.pending("The old close may remain outstanding for over 30 seconds") }
            h.at(replyDelay) {
                h.reply(Gen1Commands.closeHotspot, [0x02])
                h.pending("Undocumented 0x02 is a reply, not proof of closure")
            }
            h.at(replyDelay + 10) {
                h.status = 0
                h.reply(Gen1Commands.deviceStatusChanged, [0])
            }
            h.at(replyDelay + 12) { h.pending("Initial standby must not release the next import") }
            h.at(replyDelay + 13) {
                h.status = 4
                h.reply(Gen1Commands.deviceStatusChanged, [4])
                h.pending("SHUTTING_DOWN keeps the close barrier")
            }
            h.at(replyDelay + 17) {
                h.status = 0
                h.reply(Gen1Commands.deviceStatusChanged, [0])
            }
            h.at(replyDelay + 21) { h.pending("Final standby still needs a fresh stable observation interval") }

            let outcome = await h.run()
            check(outcome == .settled, "Field timeline eventually settles")
            check(!h.cleanup.isPending(h.target), "Confirmed stable idle releases the barrier")
            check(h.closeCommands.count == 1, "Only one close command per physical shutdown")
            check(h.clock >= replyDelay + 22, "Transient standby cannot shorten final stability wait")
            check(h.clock < 75, "Observed 30–33 second latency fits the bounded cleanup deadline")
            check(!h.queries.isEmpty && h.queries.allSatisfy { $0.time >= replyDelay }, "Only query after firmware answers close")
            check(h.logs.contains { $0.2.contains("reply_is_not_close_success") }, "Diagnostics explicitly avoid treating 0x02 as success")
        }
    }

    private static func testConcurrentCloseAndParentCancellation() async {
        let h = Harness()
        h.status = 0
        h.at(31) { h.reply(Gen1Commands.closeHotspot, [2]) }
        let first = Task { await h.run() }
        let second = Task { await h.run() }
        first.cancel()
        let firstOutcome = await first.value
        let secondOutcome = await second.value
        check(firstOutcome == .settled && secondOutcome == .settled, "Cancelled import and concurrent caller await one physical close")
        check(h.closeCommands.count == 1, "Concurrent cleanup cannot duplicate 0x38")
        check(h.commands.allSatisfy { !$0.cancelled }, "Cleanup worker does not inherit import cancellation")
        check(h.clock >= 51, "Cancellation cannot bypass confirmation and settling")
        check(!h.cleanup.isPending(h.target), "Worker completes cleanup after the parent was cancelled")
    }

    private static func testTimeoutAndResume() async {
        let h = Harness()
        check(await h.run() == .pending, "No reply times out as pending")
        check(h.clock == 75, "Default cleanup deadline is 75 seconds")
        h.pending("Timeout must retain the next-import barrier")
        check(h.closeCommands.count == 1 && h.queries.isEmpty, "No blind queries or repeated close before reply")

        h.status = 0
        h.at(80) { h.reply(Gen1Commands.closeHotspot, [2]) }
        h.cleanup.resume(h.target)
        check(await h.run() == .settled, "Retry resumes observation of the old physical close")
        check(h.closeCommands.count == 1, "Resuming after timeout never resends an already queued 0x38")
        check(h.clock >= 100, "Late reply still requires the full settling interval")
        check(h.logs.contains { $0.2.contains("retry_resumes_observation_without_resending_close") }, "Timeout diagnostics describe the retained barrier")
    }

    private static func testMissingReplyAndInvalidEvidence() async {
        for malformed in [[], [2, 0], [0xE3]] as [[UInt8]] {
            let h = Harness()
            h.status = 0
            h.at(1) { h.reply(Gen1Commands.closeHotspot, malformed) }
            h.at(30) {
                h.reply(Gen1Commands.deviceStatusQuery, [0])
                h.reply(Gen1Commands.deviceStatusChanged, [0])
            }
            check(await h.run() == .pending, "Malformed/busy close reply cannot authorize reopening: \(malformed)")
            h.pending("Malformed/busy response retains barrier")
            check(h.queries.isEmpty, "Unowned 0x72 is not a solicited fresh status")
            check(h.closeCommands.count == 1, "Bad reply never triggers a duplicate close")
        }

        let wrongTarget = Harness()
        wrongTarget.status = 0
        let unrelated = UUID()
        wrongTarget.at(1) { wrongTarget.reply(Gen1Commands.closeHotspot, [2], target: unrelated) }
        wrongTarget.at(30) { wrongTarget.reply(Gen1Commands.deviceStatusQuery, [0], target: unrelated) }
        check(await wrongTarget.run() == .pending, "A different peripheral cannot confirm target shutdown")
        check(!wrongTarget.cleanup.isPending(unrelated), "Unrelated responses do not create cleanup state")
        check(wrongTarget.queries.isEmpty, "Wrong-target close reply cannot start verification")

        let unsolicited = Harness()
        unsolicited.connected = false
        // Queue the close, lose BLE, then inject a well-formed reply and status
        // without ever letting the coordinator actively query this connection.
        unsolicited.connected = true
        unsolicited.at(0.25) {
            unsolicited.connected = false
            unsolicited.cleanup.connectionInterrupted()
            unsolicited.reply(Gen1Commands.closeHotspot, [2])
        }
        for time in [25.0, 35, 50, 70] {
            unsolicited.at(time) { unsolicited.reply(Gen1Commands.deviceStatusQuery, [0]) }
        }
        check(await unsolicited.run() == .pending, "Unsolicited 0x72 cannot stand in for an active status query")
        check(unsolicited.queries.isEmpty, "No query is sent while disconnected")

        let malformedStatus = Harness()
        malformedStatus.onSend = { target, command in
            if command == Gen1Commands.deviceStatusQuery {
                malformedStatus.reply(command, [0, 0], target: target)
                malformedStatus.reply(Gen1Commands.deviceStatusChanged, [0], target: target)
            }
            return true
        }
        malformedStatus.at(1) { malformedStatus.reply(Gen1Commands.closeHotspot, [2]) }
        check(await malformedStatus.run() == .pending, "Malformed query replies and unsolicited 0x73 cannot confirm stable idle")
        malformedStatus.pending("Invalid status evidence retains shutdown barrier")
    }

    private static func testReconnectRestartsIdleEvidence() async {
        for explicitlyInterrupted in [false, true] {
            let h = Harness()
            h.status = 0
            h.at(1) { h.reply(Gen1Commands.closeHotspot, [2]) }
            h.at(19) {
                h.connected = false
                if explicitlyInterrupted { h.cleanup.connectionInterrupted() }
            }
            h.at(22) { h.reply(Gen1Commands.deviceStatusQuery, [0]) }
            h.at(25) { h.connected = true }
            h.at(29) { h.pending("BLE reconnect cannot reuse idle evidence from the prior connection") }
            check(await h.run() == .settled, "Reconnection eventually confirms fresh stable idle")
            check(h.clock >= 31, "Reconnection requires new idle interval, whether reset by callback or disconnected poll")
            check(h.closeCommands.count == 1, "BLE reconnect must not send another physical close")
            check(!h.queries.contains { (19..<25).contains($0.time) }, "No status requests cross the disconnected interval")
        }
    }

    private static func testAuthorizationLoss() async {
        let initiallyInvalid = Harness()
        initiallyInvalid.authorized = false
        check(await initiallyInvalid.run() == .pending, "Unauthorized close leaves unresolved physical state")
        check(initiallyInvalid.commands.isEmpty, "No close or query is sent without account ownership")
        initiallyInvalid.pending("Account loss never silently clears barrier")
        initiallyInvalid.authorized = true
        initiallyInvalid.status = 0
        initiallyInvalid.at(1) { initiallyInvalid.reply(Gen1Commands.closeHotspot, [2]) }
        check(await initiallyInvalid.run() == .settled, "Restored ownership can finish a close that was never sent")
        check(initiallyInvalid.closeCommands.count == 1, "Only the authorized resume submits the close")

        let midClose = Harness()
        midClose.status = 0
        midClose.at(1) { midClose.reply(Gen1Commands.closeHotspot, [2]) }
        midClose.at(5) { midClose.authorized = false }
        check(await midClose.run() == .pending, "Ownership change pauses cleanup")
        midClose.pending("Existing close remains blocked after account change")
        let count = midClose.commands.count
        midClose.cleanup.resume(midClose.target)
        check(await midClose.run() == .pending, "Unauthorized retry cannot restart sending")
        check(midClose.commands.count == count, "No command is added after losing account ownership")
        midClose.authorized = true
        midClose.advance(25)
        let resumedAt = midClose.clock
        check(await midClose.run() == .settled, "Restored ownership resumes the existing close")
        check(midClose.clock >= resumedAt + 6, "Unobserved account-pause interval cannot count as stable idle")
        check(midClose.closeCommands.count == 1, "Ownership pause cannot duplicate the physical close")

        let lateReply = Harness()
        lateReply.at(1) { lateReply.reply(Gen1Commands.closeHotspot, [2]) }
        lateReply.onSend = { target, command in
            guard command == Gen1Commands.deviceStatusQuery else { return true }
            if lateReply.clock >= 21 {
                lateReply.authorized = false
                lateReply.reply(command, [0], target: target)
            } else {
                lateReply.reply(command, [0], target: target)
            }
            return true
        }
        check(await lateReply.run() == .pending, "Late reply after account change must not authorize reopening")
        lateReply.pending("Receive path must preserve barrier once ownership is lost")
    }

    private static func testQueryTimeoutRestartsIdleEvidence() async {
        let h = Harness()
        h.at(1) { h.reply(Gen1Commands.closeHotspot, [2]) }
        h.onSend = { target, command in
            if command == Gen1Commands.deviceStatusQuery,
               h.clock < 7 || h.clock >= 21 {
                h.reply(command, [0], target: target)
            }
            return true
        }
        h.at(24) { h.pending("A long gap in query replies invalidates earlier stable-idle evidence") }
        check(await h.run() == .settled, "Fresh status replies can recover after query timeouts")
        check(h.clock >= 28, "Stable interval restarts after a missing-reply gap")
        check(h.closeCommands.count == 1, "Status query timeout cannot resubmit physical shutdown")
    }

    private static func testObserverTimeoutGapDoesNotCountAsIdle() async {
        let h = Harness()
        h.status = 0
        h.at(62) { h.reply(Gen1Commands.closeHotspot, [2]) }
        check(await h.run() == .pending, "Late close reply can leave settling incomplete at overall deadline")
        h.pending("Partially verified close remains blocked at timeout")
        h.advance(100)
        let resumedAt = h.clock
        check(await h.run() == .settled, "Observation can resume after a long timeout gap")
        check(h.clock >= resumedAt + 6, "Timeout gap cannot stand in for fresh stable status sampling")
        check(h.closeCommands.count == 1, "Resuming partially verified close does not resend shutdown")
    }

    private static func testFailedStatusEnqueueRestartsIdleEvidence() async {
        let h = Harness()
        var rejectedQueries = 0
        h.at(1) { h.reply(Gen1Commands.closeHotspot, [2]) }
        h.onSend = { target, command in
            guard command == Gen1Commands.deviceStatusQuery else { return true }
            if (7..<21).contains(h.clock) {
                rejectedQueries += 1
                return false
            }
            h.reply(command, [0], target: target)
            return true
        }
        h.at(22) { h.pending("First status after failed enqueues cannot reuse idle evidence from seconds 1–5") }
        h.at(26) { h.pending("Recovered transport must produce a full fresh stable-idle interval") }
        check(await h.run() == .settled, "Status sampling can recover after transport enqueue failures")
        check(rejectedQueries == 7, "Regression exercises failed status sends at seconds 7 through 19")
        check(h.clock >= 27, "Enqueue failures reset stable idle, delaying completion beyond the first reply at second 21")
        check(h.closeCommands.count == 1, "Failed status enqueues cannot duplicate physical shutdown")
    }

    private static func testIndependentDevices() async {
        let h = Harness()
        check(await h.run() == .pending, "Device A retains a pending close")
        let second = Gen1APImportIdentity(targetID: UUID(), token: UUID(), accountID: "account-a")
        h.onSend = { target, command in
            if target == second.targetID {
                if command == Gen1Commands.closeHotspot { h.reply(command, [2], target: target) }
                if command == Gen1Commands.deviceStatusQuery { h.reply(command, [0], target: target) }
            }
            return true
        }
        check(await h.cleanup.close(second) == .settled, "Device B shutdown is independent of A's missing reply")
        h.pending("Completing B cannot clear A's pending close")
        check(!h.cleanup.isPending(second.targetID), "B alone is released")
        check(h.closeCommands.filter { $0.target == h.target }.count == 1, "B does not resend A's close")
        check(h.closeCommands.filter { $0.target == second.targetID }.count == 1, "B has its own single close command")
        let count = h.commands.count
        h.cleanup.resume(UUID())
        await Task.yield()
        check(h.commands.count == count, "Resuming an unknown peripheral does nothing")
    }

    private static func testFailedQueueCanRetryWithoutFalseEvidence() async {
        let h = Harness()
        var attempts = 0
        h.onSend = { target, command in
            if command == Gen1Commands.closeHotspot {
                attempts += 1
                if attempts == 1 { return false }
                h.reply(command, [2], target: target)
            } else if command == Gen1Commands.deviceStatusQuery {
                h.reply(command, [0], target: target)
            }
            return true
        }
        check(await h.run() == .settled, "A rejected transport enqueue can be attempted again")
        check(attempts == 2, "Retry only applies to close that was not enqueued")
        check(h.closeCommands[1].time > h.closeCommands[0].time, "Failed enqueue uses bounded polling instead of spinning")
        check(h.clock >= 20.25, "An immediate device reply still requires actual settling time")
    }

    static func main() async {
        let defaults = Cleanup.Timing()
        check(defaults.timeout == 75, "Production cleanup has a 75-second overall deadline")
        check(defaults.replySettleInterval == 20, "Transient post-reply standby is guarded for 20 seconds")
        check(defaults.idleInterval == 5, "Final idle must remain stable for five seconds")
        await testFieldTimeline()
        await testConcurrentCloseAndParentCancellation()
        await testTimeoutAndResume()
        await testMissingReplyAndInvalidEvidence()
        await testReconnectRestartsIdleEvidence()
        await testAuthorizationLoss()
        await testQueryTimeoutRestartsIdleEvidence()
        await testObserverTimeoutGapDoesNotCountAsIdle()
        await testFailedStatusEnqueueRestartsIdleEvidence()
        await testIndependentDevices()
        await testFailedQueueCanRetryWithoutFalseEvidence()
        print("Gen1HotspotCleanupTests passed: \(assertions) assertions")
    }
}
