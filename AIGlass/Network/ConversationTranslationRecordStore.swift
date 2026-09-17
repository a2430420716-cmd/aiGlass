import Foundation

struct ConversationTranslationHistoryMessage: Codable, Identifiable, Hashable {
    let id: UUID
    let side: String
    let sourceLanguage: String
    let targetLanguage: String
    let sourceText: String
    let translatedText: String
}

struct ConversationTranslationRecord: Codable, Identifiable, Hashable {
    let id: UUID
    var glassesLanguage: String
    var phoneLanguage: String
    var updatedAt: Date
    var messages: [ConversationTranslationHistoryMessage]
}

enum ConversationTranslationRecordStore {
    private static let storageKey = "conversation.translation.records"

    static func getAll() -> [ConversationTranslationRecord] {
        guard let data = UserDefaults.standard.data(forKey: storageKey) else { return [] }
        return (try? JSONDecoder().decode([ConversationTranslationRecord].self, from: data))?
            .sorted { $0.updatedAt > $1.updatedAt } ?? []
    }

    static func saveOrUpdate(
        id: UUID,
        glassesLanguage: String,
        phoneLanguage: String,
        messages: [ConversationTranslationHistoryMessage]
    ) {
        guard !messages.isEmpty else { return }
        var records = getAll()
        let record = ConversationTranslationRecord(
            id: id,
            glassesLanguage: glassesLanguage,
            phoneLanguage: phoneLanguage,
            updatedAt: Date(),
            messages: messages
        )
        if let index = records.firstIndex(where: { $0.id == id }) {
            records[index] = record
        } else {
            records.append(record)
        }
        persist(records)
    }

    static func delete(ids: Set<UUID>) {
        persist(getAll().filter { !ids.contains($0.id) })
    }

    private static func persist(_ records: [ConversationTranslationRecord]) {
        guard let data = try? JSONEncoder().encode(records) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }
}
