import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

@main
@MainActor
enum AlbumShareImageProviderTests {
    private static var checks = 0

    private static func check(_ condition: Bool, _ message: String) {
        checks += 1
        precondition(condition, message)
    }

    static func main() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AlbumShareImageProviderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let jpegA = imageData(type: .jpeg, red: 1, blue: 0)
        let jpegB = imageData(type: .jpeg, red: 0, blue: 1)
        let urls = [directory.appendingPathComponent("a.jpg"), directory.appendingPathComponent("b.jpg")]
        try jpegA.write(to: urls[0])
        try jpegB.write(to: urls[1])
        let providers = urls.compactMap { AlbumShareImageProvider.make(url: $0) }
        check(providers.count == 2, "A two-photo share must expose two separate image items")
        for (index, provider) in providers.enumerated() {
            check(provider.registeredTypeIdentifiers.contains(UTType.jpeg.identifier), "Expose concrete JPEG type")
            check(provider.hasItemConformingToTypeIdentifier(UTType.image.identifier), "Image services can discover this item")
            check(!provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier), "Do not advertise a generic Open In URL")
            check(provider.suggestedName == urls[index].lastPathComponent, "Keep the original filename")
            let expected = index == 0 ? jpegA : jpegB
            let data = try await loadData(provider, type: .jpeg)
            check(data == expected, "Data consumers receive original JPEG bytes, including orientation metadata")
            let copied = try await loadFileData(provider, type: .jpeg)
            check(copied == expected, "File consumers receive a full copy of the same photo")
            let repeated = try await loadData(provider, type: .jpeg)
            check(repeated == expected, "Repeated extension requests retain each photo's identity")
        }

        // Never label PNG bytes as JPEG, even if a source filename has the wrong suffix.
        let png = imageData(type: .png, red: 0, blue: 1)
        let mislabeledURL = directory.appendingPathComponent("actually-png.jpg")
        try png.write(to: mislabeledURL)
        let pngProvider = AlbumShareImageProvider.make(url: mislabeledURL)!
        check(pngProvider.registeredTypeIdentifiers.contains(UTType.png.identifier), "Inspect encoded image type")
        check(!pngProvider.registeredTypeIdentifiers.contains(UTType.jpeg.identifier), "Do not mislabel encoded bytes")
        check(pngProvider.suggestedName == "actually-png.png", "Filename suffix must match the provided bytes")
        let loadedPNG = try await loadData(pngProvider, type: .png)
        check(loadedPNG == png, "PNG stays PNG, without unnecessary JPEG transcoding")

        let invalidURL = directory.appendingPathComponent("not-an-image.jpg")
        try Data("not an image".utf8).write(to: invalidURL)
        check(AlbumShareImageProvider.make(url: invalidURL) == nil, "Invalid images cannot advertise a working image provider")
        check(AlbumShareImageProvider.make(url: directory.appendingPathComponent("missing.jpg")) == nil,
              "Missing images cannot create providers")
        check(AlbumShareImageProvider.make(url: URL(string: "https://example.com/photo.jpg")!) == nil,
              "Sharing never fetches a remote image")

        let removedURL = directory.appendingPathComponent("removed.jpg")
        try jpegA.write(to: removedURL)
        let removedProvider = AlbumShareImageProvider.make(url: removedURL)!
        try FileManager.default.removeItem(at: removedURL)
        do {
            _ = try await loadData(removedProvider, type: .jpeg)
            preconditionFailure("A deleted source must report an error, not provide a thumbnail or empty photo")
        } catch { checks += 1 }
        do {
            _ = try await loadFileData(removedProvider, type: .jpeg)
            preconditionFailure("File requests must also report deleted sources")
        } catch { checks += 1 }
        print("Album share image provider tests passed: \(checks)")
    }

    private static func imageData(type: UTType, red: CGFloat, blue: CGFloat) -> Data {
        let context = CGContext(data: nil, width: 2, height: 3, bitsPerComponent: 8, bytesPerRow: 8,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(red: red, green: 0, blue: blue, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 2, height: 3))
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, [kCGImagePropertyOrientation: 6] as CFDictionary)
        precondition(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private static func loadData(_ provider: NSItemProvider, type: UTType) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            _ = provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, error in
                if let data { continuation.resume(returning: data) }
                else { continuation.resume(throwing: error ?? CocoaError(.fileReadUnknown)) }
            }
        }
    }

    private static func loadFileData(_ provider: NSItemProvider, type: UTType) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            _ = provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, error in
                guard let url else {
                    continuation.resume(throwing: error ?? CocoaError(.fileReadUnknown))
                    return
                }
                // NSItemProvider deletes its temporary copy after this callback returns.
                do { continuation.resume(returning: try Data(contentsOf: url)) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }
}
