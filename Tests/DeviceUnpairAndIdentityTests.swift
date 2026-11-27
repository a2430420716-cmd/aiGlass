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

        let suite = "aiglass.unpair.tests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let recovery = DeviceUnpairRecovery(accountID: 1, serialNumber: target.uuidString,
                                            hardwareSN: "SN-A", resetConfirmed: true, forceAllowed: false)
        DeviceUnpairRecoveryStore.save(recovery, defaults: defaults)
        check(DeviceUnpairRecoveryStore.pending(accountID: 1, serialNumber: target.uuidString.lowercased(), defaults: defaults) == recovery,
              "Acknowledged reset survives re-reading by account and case-insensitive UUID")
        check(DeviceUnpairRecoveryStore.pending(accountID: 2, serialNumber: target.uuidString, defaults: defaults) == nil,
              "Another account cannot reuse reset confirmation")
        check(DeviceUnpairRecoveryStore.blocksReconnect(accountID: 1, serialNumber: target.uuidString, defaults: defaults),
              "An uncertain cloud unbind blocks old binding reconnect")
        check(!DeviceUnpairRecoveryStore.blocksReconnect(accountID: 1, serialNumber: other.uuidString, defaults: defaults),
              "Other glasses are not blocked")
        check(!DeviceUnpairRecoveryStore.blocksReconnect(accountID: 2, serialNumber: target.uuidString, defaults: defaults),
              "Another loaded account is not blocked")
        check(DeviceUnpairRecoveryStore.blocksReconnect(accountID: nil, serialNumber: target.uuidString, defaults: defaults),
              "Known pending UUID waits until account identity is loaded")
        let present: [String: Any] = ["id": 1, "device": [["serial_number": target.uuidString, "sn": "SN-A"]]]
        let absent: [String: Any] = ["id": 1, "device": [[String: Any]]()]
        check(DeviceUnpairRecovery.bindingPresence(in: present, accountID: 1, serialNumber: target.uuidString, hardwareSN: "SN-A") == true,
              "A fresh bound snapshot requires completing cloud unbind")
        check(DeviceUnpairRecovery.bindingPresence(in: absent, accountID: 1, serialNumber: target.uuidString, hardwareSN: "SN-A") == false,
              "A complete empty snapshot proves absence without repeat POST or reset")
        check(DeviceUnpairRecovery.bindingPresence(in: present, accountID: 2, serialNumber: target.uuidString, hardwareSN: "SN-A") == nil,
              "Wrong account cannot prove unbind success")
        check(DeviceUnpairRecovery.bindingPresence(in: ["id": 1], accountID: 1, serialNumber: target.uuidString, hardwareSN: "SN-A") == nil,
              "Missing device list is not proof of removal")
        check(DeviceUnpairRecovery.bindingPresence(in: ["id": 1, "device": [[String: Any]()] ], accountID: 1,
              serialNumber: target.uuidString, hardwareSN: "SN-A") == nil,
              "Malformed rows cannot turn uncertain unbind into success")
        DeviceUnpairRecoveryStore.remove(accountID: 2, serialNumber: target.uuidString, defaults: defaults)
        check(DeviceUnpairRecoveryStore.pending(accountID: 1, serialNumber: target.uuidString, defaults: defaults) != nil,
              "Cleanup for another account cannot discard recovery")
        DeviceUnpairRecoveryStore.remove(accountID: 1, serialNumber: target.uuidString, defaults: defaults)
        check(!DeviceUnpairRecoveryStore.blocksReconnect(accountID: 1, serialNumber: target.uuidString, defaults: defaults),
              "Confirmed cleanup releases only the affected target")

        let forcedRecovery = DeviceUnpairRecovery(accountID: 1, serialNumber: other.uuidString,
                                                  hardwareSN: "", resetConfirmed: false, forceAllowed: true)
        DeviceUnpairRecoveryStore.save(forcedRecovery, defaults: defaults)
        check(DeviceUnpairRecoveryStore.pending(accountID: 1, serialNumber: other.uuidString, defaults: defaults)?.forceAllowed == true,
              "User-confirmed offline server-only removal retains that exact target's consent")
        check(DeviceUnpairRecoveryStore.pending(accountID: 1, serialNumber: other.uuidString, defaults: defaults)?.resetConfirmed == false,
              "Offline force removal never pretends device data was erased")
        check(DeviceUnpairRecovery.bindingPresence(in: ["id": 1, "device": [["serial_number": other.uuidString, "sn": "SN-A"]]],
              accountID: 1, serialNumber: target.uuidString, hardwareSN: "SN-A") == true,
              "A matching physical SN prevents falsely confirming cloud removal")
        check(DeviceUnpairRecovery.bindingPresence(in: ["id": 1, "device": [["serial_number": other.uuidString, "sn": "SN-B"]]],
              accountID: 1, serialNumber: target.uuidString, hardwareSN: "SN-A") == false,
              "A valid different device is not confused with the target")
        DeviceUnpairRecoveryStore.remove(accountID: 1, serialNumber: target.uuidString, defaults: defaults)
        check(DeviceUnpairRecoveryStore.pending(accountID: 1, serialNumber: other.uuidString, defaults: defaults) != nil,
              "Confirmed cleanup for one target preserves another pending operation")

        let regional = DeviceUnpairRecovery(accountID: 1, serialNumber: target.uuidString,
                       hardwareSN: "SN-A", resetConfirmed: true, forceAllowed: false, backendOrigin: "region-A")
        DeviceUnpairRecoveryStore.save(regional, defaults: defaults)
        check(DeviceUnpairRecoveryStore.pending(accountID: 1, serialNumber: target.uuidString,
              backendOrigin: "region-B", defaults: defaults) == nil,
              "Equal numeric IDs on different backends are separate accounts")
        check(!DeviceUnpairRecoveryStore.blocksReconnect(accountID: 1, serialNumber: target.uuidString,
              backendOrigin: "region-B", defaults: defaults), "Another region does not inherit reconnect suppression")
        DeviceUnpairRecoveryStore.remove(accountID: 1, serialNumber: target.uuidString, backendOrigin: "region-B", defaults: defaults)
        check(DeviceUnpairRecoveryStore.pending(accountID: 1, serialNumber: target.uuidString,
              backendOrigin: "region-A", defaults: defaults) == regional, "Another region cannot clear recovery")

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

        let cardOrder = bound + ["glasses-C", "find-device"]
        let offlineOrder = HomeDeviceSelection.connectedFirst(cardOrder) { _ in false }
        check(offlineOrder == cardOrder,
              "All disconnected glasses retain their original order and the find-device card stays last")
        let connectedOrder = HomeDeviceSelection.connectedFirst(cardOrder) { $0 == "glasses-B" }
        check(connectedOrder == ["glasses-B", "glasses-A", "glasses-C", "find-device"],
              "Connecting B promotes it to page one while preserving every other card's relative order")
        check(cardOrder == ["glasses-A", "glasses-B", "glasses-C", "find-device"],
              "Live sorting must not mutate the underlying bound-device order")
        check(HomeDeviceSelection.connectedFirst(connectedOrder) { $0 == "glasses-B" } == connectedOrder,
              "Repeated BLE updates leave the connected-first order unchanged")
        check(HomeDeviceSelection.connectedFirst(cardOrder) { $0 == "unbound" } == cardOrder,
              "An unbound peripheral cannot reorder the home cards")
        check(HomeDeviceSelection.connectedFirst([String]()) { _ in true }.isEmpty,
              "Empty bindings have no connected card to promote")
        let selectedKey = HomeDeviceSelection.keyOnReturn(selected: "glasses-B", connected: "glasses-B", bound: bound)
        check(connectedOrder.firstIndex(where: { $0 == selectedKey }) == 0,
              "The selected B keeps its identity and moves to page one after connection")
        check(offlineOrder.firstIndex(where: { $0 == selectedKey }) == 1,
              "After disconnect, B stays selected when the original order returns")

        check(HomeDeviceSelection.visibleIndex(browsedKey: nil, connectionIndex: 1, cardKeys: cardOrder) == 1,
              "Opening home without browsing still shows the current connection target")
        check(HomeDeviceSelection.visibleIndex(browsedKey: "glasses-C", connectionIndex: 0, cardKeys: cardOrder) == 2,
              "Browsing the last glasses card does not jump to the connected first card")
        check(HomeDeviceSelection.visibleIndex(browsedKey: "find-device", connectionIndex: 0, cardKeys: cardOrder) == 3,
              "The page after the last glasses is the add-device card")
        check(HomeDeviceSelection.visibleIndex(browsedKey: "find-device", connectionIndex: 0, cardKeys: connectedOrder) == 3,
              "A late connection reorder cannot pull the add-device page back to the first card")
        check(HomeDeviceSelection.visibleIndex(browsedKey: "find-device", connectionIndex: 0,
                                               cardKeys: ["glasses-A", "glasses-B", "glasses-C", "glasses-D", "find-device"]) == 4,
              "A refreshed list with another binding keeps the add-device card visible at its new index")
        check(HomeDeviceSelection.visibleIndex(browsedKey: "find-device", connectionIndex: 0,
                                               cardKeys: ["glasses-A", "find-device"]) == 1,
              "Removing a binding preserves the add-device page by identity")
        check(HomeDeviceSelection.visibleIndex(browsedKey: "find-device", connectionIndex: 2,
                                               cardKeys: ["find-device"]) == 0,
              "With no bindings, only the add-device page remains")
        check(HomeDeviceSelection.visibleIndex(browsedKey: "GLASSES-b", connectionIndex: 0, cardKeys: connectedOrder) == 0,
              "A browsed device follows its identity when promoted to the first card")
        check(HomeDeviceSelection.visibleIndex(browsedKey: "removed", connectionIndex: 1, cardKeys: cardOrder) == 1,
              "Removing the browsed device falls back to a valid connection page")
        check(HomeDeviceSelection.visibleIndex(browsedKey: nil, connectionIndex: -1, cardKeys: cardOrder) == 0,
              "An invalid connection index falls back safely")
        check(HomeDeviceSelection.visibleIndex(browsedKey: nil, connectionIndex: 0, cardKeys: []) == 0,
              "An empty intermediate list has a safe initial position")

        var carousel = HomeCarouselSelection()
        carousel.synchronize(to: 1, cardOrder: cardOrder)
        check(carousel.receiveVisibleIndex(0, cardOrder: cardOrder) == nil && carousel.index == 1,
              "An initial layout callback for A cannot replace connected B")
        carousel.beginUserScroll()
        check(carousel.receiveVisibleIndex(0, cardOrder: cardOrder) == 0 && carousel.index == 0,
              "A real swipe to A changes the visible page")
        check(carousel.receiveVisibleIndex(nil, cardOrder: cardOrder) == nil,
              "Transient missing scroll positions do not select another device")
        carousel.synchronize(to: 1, cardOrder: cardOrder)
        check(carousel.receiveVisibleIndex(0, cardOrder: cardOrder) == nil && carousel.index == 1,
              "Returning from another page resets the old drag session and retains connected B")
        carousel.synchronize(to: 2, cardOrder: cardOrder)
        check(carousel.receiveVisibleIndex(0, cardOrder: cardOrder) == nil && carousel.index == 2,
              "Server list reordering cannot reset an explicit selected device to the first card")

        carousel.synchronize(to: 1, cardOrder: cardOrder)
        carousel.beginUserScroll()
        check(carousel.receiveVisibleIndex(1, cardOrder: connectedOrder) == nil,
              "Promoting connected B rejects old scroll positions before the reorder observer runs")
        carousel.synchronize(to: 0, cardOrder: connectedOrder)
        check(carousel.receiveVisibleIndex(1, cardOrder: connectedOrder) == nil && carousel.index == 0,
              "A reorder layout callback must not switch from connected B to disconnected A")
        carousel.beginUserScroll()
        check(carousel.receiveVisibleIndex(1, cardOrder: connectedOrder) == 1,
              "After reordering, an explicit swipe can still select A")
        check(carousel.receiveVisibleIndex(-1, cardOrder: connectedOrder) == nil
              && carousel.receiveVisibleIndex(connectedOrder.count, cardOrder: connectedOrder) == nil,
              "Out-of-range layout callbacks cannot change the device selection")
        check(carousel.receiveVisibleIndex(1, cardOrder: offlineOrder) == nil,
              "Disconnecting B also rejects callbacks when the original card order returns")

        carousel.synchronize(to: 2, cardOrder: cardOrder)
        carousel.beginUserScroll()
        check(carousel.receiveVisibleIndex(3, cardOrder: cardOrder) == 3 && carousel.index == 3,
              "Swiping past the last glasses reaches the add-device page")
        check(carousel.receiveVisibleIndex(4, cardOrder: cardOrder) == nil && carousel.index == 3,
              "Scrolling beyond the add-device page cannot wrap around to the first device")
        check(carousel.receiveVisibleIndex(nil, cardOrder: cardOrder) == nil && carousel.index == 3,
              "A transient missing position keeps the add-device page selected")
        check(carousel.receiveVisibleIndex(2, cardOrder: cardOrder) == 2 && carousel.index == 2,
              "Swiping back from the add-device page shows the last glasses again")
        print("Device reset/identity: \(assertions) assertions passed")
    }
}
