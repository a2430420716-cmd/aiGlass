import Foundation

@main
enum GATTRecoveryTests {
    private static var assertionCount = 0

    private static func check(
        _ condition: @autoclosure () -> Bool,
        _ message: String,
        file: StaticString = #file,
        line: UInt = #line
    ) {
        precondition(condition(), message, file: file, line: line)
        assertionCount += 1
    }

    static func main() {
        testSlowDiscoveryDoesNotConsumeNotificationBudget()
        testStaleWatchdogsCannotTerminateCurrentConnection()
        testRetryNeedsFailureAndConsumesAuthorization()
        testPollingDoesNotPostponeRetry()
        testRetryBackoffAndReset()
        testBoundReconnectScanAndFailureCooldowns()
        testBoundReconnectStopsAfterThreeRetries()
        print("GATT recovery: \(assertionCount) assertions passed")
    }

    private static func testBoundReconnectScanAndFailureCooldowns() {
        var policy = BoundBLEReconnectPolicy()
        check(policy.canRetry(now: 0), "A bound device can reconnect without waiting for system BLE evidence")
        check(policy.claimScan(now: 0), "Missing peripheral cache permits the first identity scan")
        for second in 1..<30 {
            check(!policy.claimScan(now: TimeInterval(second)), "Repeated home refreshes must not start another scan or move its deadline")
            check(policy.canRetry(now: TimeInterval(second)), "Scan cooldown must not block a subsequently retrieved cached peripheral")
        }
        check(policy.claimScan(now: 30), "A missing device can be scanned again after the cooldown")
        policy.noteConnectionFailure(now: 35)
        for second in 36..<65 {
            check(!policy.canRetry(now: TimeInterval(second)), "Actual connection failure waits 30 seconds")
            check(!policy.claimScan(now: TimeInterval(second)), "Scan fallback must not bypass connection failure cooldown")
        }
        check(policy.canRetry(now: 65), "Polling does not postpone the next connection attempt")
        check(policy.claimScan(now: 65), "Scan can resume when both deadlines have passed")
        policy.noteConnectionFailure(now: 66)
        policy.reset()
        check(policy.canRetry(now: 66), "Successful GATT setup clears the failure deadline")
        check(policy.claimScan(now: 66), "Successful GATT setup also clears old scan throttling")
    }

    private static func testBoundReconnectStopsAfterThreeRetries() {
        var policy = BoundBLEReconnectPolicy()
        check(policy.canRetry(now: 0), "Initial connection is allowed")
        for retry in 1...2 {
            let failedAt = TimeInterval((retry - 1) * 30)
            policy.noteConnectionFailure(now: failedAt)
            check(!policy.isExhausted, "Failure before retry \(retry) must leave that retry available")
            check(!policy.canRetry(now: failedAt + 29), "Each retry still respects cooldown")
            check(policy.canRetry(now: failedAt + 30), "Automatic retry \(retry) is allowed")
        }
        policy.noteConnectionFailure(now: 60)
        check(policy.isExhausted, "Failure of the third total attempt stops this cycle")
        check(policy.failedAttempts == 3, "Budget is three total automatic attempts")
        for second in 120...300 {
            check(!policy.canRetry(now: TimeInterval(second)), "Polling or foreground refresh must not reopen exhausted retries")
            check(!policy.claimScan(now: TimeInterval(second)), "Scanning cannot bypass exhausted retries")
        }
        policy.noteConnectionFailure(now: 400)
        check(policy.failedAttempts == 3, "Extra callbacks cannot grow or reset exhausted counter")
        check(!policy.resumeOnSystemConnection(targetMatches: false), "Another device's event cannot reopen retries")
        check(policy.isExhausted, "Unrelated Bluetooth events retain the stopped state")
        check(policy.resumeOnSystemConnection(targetMatches: true), "A new bound-target system event reopens retries")
        check(!policy.resumeOnSystemConnection(targetMatches: true), "Repeated events during an active cycle cannot reset failures")
        policy.noteConnectionFailure(now: 401)
        check(!policy.resumeOnSystemConnection(targetMatches: true), "A system event cannot erase failures within an active cycle")
        check(policy.failedAttempts == 1, "Active-cycle failure budget is preserved")
        policy.reset()
        check(policy.failedAttempts == 0 && !policy.isExhausted, "Success or explicit manual retry starts a new cycle")
        check(policy.canRetry(now: 400), "New cycle can connect immediately")
    }

