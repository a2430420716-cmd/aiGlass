import CryptoKit
import Foundation

/// Durable, immutable originals for Gen1 imports. Inbox paths are unique per download
/// and remain stable across retries; neither processing nor album deletion removes this archive.
nonisolated struct Gen1MediaStaging: Sendable {
    struct Receipt: Codable, Equatable, Sendable {
        let id: UUID
        let sourcePath: String
        let originalFileName: String
        let archivedFileName: String
        let createdAt: Date
        let byteCount: UInt64
        let sha256: String
    }

    enum Failure: LocalizedError {
        case invalidFileName
        case invalidSource
        case sourceChanged
        case damagedArchive

        var errorDescription: String? {
            switch self {
            case .invalidFileName: return "Invalid Gen1 media filename."
            case .invalidSource: return "The completed Gen1 original is missing or empty."
            case .sourceChanged: return "The Gen1 import source changed. Keep its original inbox path and retry."
            case .damagedArchive: return "The preserved Gen1 original could not be verified."
            }
        }
    }

    let rootURL: URL

    func preserve(fileURL: URL, fileName: String) throws -> Receipt {
        guard fileURL.isFileURL else { throw Failure.invalidSource }
        guard !fileName.isEmpty, fileName != ".", fileName != "..",
              !fileName.contains("/"), !fileName.contains("\\"),
              !fileName.contains("\0") else { throw Failure.invalidFileName }

        let fileManager = FileManager.default
        let sourcePath = Self.sourceIdentity(for: fileURL)
        let id = Self.sourceID(for: fileURL)
        let directory = directoryURL(for: id)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let receiptURL = directory.appendingPathComponent("receipt.json")

        if fileManager.fileExists(atPath: receiptURL.path) {
            // A malformed receipt must fail visibly, never replace an archived original.
            let receipt = try JSONDecoder().decode(Receipt.self, from: Data(contentsOf: receiptURL))
            guard receipt.id == id, receipt.sourcePath == sourcePath,
                  receipt.originalFileName == fileName,
                  receipt.archivedFileName == Self.archiveFileName(for: fileName) else {
                throw Failure.sourceChanged
            }
            if fileManager.fileExists(atPath: fileURL.path) {
                let incoming = try Self.fingerprint(fileURL)
                guard incoming == (receipt.byteCount, receipt.sha256) else { throw Failure.sourceChanged }
            }
            let original = originalURL(for: receipt)
            if !fileManager.fileExists(atPath: original.path) {
                try copyVerifiedOriginal(from: fileURL, to: original, expected: (receipt.byteCount, receipt.sha256))
            }
            guard try Self.fingerprint(original) == (receipt.byteCount, receipt.sha256) else {
                throw Failure.damagedArchive
            }
            return receipt
        }

        let fingerprint = try Self.fingerprint(fileURL)
        let receipt = Receipt(
            id: id, sourcePath: sourcePath, originalFileName: fileName,
            archivedFileName: Self.archiveFileName(for: fileName), createdAt: Date(),
            byteCount: fingerprint.0, sha256: fingerprint.1
        )
        let original = originalURL(for: receipt)
        if fileManager.fileExists(atPath: original.path) {
            // Recover a crash between preserving the file and committing its receipt.
            guard try Self.fingerprint(original) == fingerprint else { throw Failure.damagedArchive }
        } else {
            try copyVerifiedOriginal(from: fileURL, to: original, expected: fingerprint)
        }
        try JSONEncoder().encode(receipt).write(to: receiptURL, options: .atomic)
        return receipt
    }

    func originalURL(for receipt: Receipt) -> URL {
        directoryURL(for: receipt.id).appendingPathComponent(receipt.archivedFileName)
    }

    func preservedOriginalURL(itemID: UUID) -> URL? {
        let receiptURL = directoryURL(for: itemID).appendingPathComponent("receipt.json")
        guard let data = try? Data(contentsOf: receiptURL),
              let receipt = try? JSONDecoder().decode(Receipt.self, from: data),
              receipt.id == itemID,
              receipt.archivedFileName == Self.archiveFileName(for: receipt.originalFileName) else { return nil }
        let url = originalURL(for: receipt)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    static func sourceID(for fileURL: URL) -> UUID {
        let bytes = Array(SHA256.hash(data: Data(sourceIdentity(for: fileURL).utf8)))
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    /// The caller publishes its in-memory album only after this durable commit succeeds.
    static func writeManifest(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
    }

    private func directoryURL(for id: UUID) -> URL {
        rootURL.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    private static func sourceIdentity(for fileURL: URL) -> String {
        let standardized = fileURL.standardizedFileURL
        let components = standardized.pathComponents
        if let inboxIndex = components.lastIndex(of: "Gen1ImportInbox") {
            // App container UUIDs can change after updates/restores. The target and
            // transfer UUIDs inside the inbox remain the durable download identity.
            return components[inboxIndex...].joined(separator: "/")
        }
        return standardized.path
    }

    private static func archiveFileName(for fileName: String) -> String {
        let ext = (fileName as NSString).pathExtension.lowercased()
        return ext.isEmpty ? "original" : "original.\(ext)"
    }

    private func copyVerifiedOriginal(from source: URL, to destination: URL, expected: (UInt64, String)) throws {
        let temporary = destination.deletingLastPathComponent().appendingPathComponent("\(UUID().uuidString).partial")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try FileManager.default.copyItem(at: source, to: temporary)
        guard try Self.fingerprint(temporary) == expected else { throw Failure.sourceChanged }
        // Same-directory rename exposes only a complete, verified original.
        try FileManager.default.moveItem(at: temporary, to: destination)
    }

    private static func fingerprint(_ url: URL) throws -> (UInt64, String) {
        let properties = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard properties.isRegularFile == true, properties.isSymbolicLink != true else { throw Failure.invalidSource }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var digest = SHA256()
        var byteCount: UInt64 = 0
        while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty {
            try Task.checkCancellation()
            byteCount += UInt64(data.count)
            digest.update(data: data)
        }
        guard byteCount > 0 else { throw Failure.invalidSource }
        return (byteCount, digest.finalize().map { String(format: "%02x", $0) }.joined())
    }
}
