import Foundation
import SwiftUI
import UIKit

enum FAQHTMLText {
    private static let secondaryTextColor = UIColor(red: 0.55, green: 0.55, blue: 0.55, alpha: 1)
    private static let bodyFont = UIFont.systemFont(ofSize: 13)

    static func attributedString(from html: String) -> AttributedString? {
        let trimmed = html.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let wrapped = """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <style>
          body {
            font-family: -apple-system, "PingFang SC", "Noto Sans SC", sans-serif;
            font-size: 13px;
            line-height: 1.6;
            color: #8C8C8C;
            margin: 0;
            padding: 0;
          }
          p { margin: 8px 0; }
          img { max-width: 100%; height: auto; }
        </style>
        </head>
        <body>
        \(normalizeHTML(trimmed))
        </body>
        </html>
        """

        guard let data = wrapped.data(using: .utf8) else { return nil }

        let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
            .documentType: NSAttributedString.DocumentType.html,
            .characterEncoding: String.Encoding.utf8.rawValue
        ]

        guard let nsAttr = try? NSMutableAttributedString(
            data: data,
            options: options,
            documentAttributes: nil
        ), nsAttr.length > 0 else {
            return nil
        }

        let fullRange = NSRange(location: 0, length: nsAttr.length)
        nsAttr.addAttribute(.font, value: bodyFont, range: fullRange)
        nsAttr.addAttribute(.foregroundColor, value: secondaryTextColor, range: fullRange)

        return AttributedString(nsAttr)
    }

    private static func normalizeHTML(_ html: String) -> String {
        var result = html
        let replacements = [
            ("src=\"/upload/", "src=\"https://glasses.kaimou.net/upload/"),
            ("src='/upload/", "src='https://glasses.kaimou.net/upload/"),
            ("src=\"/Upload/", "src=\"https://glasses.kaimou.net/upload/"),
            ("src=\"//", "src=\"https://")
        ]
        for (from, to) in replacements {
            result = result.replacingOccurrences(of: from, with: to)
        }
        return result
    }
}

struct FAQHTMLContentView: View {
    let html: String

    var body: some View {
        Group {
            if let attributed = FAQHTMLText.attributedString(from: html) {
                Text(attributed)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(HTMLPlainText.from(html))
                    .font(AppTheme.notoSansSC(size: 13, weight: .regular))
                    .foregroundStyle(AppTheme.secondaryText)
                    .lineSpacing(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}
