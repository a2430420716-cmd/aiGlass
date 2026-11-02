import SwiftUI
import WebKit

/// 用于渲染接口返回的 HTML（配对准备说明等）。
struct HTMLWebView: UIViewRepresentable {
    enum TextStyle {
        case standard
        case pairingInstructions

        var overrides: String {
            switch self {
            case .standard:
                return ""
            case .pairingInstructions:
                return """
                body, p, div, span, li, h1, h2, h3 { color: #000000 !important; }
                body, p, div, span, li { font-size: 16px !important; }
                """
            }
        }
    }

    let html: String
    var textStyle: TextStyle = .standard
    var baseURL: URL? = URL(string: "https://glasses.kaimou.net/")
    var onLoadResult: ((Bool) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(onLoadResult: onLoadResult)
    }

    func makeUIView(context: Context) -> WKWebView {
        let webView = WKWebView(frame: .zero)
        webView.navigationDelegate = context.coordinator
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        let processed = Self.normalizeHTML(html)
        let wrapped = """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
        <style>
          * { box-sizing: border-box; }
          html, body {
            margin: 0;
            padding: 0;
            background: transparent;
          }
          body {
            padding: 8px 20px 30px;
            font-family: -apple-system, "PingFang SC", "Noto Sans SC", sans-serif;
            font-size: 14px;
            line-height: 1.6;
            color: #666666;
            word-wrap: break-word;
            overflow-wrap: break-word;
          }
          img {
            max-width: 100% !important;
            width: auto !important;
            height: auto !important;
            display: block;
            margin: 8px 0;
          }
          h3 {
            font-size: 16px;
            font-weight: 700;
            color: #333333;
            margin: 16px 0 8px;
          }
          p { margin: 8px 0; }
          \(textStyle.overrides)
        </style>
        </head>
        <body>
        \(processed)
        </body>
        </html>
        """
        guard context.coordinator.loadedHTML != wrapped else { return }
        context.coordinator.loadedHTML = wrapped
        webView.loadHTMLString(wrapped, baseURL: baseURL)
    }

    /// 把相对路径图片转成绝对地址，避免 WebView 加载失败。
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

    final class Coordinator: NSObject, WKNavigationDelegate {
        var loadedHTML: String?
        private let onLoadResult: ((Bool) -> Void)?

        init(onLoadResult: ((Bool) -> Void)?) {
            self.onLoadResult = onLoadResult
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            onLoadResult?(true)
        }

        func webView(
            _ webView: WKWebView,
            didFail navigation: WKNavigation!,
            withError error: Error
        ) {
            onLoadResult?(false)
        }

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation!,
            withError error: Error
        ) {
            onLoadResult?(false)
        }
    }
}
