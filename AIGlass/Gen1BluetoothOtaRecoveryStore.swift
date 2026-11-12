import Foundation

/// Device-scoped recovery evidence. Never infer an interrupted flash from a failed
/// version read alone, or reuse another device's firmware package.
struct Gen1BluetoothOtaRecoveryStore {
    struct Record: Codable, Equatable {
        let targetID: UUID
        let version: String
        let downloadURL: String
        let content: String
        var accountID: String? = nil
        var otaPeripheralID: UUID? = nil
        var otaMAC: String? = nil
        var firmwareSHA256: String? = nil

        func permitsLoaderRecovery(savedID: UUID?, accountID: String?) -> Bool {
            targetID == savedID && self.accountID?.isEmpty == false && self.accountID == accountID
                && firmwareSHA256?.count == 64
                && (otaPeripheralID != nil || otaMAC?.isEmpty == false)
        }
    }

    private let defaults: UserDefaults
    private let key = "Gen1BluetoothOtaRecovery.v1"

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func record(for targetID: UUID) -> Record? {
        guard let data = defaults.dictionary(forKey: key)?[targetID.uuidString] as? Data,
              let record = try? JSONDecoder().decode(Record.self, from: data),
              record.targetID == targetID else { return nil }
        return record
    }

    func markImageSubmitted(_ record: Record) {
        guard let data = try? JSONEncoder().encode(record) else { return }
        var records = defaults.dictionary(forKey: key) ?? [:]
        records[record.targetID.uuidString] = data
        defaults.set(records, forKey: key)
    }

    /// The caller must supply a fresh normal-service reply from this bound device.
    /// SDK success, transfer percentage and a reboot never authorize clearance.
    @discardableResult
    func clearAfterVersionConfirmation(targetID: UUID, actualVersion: String, accountID: String? = nil) -> Bool {
        guard let record = record(for: targetID),
              record.accountID == nil || (record.accountID?.isEmpty == false && record.accountID == accountID),
              Gen1FirmwareUpdateProtocol.versionsMatch(actualVersion, target: record.version) else { return false }
        var records = defaults.dictionary(forKey: key) ?? [:]
        records.removeValue(forKey: targetID.uuidString)
        defaults.set(records, forKey: key)
        return true
    }
}
