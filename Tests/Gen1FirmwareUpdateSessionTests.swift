import Foundation

@main
@MainActor
enum Gen1FirmwareUpdateSessionTests {
    typealias Session = Gen1FirmwareUpdateSession
    private static var assertions = 0

    private static func check(_ condition: Bool, _ message: String) {
        assertions += 1
        precondition(condition, message)
    }

    private enum OwnershipError: Error { case accountChanged, deviceChanged }

    @MainActor
    private final class Harness {
        struct Transmission {
            let command: UInt8
            let payload: Data
            let time: TimeInterval
        }
        struct Event {
            let time: TimeInterval
            let action: () -> Void
        }

        var clock: TimeInterval = 0
        var connected = true
        var ownershipError: Error?
        var commands: [Transmission] = []
        var phases: [Session.Phase] = []
        var logs: [String] = []
        var events: [Event] = []
        var reconnectCount = 0
        var onSend: ((UInt8, Data) -> Bool)?
        var onSleep: (() -> Void)?
        var onReconnect: (() -> Void)?
        var batteryReply: UInt8? = 80
        var wifiReply: UInt8? = 1
        var progressCommand: UInt8 = 0x3A
        var finalVersion: String? = "G5K61_V1.02.3_20250901"
        var baselineBattery: Int?
        var automaticProgress = true
        var automaticallyConfirmWifi = true
        var timing: Session.Timing
        lazy var session: Session = Session(
            timing: timing,
            send: { [unowned self] command, payload in
                commands.append(Transmission(command: command, payload: payload, time: clock))
                if let onSend { return onSend(command, payload) }
                return defaultSend(command, payload)
            },
            validate: { [unowned self] in
                if let ownershipError { throw ownershipError }
            },
            isConnected: { [unowned self] in connected },
            reconnect: { [unowned self] in
                reconnectCount += 1
                onReconnect?()
            },
            now: { [unowned self] in clock },
            sleep: { [unowned self] interval in
                await MainActor.run { self.advanceClock(interval) }
                await Task.yield()
            },
            changed: { [unowned self] phase in
                phases.append(phase)
                if phase == .awaitingWifiConfirmation, automaticallyConfirmWifi {
                    _ = session.confirmWifiProvision()
                }
            },
            log: { [unowned self] in logs.append($0) }
        )

        init() {
            var timing = Session.Timing()
            timing.poll = 0.25 // Exact binary increments make deadline boundary checks deterministic.
            self.timing = timing
        }

        var codes: [UInt8] { commands.map(\.command) }
        var completed: Bool { phases.contains(.completed) }

        func advanceClock(_ interval: TimeInterval) {
            clock += interval
            let ready = events.filter { $0.time <= clock }
            events.removeAll { $0.time <= clock }
            for event in ready { event.action() }
            onSleep?()
        }

        func reply(_ command: UInt8, _ bytes: [UInt8]) {
            session.receive(command: command, payload: Data(bytes))
        }

        func after(_ delay: TimeInterval, _ action: @escaping () -> Void) {
            events.append(Event(time: clock + delay, action: action))
        }

        func defaultSend(_ command: UInt8, _ payload: Data) -> Bool {
            switch command {
            case 0x05:
                if let batteryReply { reply(0x05, [batteryReply]) }
            case 0x06:
                if let wifiReply { reply(0x06, [wifiReply]) }
            case 0x09:
                if automaticProgress {
                    after(0.5) { [unowned self] in reply(progressCommand, [50]) }
                    after(1) { [unowned self] in reply(progressCommand, [100]) }
                }
            case 0x15:
                if let finalVersion {
                    session.receive(command: 0x15, payload: Data(finalVersion.utf8))
                }
            default: break
            }
            return true
        }

        func run() async throws {
            try await session.run(
                wifi: Gen1FirmwareWifiCredentials(ssid: "Home", password: "secret-password"),
                urlPayload: Data([1]) + Data("http://firmware.example.com/main.bin".utf8),
                targetVersion: "1.2.3", baselineBattery: baselineBattery
            )
        }
    }

    private static func expectFailure(_ harness: Harness, _ failure: Session.Failure) async {
        do {
            try await harness.run()
            preconditionFailure("Expected failure: \(failure)")
        } catch let actual as Session.Failure {
            check(actual == failure, "Expected \(failure), received \(actual)")
        } catch {
            preconditionFailure("Unexpected error: \(error)")
        }
        check(!harness.completed, "A failed session must never report completion")
    }