    private static func testSlowDiscoveryDoesNotConsumeNotificationBudget() {
        let peripheralID = UUID()
        var policy = GATTWatchdogPolicy()
        check(policy.active == nil, "No watchdog exists before a connection starts")
        let connecting = policy.arm(peripheralID: peripheralID, phase: .connecting, now: 0, timeout: 15)
        let discovering = policy.arm(peripheralID: peripheralID, phase: .discoveringServices, now: 0, timeout: 15)
        // The reported failure: discovery finished at 13 seconds, but notifications
        // were failed at 15 seconds by a timer armed for the previous phase.
        let notifications = policy.arm(peripheralID: peripheralID, phase: .enablingNotifications, now: 13, timeout: 15)
        check(notifications.deadline == 28, "Notifications receive their own full 15-second budget")
        check(!policy.accepts(connecting, peripheralID: peripheralID, phase: .enablingNotifications, now: 15), "Old connect timer must not fail notification setup")
        check(!policy.accepts(discovering, peripheralID: peripheralID, phase: .enablingNotifications, now: 15), "Old discovery timer must not fail notification setup")
        check(!policy.accepts(discovering, peripheralID: peripheralID, phase: .discoveringServices, now: 15), "Even an old callback's captured phase cannot make its timer current")
        check(!policy.accepts(notifications, peripheralID: peripheralID, phase: .enablingNotifications, now: 15), "Notification setup remains live after two seconds")
        check(!policy.accepts(notifications, peripheralID: peripheralID, phase: .enablingNotifications, now: 27.999), "Current watchdog cannot fire early")
        check(policy.accepts(notifications, peripheralID: peripheralID, phase: .enablingNotifications, now: 28), "Current watchdog fires at its own deadline")
        check(policy.accepts(notifications, peripheralID: peripheralID, phase: .enablingNotifications, now: 29), "Delayed current watchdog still expires")
        policy.cancel()
        check(!policy.accepts(notifications, peripheralID: peripheralID, phase: .enablingNotifications, now: 29), "Successful setup cancels the watchdog")
    }

    private static func testStaleWatchdogsCannotTerminateCurrentConnection() {
        let firstID = UUID()
        let secondID = UUID()
        var policy = GATTWatchdogPolicy()
        let first = policy.arm(peripheralID: firstID, phase: .connecting, now: 10, timeout: 15)
        let replacement = policy.arm(peripheralID: firstID, phase: .connecting, now: 10, timeout: 15)
        check(first != replacement, "Rearming an identical phase and deadline creates a fresh token")
        check(!policy.accepts(first, peripheralID: firstID, phase: .connecting, now: 25), "Replaced timer cannot terminate the same phase")
        check(policy.accepts(replacement, peripheralID: firstID, phase: .connecting, now: 25), "Replacement timer remains valid")
        check(!policy.accepts(replacement, peripheralID: secondID, phase: .connecting, now: 25), "Timer requires current peripheral identity")
        check(!policy.accepts(replacement, peripheralID: firstID, phase: .discoveringServices, now: 25), "Timer requires current phase")
        let second = policy.arm(peripheralID: secondID, phase: .connecting, now: 20, timeout: 15)
        check(!policy.accepts(replacement, peripheralID: firstID, phase: .connecting, now: 40), "Switching devices invalidates the previous timer")
        check(policy.active == second, "Active watchdog belongs to the new device")
        check(policy.accepts(second, peripheralID: secondID, phase: .connecting, now: 35), "New device has a working watchdog")
        policy.cancel()
        check(policy.active == nil, "Cancel clears active watchdog")
        check(!policy.accepts(second, peripheralID: secondID, phase: .connecting, now: 100), "Cancelled timer cannot affect a disconnected device")
        let restarted = policy.arm(peripheralID: secondID, phase: .connecting, now: 20, timeout: 15)
        check(restarted != second, "Cancel and restart cannot reuse an old token")
        check(!policy.accepts(second, peripheralID: secondID, phase: .connecting, now: 100), "Old timer stays invalid after restart")
        check(policy.accepts(restarted, peripheralID: secondID, phase: .connecting, now: 100), "Restarted timer can expire normally")
    }

