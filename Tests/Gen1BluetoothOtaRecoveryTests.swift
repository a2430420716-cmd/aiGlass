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
        precondition(!reopened.clearAfterVersionConfirmation(targetID: targetB, actualVersion: ""))
        precondition(!reopened.clearAfterVersionConfirmation(targetID: targetB, actualVersion: recordA.version))
        precondition(reopened.record(for: targetB) == recordB)
        precondition(reopened.clearAfterVersionConfirmation(targetID: targetB, actualVersion: "V3.26.1.15"))
        precondition(store.record(for: targetA) == recordA)
        precondition(store.record(for: targetB) == nil)
        var loaderRecord = recordA
        loaderRecord.accountID = "account-a"
        loaderRecord.otaMAC = "cc731542f757"
        loaderRecord.otaPeripheralID = UUID()
        loaderRecord.firmwareSHA256 = String(repeating: "a", count: 64)
        store.markImageSubmitted(loaderRecord)
        precondition(reopened.record(for: targetA) == loaderRecord)
        precondition(loaderRecord.permitsLoaderRecovery(savedID: targetA, accountID: "account-a"))
        precondition(!loaderRecord.permitsLoaderRecovery(savedID: targetB, accountID: "account-a"))
        precondition(!loaderRecord.permitsLoaderRecovery(savedID: targetA, accountID: "account-b"))
        precondition(!loaderRecord.permitsLoaderRecovery(savedID: targetA, accountID: nil))
        precondition(!recordA.permitsLoaderRecovery(savedID: targetA, accountID: "account-a"))
        let oldJSON = """
        {"targetID":"\(targetB.uuidString)","version":"old","downloadURL":"https://example.com/old.ufw","content":""}
        """
        let oldRecord = try! JSONDecoder().decode(Gen1BluetoothOtaRecoveryStore.Record.self, from: Data(oldJSON.utf8))
        precondition(oldRecord.otaMAC == nil && oldRecord.accountID == nil)
        // SDK completion/reopening cannot clear evidence; only a matching fresh
        // normal-service version from the owning account can authorize it.
        precondition(!store.clearAfterVersionConfirmation(targetID: UUID(), actualVersion: loaderRecord.version, accountID: "account-a"))
        precondition(!store.clearAfterVersionConfirmation(targetID: targetA, actualVersion: loaderRecord.version, accountID: "account-b"))
        precondition(!store.clearAfterVersionConfirmation(targetID: targetA, actualVersion: loaderRecord.version))
        precondition(!store.clearAfterVersionConfirmation(targetID: targetA, actualVersion: "03.26.01.13", accountID: "account-a"))
        precondition(!store.clearAfterVersionConfirmation(targetID: targetA, actualVersion: " ", accountID: "account-a"))
        precondition(reopened.record(for: targetA) == loaderRecord)
        precondition(store.clearAfterVersionConfirmation(targetID: targetA, actualVersion: loaderRecord.version, accountID: "account-a"))
        precondition(reopened.record(for: targetA) == nil)
        print("Gen1 Bluetooth OTA recovery persistence tests passed")
    }
}
