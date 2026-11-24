import Foundation

/// Created before requesting a file: firmware may delete its copy as soon as it sends it.
/// TCP commits a validated download by renaming .partial to the final destination.
struct Gen1ImportInbox {
    struct Entry: Codable, Equatable {
        let id: UUID
        let targetID: UUID
        let fileName: String
        let accountID: String
        var processingError: String? = nil
    }

    let root: URL

    init(root: URL? = nil) {
        self.root = root ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Gen1ImportInbox", isDirectory: true)
    }

    func prepare(targetID: UUID, fileName: String, accountID: String = "") throws -> Entry {
        guard Gen1FileListParser.parseMediaFiles(Data(fileName.utf8)) == [fileName] else {
            throw Gen1APImportError.invalidFileName
        }
        let entry = Entry(id: UUID(), targetID: targetID, fileName: fileName, accountID: accountID)
        let directory = directory(for: entry)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(entry).write(to: directory.appendingPathComponent("entry.json"), options: .atomic)
        return entry
    }

    func fileURL(for entry: Entry) -> URL { directory(for: entry).appendingPathComponent(entry.fileName) }

    /// Persist failure metadata only; never replace or remove the downloaded original.
    func recordProcessingFailure(_ entry: Entry, reason: String) throws {
        var updated = entry
        updated.processingError = reason
        try JSONEncoder().encode(updated).write(
            to: directory(for: entry).appendingPathComponent("entry.json"), options: .atomic
        )
    }

    func completedEntries(for targetID: UUID, accountID: String? = nil) throws -> [Entry] {
        let target = root.appendingPathComponent(targetID.uuidString, isDirectory: true)
        guard FileManager.default.fileExists(atPath: target.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: target, includingPropertiesForKeys: nil)
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { directory in
                guard let data = try? Data(contentsOf: directory.appendingPathComponent("entry.json")),
                      let entry = try? JSONDecoder().decode(Entry.self, from: data),
                      entry.targetID == targetID, directory.lastPathComponent == entry.id.uuidString,
                      accountID == nil || entry.accountID == accountID,
                      Gen1FileListParser.parseMediaFiles(Data(entry.fileName.utf8)) == [entry.fileName],
                      let values = try? fileURL(for: entry).resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                      values.isRegularFile == true, (values.fileSize ?? 0) > 0 else { return nil }
                return entry
            }
    }

    /// Call only after MediaLibrary committed both its permanent original and manifest.
    func removeCommitted(_ entry: Entry) throws {
        try FileManager.default.removeItem(at: directory(for: entry))
    }

    private func directory(for entry: Entry) -> URL {
        root.appendingPathComponent(entry.targetID.uuidString, isDirectory: true)
            .appendingPathComponent(entry.id.uuidString, isDirectory: true)
    }
}
