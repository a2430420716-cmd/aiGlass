import Foundation

@main
enum Gen1BluetoothOtaSessionStateTests {
    typealias Session = Gen1BluetoothOtaSessionState

    static func main() {
        testTwoTransfers()
        testLateCallbacks()
        testRecoveryMode()
        testLoaderConnectionRecovery()
        testReconnectDeadlineAndStaleCallbacks()
        print("Gen1 Bluetooth OTA stage tests passed")
    }

    private static func testTwoTransfers() {
        var session = Session()
        precondition(!session.receiveSuccess(), "No image has been submitted")
        precondition(!session.requestReconnect(), "No upgrade to resume")
        precondition(session.imageCommandAfterFeature() == .start)
        precondition(session.imageCommandAfterFeature() == nil, "Duplicate features must not resubmit the image")

        session.receiveLoaderProgress(100)
        precondition(session.phase == .transferringLoader(100))
        precondition(!session.receiveSuccess(), "Loader completion cannot finish the update")
        precondition(!session.canVerifyAfterReboot, "Loader reboot cannot start final version verification")
        precondition(session.phase.overallProgress == 35)

        precondition(session.requestReconnect())
        precondition(session.phase == .reconnecting)
        precondition(!session.requestReconnect(), "Duplicate reconnect results must not restart the wait")
        session.receiveLoaderProgress(100)
        session.receiveFirmwareProgress(100)
        precondition(session.phase == .reconnecting, "Old connection callbacks cannot skip reconnect")
        precondition(!session.receiveSuccess(), "Pending reconnect is not terminal success")

        precondition(session.imageCommandAfterFeature() == .resume, "Reconnect must use the second-stage entry")
        precondition(session.imageCommandAfterFeature() == nil)
        session.receiveFirmwareProgress(70)
        precondition(session.phase == .transferringFirmware(70))
        precondition(!session.canVerifyAfterReboot)
        session.receiveFirmwareProgress(100)
        precondition(session.phase == .awaitingResult, "Second transfer still waits for a final device result")
        precondition(session.phase.overallProgress == 94)
        precondition(session.canVerifyAfterReboot, "A full second transfer can be verified after reboot")
        precondition(session.receiveSuccess())
        precondition(session.phase == .completed)
        precondition(session.phase.overallProgress == 95, "Fresh version verification is still required")
        precondition(!session.receiveSuccess(), "Final success is consumed once")
        precondition(!session.requestReconnect())
        precondition(session.imageCommandAfterFeature() == nil)
    }

    private static func testLateCallbacks() {
        var session = Session()
        session.receiveLoaderProgress(100)
        session.receiveFirmwareProgress(100)
        precondition(session.phase == .transferringLoader(0), "Ignore progress before image submission")
        _ = session.imageCommandAfterFeature()
        session.receiveLoaderProgress(-1)
        precondition(session.phase == .transferringLoader(0))
        session.receiveLoaderProgress(75)
        session.receiveLoaderProgress(10)
        precondition(session.phase == .transferringLoader(75), "Loader progress cannot regress")
        session.receiveLoaderProgress(105)
        precondition(session.phase == .transferringLoader(100))
        _ = session.requestReconnect()
        _ = session.imageCommandAfterFeature()
        session.receiveFirmwareProgress(80)
        session.receiveLoaderProgress(100)
        session.receiveFirmwareProgress(5)
        precondition(session.phase == .transferringFirmware(80), "Late loader and lower firmware values cannot regress stage 2")
        session.receiveFirmwareProgress(110)
        session.receiveFirmwareProgress(0)
        precondition(session.phase == .awaitingResult)
        _ = session.receiveSuccess()
        session.receiveFirmwareProgress(40)
        session.receiveLoaderProgress(40)
        precondition(session.phase == .completed, "Late callbacks cannot reactivate a completed update")
    }