    private static func testHappyPathAndFreshVersion() async throws {
        for progressCommand: UInt8 in [0x3A, 0x18] {
            let h = Harness()
            h.progressCommand = progressCommand
            try await h.run()
            check(h.codes == [0x05, 0x06, 0x09, 0x12, 0x15], "Battery → Wi-Fi → OTA → restart → fresh version")
            check(h.commands[1].payload == Data("Home/secret-password".utf8), "Credentials retain Android encoding")
            check(h.commands[2].payload == Data([1]) + Data("http://firmware.example.com/main.bin".utf8), "OTA sends exact URL payload")
            check(h.commands[0].payload.isEmpty && h.commands[3].payload.isEmpty && h.commands[4].payload.isEmpty, "Queries/restart carry empty payloads")
            check(h.phases == [.checkingBattery, .provisioningWifi(1), .awaitingWifiConfirmation, .upgrading(0), .upgrading(50), .upgrading(100), .restarting, .verifyingVersion, .completed], "Confirmation separates provisioning from firmware download")
            check(h.commands[3].time == 1, "Restart waits for progress 100, without requiring an OTA ACK")
            check(h.commands[4].time == 4, "Version is queried after the full reboot delay")
        }

        let fresh = Harness()
        fresh.finalVersion = nil
        fresh.onSend = { command, payload in
            if command == 0x09 {
                fresh.session.receive(command: 0x15, payload: Data("1.2.3".utf8))
            }
            if command == 0x12 {
                fresh.session.receive(command: 0x15, payload: Data("1.2.3".utf8))
            }
            return fresh.defaultSend(command, payload)
        }
        await expectFailure(fresh, .versionNotConfirmed(nil))
        check(fresh.codes.filter { $0 == 0x15 }.count > 1, "Version confirmation retries fresh reads")
        check(fresh.clock == 94, "Version confirmation retains its 90-second deadline")
    }

    private static func testBatteryGate() async throws {
        let low = Harness()
        low.batteryReply = 79
        await expectFailure(low, .batteryLow(79))
        check(low.codes == [0x05], "Low battery prevents provisioning and OTA")

        for invalid: UInt8? in [nil, 101, 255] {
            let unknown = Harness()
            unknown.batteryReply = invalid
            await expectFailure(unknown, .batteryUnknown)
            check(unknown.codes == [0x05], "Unknown battery prevents provisioning and OTA")
            check(unknown.clock == 3, "Battery query times out after three seconds")
        }

        let cached = Harness()
        cached.batteryReply = nil
        cached.baselineBattery = 80
        try await cached.run()
        check(cached.completed, "An 80% cached baseline supports an unanswered fresh battery query")
        check(cached.commands.first { $0.command == 0x06 }?.time == 3, "Cached battery is used only after the query wait")

        let transient = Harness()
        transient.batteryReply = 75
        transient.baselineBattery = 80
        await expectFailure(transient, .batteryLow(75))
        check(transient.codes == [0x05], "Fresh battery below 80% blocks provisioning despite older high cache")

        let failedQuery = Harness()
        failedQuery.baselineBattery = 80
        failedQuery.onSend = { command, payload in
            command == 0x05 ? false : failedQuery.defaultSend(command, payload)
        }
        try await failedQuery.run()
        check(failedQuery.commands.first { $0.command == 0x06 }?.time == 0, "A failed battery send can use a valid baseline without waiting")

        let invalidCache = Harness()
        invalidCache.batteryReply = nil
        invalidCache.baselineBattery = 101
        await expectFailure(invalidCache, .batteryUnknown)
    }

