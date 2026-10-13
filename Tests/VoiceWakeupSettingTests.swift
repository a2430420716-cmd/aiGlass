// xcrun swiftc -module-cache-path /tmp/aiglass-voice-wakeup-cache \
//   AIGlass/VoiceWakeupSettingState.swift Tests/VoiceWakeupSettingTests.swift \
//   -o /tmp/aiglass-voice-wakeup-tests && /tmp/aiglass-voice-wakeup-tests
@main
enum VoiceWakeupSettingTests {
    private static var assertions = 0

    private static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        assertions += 1
        precondition(condition(), message)
    }

    static func main() {
        var state = VoiceWakeupSettingState()
        check(state.enabled == nil, "No reply must not be displayed as disabled")
        check(!state.canChange, "Unknown state cannot send a set command")
        check(state.beginSet(true) == nil, "No speculative enable before reading the device")

        let query = state.beginQuery()!
        check(state.phase == .querying, "Query shows loading")
        check(state.beginSet(true) == nil, "Query and set must not overlap")
        check(state.receive(status: 0, enabled: true) == .none, "Query does not show set-success alert")
        check(state.enabled == true && state.canChange, "Device already enabled is shown enabled")
        check(!state.queryTimedOut(generation: query), "A replied query's timeout is stale")
        check(state.beginSet(true) == nil, "Same-value setting is not sent again")

        let write = state.beginSet(false)!
        check(state.isSetting && !state.canChange, "One setting write at a time")
        check(state.beginSet(false) == nil, "Double tap cannot duplicate a write")
        check(state.beginQuery() == nil, "Scheduled query cannot race a setting response")
        check(state.receive(status: 0, enabled: false) == .updated, "Android success status is zero")
        check(state.enabled == false && state.canChange, "Device reply owns the toggle value")
        check(!state.setTimedOut(generation: write), "Completed write cancels its timeout")

        for status: UInt8 in [1, 2, 3, 4, 255] {
            _ = state.beginSet(true)
            check(state.receive(status: status, enabled: false) == .failed(status: status),
                  "Preserve Android's generic/storage/internal/resource error statuses")
            check(state.enabled == false && state.canChange, "Failed set restores reported state")
        }
        _ = state.beginSet(true)
        check(state.receive(status: 1, enabled: true) == .failed(status: 1),
              "Do not reinterpret an error as already-enabled success")
        check(state.enabled == true, "Error reply still includes authoritative device state")

        let missingACK = state.beginSet(false)!
        check(state.setTimedOut(generation: missingACK), "Missing ACK finishes pending write")
        check(!state.isSetting && !state.canChange, "Wait for readback before another set")
        let readback = state.beginQuery()!
        check(state.receive(status: 0, enabled: false) == .none, "Timeout readback is a query, not set success")
        check(state.enabled == false, "Lost ACK does not lose actual device value")
        check(!state.queryTimedOut(generation: readback), "Readback clears timeout")

        let failedWrite = state.beginSet(true)!
        check(state.sendFailed(generation: failedWrite), "Failed transport enqueue finishes the attempt")
        check(state.enabled == false && state.canChange, "Failed enqueue retains previous state")
        check(!state.sendFailed(generation: failedWrite), "Duplicate callback cannot fail a new request")

        let failedQuery = state.beginQuery()!
        check(state.queryTimedOut(generation: failedQuery), "Missing query response becomes retryable failure")
        check(state.phase == .queryFailed && state.enabled == nil, "Query failure must not imply off")
        check(state.beginSet(true) == nil, "No blind set after a lost query response")
        _ = state.beginQuery()
        check(state.receive(status: 0, enabled: true) == .none, "Manual query retry can recover")
        check(state.enabled == true && state.canChange, "Retry restores real device value")

        let oldWrite = state.beginSet(false)!
        state.reset()
        check(state.enabled == nil && state.target == nil, "Disconnect/device change clears prior state")
        check(!state.setTimedOut(generation: oldWrite), "Old-device timeout cannot alter new session")
        check(!state.sendFailed(generation: oldWrite), "Old-device retry cannot report a failure")
        let oldQuery = state.beginQuery()!
        state.reset()
        _ = state.beginQuery()
        check(!state.queryTimedOut(generation: oldQuery), "View exit or reconnect cancels old query timeout")
        check(state.phase == .querying, "Stale timeout leaves current query pending")

        check(state.receive(status: 2, enabled: true) == .none, "Like Android, query status is not a set alert")
        check(state.enabled == true, "Valid query enabled byte always supplies device state")
        print("Voice wake-up settings: \(assertions) assertions passed")
    }
}
