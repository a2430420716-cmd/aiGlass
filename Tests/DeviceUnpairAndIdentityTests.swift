import Foundation

@main
enum DeviceUnpairAndIdentityTests {
    private static var assertions = 0

    private static func check(_ value: @autoclosure () -> Bool, _ message: String) {
        precondition(value(), message)
        assertions += 1
    }

    static func main() {
        let target = UUID()
        let other = UUID()
        var reset = FactoryResetConfirmation(targetID: target, deadline: 30)
        check(reset.outcome(now: 0) == .waiting, "Sending a command does not confirm data erasure")
        check(!reset.receive(1, from: other, now: 1), "Another glasses' success cannot authorize unbinding")
        check(!reset.receive(1, from: nil, now: 1), "A response without current target identity is rejected")
        check(reset.receive(2, from: target, now: 2), "Progress from the target is accepted")
        check(reset.outcome(now: 2) == .waiting, "Progress is not success")
        check(reset.receive(1, from: target, now: 3), "Explicit success completes reset")
        check(reset.outcome(now: 31) == .succeeded, "Confirmed success survives subsequent disconnect or polling delay")
        check(!reset.receive(0, from: target, now: 4), "Late duplicate response cannot undo terminal success")

        var expired = FactoryResetConfirmation(targetID: target, deadline: 30)
        check(expired.receive(2, from: target, now: 29), "Progress can arrive before deadline")
        check(expired.outcome(now: 30) == .timedOut, "Progress does not extend the deadline")
        check(!expired.receive(1, from: target, now: 30), "Success at or after deadline is rejected")
        check(expired.outcome(now: 60) == .timedOut, "Late success cannot reopen expired authorization")

        for result in [UInt8(0), 3, 255] {
            var failed = FactoryResetConfirmation(targetID: target, deadline: 30)
            check(failed.receive(result, from: target, now: 1), "Failure response is recorded")
            check(failed.outcome(now: 1) == .failed, "Failure and unknown results must not authorize unbinding")
            check(!failed.receive(1, from: target, now: 2), "Failure is terminal for this request")
        }

        let mac = "CC:27:15:44:62:EB"
        check(DeviceIdentityPresentation.hardwareSN(candidates: [nil, "", "  ", target.uuidString, mac], bluetoothID: target.uuidString) == nil, "UUID/MAC/empty values cannot be displayed as hardware SN")
        check(DeviceIdentityPresentation.hardwareSN(candidates: ["G5T712604R00269"], bluetoothID: target.uuidString) == "G5T712604R00269", "A genuine hardware serial is displayed")
        check(DeviceIdentityPresentation.hardwareSN(candidates: [target.uuidString, " G5T712604R00269 "], bluetoothID: target.uuidString) == "G5T712604R00269", "Invalid live identity falls back to genuine cached hardware SN")
        check(DeviceIdentityPresentation.hardwareSN(candidates: ["cc-27-15-44-62-eb"], bluetoothID: nil) == nil, "Hyphenated MAC is not hardware SN")
        check(DeviceIdentityPresentation.hardwareSN(candidates: ["same-id", "real-sn"], bluetoothID: "SAME-ID") == "real-sn", "The binding identifier is rejected case-insensitively")

        let bound = ["glasses-A", "glasses-B"]
        check(HomeDeviceSelection.keyOnReturn(selected: "glasses-A", connected: "glasses-B", bound: bound) == "glasses-B",
              "Returning home selects connected B instead of stale disconnected A")
        check(HomeDeviceSelection.keyOnReturn(selected: "glasses-B", connected: nil, bound: bound) == "glasses-B",
              "Without a live connection, preserve the user's selected reconnection target")
        check(HomeDeviceSelection.keyOnReturn(selected: nil, connected: "GLASSES-b", bound: Array(bound.reversed())) == "glasses-B",
              "A recreated home and reordered server list retain the live device case-insensitively")
        check(HomeDeviceSelection.keyOnReturn(selected: "glasses-A", connected: "unbound", bound: bound) == "glasses-A",
              "An unbound peripheral cannot select a home card")
        check(HomeDeviceSelection.keyOnReturn(selected: "removed", connected: nil, bound: bound) == "glasses-A",
              "Removing a selected device falls back to a remaining binding")
        check(HomeDeviceSelection.keyOnReturn(selected: "glasses-A", connected: "glasses-A", bound: []) == nil,
              "Empty bindings cannot preserve an old account's device selection")

        check(!HomeDeviceSelection.canManageConnection(homeIsVisible: true, pairingInProgress: true, hasPresentedPage: false),
              "BLE ready during pairing must not switch back to a previously bound device")
        check(!HomeDeviceSelection.canManageConnection(homeIsVisible: true, pairingInProgress: false, hasPresentedPage: true),
              "A home container behind a settings or translation page must not select a connection")
        check(!HomeDeviceSelection.canManageConnection(homeIsVisible: false, pairingInProgress: false, hasPresentedPage: false),
              "Another tab must not reconnect the home card")
        check(HomeDeviceSelection.canManageConnection(homeIsVisible: true, pairingInProgress: false, hasPresentedPage: false),
              "Returning to the home root resumes selection of the current bound device")

        var carousel = HomeCarouselSelection()
        carousel.synchronize(to: 1)
        check(carousel.receiveVisibleIndex(0) == nil && carousel.index == 1,
              "An initial layout callback for A cannot replace connected B")
        carousel.beginUserScroll()
        check(carousel.receiveVisibleIndex(0) == 0 && carousel.index == 0,
              "A real swipe to A still changes the reconnection target")
        check(carousel.receiveVisibleIndex(nil) == nil,
              "Transient missing scroll positions do not select another device")
        carousel.synchronize(to: 1)
        check(carousel.receiveVisibleIndex(0) == nil && carousel.index == 1,
              "Returning from another page resets the old drag session and retains connected B")
        carousel.synchronize(to: 2)
        check(carousel.receiveVisibleIndex(0) == nil && carousel.index == 2,
              "Server list reordering cannot reset an explicit selected device to the first card")
        print("Device reset/identity: \(assertions) assertions passed")
    }
}