    private static func testWifiRetryAndDiagnostics() async throws {
        for reply: UInt8? in [0, 2, nil] {
            let h = Harness()
            h.wifiReply = reply
            h.onSend = { command, payload in
                if command == 0x17 {
                    h.session.receive(command: command, payload: Data("SSID=Home password=secret-password error=auth".utf8))
                }
                return h.defaultSend(command, payload)
            }
            let failure: Session.Failure = reply.map { $0 == 0 ? .wifiProvisionFailed : .wifiUnexpectedResult($0) } ?? .wifiResponseTimedOut
            await expectFailure(h, failure)
            check(h.codes == [0x05, 0x06, 0x06, 0x17], "Provisioning gets two attempts, then diagnostic; OTA must never start")
            check(h.logs.contains { $0.contains("wifi diagnostic=") && $0.contains("<redacted>") }, "Wi-Fi diagnosis redacts passwords")
            check(!h.logs.contains { $0.contains("secret-password") }, "No diagnostic or normal log leaks the password")
            if reply == nil {
                check(h.clock == 60, "Two provisioning timeouts each last thirty seconds")
                check(h.commands.filter { $0.command == 0x06 }.map(\.time) == [0, 30], "Unanswered provisioning retries only after thirty seconds")
            }
        }

        for delay: TimeInterval in [14, 29.75, 30] {
            let delayed = Harness()
            delayed.onSend = { command, payload in
                if command == 0x06 {
                    delayed.after(10) { delayed.reply(0x06, []) }
                    delayed.after(delay) { delayed.reply(0x06, [1]) }
                    return true
                }
                return delayed.defaultSend(command, payload)
            }
            try await delayed.run()
            check(delayed.codes == [0x05, 0x06, 0x09, 0x12, 0x15], "Valid Wi-Fi replies within thirty seconds avoid duplicate provisioning")
            check(delayed.commands.first { $0.command == 0x09 }?.time == delay, "Empty replies cannot start OTA or shorten the provisioning wait")
            check(delayed.logs.contains { $0.contains("timeoutSeconds=30") }, "Provisioning logs expose the active timeout")
        }

        let secondTry = Harness()
        var attempt = 0
        secondTry.onSend = { command, payload in
            if command == 0x06 {
                attempt += 1
                secondTry.reply(0x06, [attempt == 1 ? 0 : 1])
                return true
            }
            return secondTry.defaultSend(command, payload)
        }
        try await secondTry.run()
        check(secondTry.codes == [0x05, 0x06, 0x06, 0x09, 0x12, 0x15], "Only a successful retry allows OTA")

        let sendFailure = Harness()
        sendFailure.onSend = { command, payload in
            command == 0x06 ? false : sendFailure.defaultSend(command, payload)
        }
        await expectFailure(sendFailure, .sendFailed(0x06))
        check(sendFailure.codes == [0x05, 0x06], "Unqueued provisioning stops immediately without claiming device/network failure")
        check(sendFailure.clock == 0, "A failed local send must not spend time waiting for a device reply")

        let diagnosticFailure = Harness()
        diagnosticFailure.wifiReply = 0
        diagnosticFailure.onSend = { command, payload in
            command == 0x17 ? false : diagnosticFailure.defaultSend(command, payload)
        }
        await expectFailure(diagnosticFailure, .wifiProvisionFailed)
        check(diagnosticFailure.clock == 0, "Failed diagnostic send does not wait")
    }

    private static func testWifiFailureEvidence() async {
        let malformed = Harness()
        malformed.onSend = { command, payload in
            if command == 0x06 {
                malformed.reply(0x06, [1, 0])
                return true
            }
            if command == 0x17 {
                // Even a partial or reformatted password must never reach logs.
                malformed.session.receive(command: 0x17, payload: Data("password=secret-".utf8))
                return true
            }
            return malformed.defaultSend(command, payload)
        }
        await expectFailure(malformed, .wifiMalformedResponse)
        check(!malformed.codes.contains(0x09), "Malformed success payload cannot authorize firmware download")
        check(malformed.logs.contains { $0.contains("expected_exactly_one_status_byte") }, "Malformed replies retain framing evidence")
        check(!malformed.logs.contains { $0.contains("secret-") }, "Raw diagnostics never expose partial credentials")

        let disconnected = Harness()
        disconnected.wifiReply = nil
        disconnected.onSend = { command, payload in
            if command == 0x06 { disconnected.after(1) { disconnected.connected = false }; return true }
            return disconnected.defaultSend(command, payload)
        }
        await expectFailure(disconnected, .wifiConnectionLost)
        check(disconnected.codes == [0x05, 0x06], "Disconnect is not disguised as wrong credentials or retried on dead GATT")
        check(disconnected.logs.contains { $0.contains("bleConnected=false") }, "Connection transitions are recorded")

        let timeout = Harness()
        timeout.wifiReply = nil
        await expectFailure(timeout, .wifiResponseTimedOut)
        check(timeout.logs.contains { $0.contains("phaseElapsed=") && $0.contains("waiting") }, "Bounded wait records periodic phase/connection evidence")
        check(timeout.logs.contains { $0.contains("OTA_command_0x09_not_sent=true") }, "Failure records that firmware download never began")
        check(Session.Failure.wifiResponseTimedOut.errorDescription != Session.Failure.wifiProvisionFailed.errorDescription, "Timeout and explicit device rejection have distinct messages")
    }

