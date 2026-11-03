import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Shares the original encoded image, with its concrete content type and filename.
enum AlbumShareImageProvider {
    nonisolated static func make(
        url: URL,
        onLoad: (@Sendable (_ representation: String, _ type: String, _ readable: Bool) -> Void)? = nil
    ) -> NSItemProvider? {
        guard url.isFileURL, FileManager.default.isReadableFile(atPath: url.path),
              let source = CGImageSourceCreateWithURL(
                url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary
              ),
              let imageType = CGImageSourceGetType(source) else { return nil }
        let identifier = imageType as String
        guard let type = UTType(identifier), type.conforms(to: .image) else { return nil }

        let provider = NSItemProvider()
        // Do not register public.file-url: this item is an image, not an Open In document.
        provider.suggestedName = UTType(filenameExtension: url.pathExtension) == type
            ? url.lastPathComponent
            : url.deletingPathExtension().lastPathComponent
                + "." + (type.preferredFilenameExtension ?? url.pathExtension)
        // The system copies this file for the extension; it need not open our sandbox URL.
        provider.registerFileRepresentation(forTypeIdentifier: identifier, fileOptions: [], visibility: .all) { completion in
            let readable = FileManager.default.isReadableFile(atPath: url.path)
            onLoad?("originalImageFile", identifier, readable)
            completion(readable ? url : nil, false, readable ? nil : CocoaError(.fileReadNoSuchFile))
            return nil
        }
        // Also serve extensions that request encoded data instead of a file. Keep the
        // original bytes; UIImage transcoding can change JPEG into a generic/PNG item.
        provider.registerDataRepresentation(forTypeIdentifier: identifier, visibility: .all) { completion in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let data = try Data(contentsOf: url)
                    onLoad?("originalImageData", identifier, true)
                    completion(data, nil)
                } catch {
                    onLoad?("originalImageData", identifier, false)
                    completion(nil, error)
                }
            }
            return nil
        }
        return provider
    }
}
