import Foundation

@main
enum Gen1BluetoothOtaRecoveryTests {
    static func main() {
        let suite = "Gen1BluetoothOtaRecoveryTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let targetA = UUID(), targetB = UUID()
        let recordA = Gen1BluetoothOtaRecoveryStore.Record(
            targetID: targetA, version: "03.26.01.14", downloadURL: "https://example.com/a.bin", content: "A"
        )
        let recordB = Gen1BluetoothOtaRecoveryStore.Record(
            targetID: targetB, version: "03.26.01.15", downloadURL: "https://example.com/b.bin", content: "B"
        )
        let store = Gen1BluetoothOtaRecoveryStore(defaults: defaults)
        precondition(store.record(for: targetA) == nil)
        store.markImageSubmitted(recordA)
        // A newly-created store must see interrupted image evidence, without any
        // version reply, and must not offer it for another bound device.
        let reopened = Gen1BluetoothOtaRecoveryStore(defaults: UserDefaults(suiteName: suite)!)
        precondition(reopened.record(for: targetA) == recordA)
        precondition(reopened.record(for: targetB) == nil)
        reopened.markImageSubmitted(recordB)
        reopened.clearAfterSuccess(targetID: targetB)
        precondition(store.record(for: targetA) == recordA)
        precondition(store.record(for: targetB) == nil)
        store.clearAfterSuccess(targetID: targetA)
        precondition(reopened.record(for: targetA) == nil)
        print("Gen1 Bluetooth OTA recovery persistence tests passed")
    }
}
