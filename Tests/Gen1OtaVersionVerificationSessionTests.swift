import Foundation

@main
@MainActor
enum Gen1OtaVersionVerificationSessionTests {
    typealias Session = Gen1OtaVersionVerificationSession
    private static var assertions = 0

    private static func check(_ condition: Bool, _ message: String) {
        assertions += 1
        precondition(condition, message)
    }

    private enum OwnershipError: Error { case changed }

    @MainActor
    private final class Harness {
        struct Event {
            let time: TimeInterval
            let action: () -> Void
        }

        var clock: TimeInterval = 0
        var ready = true
        var valid = true
        var commands: [TimeInterval] = []
        var reconnects: [TimeInterval] = []
        var logs: [String] = []
        var events: [Event] = []
        var onSend: (() -> Bool)?
        var onSleep: (() -> Void)?
        var timing: Session.Timing
        let target = "03.26.01.07"
        lazy var session = Session(
            timing: timing,
            send: { [unowned self] in
                commands.append(clock)
                return onSend?() ?? true
            },
            validate: { [unowned self] in
                if !valid { throw OwnershipError.changed }
            },
            isReady: { [unowned self] in ready },
            reconnect: { [unowned self] in reconnects.append(clock) },
            now: { [unowned self] in clock },
            sleep: { [unowned self] interval in
                await MainActor.run { self.advance(interval) }
                await Task.yield()
            },
            log: { [unowned self] in logs.append($0) }
        )

        init() {
            var timing = Session.Timing()
            timing.poll = 0.25
            self.timing = timing
        }

        func advance(_ interval: TimeInterval) {
            let deadline = clock + interval
            while let event = events.filter({ $0.time <= deadline }).min(by: { $0.time < $1.time }) {
                let index = events.firstIndex { $0.time == event.time }!
                events.remove(at: index)
                clock = event.time
                event.action()
            }
            clock = deadline
            onSleep?()
        }

        func at(_ time: TimeInterval, _ action: @escaping () -> Void) {
            events.append(Event(time: time, action: action))
        }

        func reply(_ version: String) { session.receive(payload: Data(version.utf8)) }
        func run() async throws { try await session.run(targetVersion: target) }
    }

    private static func expectFailure(_ h: Harness, _ expected: Session.Failure) async {
        do {
            try await h.run()
            preconditionFailure("Expected \(expected)")
        } catch let actual as Session.Failure {
            check(actual == expected, "Expected \(expected), received \(actual)")
        } catch {
            preconditionFailure("Unexpected error: \(error)")
        }
        check(!h.logs.contains { $0.contains("phase=confirmed") }, "Failure never reports confirmed")
    }

    private static func testFreshSynchronousReply() async throws {
        let h = Harness()
        h.onSend = {
            h.reply("\0  V3.26.1.7\r\n")
            return true
        }
        try await h.run()
        check(h.commands == [3], "Query starts after the full reboot delay")
        check(h.clock == 3, "A synchronous fresh matching reply completes immediately")
        check(h.logs.contains { $0.contains("matches=true") }, "Matching reply recorded")
        check(h.logs.contains { $0.contains("version query queued=true") }, "Successful submission recorded")
        let count = h.logs.count
        h.reply("03.26.01.04")
        check(h.logs.count == count, "Completed session ignores late replies")

        let multiple = Harness()
        multiple.onSend = {
            multiple.reply(multiple.target)
            multiple.reply("03.26.01.05")
            return true
        }
        try await multiple.run()
        check(multiple.logs.contains { $0.contains("phase=confirmed actual=\"03.26.01.07\"") }, "Confirmation records the matching reply even if another version follows")
    }

    private static func testSeparateBudgets() async throws {
        let h = Harness()
        h.ready = false
        h.at(92) { h.ready = true }
        h.at(120) { h.reply(h.target) }
        try await h.run()
        check(h.commands.first == 92, "Reconnection may consume 89 seconds before the first query")
        check(h.clock == 120, "Version reply remains eligible 28 seconds after late reconnect")
        check(h.commands.count == 10, "Late reconnect retains the complete 30-second query window")
        check(h.reconnects == Array(stride(from: 3.0, through: 91.0, by: 2.0)), "Reconnect requests are throttled to two seconds")

        let absent = Harness()
        absent.ready = false
        await expectFailure(absent, .reconnectTimedOut)
        check(absent.clock == 93, "Reboot and reconnection deadlines remain separate")
        check(absent.commands.isEmpty, "No queries sent before ready")
        check(absent.logs.contains { $0.contains("stage=reconnect") }, "Reconnect timeout stage recorded")
    }

    private static func testFinalSleepBoundary() async throws {
        let h = Harness()
        h.timing.reboot = 0
        h.timing.version = 1
        h.timing.poll = 0.6
        h.at(0.95) { h.reply(h.target) }
        try await h.run()
        check(h.clock > 1, "Next poll crosses the deadline after an in-time reply")
        check(h.logs.contains { $0.contains("phase=confirmed") }, "Reply received before the deadline wins over the subsequent timeout check")

        let late = Harness()
        late.timing.reboot = 0
        late.timing.version = 1
        late.timing.poll = 0.6
        late.at(1.1) { late.reply(late.target) }
        await expectFailure(late, .versionTimedOut(nil))
        check(late.logs.contains { $0.contains("after_deadline") }, "A genuinely late reply does not confirm the update")
    }

