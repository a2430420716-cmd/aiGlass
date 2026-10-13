@main
enum DeviceVersionQueryGateTests {
    private static var assertions = 0

    private static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        assertions += 1
        precondition(condition(), message)
    }

    static func main() {
        pendingRequestsAreDeduplicated()
        failedQueriesDoNotAutomaticallyRestart()
        newSessionsAllowOneNewAttempt()
        explicitQueriesReplaceDelayedAutomaticWork()
        cancellationPreservesConsumedAttempts()
        cancelledUnsentQueriesCanBeRescheduled()
        print("Device version query gate: \(assertions) assertions passed")
    }

    private static func pendingRequestsAreDeduplicated() {
        var gate = DeviceVersionQueryGate()
        let token = gate.reserveAutomaticQuery()!
        check(gate.reserveAutomaticQuery() == nil,
              "Repeated battery or ready updates must not queue duplicate version queries")
        check(gate.claimAutomaticQuery(token), "The reserved automatic query can start")
        check(!gate.claimAutomaticQuery(token), "A delayed callback cannot start the same query twice")
    }

    private static func failedQueriesDoNotAutomaticallyRestart() {
        var gate = DeviceVersionQueryGate()
        let token = gate.reserveAutomaticQuery()!
        check(gate.claimAutomaticQuery(token), "The automatic query starts before waiting for replies")
        check(gate.reserveAutomaticQuery() == nil,
              "An absent or truncated version reply must not start another automatic query")
        gate.cancelPendingQuery()
        check(gate.reserveAutomaticQuery() == nil,
              "Completing a failed query cannot restore the automatic attempt")
    }

    private static func newSessionsAllowOneNewAttempt() {
        var gate = DeviceVersionQueryGate()
        let completed = gate.reserveAutomaticQuery()!
        check(gate.claimAutomaticQuery(completed), "The first connection consumes its attempt")
        gate.reset()
        let previousSession = gate.reserveAutomaticQuery()!
        check(previousSession != completed, "Reconnecting the same device creates a new token")
        gate.reset()
        let currentSession = gate.reserveAutomaticQuery()!
        check(currentSession != previousSession, "Reset must never reuse a pending token")
        check(!gate.claimAutomaticQuery(previousSession),
              "An old connection's delayed callback cannot claim the new session's query")
        gate.cancelPendingQuery(previousSession)
        check(gate.reserveAutomaticQuery() == nil,
              "An old connection's cancellation must leave the new reservation intact")
        check(gate.claimAutomaticQuery(currentSession),
              "The new connection still gets its automatic version attempt")
        check(!gate.claimAutomaticQuery(completed), "A completed old token remains invalid after reset")
        check(gate.reserveAutomaticQuery() == nil, "Each new connection still has only one attempt")
    }

    private static func explicitQueriesReplaceDelayedAutomaticWork() {
        var gate = DeviceVersionQueryGate()
        let delayed = gate.reserveAutomaticQuery()!
        gate.beginExplicitQuery()
        check(!gate.claimAutomaticQuery(delayed), "Explicit refresh cancels the delayed automatic query")
        check(gate.reserveAutomaticQuery() == nil,
              "A failed explicit refresh must not trigger an automatic query loop")
        gate.beginExplicitQuery()
        gate.beginExplicitQuery()
        check(gate.reserveAutomaticQuery() == nil,
              "Repeated explicit refreshes remain allowed without replenishing automatic attempts")
        gate.reset()
        check(gate.reserveAutomaticQuery() != nil, "Reconnecting restores automatic refresh after explicit work")
    }

    private static func cancellationPreservesConsumedAttempts() {
        var gate = DeviceVersionQueryGate()
        let used = gate.reserveAutomaticQuery()!
        check(gate.claimAutomaticQuery(used), "The version query starts before OTA takes ownership")
        gate.cancelPendingQuery()
        gate.cancelPendingQuery(used)
        check(gate.reserveAutomaticQuery() == nil,
              "Cancelling pending work for OTA cannot return an already consumed attempt")
        gate.beginExplicitQuery()
        gate.cancelPendingQuery()
        check(gate.reserveAutomaticQuery() == nil,
              "Cancelling OTA after an explicit query cannot restart background queries")
    }

    private static func cancelledUnsentQueriesCanBeRescheduled() {
        var gate = DeviceVersionQueryGate()
        let cancelled = gate.reserveAutomaticQuery()!
        gate.cancelPendingQuery(cancelled)
        let replacement = gate.reserveAutomaticQuery()!
        check(replacement != cancelled, "Cancelling unsent work allows a fresh reservation")
        check(!gate.claimAutomaticQuery(cancelled), "Cancelled work cannot send after rescheduling")
        gate.cancelPendingQuery(cancelled)
        check(gate.reserveAutomaticQuery() == nil,
              "A stale cancellation cannot remove the replacement reservation")
        gate.cancelPendingQuery()
        let latest = gate.reserveAutomaticQuery()!
        check(latest != replacement, "Unconditional cancellation also preserves an unused attempt")
        check(!gate.claimAutomaticQuery(replacement), "Unconditionally cancelled work stays invalid")
        check(gate.claimAutomaticQuery(latest), "The replacement can still consume the one attempt")
    }
}
