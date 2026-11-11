import Foundation

@main
enum Gen1RecordDurationSettingTests {
    static var assertions = 0
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        assertions += 1
        guard condition() else { fatalError(message) }
    }

    static func main() {
        var state = Gen1RecordDurationSettingState()
        let token = state.beginSet(seconds: 300)!
        check(state.receive(command: 0x25, payload: Data([0])) == nil,
              "SET ACK zero is not a 15-second duration")
        check(state.confirmedSeconds == nil && state.isPending, "ACK never confirms a setting")
        check(state.receive(command: 0x87, payload: Data([3])) == nil,
              "old query before verification cannot confirm new SET")
        check(state.beginVerificationQuery(token: token), "current request can read back")
        check(state.receive(command: 0x87, payload: Data([3])) == 300, "profile 3 means 300 seconds")
        check(state.result?.outcome == .confirmed(seconds: 300) && !state.isPending,
              "matching readback confirms success")
        check(!state.finish(token: token), "completed request cannot time out")

        let mismatchToken = state.beginSet(seconds: 300)!
        check(state.result == nil, "new set clears previous result")
        _ = state.beginVerificationQuery(token: mismatchToken)
        check(state.receive(command: 0x87, payload: Data([0])) == 15, "actual mismatched duration is exposed")
        check(state.isPending && state.result == nil, "mismatch waits for bounded retry, never success")
        check(state.finish(token: mismatchToken), "mismatch finishes on deadline")
        check(state.result?.outcome == .different(requested: 300, actual: 15), "report actual device value")

        let delayedToken = state.beginSet(seconds: 300)!
        _ = state.beginVerificationQuery(token: delayedToken)
        _ = state.receive(command: 0x87, payload: Data([0]))
        _ = state.beginVerificationQuery(token: delayedToken)
        _ = state.receive(command: 0x87, payload: Data([3]))
        check(state.result?.outcome == .confirmed(seconds: 300), "later matching readback can confirm")

        let missingToken = state.beginSet(seconds: 60)!
        _ = state.beginVerificationQuery(token: missingToken)
        for invalid in [Data(), Data([5]), Data([255]), Data([1, 0])] {
            check(state.receive(command: 0x87, payload: invalid) == nil, "invalid query payload ignored")
        }
        _ = state.receive(command: 0x25, payload: Data([1]))
        check(state.finish(token: missingToken), "silence/invalid replies have bounded wait")
        check(state.result?.outcome == .unconfirmed(seconds: 60), "old confirmed value is not a new mismatch")

        let superseded = state.beginSet(seconds: 15)!
        let replacement = state.beginSet(seconds: 180)!
        check(!state.beginVerificationQuery(token: superseded) && !state.finish(token: superseded),
              "superseded timer cannot query or finish replacement")
        check(!state.beginVerificationQuery(token: replacement - 1), "stale token rejected")
        state.reset()
        check(!state.isPending && state.result == nil && state.confirmedSeconds == nil, "reset clears connection values")
        check(!state.beginVerificationQuery(token: replacement) && !state.finish(token: replacement),
              "old connection timers are invalidated")
        check(state.beginSet(seconds: 30) == nil && !state.isPending, "unsupported duration rejected")
        check(state.receive(command: 0x25, payload: Data([0])) == nil, "unsolicited SET ACK ignored")
        check(state.receive(command: 0x87, payload: Data([4])) == 600, "ordinary query still synchronizes settings")
        check(state.result == nil, "ordinary query cannot generate a SET success")

        let sameValue = state.beginSet(seconds: 600)!
        _ = state.beginVerificationQuery(token: sameValue)
        _ = state.receive(command: 0x87, payload: Data([4]))
        let previousResult = state.result
        let repeated = state.beginSet(seconds: 600)!
        _ = state.beginVerificationQuery(token: repeated)
        _ = state.receive(command: 0x87, payload: Data([4]))
        check(state.result != previousResult, "repeated same-value success publishes a new token")
        print("Gen1 record duration: \(assertions) assertions passed")
    }
}
