import Foundation

enum L10n {
    static func t(_ chinese: String, _ english: String) -> String { chinese }
}

@main
enum HomeVideoCaptureTests {
    static var assertions = 0

    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        precondition(condition(), message)
        assertions += 1
    }

    static func response(_ payload: [UInt8]) -> AstraA1BleProtocol.DeviceActionResponse? {
        AstraA1BleProtocol.parseActionResponse(
            AstraA1BleProtocol.buildPacket(command: "actionrsp0", payload: Data(payload))
        )
    }

    static func main() {
        // Actual October 9 firmware reply: STOP_VIDEO / undocumented result 6 / recording.
        let rejected = response([3, 6, 2])!
        check(rejected.action == .stopVideo, "preserve action for undocumented rejection")
        check(rejected.rawResult == 6 && rejected.result == .failed, "unknown result is a rejection, not a dropped packet")
        check(rejected.currentStatus == .videoRecording, "rejected stop still carries device recording state")
        for code: UInt8 in [0, 1, 2, 3, 4, 5, 6, 255] {
            let value = response([3, code, 2])!
            check(value.rawResult == code, "preserve raw result \(code)")
            check((value.result == .accepted) == (code == 0), "only zero is accepted")
        }
        check(response([3, 6]) == nil, "truncated response rejected")
        check(response([255, 0, 0]) == nil, "unknown action not misclassified")

        var state = HomeVideoCaptureState()
        state.startSent(at: 100)
        check(state.stopDelayRemaining(at: 101.486) > 1.5, "logged early stop is blocked")
        check(!state.receive(.videoRecording, at: 101.132), "start ACK is not completion")
        check(!state.receive(.videoRecording, at: 102.5), "duplicate recording report is not completion")
        check(state.stopDelayRemaining(at: 103) == 0, "repeated reports do not restart minimum duration")
        state.stopSent()
        check(!state.receive(.videoRecording, at: 103.1) && state.isStopPending,
              "recording report keeps pending stop locked")
        state.stopRejectedOrUnconfirmed()
        check(!state.receive(rejected.currentStatus, at: 103.2, allowsCompletion: false),
              "logged rejection never marks recording done")
        check(!state.isStopPending && state.hasConfirmedRecording, "rejected stop allows retry while recording")
        state.stopSent()
        check(!state.receive(.videoRecording, at: 108), "accepted stop with recording status still waits")
        check(state.receive(.standby, at: 108.1), "standby confirms successful retry")
        check(!state.receive(.standby, at: 108.2), "duplicate standby does not repeat success")

        state.startSent(at: 200)
        _ = state.receive(.videoRecording, at: 201)
        state.stopSent()
        state.stopRejectedOrUnconfirmed()
        check(state.hasConfirmedRecording && !state.isStopPending, "timeout unlocks retry without success")
        check(!state.receive(.videoRecording, at: 207), "still-recording query cannot trigger success")
        check(state.receive(.standby, at: 210), "late standby after timeout confirms actual completion")

        state.startSent(at: 300)
        state.stopSent()
        check(!state.receive(.standby, at: 304, allowsCompletion: false), "rejected stop plus idle is not reported as success")
        check(!state.receive(.standby, at: 305), "rejected idle clears stale operation")
        state.startSent(at: 400)
        check(!state.receive(.standby, at: 400.1), "start write without recording confirmation is not a completed video")
        check(!state.receive(.videoRecording, at: 500), "hardware recording starts tracked session")
        check(state.stopDelayRemaining(at: 501) == 2, "hardware recording also has minimum duration")
        state.stopSent()
        state.reset()
        check(!state.isStopPending && !state.hasConfirmedRecording && state.startedAt == nil,
              "disconnect reset cancels prior recording state")
        check(!state.receive(.standby, at: 510), "new connection does not finish old recording")
        print("Home video capture: \(assertions) assertions passed")
    }
}