    private static func testWifiConfirmationGate() async throws {
        let waiting = Harness()
        waiting.automaticallyConfirmWifi = false
        check(!waiting.session.confirmWifiProvision(), "A decision before successful provisioning is ignored")
        check(!waiting.session.cancelWifiProvision(), "An early cancel cannot poison a later confirmation")
        waiting.onSleep = {
            if waiting.session.phase == .awaitingWifiConfirmation {
                check(waiting.codes == [0x05, 0x06], "Provisioning success cannot send OTA before confirmation")
                waiting.reply(0x06, [1])
                waiting.reply(0x3A, [100])
                check(!waiting.completed, "Late provisioning or progress cannot bypass confirmation")
            }
        }
        waiting.after(45) {
            check(waiting.session.confirmWifiProvision(), "The user may confirm after the usual startup deadline")
            check(!waiting.session.confirmWifiProvision(), "Duplicate confirmation is ignored")
            check(!waiting.session.cancelWifiProvision(), "Only the first decision wins")
        }
        try await waiting.run()
        check(waiting.completed, "Confirmed provisioning continues through version verification")
        check(waiting.commands.first { $0.command == 0x09 }?.time == 45,
              "Firmware download starts only when confirmed, even after a long pause")
        check(waiting.codes.filter { $0 == 0x09 }.count == 1, "Duplicate decisions never resubmit the URL")
        check(!waiting.session.confirmWifiProvision(), "Completed sessions ignore old UI actions")

        let noProgress = Harness()
        noProgress.automaticallyConfirmWifi = false
        noProgress.automaticProgress = false
        noProgress.after(45) { _ = noProgress.session.confirmWifiProvision() }
        await expectFailure(noProgress, .startTimedOut)
        check(noProgress.clock == 75, "The full 30-second startup deadline begins after confirmation")

        let cancelled = Harness()
        cancelled.automaticallyConfirmWifi = false
        cancelled.after(1) { check(cancelled.session.cancelWifiProvision(), "User can cancel after provisioning") }
        await expectFailure(cancelled, .wifiConfirmationCancelled)
        check(cancelled.codes == [0x05, 0x06], "Cancel never sends OTA or restart")

        let disconnected = Harness()
        disconnected.automaticallyConfirmWifi = false
        disconnected.after(1) { disconnected.connected = false }
        await expectFailure(disconnected, .wifiConnectionLost)
        check(disconnected.codes == [0x05, 0x06], "A lost connection while waiting cannot authorize OTA")
        check(!disconnected.session.confirmWifiProvision(), "A failed session ignores a delayed UI confirmation")
    }

