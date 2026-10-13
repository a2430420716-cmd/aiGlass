import Foundation

@main
enum PairingAttemptStateTests {
    private static var assertions = 0

    private static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        assertions += 1
        precondition(condition(), message)
    }

    static func main() {
        let firstDevice = UUID()
        let secondDevice = UUID()
        var state = PairingAttemptState()
        check(state.phase == .idle, "Opening the model list does not begin a pairing attempt")
        check(!state.isCurrent(state.generation), "Idle state cannot authorize a bind")

        let timedOut = state.begin(peripheralID: firstDevice)
        check(state.phase == .waitingForIdentity, "Selecting a device starts the identity wait")
        check(!state.beginBinding(token: timedOut, peripheralID: secondDevice),
              "Another device's cached identity cannot bind the selected device")
        check(state.phase == .waitingForIdentity, "An unrelated reply leaves the deadline active")
        check(state.expireIdentityWait(token: timedOut), "Missing SN ends the wait")
        check(state.phase == .idle && state.peripheralID == nil, "Expiry clears the selected device")
        check(!state.beginBinding(token: timedOut, peripheralID: firstDevice),
              "A late SN after timeout must never bind automatically")
        check(!state.expireIdentityWait(token: timedOut), "A repeated timeout cannot show a second failure")

        let connecting = state.begin(peripheralID: firstDevice)
        check(state.beginBinding(token: connecting, peripheralID: firstDevice),
              "Complete identity from the selected device starts server binding")
        check(state.phase == .binding && state.isCurrent(connecting), "Binding retains its session token")
        check(!state.expireIdentityWait(token: connecting), "Identity deadline cannot interrupt a server bind")
        check(!state.beginBinding(token: connecting, peripheralID: firstDevice),
              "Duplicate ready callbacks cannot submit two binds")
        state.cancel()
        check(!state.isCurrent(connecting), "Finishing or cancelling invalidates delayed server UI callbacks")

        let previous = state.begin(peripheralID: firstDevice)
        let retry = state.begin(peripheralID: firstDevice)
        check(previous != retry, "Retrying the same physical device still creates a new attempt")
        check(!state.expireIdentityWait(token: previous), "Previous attempt's deadline cannot cancel retry")
        check(!state.beginBinding(token: previous, peripheralID: firstDevice),
              "A queued ready task from the old attempt cannot bind during retry")
        check(state.isCurrent(retry) && state.phase == .waitingForIdentity,
              "Stale callbacks preserve the new waiting state")

        let switched = state.begin(peripheralID: secondDevice)
        check(!state.expireIdentityWait(token: retry), "Switching devices cancels the prior deadline")
        check(!state.beginBinding(token: switched, peripheralID: firstDevice),
              "A previous device's complete identity cannot satisfy the new attempt")
        check(state.beginBinding(token: switched, peripheralID: secondDevice), "The new device can bind normally")

        // Cancellation invalidates both the pending timeout and a queued identity callback.
        state.cancel()
        let cancelled = state.begin(peripheralID: firstDevice)
        state.cancel()
        check(!state.expireIdentityWait(token: cancelled), "Cancelled attempt cannot time out later")
        check(!state.beginBinding(token: cancelled, peripheralID: firstDevice),
              "Cancelled attempt cannot bind from a late notification")
        let afterLogout = state.begin(peripheralID: secondDevice)
        check(state.beginBinding(token: afterLogout, peripheralID: secondDevice), "New account starts independently")
        check(!state.isCurrent(switched), "An old account's async server reply cannot update the new flow")
        check(!state.expireIdentityWait(token: cancelled), "Old timeout cannot invalidate an active bind")
        check(state.phase == .binding && state.isCurrent(afterLogout), "New account's active binding survives")

        print("Pairing attempt state: \(assertions) assertions passed")
    }
}
