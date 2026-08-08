import SwiftUI
import WebKit

/// 包一層 WKWebView，避免 reloadToken/url 沒真的變也重新 load 一次
/// （SwiftUI 狀態變化會頻繁重新呼叫 updateNSView）。
struct WebView: NSViewRepresentable {
    let url: URL
    let reloadToken: UUID

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let webView = WKWebView()
        context.coordinator.load(url: url, reloadToken: reloadToken, into: webView)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.load(url: url, reloadToken: reloadToken, into: webView)
    }

    final class Coordinator {
        private var lastURL: URL?
        private var lastReloadToken: UUID?

        func load(url: URL, reloadToken: UUID, into webView: WKWebView) {
            guard url != lastURL || reloadToken != lastReloadToken else { return }
            lastURL = url
            lastReloadToken = reloadToken
            webView.load(URLRequest(url: url))
        }
    }
}