    private static func testOTADeadlinesAndRejections() async throws {
        let noProgress = Harness()
        noProgress.automaticProgress = false
        await expectFailure(noProgress, .startTimedOut)
        check(noProgress.clock == 30, "OTA without ACK or progress times out at 30 seconds")
        check(noProgress.codes == [0x05, 0x06, 0x09], "No progress must never trigger a restart")

        let ackOnly = Harness()
        ackOnly.automaticProgress = false
        ackOnly.onSend = { command, payload in
            if command == 0x09 { ackOnly.reply(command, [1]) }
            return ackOnly.defaultSend(command, payload)
        }
        await expectFailure(ackOnly, .startTimedOut)
        check(ackOnly.clock == 30, "An unsolicited success ACK cannot replace progress")

        let stalls = Harness()
        stalls.automaticProgress = false
        stalls.onSend = { command, payload in
            if command == 0x09 {
                stalls.after(29.75) { stalls.reply(0x3A, [5]) }
                stalls.after(40) { stalls.reply(0x18, [45]) }
            }
            return stalls.defaultSend(command, payload)
        }
        await expectFailure(stalls, .progressTimedOut)
        check(stalls.clock == 220, "Subsequent progress resets the full 180-second deadline")
        check(stalls.phases.contains(.upgrading(45)), "Both progress commands update the same session")
        check(!stalls.codes.contains(0x12), "Stalled progress never sends restart")

        let invalidProgress = Harness()
        invalidProgress.automaticProgress = false
        invalidProgress.onSend = { command, payload in
            if command == 0x09 {
                invalidProgress.reply(0x3A, [101])
                invalidProgress.reply(0x18, [255])
                invalidProgress.reply(0x17, [100])
                invalidProgress.reply(0x3A, [])
            }
            return invalidProgress.defaultSend(command, payload)
        }
        await expectFailure(invalidProgress, .startTimedOut)
        check(!invalidProgress.phases.contains(.upgrading(100)), "Malformed/unknown progress cannot complete an upgrade")

        for rejected: UInt8 in [0, 0xE3] {
            let h = Harness()
            h.onSend = { command, payload in
                if command == 0x09 { h.reply(command, [rejected]); return true }
                return h.defaultSend(command, payload)
            }
            await expectFailure(h, .otaRejected(rejected))
            check(!h.codes.contains(0x12), "Device rejection never triggers restart")
        }

        let sendFailure = Harness()
        sendFailure.onSend = { command, payload in
            command == 0x09 ? false : sendFailure.defaultSend(command, payload)
        }
        await expectFailure(sendFailure, .sendFailed(0x09))
        check(sendFailure.clock == 0, "OTA send failure stops immediately")
    }

    private static func testRestartAndVersionFailures() async {
        let restartFailure = Harness()
        restartFailure.onSend = { command, payload in
            command == 0x12 ? false : restartFailure.defaultSend(command, payload)
        }
        await expectFailure(restartFailure, .sendFailed(0x12))
        check(!restartFailure.codes.contains(0x15), "Failed restart cannot enter version verification")

        let mismatch = Harness()
        mismatch.finalVersion = "1.2.2"
        await expectFailure(mismatch, .versionNotConfirmed("1.2.2"))
        check(mismatch.clock == 94, "A readable old version does not count as upgrade success")

        let disconnected = Harness()
        disconnected.automaticProgress = false
        disconnected.onSend = { command, payload in
            if command == 0x09 {
                disconnected.after(1) {
                    disconnected.reply(0x18, [100])
                    disconnected.connected = false
                }
            }
            return disconnected.defaultSend(command, payload)
        }
        await expectFailure(disconnected, .reconnectTimedOut)
        check(disconnected.reconnectCount > 0, "Lost GATT is actively reconnected before restart")
        check(disconnected.clock == 31, "Pre-restart reconnect has a 30-second deadline")
        check(!disconnected.codes.contains(0x12), "Restart is not sent over disconnected GATT")
    }

    private static func testReconnectAndMonotonicProgress() async throws {
        let h = Harness()
        h.automaticProgress = false
        h.onSend = { command, payload in
            if command == 0x09 {
                h.after(0.25) { h.connected = false }
                h.after(0.5) { h.reply(0x3A, [60]) }
                h.after(0.75) { h.reply(0x18, [30]) }
                h.after(1) { h.reply(0x18, [100]) }
            }
            if command == 0x12 { h.connected = false }
            return h.defaultSend(command, payload)
        }
        h.onReconnect = { h.connected = true }
        try await h.run()
        check(h.completed, "A brief download disconnect and reboot disconnect can both recover")
        check(h.reconnectCount == 2, "GATT is reconnected during OTA and after restart")
        check(h.codes == [0x05, 0x06, 0x09, 0x12, 0x15], "Reconnect does not duplicate provisioning or restart")
        check(h.phases.contains(.upgrading(60)) && !h.phases.contains(.upgrading(30)), "Regressive progress cannot move the UI backward")
        check(h.commands.last?.time == 4.25, "Version is read only after the reboot delay and GATT recovery")
    }

