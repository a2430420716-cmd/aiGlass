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

    static func main() async {
        let normal = Harness()
        check(normal.cleanup.prepareForTransferCompletion(normal.identity), "Arm normal shutdown before writing TCP end")
        normal.at(0.25) { normal.reply(Gen1Commands.deviceStatusChanged, [4]) }
        normal.at(0.5) { normal.reply(Gen1Commands.deviceStatusChanged, [0]) }
        check(await normal.cleanup.waitForTransferCompletion(normal.identity) == .settled, "TCP end followed by 4 then 0 closes hotspot")
        check(normal.commands.isEmpty, "Normal completion sends neither 0x38 nor status queries")
        check(normal.clock < 2, "Normal shutdown settles immediately after idle")

        let earlyReports = Harness()
        check(earlyReports.cleanup.prepareForTransferCompletion(earlyReports.identity), "Arm before TCP completion callback")
        earlyReports.reply(Gen1Commands.deviceStatusChanged, [4])
        earlyReports.reply(Gen1Commands.deviceStatusChanged, [0])
        check(await earlyReports.cleanup.waitForTransferCompletion(earlyReports.identity) == .settled, "Reports before close begins are retained")
        earlyReports.cleanup.transferCompletionFailed(earlyReports.identity)
        check(!earlyReports.cleanup.isPending(earlyReports.target), "Late write failure cannot recreate a settled barrier")
        check(earlyReports.commands.isEmpty, "Early reports do not trigger a forced close")

        let normalTimeout = Harness()
        check(normalTimeout.cleanup.prepareForTransferCompletion(normalTimeout.identity), "Arm shutdown timeout test")
        normalTimeout.at(0.5) { normalTimeout.reply(Gen1Commands.deviceStatusChanged, [0]) }
        normalTimeout.onSend = { target, command in
            normalTimeout.reply(command, [0], target: target)
            return true
        }
        check(await normalTimeout.cleanup.waitForTransferCompletion(normalTimeout.identity) == .settled, "Incomplete normal sequence falls back to forced ACK")
        check(normalTimeout.closeCommands.count == 1, "Normal timeout forces one close")
        check(normalTimeout.closeCommands[0].time >= 30, "Idle alone cannot release barrier before normal shutdown deadline")

        let wrongSequence = Harness()
        wrongSequence.reply(Gen1Commands.deviceStatusChanged, [4])
        check(wrongSequence.cleanup.prepareForTransferCompletion(wrongSequence.identity), "Prepare new batch after stale shutdown")
        wrongSequence.at(0.25) {
            wrongSequence.reply(Gen1Commands.deviceStatusChanged, [0])
            wrongSequence.reply(Gen1Commands.deviceStatusChanged, [4], target: UUID())
            wrongSequence.reply(Gen1Commands.deviceStatusChanged, [0])
            wrongSequence.reply(Gen1Commands.deviceStatusChanged, [4, 0])
            wrongSequence.reply(Gen1Commands.deviceStatusChanged, [0])
            wrongSequence.reply(Gen1Commands.deviceStatusQuery, [4])
            wrongSequence.reply(Gen1Commands.deviceStatusChanged, [0])
            wrongSequence.reply(Gen1Commands.deviceStatusChanged, [4])
            wrongSequence.reply(Gen1Commands.deviceStatusChanged, [2])
            wrongSequence.reply(Gen1Commands.deviceStatusChanged, [0])
        }
        check(await wrongSequence.cleanup.waitForTransferCompletion(wrongSequence.identity) == .pending, "Stale, foreign, malformed or interrupted status sequences cannot confirm shutdown")
        check(wrongSequence.closeCommands.count == 2, "Abnormal fallback retains bounded missing ACK retry")
        wrongSequence.reply(Gen1Commands.deviceStatusChanged, [4])
        wrongSequence.reply(Gen1Commands.deviceStatusChanged, [0])
        check(!wrongSequence.cleanup.isPending(wrongSequence.target), "Late valid normal shutdown sequence releases barrier")

        let interrupted = Harness()
        check(interrupted.cleanup.prepareForTransferCompletion(interrupted.identity), "Arm disconnect sequence test")
        interrupted.reply(Gen1Commands.deviceStatusChanged, [4])
        interrupted.cleanup.connectionInterrupted()
        interrupted.reply(Gen1Commands.deviceStatusChanged, [0])
        check(interrupted.cleanup.isPending(interrupted.target), "Do not join reports across BLE connections")

        let normalUnauthorized = Harness()
        check(normalUnauthorized.cleanup.prepareForTransferCompletion(normalUnauthorized.identity), "Arm account change test")
        normalUnauthorized.authorized = false
        normalUnauthorized.reply(Gen1Commands.deviceStatusChanged, [4])
        normalUnauthorized.reply(Gen1Commands.deviceStatusChanged, [0])
        check(await normalUnauthorized.cleanup.waitForTransferCompletion(normalUnauthorized.identity) == .pending, "Account switch rejects normal completion reports")
        check(normalUnauthorized.commands.isEmpty, "No forced close after authorization is lost")

        let writeFailed = Harness()
        check(writeFailed.cleanup.prepareForTransferCompletion(writeFailed.identity), "Arm write failure test")
        writeFailed.cleanup.transferCompletionFailed(writeFailed.identity)
        writeFailed.onSend = { target, command in
            writeFailed.reply(command, [0], target: target)
            return true
        }
        check(await writeFailed.cleanup.waitForTransferCompletion(writeFailed.identity) == .settled, "TCP end write failure uses abnormal close")
        check(writeFailed.closeCommands.count == 1 && writeFailed.closeCommands[0].time < 1, "Write failure does not wait for normal shutdown deadline")

        let success = Harness()
        success.at(0.5) { success.reply(Gen1Commands.closeHotspot, [0]) }
        check(await success.run() == .settled, "00 immediately completes cleanup")
        check(success.clock < 2, "No twenty-second settle or five-second idle wait")
        success.reply(Gen1Commands.deviceStatusChanged, [4])
        check(!success.cleanup.isPending(success.target), "Post-ACK shutdown is normal and cannot restore barrier")
        check(success.queries.isEmpty, "No 0x72 queries")
        check(success.closeCommands.count == 1, "Successful close sent once")

        let malformed = Harness()
        malformed.at(0.25) {
            malformed.reply(Gen1Commands.closeHotspot, [])
            malformed.reply(Gen1Commands.closeHotspot, [0, 0])
            malformed.reply(Gen1Commands.closeHotspot, [0], target: UUID())
            malformed.reply(Gen1Commands.deviceStatusChanged, [0])
            malformed.reply(Gen1Commands.deviceStatusQuery, [0])
        }
        check(await malformed.run() == .pending, "Only exact single-byte 0x38 from owner accepted")
        check(malformed.queries.isEmpty, "Runtime status never used for cleanup")
        malformed.reply(Gen1Commands.closeHotspot, [0])
        check(!malformed.cleanup.isPending(malformed.target), "Late valid ACK releases timeout barrier")

        let missingThenSuccess = Harness()
        missingThenSuccess.onSend = { target, command in
            if missingThenSuccess.closeCommands.count == 2 {
                missingThenSuccess.reply(command, [0], target: target)
            }
            return true
        }
        check(await missingThenSuccess.run() == .settled, "Missing ACK retries once and accepts success")
        check(missingThenSuccess.closeCommands.count == 2, "Exactly one missing ACK retry")
        check(missingThenSuccess.closeCommands[1].time >= 10, "Do not resend before ACK timeout")

        let noAcknowledgement = Harness()
        check(await noAcknowledgement.run() == .pending, "Missing ACK never fabricates close success")
        check(noAcknowledgement.closeCommands.count == 2, "Missing ACK resend remains bounded")
        check(noAcknowledgement.clock <= 21, "No 75-second wait after retry is exhausted")
        check(await noAcknowledgement.run() == .pending, "Reentering cleanup preserves missing ACK budget")
        check(noAcknowledgement.closeCommands.count == 2, "Reentry cannot create an endless resend loop")
        noAcknowledgement.reply(Gen1Commands.closeHotspot, [0])
        check(!noAcknowledgement.cleanup.isPending(noAcknowledgement.target), "Late ACK after retry releases barrier")

        let disconnected = Harness()
        disconnected.at(1) { disconnected.connected = false }
        check(await disconnected.run() == .pending, "Disconnected cleanup remains pending")
        check(disconnected.closeCommands.count == 1, "No retry sent to disconnected device")

        let retry = Harness()
        retry.onSend = { target, command in
            if retry.closeCommands.count == 1 { retry.reply(command, [2], target: target) }
            else { retry.reply(command, [0], target: target) }
            return true
        }
        check(await retry.run() == .settled, "Process failure retries and then succeeds")
        check(retry.closeCommands.count == 2, "02 permits one additional close")
        check(retry.closeCommands[1].time - retry.closeCommands[0].time >= 2, "Retry is delayed")

        let repeatedFailure = Harness()
        repeatedFailure.onSend = { target, command in
            repeatedFailure.reply(command, [2], target: target)
            return true
        }
        check(await repeatedFailure.run() == .pending, "Repeated 02 remains blocked")
        check(repeatedFailure.closeCommands.count == 2, "No endless process failure retries")
        check(repeatedFailure.queries.isEmpty, "Failure does not query runtime")

        let busy = Harness()
        busy.onSend = { target, command in
            busy.reply(command, [0xE3], target: target)
            return true
        }
        check(await busy.run() == .pending, "Busy never treated as close success")
        check(busy.closeCommands.count == 3, "Busy retry budget is bounded")

        let unknown = Harness()
        unknown.at(0.5) { unknown.reply(Gen1Commands.closeHotspot, [1]) }
        check(await unknown.run() == .pending, "Unknown/failure code does not release barrier")

        let unauthorized = Harness()
        unauthorized.at(0.5) {
            unauthorized.authorized = false
            unauthorized.reply(Gen1Commands.closeHotspot, [0])
        }
        check(await unauthorized.run() == .pending, "Lost account authorization rejects ACK")

        let synchronous = Harness()
        synchronous.onSend = { target, command in
            synchronous.reply(command, [0], target: target)
            return true
        }
        check(await synchronous.run() == .settled, "Synchronous ACK cannot be overwritten")
        check(!synchronous.cleanup.isPending(synchronous.target), "Synchronous success leaves no barrier")

        let cancelled = Harness()
        cancelled.at(1) { cancelled.reply(Gen1Commands.closeHotspot, [0]) }
        let task = Task { await cancelled.run() }
        task.cancel()
        check(await task.value == .settled, "Import cancellation does not cancel owned cleanup worker")
        check(cancelled.closeCommands.count == 1, "Parent cancellation does not duplicate close")
        print("Gen1HotspotCleanupTests passed: \(assertions) assertions")
    }
}
