import Foundation

@main
@MainActor
enum Gen2OtaWifiConnectionSessionTests {
    private enum TestError: Error { case unreachable, denied, targetChanged }
    private static let wifi = Gen2OtaWifiConnectionSession.Credential(
        ssid: "glasses", password: "password", httpAddress: "http://192.168.0.1/"
    )

    static func main() async throws {
        var initialJoins = 0
        let initial = makeSession(join: { _ in initialJoins += 1 })
        let initialResult = try await initial.connect()
        precondition(initialResult == wifi && initialJoins == 1)
        var events: [String] = [], opens = 0
        let retry = Gen2OtaWifiConnectionSession(
            validate: {}, open: {
                opens += 1; events.append("open\(opens)")
                return .init(ssid: "glasses\(opens)", password: "password", httpAddress: wifi.httpAddress)
            }, restart: { events.append("restart") },
            join: { credential in
                events.append("join:\(credential.ssid)")
                if opens == 1 { throw TestError.unreachable }
            }, verify: { _ in preconditionFailure("Automatic success must not enter manual verification") },
            canRetry: canRetry, onPhase: { _ in }
        )
        let joined = try await retry.connect()
        precondition(joined.ssid == "glasses2")
        precondition(events == ["open1", "join:glasses1", "restart", "open2", "join:glasses2"])

        var deniedJoins = 0
        let denied = makeSession(join: { _ in deniedJoins += 1; throw TestError.denied })
        do { _ = try await denied.connect(); preconditionFailure("Expected denial") }
        catch TestError.denied {}
        precondition(deniedJoins == 1)

        var checks = 0, joins = 0
        let manual = makeSession(join: { _ in joins += 1; throw TestError.unreachable },
                                 verify: { _ in checks += 1; if checks == 1 { throw TestError.unreachable } })
        let task = Task { try await manual.connect() }
        await confirmWhenReady(manual)
        while checks == 0 { await Task.yield() }
        await confirmWhenReady(manual)
        let confirmed = try await task.value
        precondition(confirmed == wifi && joins == 2 && checks == 2)
        precondition(!manual.confirmManualConnection(), "Late taps after completion must do nothing")

        let cancelled = makeSession(join: { _ in throw TestError.unreachable })
        let cancelledTask = Task { try await cancelled.connect() }
        await waitForManual(cancelled)
        cancelledTask.cancel()
        do { _ = try await cancelledTask.value; preconditionFailure("Expected cancellation") }
        catch is CancellationError {}
        precondition(cancelled.phase == .finished)

        let userCancelled = makeSession(join: { _ in throw TestError.unreachable })
        let userCancelledTask = Task { try await userCancelled.connect() }
        await waitForManual(userCancelled)
        userCancelled.cancel()
        do { _ = try await userCancelledTask.value; preconditionFailure("Expected user cancellation") }
        catch is CancellationError {}
        precondition(!userCancelled.confirmManualConnection())

        var manualTargetChanged = false
        let invalidated = Gen2OtaWifiConnectionSession(
            validate: { if manualTargetChanged { throw TestError.targetChanged } },
            open: { wifi }, restart: {}, join: { _ in throw TestError.unreachable },
            verify: { _ in preconditionFailure("An invalidated session must not verify or upload") },
            canRetry: canRetry, onPhase: { _ in }
        )
        let invalidatedTask = Task { try await invalidated.connect() }
        await waitForManual(invalidated)
        manualTargetChanged = true
        do { _ = try await invalidatedTask.value; preconditionFailure("Expected target change during manual wait") }
        catch TestError.targetChanged {}
        precondition(invalidated.phase == .finished)

        var changed = false, restarted = false
        let stale = Gen2OtaWifiConnectionSession(
            validate: { if changed { throw TestError.targetChanged } },
            open: { wifi }, restart: { restarted = true },
            join: { _ in changed = true; throw TestError.unreachable }, verify: { _ in },
            canRetry: canRetry, onPhase: { _ in }
        )
        do { _ = try await stale.connect(); preconditionFailure("Expected target change") }
        catch TestError.targetChanged {}
        precondition(!restarted)

        let expired = makeSession(timeout: 0.01, join: { _ in throw TestError.unreachable })
        do { _ = try await expired.connect(); preconditionFailure("Expected deadline") }
        catch Gen2OtaWifiConnectionSession.Failure.manualConnectionTimedOut {}
        precondition(expired.phase == .finished)
        print("Gen2 OTA Wi-Fi connection session tests passed")
    }

    private static func canRetry(_ error: Error) -> Bool {
        if case TestError.unreachable = error { return true }; return false
    }

    private static func makeSession(
        timeout: TimeInterval = 180,
        join: @escaping (Gen2OtaWifiConnectionSession.Credential) async throws -> Void,
        verify: @escaping (Gen2OtaWifiConnectionSession.Credential) async throws -> Void = { _ in }
    ) -> Gen2OtaWifiConnectionSession {
        Gen2OtaWifiConnectionSession(manualTimeout: timeout, validate: {}, open: { wifi }, restart: {},
                                    join: join, verify: verify, canRetry: canRetry, onPhase: { _ in })
    }

    private static func waitForManual(_ session: Gen2OtaWifiConnectionSession) async {
        for _ in 0..<10_000 {
            if case .awaitingManual = session.phase { await Task.yield(); return }
            await Task.yield()
        }
        preconditionFailure("Manual prompt did not appear")
    }

    private static func confirmWhenReady(_ session: Gen2OtaWifiConnectionSession) async {
        for _ in 0..<10_000 {
            if session.confirmManualConnection() { return }
            await Task.yield()
        }
        preconditionFailure("Manual prompt did not become ready")
    }
}
