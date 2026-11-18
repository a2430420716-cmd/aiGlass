import SwiftUI
import UIKit
import WebKit

/// Preserve rich content while fitting backend typography to the app's reading size.
struct FAQHTMLContentView: View {
    let html: String
    @State private var contentHeight: CGFloat = 1

    var body: some View {
        FAQHTMLWebView(html: html, contentHeight: $contentHeight)
            .frame(height: contentHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct FAQHTMLWebView: UIViewRepresentable {
    let html: String
    @Binding var contentHeight: CGFloat

    func makeCoordinator() -> Coordinator {
        Coordinator(contentHeight: $contentHeight)
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.userContentController.add(context.coordinator, name: "faqHeight")
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.isOpaque = false
        view.backgroundColor = .clear
        view.scrollView.backgroundColor = .clear
        view.scrollView.isScrollEnabled = false
        view.scrollView.contentInsetAdjustmentBehavior = .never
        view.navigationDelegate = context.coordinator
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        let coordinator = context.coordinator
        coordinator.contentHeight = $contentHeight
        let baseURL = BackendRouting.rootURL
        guard coordinator.html != html || coordinator.baseURL != baseURL else { return }
        coordinator.html = html
        coordinator.baseURL = baseURL
        coordinator.documentID = UUID().uuidString
        let controller = view.configuration.userContentController
        controller.removeAllUserScripts()
        controller.addUserScript(WKUserScript(
            source: Self.measurementScript(documentID: coordinator.documentID),
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        ))
        let normalizedHTML = html
            .replacingOccurrences(of: "src=\"/Upload/", with: "src=\"/upload/")
            .replacingOccurrences(of: "src='/Upload/", with: "src='/upload/")
        view.loadHTMLString(Self.document(normalizedHTML), baseURL: baseURL)
    }

    static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) {
        view.stopLoading()
        view.navigationDelegate = nil
        view.configuration.userContentController.removeScriptMessageHandler(forName: "faqHeight")
        view.configuration.userContentController.removeAllUserScripts()
    }

    private static func document(_ html: String) -> String {
        """
        <!doctype html><html><head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>
          * { box-sizing: border-box; }
          html, body { margin: 0; padding: 0; background: transparent; }
          body {
            display: flow-root;
            font-family: -apple-system, "PingFang SC", sans-serif;
            font-size: 14px; line-height: 1.5; color: #333;
            overflow-wrap: anywhere; -webkit-text-size-adjust: 100%;
          }
          p { margin: 0 0 6px; }
          img, video { max-width: 100%; height: auto; }
          img { display: block; margin: 6px auto; }
          table { max-width: 100%; overflow-wrap: anywhere; }
          a { color: #2f6bff; }
        </style></head><body>\(html)</body></html>
        """
    }

    private static func measurementScript(documentID: String) -> String {
        #"""
        (() => {
          const body = document.body;
          // Some answers are authored at 28/32/36px for Android's wider CSS
          // viewport. Snapshot first so inherited font sizes are not scaled twice.
          const typography = Array.from(body.querySelectorAll('*'))
            .filter(el => !['SCRIPT', 'STYLE'].includes(el.tagName))
            .map(el => ({el, size: parseFloat(getComputedStyle(el).fontSize)}));
          const bodySizes = new Map();
          const walker = document.createTreeWalker(body, NodeFilter.SHOW_TEXT);
          while (walker.nextNode()) {
            const node = walker.currentNode;
            const parent = node.parentElement;
            const length = node.textContent.trim().length;
            if (!length || parent.closest('h1,h2,h3,h4,h5,h6,script,style') ||
                !parent.getClientRects().length) continue;
            const size = parseFloat(getComputedStyle(parent).fontSize);
            if (Number.isFinite(size)) bodySizes.set(size, (bodySizes.get(size) || 0) + length);
          }
          const authoredBodySize = Array.from(bodySizes)
            .sort((a, b) => b[1] - a[1])[0]?.[0] || 14;
          const textScale = Math.min(1, 14 / authoredBodySize);
          typography.forEach(({el, size}) => {
            if (!Number.isFinite(size)) return;
            const fitted = Math.min(20, Math.max(Math.min(size, 14), size * textScale));
            el.style.setProperty('font-size', fitted + 'px', 'important');
          });
          // Match Android: empty formatting blocks must not leave a large blank tail.
          body.querySelectorAll('p,h1,h2,h3,h4,h5,h6,div,section,li').forEach(el => {
            const text = (el.textContent || '').replace(/[\u00a0\u200b\s]/g, '');
            if (!text && !el.querySelector('img,video,iframe,table,canvas')) {
              el.style.display = 'none';
            }
          });
          let scheduled = false;
          const measure = () => {
            if (scheduled) return;
            scheduled = true;
            requestAnimationFrame(() => {
              scheduled = false;
              const height = Math.ceil(body.getBoundingClientRect().height);
              window.webkit.messageHandlers.faqHeight.postMessage({
                id: '\#(documentID)', height: Math.max(1, height)
              });
            });
          };
          new ResizeObserver(measure).observe(body);
          window.addEventListener('resize', measure);
          body.addEventListener('load', measure, true);
          if (document.fonts) document.fonts.ready.then(measure);
          measure();
        })();
        """#
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var contentHeight: Binding<CGFloat>
        var html: String?
        var baseURL: URL?
        var documentID = ""

        init(contentHeight: Binding<CGFloat>) {
            self.contentHeight = contentHeight
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let payload = message.body as? [String: Any],
                  payload["id"] as? String == documentID,
                  let number = payload["height"] as? NSNumber else { return }
            let height = CGFloat(number.doubleValue)
            guard height.isFinite, height > 0, abs(contentHeight.wrappedValue - height) > 0.5 else { return }
            contentHeight.wrappedValue = height
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if navigationAction.navigationType == .linkActivated,
               let url = navigationAction.request.url,
               ["https", "http", "mailto", "tel"].contains(url.scheme?.lowercased() ?? "") {
                UIApplication.shared.open(url)
            }
            // Keep the answer inline; links open through the system browser.
            let isDocumentLoad = navigationAction.navigationType == .other
                && (navigationAction.request.url?.absoluteString == "about:blank"
                    || navigationAction.request.url == baseURL)
            decisionHandler(isDocumentLoad ? .allow : .cancel)
        }
    }
}
