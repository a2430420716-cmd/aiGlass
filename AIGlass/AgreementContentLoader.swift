import Foundation

enum AgreementType: String, Identifiable {
    case service
    case privacy

    var id: String { rawValue }

    var title: String {
        switch self {
        case .service:
            return "《用户协议》"
        case .privacy:
            return "《隐私政策》"
        }
    }

    /// 对齐 Android `values-en/strings.xml`。
    var englishTitle: String {
        switch self {
        case .service:
            return "Terms of Service"
        case .privacy:
            return "Privacy Policy"
        }
    }

    var shortTitle: String {
        switch self {
        case .service:
            return "用户协议"
        case .privacy:
            return "隐私政策"
        }
    }

    var resourceName: String {
        switch self {
        case .service:
            return "service"
        case .privacy:
            return "privacyPolicy"
        }
    }

    var fallbackContent: String {
        switch self {
        case .service:
            return """
            欢迎使用 MOCO AI。使用本应用及相关设备服务前，请您认真阅读本协议内容。我们会在您使用登录、设备连接、图片与音视频处理、问题反馈、升级服务等功能时，基于实现功能所必需的范围收集和使用相关信息。您应妥善保管账号、密码及设备信息，不得利用本应用从事违法违规行为。如您继续使用，即视为您已知悉并同意遵守相关服务约定。
            """
        case .privacy:
            return """
            我们重视您的个人信息与隐私安全。为实现登录认证、设备绑定、内容导入、版本更新、问题反馈等功能，我们可能会收集手机号、头像昵称、设备标识、蓝牙设备信息、应用版本信息及您主动上传的图片、音频或反馈内容。我们会采取合理的安全措施保护您的数据，并仅在必要范围内进行使用。未经您的授权，我们不会超出法律法规允许的范围使用您的信息。
            """
        }
    }
}

/// `.uvue` 解析出的排版块，对齐 Android `AgreementActivity.AgreementBlock`。
enum AgreementBlock {
    case paragraph(AgreementParagraph)
    case table([[AgreementTableCell]])
}

struct AgreementParagraph {
    let text: String
    /// class 含 `fw7`
    let bold: Bool
    /// class 含 `fs18` / `fs16`，用大一号字并加粗
    let title: Bool
    /// class 同时含 `ta` 与 `fs18`
    let center: Bool
}

struct AgreementTableCell {
    let text: String
    let bold: Bool
}

enum AgreementContentLoader {
    /// 权限表列数与列宽，对齐 Android `TABLE_COLUMN_COUNT` / `TABLE_COLUMN_WEIGHTS`。
    static let tableColumnCount = 4
    static let tableColumnWeights: [CGFloat] = [1.1, 1.5, 1.5, 1.5]

    /// 对齐 Android `AgreementActivity.loadAgreementBlocks`：解析段落与权限表格。
    @MainActor
    static func loadBlocks(type: AgreementType) -> [AgreementBlock] {
        let isZh = !AppLanguageManager.shared.usesEnglish
        guard let source = loadSource(type: type) else {
            return [.paragraph(AgreementParagraph(text: type.fallbackContent, bold: false, title: false, center: false))]
        }
        let blocks = parseUniappAgreementBlocks(source, isZh: isZh)
        guard !blocks.isEmpty else {
            return [.paragraph(AgreementParagraph(text: type.fallbackContent, bold: false, title: false, center: false))]
        }
        return blocks
    }

    private static func loadSource(type: AgreementType) -> String? {
        guard let url = Bundle.main.url(
            forResource: type.resourceName,
            withExtension: "uvue",
            subdirectory: "agreements"
        ) ?? Bundle.main.url(forResource: type.resourceName, withExtension: "uvue") else {
            return nil
        }
        guard let source = try? String(contentsOf: url, encoding: .utf8), !source.isEmpty else {
            return nil
        }
        return source
    }

    /// 对齐 Android `AgreementActivity`：从 bundled `.uvue` 解析中英文段落。
    static func load(type: AgreementType) -> String {
        let isZh = Locale.current.languageCode?.hasPrefix("zh") ?? true
        guard let url = Bundle.main.url(
            forResource: type.resourceName,
            withExtension: "uvue",
            subdirectory: "agreements"
        ) ?? Bundle.main.url(forResource: type.resourceName, withExtension: "uvue") else {
            return type.fallbackContent
        }

        guard let source = try? String(contentsOf: url, encoding: .utf8), !source.isEmpty else {
            return type.fallbackContent
        }

        let parsed = parseUniappAgreementText(source, isZh: isZh)
        return parsed.isEmpty ? type.fallbackContent : parsed
    }