    private static func testMissingAndMalformedReplies() async {
        let absent = Harness()
        await expectFailure(absent, .versionTimedOut(nil))
        check(absent.clock == 33, "Ready connection has a bounded 30-second query budget")
        check(absent.commands == Array(stride(from: 3.0, through: 30.0, by: 3.0)), "Version queries are throttled to three seconds")
        check(absent.logs.contains { $0.contains("stage=version lastVersion=nil") }, "Missing-version timeout recorded")

        let wrong = Harness()
        wrong.onSend = { wrong.reply("03.26.01.05"); return true }
        await expectFailure(wrong, .versionTimedOut("03.26.01.05"))
        check(wrong.logs.contains { $0.contains("matches=false") }, "Mismatched version recorded")

        for payload in [Data(), Data(" \0\r\n".utf8), Data([0xFF, 0xFE])] {
            let malformed = Harness()
            malformed.onSend = { malformed.session.receive(payload: payload); return true }
            await expectFailure(malformed, .versionTimedOut(nil))
            check(malformed.logs.contains { $0.contains("empty_or_invalid_utf8") }, "Empty or invalid UTF-8 cannot confirm a version")
        }
    }

    private static func testQueryEligibility() async {
        let cached = Harness()
        cached.reply(cached.target)
        cached.at(1) { cached.reply(cached.target) }
        await expectFailure(cached, .versionTimedOut(nil))
        check(!cached.logs.contains { $0.contains("version reply actual=") }, "Pre-run and reboot-time replies cannot stand in for a fresh query")

        let rejected = Harness()
        rejected.onSend = { rejected.reply(rejected.target); return false }
        await expectFailure(rejected, .versionTimedOut(nil))
        check(rejected.logs.contains { $0.contains("queued=false") }, "Rejected query submission recorded")

        let unsolicited = Harness()
        unsolicited.onSend = { false }
        unsolicited.at(5) { unsolicited.reply(unsolicited.target) }
        await expectFailure(unsolicited, .versionTimedOut(nil))
        check(!unsolicited.logs.contains { $0.contains("matches=true") }, "No successful query means a later unsolicited match is ineligible")

        let preserved = Harness()
        preserved.onSend = {
            if preserved.commands.count == 1 {
                preserved.reply("03.26.01.05")
                return true
            }
            preserved.reply(preserved.target)
            return false
        }
        await expectFailure(preserved, .versionTimedOut("03.26.01.05"))
    }

    private static func testDisconnectCannotExtendBudget() async {
        let h = Harness()
        h.at(5) { h.ready = false }
        h.at(10) { h.reply(h.target) }
        h.at(20) { h.ready = true }
        await expectFailure(h, .versionTimedOut(nil))
        check(h.clock == 33, "Disconnect and reconnect do not reset the query deadline")
        check(h.logs.filter { $0.contains("phase=verifying timeoutSeconds=") }.count == 1, "Version phase starts once")
        check(h.logs.contains { $0.contains("reason=target_unavailable") }, "Disconnected reply ignored")
        check(!h.reconnects.isEmpty, "Query phase still attempts reconnection")
    }

    private static func testOwnershipAndCancellation() async throws {
        for phaseTime in [1.0, 4.0] {
            let invalid = Harness()
            invalid.at(phaseTime) {
                invalid.valid = false
                invalid.reply(invalid.target)
            }
            do {
                try await invalid.run()
                preconditionFailure("Changed ownership must stop verification")
            } catch OwnershipError.changed {
                check(invalid.clock == phaseTime, "Validation stops the session during reboot or query")
            }
            check(!invalid.logs.contains { $0.contains("phase=confirmed") }, "Invalid ownership cannot confirm success")
        }

        let invalidWhileReconnecting = Harness()
        invalidWhileReconnecting.ready = false
        invalidWhileReconnecting.at(5) { invalidWhileReconnecting.valid = false }
        do {
            try await invalidWhileReconnecting.run()
            preconditionFailure("Changed ownership must stop reconnection")
        } catch OwnershipError.changed {
            check(invalidWhileReconnecting.clock == 5, "Validation also runs while reconnecting")
            check(invalidWhileReconnecting.commands.isEmpty, "Invalid ownership never sends a query")
        }

        for cancelDuringReboot in [true, false] {
            let h = Harness()
            var task: Task<Void, Error>!
            h.onSleep = {
                if h.clock >= (cancelDuringReboot ? 1 : 4) { task.cancel() }
            }
            task = Task { try await h.run() }
            do {
                try await task.value
                preconditionFailure("Cancellation must propagate")
            } catch is CancellationError {
                check(!h.logs.contains { $0.contains("phase=confirmed") }, "Cancellation never confirms success")
            }
        }

        let invalidAfterReply = Harness()
        invalidAfterReply.onSend = {
            invalidAfterReply.reply(invalidAfterReply.target)
            invalidAfterReply.valid = false
            return true
        }
        do {
            try await invalidAfterReply.run()
            preconditionFailure("Ownership validation must precede success")
        } catch OwnershipError.changed {
            check(!invalidAfterReply.logs.contains { $0.contains("phase=confirmed") }, "A reply cannot bypass invalidated ownership")
        }
    }

    static func main() async throws {
        try await testFreshSynchronousReply()
        try await testSeparateBudgets()
        try await testFinalSleepBoundary()
        await testMissingAndMalformedReplies()
        await testQueryEligibility()
        await testDisconnectCannotExtendBudget()
        try await testOwnershipAndCancellation()
        print("Gen1 OTA version verification: \(assertions) assertions passed")
    }
}