    private static func testRetryNeedsFailureAndConsumesAuthorization() {
        var gate = GATTRecoveryRetryGate()
        check(gate.attempts == 0, "A new recovery gate has no retry attempts")
        check(!gate.claimRetry(now: 1_000_000), "Time passing alone cannot authorize a retry")
        gate.noteFailure(now: 100)
        check(gate.attempts == 0, "Recording the first failure does not count as a retry")
        check(!gate.claimRetry(now: 129.999), "First retry waits 30 seconds")
        check(gate.claimRetry(now: 130), "Failure permits a retry at the cooldown deadline")
        check(gate.attempts == 1, "Only a successful claim increments retry attempts")
        check(!gate.claimRetry(now: 130), "Concurrent foreground checks cannot claim the same retry twice")
        check(!gate.claimRetry(now: 1_000_000), "A consumed retry needs a new failure before another attempt")
        check(gate.attempts == 1, "Rejected retry claims do not affect backoff")
    }

    private static func testPollingDoesNotPostponeRetry() {
        var gate = GATTRecoveryRetryGate()
        gate.noteFailure(now: 0)
        for second in 1..<30 {
            gate.noteFailure(now: TimeInterval(second))
            check(!gate.claimRetry(now: TimeInterval(second)), "Polling before the cooldown ends must not claim a retry")
        }
        check(gate.claimRetry(now: 30), "Repeated failure observations do not push the deadline forward")
        gate.noteFailure(now: 40)
        gate.noteFailure(now: 99)
        check(!gate.claimRetry(now: 99), "Second failure uses a 60-second cooldown")
        check(gate.claimRetry(now: 100), "Repeated observations preserve the second cooldown deadline")
    }

    private static func testRetryBackoffAndReset() {
        var gate = GATTRecoveryRetryGate()
        var now: TimeInterval = 100
        for (index, cooldown) in [30.0, 60, 120, 240, 300, 300, 300].enumerated() {
            gate.noteFailure(now: now)
            check(gate.attempts == index, "Failures preserve the number of actual attempts")
            check(!gate.claimRetry(now: now + cooldown - 0.001), "Backoff cannot end early")
            check(gate.claimRetry(now: now + cooldown), "Backoff follows 30/60/120/240/300 seconds and caps at 300")
            check(gate.attempts == index + 1, "Every authorized retry counts once")
            now += cooldown + 10
        }
        gate.noteFailure(now: now)
        gate.reset()
        check(gate.attempts == 0, "Successful connection or explicit reset clears attempt history")
        check(!gate.claimRetry(now: now + 1_000), "Reset revokes any pending retry authorization")
        gate.noteFailure(now: now + 1_000)
        check(!gate.claimRetry(now: now + 1_029), "Next failure after reset begins with a 30-second cooldown")
        check(gate.claimRetry(now: now + 1_030), "Reset does not retain the old 300-second backoff")
        check(gate.attempts == 1, "Attempt numbering restarts after reset")
        gate.reset()
        check(!gate.claimRetry(now: now + 2_000), "Reset after a consumed retry also requires a new failure")
    }
}