    private static func testRecoveryMode() {
        var session = Session()
        precondition(session.imageCommandAfterFeature() == .start)
        session.receiveFirmwareProgress(5)
        precondition(session.phase == .transferringFirmware(5), "A device already in its loader can enter stage 2 directly")
        precondition(!session.canVerifyAfterReboot)
        // SDK terminal success is authoritative even if its last percentage was omitted.
        precondition(session.receiveSuccess())
    }

    private static func testLoaderConnectionRecovery() {
        let loader = UUID(uuidString: "17974F32-A276-E8BD-FC27-DBD206CD0955")!
        var session = Session()
        var reconnect = Gen1BluetoothOtaReconnectPolicy()
        precondition(reconnect.claim(peripheralID: loader, isConnectable: true, now: 0) == nil)
        precondition(session.imageCommandAfterFeature() == .start)
        session.receiveLoaderProgress(100)
        precondition(session.requestReconnect())
        reconnect.begin(now: 0)
        precondition(reconnect.deadline == 90)
        precondition(reconnect.claim(peripheralID: loader, isConnectable: false, now: 1) == nil,
                     "Nonconnectable advertising must not stop scanning or consume a connection attempt")
        precondition(reconnect.attempts == 0)

        // Both failed Nov 4 sessions discovered this loader about 2.5 seconds
        // after reboot, then waited the entire 90 seconds without didConnect.
        let first = reconnect.claim(peripheralID: loader, isConnectable: true, now: 2.5)!
        precondition(first.deadline == 27.5)
        precondition(reconnect.claim(peripheralID: loader, isConnectable: true, now: 3) == nil,
                     "Duplicate advertisements must not create parallel native connects")
        precondition(!reconnect.expire(first, now: 27.49))
        precondition(reconnect.expire(first, now: 27.5),
                     "A stalled loader connection must release before a fresh scan and retry")
        let second = reconnect.claim(peripheralID: loader, isConnectable: true, now: 29)!
        precondition(second.deadline == 54 && reconnect.deadline == 90,
                     "Retry gets its own attempt budget without extending the total wait")
        // The successful Nov 4 loader connection took 11.175 seconds.
        precondition(!reconnect.expire(second, now: 40.175))
        reconnect.stop()
        precondition(!reconnect.expire(second, now: 54), "Connection success invalidates its old timeout")
        precondition(session.imageCommandAfterFeature() == .resume,
                     "Retry continues the retained firmware; it must not push the loader again")
        session.receiveFirmwareProgress(100)
        precondition(session.receiveSuccess())
    }

    private static func testReconnectDeadlineAndStaleCallbacks() {
        let loader = UUID()
        var reconnect = Gen1BluetoothOtaReconnectPolicy()
        reconnect.begin(now: 100)
        let first = reconnect.claim(peripheralID: loader, isConnectable: true, now: 102)!
        reconnect.cancelAttempt() // didFailToConnect / disconnect releases this attempt.
        let second = reconnect.claim(peripheralID: loader, isConnectable: true, now: 104)!
        precondition(!reconnect.expire(first, now: 150), "Old timers cannot cancel a replacement attempt")
        precondition(reconnect.expire(second, now: 129))
        let third = reconnect.claim(peripheralID: loader, isConnectable: true, now: 131)!
        precondition(reconnect.expire(third, now: 156))
        precondition(!reconnect.canAttempt(now: 158), "At most three native connections per loader reconnect")
        precondition(reconnect.deadline == 190, "Failures and duplicate callbacks cannot reset the total deadline")

        reconnect.begin(now: 200)
        let late = reconnect.claim(peripheralID: loader, isConnectable: true, now: 285)!
        precondition(late.deadline == 290, "A late discovery cannot extend the 90-second total budget")
        precondition(reconnect.expire(late, now: 290))
        precondition(!reconnect.canAttempt(now: 291))
        reconnect.begin(now: 300)
        precondition(!reconnect.expire(late, now: 400), "A previous reconnect cycle cannot stop the current cycle")
        reconnect.stop() // Cancellation, terminal result or target change.
        precondition(reconnect.claim(peripheralID: UUID(), isConnectable: true, now: 301) == nil)
    }
}
