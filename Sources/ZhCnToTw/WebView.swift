import SwiftUI
import WebKit

/// 包一層 WKWebView，避免 reloadToken/url 沒真的變也重新 load 一次
/// （SwiftUI 狀態變化會頻繁重新呼叫 updateNSView）。
struct WebView: NSViewRepresentable {
    let url: URL
    let reloadToken: UUID

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        let contentController = WKUserContentController()

        // 開發階段用：把網頁的 console.log/warn/error 轉送到這個 App 的
        // stdout，方便診斷像「按鈕點了沒反應」這種、WKWebView 本身沒有
        // 內建可直接看的開發者工具的問題，不需要另外開 Safari 掛
        // Web Inspector 才能看到網頁那邊實際發生什麼事。
        let consoleScript = """
        (function () {
          function forward(level, args) {
            try {
              var msg = Array.prototype.slice.call(args).map(function (a) {
                try { return typeof a === 'string' ? a : JSON.stringify(a); }
                catch (e) { return String(a); }
              }).join(' ');
              window.webkit.messageHandlers.consoleLog.postMessage(level + ': ' + msg);
            } catch (e) {}
          }
          ['log', 'warn', 'error', 'info'].forEach(function (level) {
            var original = console[level];
            console[level] = function () {
              forward(level, arguments);
              original.apply(console, arguments);
            };
          });
          window.addEventListener('error', function (e) {
            forward('window.onerror', [e.message + ' @ ' + e.filename + ':' + e.lineno]);
          });
        })();
        """
        let userScript = WKUserScript(
            source: consoleScript, injectionTime: .atDocumentStart, forMainFrameOnly: false
        )
        contentController.addUserScript(userScript)
        contentController.add(context.coordinator, name: "consoleLog")
        configuration.userContentController = contentController

        let webView = WKWebView(frame: .zero, configuration: configuration)
        context.coordinator.load(url: url, reloadToken: reloadToken, into: webView)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.load(url: url, reloadToken: reloadToken, into: webView)
    }

    final class Coordinator: NSObject, WKScriptMessageHandler {
        private var lastURL: URL?
        private var lastReloadToken: UUID?

        func load(url: URL, reloadToken: UUID, into webView: WKWebView) {
            guard url != lastURL || reloadToken != lastReloadToken else { return }
            lastURL = url
            lastReloadToken = reloadToken
            webView.load(URLRequest(url: url))
        }

        func userContentController(
            _ userContentController: WKUserContentController, didReceive message: WKScriptMessage
        ) {
            print("[webview-console] \(message.body)")
        }
    }
}
