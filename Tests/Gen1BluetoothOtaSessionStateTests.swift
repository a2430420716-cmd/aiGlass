@main
enum Gen1BluetoothOtaSessionStateTests {
    typealias Session = Gen1BluetoothOtaSessionState

    static func main() {
        testTwoTransfers()
        testLateCallbacks()
        testRecoveryMode()
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
}