    private static func parseUniappAgreementText(_ source: String, isZh: Bool) -> String {
        guard let zhStart = source.range(of: "<view class=\"app\" v-if=\"lang\">")?.lowerBound,
              let enStart = source.range(of: "<view class=\"app\" v-else>")?.lowerBound,
              let scriptStart = source.range(of: "<script")?.lowerBound else {
            return stripUniappTags(source)
        }

        let section: Substring
        if isZh {
            section = source[zhStart..<enStart]
        } else {
            section = source[enStart..<scriptStart]
        }

        guard let scrollStart = section.range(of: "<scroll-view")?.lowerBound,
              let scrollTagEndRange = section[scrollStart...].range(of: ">"),
              let scrollEnd = section.range(of: "</scroll-view>", options: .backwards)?.lowerBound,
              scrollEnd > scrollTagEndRange.upperBound else {
            return stripUniappTags(String(section))
        }

        let body = section[scrollTagEndRange.upperBound..<scrollEnd]
        return stripUniappTags(String(body))
    }

    private static func stripUniappTags(_ raw: String) -> String {
        var text = raw
        text = text.replacingOccurrences(
            of: "<!--.*?-->",
            with: "",
            options: .regularExpression
        )
        text = text.replacingOccurrences(
            of: "</text\\s*>",
            with: "\n",
            options: [.regularExpression, .caseInsensitive]
        )
        text = text.replacingOccurrences(
            of: "</view\\s*>",
            with: "\n",
            options: [.regularExpression, .caseInsensitive]
        )
        text = text.replacingOccurrences(
            of: "</tr\\s*>",
            with: "\n",
            options: [.regularExpression, .caseInsensitive]
        )
        text = text.replacingOccurrences(
            of: "</td\\s*>",
            with: "\t",
            options: [.regularExpression, .caseInsensitive]
        )
        text = text.replacingOccurrences(
            of: "<br\\s*/?>",
            with: "\n",
            options: [.regularExpression, .caseInsensitive]
        )
        text = text.replacingOccurrences(
            of: "<[^>]+>",
            with: "",
            options: .regularExpression
        )

        // 简单 HTML 实体解码（对齐 Android HtmlCompat）
        let entities: [(String, String)] = [
            ("&nbsp;", " "),
            ("&amp;", "&"),
            ("&lt;", "<"),
            ("&gt;", ">"),
            ("&quot;", "\""),
            ("&#39;", "'"),
        ]
        for (from, to) in entities {
            text = text.replacingOccurrences(of: from, with: to, options: .caseInsensitive)
        }

        return text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }
}

// MARK: - 结构化解析（对齐 Android AgreementActivity）

private struct AgreementTagRange {
    let start: Int
    let end: Int
    let openTag: String
    let inner: String
}

extension AgreementContentLoader {
    fileprivate static func parseUniappAgreementBlocks(_ source: String, isZh: Bool) -> [AgreementBlock] {
        guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        let section = selectLanguageSection(source, isZh: isZh) as NSString

        let scrollStart = section.range(of: "<scroll-view").location
        let scrollEnd = section.range(of: "</scroll-view>", options: .backwards).location
        var body = section as String
        if scrollStart != NSNotFound, scrollEnd != NSNotFound {
            let tagEnd = section.range(
                of: ">",
                options: [],
                range: NSRange(location: scrollStart, length: section.length - scrollStart)
            ).location
            if tagEnd != NSNotFound, scrollEnd > tagEnd {
                body = section.substring(with: NSRange(location: tagEnd + 1, length: scrollEnd - tagEnd - 1))
            }
        }
        return parseBlocks(body)
    }

    private static func selectLanguageSection(_ source: String, isZh: Bool) -> String {
        let ns = source as NSString
        let zhStart = ns.range(of: "<view class=\"app\" v-if=\"lang\">").location
        let enStart = ns.range(of: "<view class=\"app\" v-else>").location
        let scriptStart = ns.range(of: "<script").location
        guard zhStart != NSNotFound, enStart != NSNotFound, scriptStart != NSNotFound else {
            return source
        }
        if isZh {
            return ns.substring(with: NSRange(location: zhStart, length: enStart - zhStart))
        }
        return ns.substring(with: NSRange(location: enStart, length: scriptStart - enStart))
    }

    private static func parseBlocks(_ body: String) -> [AgreementBlock] {
        let ns = body as NSString
        var blocks: [AgreementBlock] = []
        var cursor = 0

        for tableRange in findTopLevelRanges(ns, startPrefix: "<view class=\"table", tagName: "view") {
            if tableRange.start > cursor {
                let head = ns.substring(with: NSRange(location: cursor, length: tableRange.start - cursor))
                blocks.append(contentsOf: parseParagraphs(head).map { AgreementBlock.paragraph($0) })
            }
            let rows = parseTableRows(tableRange.inner)
            if !rows.isEmpty {
                blocks.append(.table(rows))
            }
            cursor = tableRange.end
        }

        if cursor < ns.length {
            let tail = ns.substring(with: NSRange(location: cursor, length: ns.length - cursor))
            blocks.append(contentsOf: parseParagraphs(tail).map { AgreementBlock.paragraph($0) })
        }
        return blocks
    }

