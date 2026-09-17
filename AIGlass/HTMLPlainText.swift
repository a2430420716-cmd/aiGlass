import Foundation

enum HTMLPlainText {
    /// 将接口返回的简单 HTML（如 `<p>...</p>`）转成纯文本，避免弹窗里起 WKWebView。
    static func from(_ html: String) -> String {
        var text = html
        let replacements: [(String, String)] = [
            ("<br />", "\n"), ("<br/>", "\n"), ("<br>", "\n"),
            ("</p>", "\n"), ("</li>", "\n"),
            ("&nbsp;", " "), ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"),
        ]
        for (from, to) in replacements {
            text = text.replacingOccurrences(of: from, with: to, options: .caseInsensitive)
        }
        text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        return text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }
}
