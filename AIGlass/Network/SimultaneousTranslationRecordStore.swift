import Foundation

struct SimultaneousTranslationRecord: Codable, Identifiable, Equatable, Hashable {
    let id: String
    let title: String
    let sourceLanguage: String
    let targetLanguage: String
    let sourceText: String
    let targetText: String
    let createdAt: TimeInterval
    let durationMs: Int64
}

enum SimultaneousTranslationRecordStore {
    private static let prefsKeyPrefix = "simultaneous_translation_records_"
    private static let glassesSoundKey = "simultaneous_glasses_sound"

    private static func userKey() -> String {
        let defaults = UserDefaults.standard
        if let phone = defaults.string(forKey: "auth.phoneNumber"), !phone.isEmpty {
            return phone
        }
        return "guest"
    }

    private static var recordsKey: String {
        prefsKeyPrefix + userKey()
    }

    static func getAll() -> [SimultaneousTranslationRecord] {
        guard let data = UserDefaults.standard.data(forKey: recordsKey) else { return [] }
        return (try? JSONDecoder().decode([SimultaneousTranslationRecord].self, from: data))?
            .sorted { $0.createdAt > $1.createdAt } ?? []
    }

    static func getById(_ id: String) -> SimultaneousTranslationRecord? {
        getAll().first { $0.id == id }
    }

    @discardableResult
    static func save(
        sourceLanguage: String,
        targetLanguage: String,
        sourceText: String,
        targetText: String,
        durationMs: Int64
    ) -> SimultaneousTranslationRecord {
        let now = Date().timeIntervalSince1970
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMddHHmmss"
        let stamp = formatter.string(from: Date(timeIntervalSince1970: now))
        let record = SimultaneousTranslationRecord(
            id: UUID().uuidString,
            title: "同声传译记录\(stamp)",
            sourceLanguage: sourceLanguage,
            targetLanguage: targetLanguage,
            sourceText: sourceText,
            targetText: targetText,
            createdAt: now,
            durationMs: max(0, durationMs)
        )
        var records = getAll()
        records.insert(record, at: 0)
        persist(records)
        return record
    }

    static func delete(ids: Set<String>) {
        guard !ids.isEmpty else { return }
        persist(getAll().filter { !ids.contains($0.id) })
    }

    static var glassesSoundEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: glassesSoundKey) }
        set { UserDefaults.standard.set(newValue, forKey: glassesSoundKey) }
    }

    private static func persist(_ records: [SimultaneousTranslationRecord]) {
        guard let data = try? JSONEncoder().encode(records) else { return }
        UserDefaults.standard.set(data, forKey: recordsKey)
    }
}
