import Foundation

/// Device-scoped recovery evidence. Never infer an interrupted flash from a failed
/// version read alone, or reuse another device's firmware package.
struct Gen1BluetoothOtaRecoveryStore {
    struct Record: Codable, Equatable {
        let targetID: UUID
        let version: String
        let downloadURL: String
        let content: String
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

    /// Called only for a terminal SDK success/reboot result, never for 100% alone.
    func clearAfterSuccess(targetID: UUID) {
        var records = defaults.dictionary(forKey: key) ?? [:]
        records.removeValue(forKey: targetID.uuidString)
        defaults.set(records, forKey: key)
    }
}
