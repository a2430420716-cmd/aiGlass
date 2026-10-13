import Foundation

@main
@MainActor
enum Gen1MediaStagingTests {
    private static var assertions = 0

    private static func check(_ condition: Bool, _ message: String) {
        assertions += 1
        precondition(condition, message)
    }

    private static func mustThrow(_ message: String, _ operation: () throws -> Void) {
        assertions += 1
        do {
            try operation()
            preconditionFailure(message)
        } catch {}
    }

    static func main() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("gen1-media-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let inbox = base.appendingPathComponent("inbox", isDirectory: true)
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        let source = inbox.appendingPathComponent("photo.jpg")
        let bytes = Data((0..<(2 * 1024 * 1024 + 17)).map { UInt8($0 % 251) })
        try bytes.write(to: source)
        let archive = Gen1MediaStaging(rootURL: base.appendingPathComponent("archive"))
        let receipt = try archive.preserve(fileURL: source, fileName: "camera-photo.jpg")
        let original = archive.originalURL(for: receipt)
        let stored = try Data(contentsOf: original)
        check(stored == bytes, "The archive preserves source bytes without media processing")
        check(receipt.byteCount == UInt64(bytes.count), "Hashing handles multiple chunks and the final partial chunk")
        check(receipt.originalFileName == "camera-photo.jpg", "Device filename remains in durable metadata")
        check(archive.preservedOriginalURL(itemID: receipt.id) == original, "Album ID resolves to the unmodified original")
        let retried = try archive.preserve(fileURL: source, fileName: "camera-photo.jpg")
        check(retried == receipt, "A retry reuses identity, timestamp and archive")

        try Data("changed".utf8).write(to: source)
        mustThrow("Reusing the same inbox path for different bytes must not overwrite an original") {
            _ = try archive.preserve(fileURL: source, fileName: "camera-photo.jpg")
        }
        check(try Data(contentsOf: original) == bytes, "Source replacement leaves preserved bytes intact")
        try FileManager.default.removeItem(at: source)
        let afterInboxRemoval = try archive.preserve(fileURL: source, fileName: "camera-photo.jpg")
        check(afterInboxRemoval == receipt, "A durable receipt supports recovery after inbox removal")
        mustThrow("Changed filenames cannot alias an existing source receipt") {
            _ = try archive.preserve(fileURL: source, fileName: "other.jpg")
        }

        // Reconstruct the crash window after the atomic original rename, before receipt commit.
        try bytes.write(to: source)
        let receiptURL = original.deletingLastPathComponent().appendingPathComponent("receipt.json")
        try FileManager.default.removeItem(at: receiptURL)
        let recovered = try archive.preserve(fileURL: source, fileName: "camera-photo.jpg")
        check(recovered.id == receipt.id, "A crash before receipt commit cannot create duplicate album IDs")
        check(try Data(contentsOf: original) == bytes, "Crash recovery reuses the preserved original")

        try Data("corrupt".utf8).write(to: original)
        mustThrow("Corrupt archives fail explicitly even when an inbox source remains") {
            _ = try archive.preserve(fileURL: source, fileName: "camera-photo.jpg")
        }
        check(try Data(contentsOf: source) == bytes, "A corrupt archive never deletes the inbox fallback")
        try bytes.write(to: original)
        try Data("invalid json".utf8).write(to: receiptURL)
        mustThrow("Malformed receipt must not be silently reset") {
            _ = try archive.preserve(fileURL: source, fileName: "camera-photo.jpg")
        }
        check(try Data(contentsOf: original) == bytes, "Receipt failure preserves original bytes")

        let empty = inbox.appendingPathComponent("empty.jpg")
        try Data().write(to: empty)
        mustThrow("An empty download cannot become a durable original") {
            _ = try archive.preserve(fileURL: empty, fileName: "empty.jpg")
        }
        for name in ["", ".", "..", "../escape.jpg", "folder/name.jpg", "folder\\name.jpg", "nul\0.jpg"] {
            mustThrow("Unsafe filename must be rejected: \(name)") {
                _ = try archive.preserve(fileURL: source, fileName: name)
            }
        }
        let secondSource = inbox.appendingPathComponent("second/photo.jpg")
        check(Gen1MediaStaging.sourceID(for: source) != Gen1MediaStaging.sourceID(for: secondSource),
              "The same remote filename from another transfer has a distinct import identity")
        let beforeUpdate = URL(fileURLWithPath: "/app/old-container/Documents/Gen1ImportInbox/device/transfer/photo.jpg")
        let afterUpdate = URL(fileURLWithPath: "/app/new-container/Documents/Gen1ImportInbox/device/transfer/photo.jpg")
        check(Gen1MediaStaging.sourceID(for: beforeUpdate) == Gen1MediaStaging.sourceID(for: afterUpdate),
              "A changed application container must not duplicate a pending inbox item")

        let manifest = base.appendingPathComponent("manifest.json")
        let manifestData = Data("[1]".utf8)
        try Gen1MediaStaging.writeManifest(manifestData, to: manifest)
        check(try Data(contentsOf: manifest) == manifestData, "Manifest data is committed before success")
        let blockedManifest = base.appendingPathComponent("blocked-manifest.json")
        try FileManager.default.createDirectory(at: blockedManifest, withIntermediateDirectories: false)
        mustThrow("Manifest write failure must propagate to the coordinator") {
            try Gen1MediaStaging.writeManifest(manifestData, to: blockedManifest)
        }
        check(try Data(contentsOf: original) == bytes, "Failed manifest commit cannot remove the original")
        check(try Data(contentsOf: manifest) == manifestData, "A failed commit elsewhere leaves the existing manifest intact")
        print("Gen1 media staging: \(assertions) assertions passed")
    }
}