    private static func testPhaseIsolation() async throws {
        let lateWifi = Harness()
        lateWifi.wifiReply = nil
        lateWifi.onSend = { command, payload in
            if command == 0x05 {
                lateWifi.reply(0x06, [1])
                lateWifi.reply(0x3A, [100])
            }
            if command == 0x06 {
                lateWifi.reply(0x3A, [100])
                lateWifi.reply(0x18, [100])
                lateWifi.session.receive(command: 0x15, payload: Data("1.2.3".utf8))
            }
            return lateWifi.defaultSend(command, payload)
        }
        await expectFailure(lateWifi, .wifiResponseTimedOut)
        check(!lateWifi.codes.contains(0x09), "Out-of-phase Wi-Fi/progress/version replies cannot skip provisioning")

        let oldRejection = Harness()
        oldRejection.onSend = { command, payload in
            if command == 0x06 {
                oldRejection.reply(0x09, [0xE3])
                oldRejection.reply(0x18, [100])
            }
            return oldRejection.defaultSend(command, payload)
        }
        try await oldRejection.run()
        check(oldRejection.completed, "An earlier-phase OTA rejection must not poison a new upgrade")
        check(oldRejection.commands.first { $0.command == 0x12 }?.time == 1, "Earlier-phase 100% cannot cause an immediate restart")
    }

    private static func testOwnershipAndCancellation() async {
        for error in [OwnershipError.accountChanged, .deviceChanged] {
            let before = Harness()
            before.ownershipError = error
            do {
                try await before.run()
                preconditionFailure("Changed ownership accepted")
            } catch is OwnershipError {
                check(before.codes.isEmpty, "Account/device identity is checked before the first command")
            } catch { preconditionFailure("Unexpected error: \(error)") }
        }

        for phase: Session.Phase in [.checkingBattery, .provisioningWifi(1), .awaitingWifiConfirmation, .upgrading(0), .restarting, .verifyingVersion] {
            let h = Harness()
            if phase == .awaitingWifiConfirmation { h.automaticallyConfirmWifi = false }
            if phase == .checkingBattery { h.batteryReply = nil }
            if phase == .provisioningWifi(1) { h.wifiReply = nil }
            if phase == .verifyingVersion { h.finalVersion = nil }
            var countAtInvalidation: Int?
            h.onSleep = {
                if h.session.phase == phase, countAtInvalidation == nil {
                    countAtInvalidation = h.commands.count
                    h.ownershipError = OwnershipError.deviceChanged
                }
            }
            do {
                try await h.run()
                preconditionFailure("Ownership change during \(phase) accepted")
            } catch is OwnershipError {
                check(countAtInvalidation != nil, "Ownership change was exercised during \(phase)")
                check(h.commands.count == countAtInvalidation, "Ownership change prevents every subsequent command")
                check(!h.completed, "Ownership changes can never produce success")
            } catch { preconditionFailure("Unexpected error: \(error)") }
        }

        let cancelledBefore = Harness()
        let beforeTask = Task { try await cancelledBefore.run() }
        beforeTask.cancel()
        do {
            try await beforeTask.value
            preconditionFailure("Cancelled task proceeded")
        } catch is CancellationError {
            check(cancelledBefore.codes.isEmpty, "Pre-cancelled session sends no commands")
        } catch { preconditionFailure("Unexpected error: \(error)") }

        for phase: Session.Phase in [.provisioningWifi(1), .awaitingWifiConfirmation, .upgrading(0), .verifyingVersion] {
            let h = Harness()
            if phase == .awaitingWifiConfirmation { h.automaticallyConfirmWifi = false }
            if phase == .provisioningWifi(1) { h.wifiReply = nil }
            if phase == .verifyingVersion { h.finalVersion = nil }
            let task = Task { try await h.run() }
            var commandCount: Int?
            h.onSleep = {
                if h.session.phase == phase {
                    commandCount = h.commands.count
                    task.cancel()
                }
            }
            do {
                try await task.value
                preconditionFailure("Cancellation during \(phase) accepted")
            } catch is CancellationError {
                check(commandCount != nil, "Cancellation occurred during \(phase)")
                check(h.commands.count == commandCount, "Cancellation stops every subsequent command")
                check(!h.completed, "Cancelled session cannot report success")
            } catch { preconditionFailure("Unexpected error: \(error)") }
        }
    }

    static func main() async throws {
        try await testHappyPathAndFreshVersion()
        try await testBatteryGate()
        try await testWifiRetryAndDiagnostics()
        await testWifiFailureEvidence()
        try await testWifiConfirmationGate()
        try await testOTADeadlinesAndRejections()
        await testRestartAndVersionFailures()
        try await testReconnectAndMonotonicProgress()
        try await testPhaseIsolation()
        await testOwnershipAndCancellation()
        print("Gen1 firmware session: \(assertions) assertions passed")
    }
}