    private static func parseParagraphs(_ raw: String) -> [AgreementParagraph] {
        findTopLevelRanges(raw as NSString, startPrefix: "<text", tagName: "text").compactMap { range in
            let text = cleanText(range.inner)
            guard !text.isEmpty else { return nil }
            let classes = extractClass(range.openTag)
            return AgreementParagraph(
                text: text,
                bold: classes.contains("fw7"),
                title: classes.contains("fs18") || classes.contains("fs16"),
                center: classes.contains("ta") && classes.contains("fs18")
            )
        }
    }

    private static func parseTableRows(_ raw: String) -> [[AgreementTableCell]] {
        findTopLevelRanges(raw as NSString, startPrefix: "<view class=\"dr", tagName: "view").compactMap { rowRange in
            let cells = parseTableCells(rowRange.inner)
            return cells.isEmpty ? nil : cells
        }
    }

    private static func parseTableCells(_ row: String) -> [AgreementTableCell] {
        let ns = row as NSString
        var cells: [AgreementTableCell] = []
        var cursor = 0

        while cursor < ns.length {
            let searchRange = NSRange(location: cursor, length: ns.length - cursor)
            let textStart = ns.range(of: "<text", range: searchRange).location
            let viewStart = ns.range(of: "<view", range: searchRange).location
            if textStart == NSNotFound && viewStart == NSNotFound { break }

            let useText = textStart != NSNotFound && (viewStart == NSNotFound || textStart < viewStart)
            let start = useText ? textStart : viewStart
            guard let range = findBalancedRange(ns, start: start, tagName: useText ? "text" : "view") else { break }

            let text = cleanText(range.inner)
            if !text.isEmpty {
                cells.append(AgreementTableCell(text: text, bold: extractClass(range.openTag).contains("fw7")))
            }
            cursor = range.end
        }
        return cells
    }

    private static func findTopLevelRanges(_ raw: NSString, startPrefix: String, tagName: String) -> [AgreementTagRange] {
        var ranges: [AgreementTagRange] = []
        var cursor = 0
        while cursor < raw.length {
            let start = raw.range(
                of: startPrefix,
                range: NSRange(location: cursor, length: raw.length - cursor)
            ).location
            if start == NSNotFound { break }
            guard let range = findBalancedRange(raw, start: start, tagName: tagName) else { break }
            ranges.append(range)
            cursor = range.end
        }
        return ranges
    }

    /// 标签嵌套配平，避免内层 `<view>` 提前截断表格。
    private static func findBalancedRange(_ raw: NSString, start: Int, tagName: String) -> AgreementTagRange? {
        let openEnd = raw.range(of: ">", range: NSRange(location: start, length: raw.length - start)).location
        guard openEnd != NSNotFound else { return nil }

        let openTag = raw.substring(with: NSRange(location: start, length: openEnd - start + 1))
        let openToken = "<\(tagName)"
        let closeToken = "</\(tagName)>"
        var depth = 1
        var cursor = openEnd + 1

        while cursor < raw.length {
            let searchRange = NSRange(location: cursor, length: raw.length - cursor)
            let nextOpen = raw.range(of: openToken, range: searchRange).location
            let nextClose = raw.range(of: closeToken, range: searchRange).location
            guard nextClose != NSNotFound else { return nil }

            if nextOpen != NSNotFound && nextOpen < nextClose {
                depth += 1
                cursor = nextOpen + openToken.count
            } else {
                depth -= 1
                if depth == 0 {
                    return AgreementTagRange(
                        start: start,
                        end: nextClose + closeToken.count,
                        openTag: openTag,
                        inner: raw.substring(with: NSRange(location: openEnd + 1, length: nextClose - openEnd - 1))
                    )
                }
                cursor = nextClose + closeToken.count
            }
        }
        return nil
    }

    private static func cleanText(_ raw: String) -> String {
        var text = raw
        text = text.replacingOccurrences(of: "<!--.*?-->", with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "</text\\s*>", with: "\n", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: "<br\\s*/?>", with: "\n", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)

        let entities: [(String, String)] = [
            ("&nbsp;", " "),
            ("&amp;", "&"),
            ("&lt;", "<"),
            ("&gt;", ">"),
            ("&quot;", "\""),
            ("&#39;", "'"),
        ]
        for (from, to) in entities {
            text = text.replacingOccurrences(of: from, with: to, options: .caseInsensitive)
        }

        return text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    private static func extractClass(_ tag: String) -> Set<String> {
        guard let regex = try? NSRegularExpression(pattern: "class\\s*=\\s*\"([^\"]*)\""),
              let match = regex.firstMatch(in: tag, range: NSRange(tag.startIndex..., in: tag)),
              let range = Range(match.range(at: 1), in: tag) else {
            return []
        }
        return Set(tag[range].split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init))
    }
}
