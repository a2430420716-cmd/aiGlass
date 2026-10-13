import Foundation

// The production protocol and log store are compiled unchanged. Only app-wide UI
// localization and bundle metadata are supplied for this command-line test host.
enum L10n {
    static func t(_ chinese: String, _ english: String) -> String { chinese }
}

enum AppBundleInfo {
    static let shortVersion = "test"
    static let buildNumber = "test"
}

@main
enum BLERawLogStoreTests {
    @MainActor
    static func main() async {
        let store = DebugLogStore.shared
        store.clear(channel: .ble)
        let callbackTime = Date(timeIntervalSince1970: 1_700_000_000)
        DebugLogStore.logBLERawReceived(
            data: Data([0x31, 0x32]),
            peripheralID: "test-peripheral",
            characteristicID: "test-characteristic",
            context: "notify callback",
            capturedAt: callbackTime
        )
        DebugLogStore.logBLEEvent("Full notify read failed", detail: "ATT request not supported", capturedAt: callbackTime)
        DebugLogStore.logBLEReceived(AstraA1BleProtocol.buildPacket(command: "devstatus0", payload: Data([0])))
        for _ in 0..<100 {
            if store.bleEntries.count == 3 { break }
            await Task.yield()
        }
        precondition(store.bleEntries.count == 3, "Raw, lifecycle and parsed log APIs all append to BLE export")
        let raw = store.bleEntries.first { $0.title.hasPrefix("RAW") }!
        precondition(raw.date == callbackTime, "Raw timestamp is the callback capture time, not delayed Task execution time")
        precondition(raw.direction == .received && raw.detail.contains("hex=31 32"), "Short callback remains raw received evidence")
        let event = store.bleEntries.first { $0.direction == .event }!
        precondition(event.date == callbackTime && event.detail == "ATT request not supported", "Read lifecycle events retain time and error details")
        precondition(store.bleEntries.contains { $0.title.hasPrefix("devstatus0") }, "Existing parsed BLE log API stays functional")
        precondition(store.exportText(for: .ble).contains("RAW · before framing"), "Export includes explicitly labelled raw callbacks")
        print("BLE raw log store: 6 assertions passed")
    }
}
