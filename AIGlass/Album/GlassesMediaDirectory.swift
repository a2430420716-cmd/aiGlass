import Foundation

/// Media directories returned by the glasses HTTP server. An empty directory is
/// a valid response; an empty/error/captive-portal body is not a directory.
nonisolated enum GlassesMediaDirectory {
    static func isDirectoryListing(_ html: String) -> Bool {
        let heading = #"<(?:title|h1)\b[^>]*>\s*Index of\s+[^<]*</(?:title|h1)>"#
        return html.range(of: heading, options: [.regularExpression, .caseInsensitive]) != nil
            && html.range(of: "</body>", options: .caseInsensitive) != nil
            && html.range(of: "</html>", options: .caseInsensitive) != nil
    }

    static func fileNames(from html: String) -> [String] {
        var names: [String] = []

        let hrefPatterns = [
            #"href\s*=\s*["']([^"']+)["']"#,
            #"href\s*=\s*([^\s>"]+\.(?:jpg|jpeg|png|heic|mp4|mov))"#,
        ]
        for pattern in hrefPatterns {
            appendMatches(from: html, pattern: pattern, into: &names)
        }

        let textPattern = #"([A-Za-z0-9_\-\.]+\.(?:jpg|jpeg|png|heic|mp4|mov))"#
        appendMatches(from: html, pattern: textPattern, into: &names)

        return names
    }

    private static func appendMatches(from html: String, pattern: String, into names: inout [String]) {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return }
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        for match in regex.matches(in: html, options: [], range: range) {
            guard match.numberOfRanges > 1,
                  let nameRange = Range(match.range(at: 1), in: html) else { continue }
            guard let normalized = normalizeMediaFileName(String(html[nameRange])),
                  !names.contains(normalized) else { continue }
            names.append(normalized)
        }
    }

    private static func normalizeMediaFileName(_ raw: String) -> String? {
        var name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { return nil }
        if let query = name.firstIndex(of: "?") {
            name = String(name[..<query])
        }
        if let slash = name.lastIndex(of: "/") {
            name = String(name[name.index(after: slash)...])
        }
        let lower = name.lowercased()
        if lower.contains("_thumb") || lower.contains("thumb.jpg") { return nil }
        guard lower.hasSuffix(".jpg") || lower.hasSuffix(".jpeg") || lower.hasSuffix(".png")
            || lower.hasSuffix(".heic") || lower.hasSuffix(".mp4") || lower.hasSuffix(".mov") else {
            return nil
        }
        return name
    }

}
