import Foundation

/// HTTP success can contain a gateway/login page instead of the requested image.
enum FirmwareDownloadValidation {
    enum ValidationError: Error, Equatable {
        case emptyFile
        case documentResponse
        case lengthMismatch
    }

    nonisolated static func validate(_ data: Data, response: HTTPURLResponse) throws {
        guard !data.isEmpty else { throw ValidationError.emptyFile }

        let mime = (response.mimeType ?? "").lowercased()
        if mime.hasPrefix("text/") || mime == "application/json" || mime.hasSuffix("+json")
            || mime == "application/xml" || mime.hasSuffix("+xml") {
            throw ValidationError.documentResponse
        }

        // Do not depend on a file extension or a server's generic binary MIME type.
        let prefix = String(decoding: data.prefix(512), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{FEFF}")))
            .lowercased()
        if ["<!doctype html", "<html", "<head", "<body", "<?xml", "<!--"].contains(where: { prefix.hasPrefix($0) }) {
            throw ValidationError.documentResponse
        }
        if (prefix.hasPrefix("{") || prefix.hasPrefix("[")),
           (try? JSONSerialization.jsonObject(with: data)) != nil {
            throw ValidationError.documentResponse
        }

        // URLSession may decode content, while Content-Length describes compressed bytes.
        let encoding = (response.value(forHTTPHeaderField: "Content-Encoding") ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if encoding.isEmpty || encoding == "identity" {
            let expected = response.expectedContentLength
            if expected >= 0, Int64(data.count) != expected {
                throw ValidationError.lengthMismatch
            }
        }
    }
}
