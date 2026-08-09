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

        // 開發階段用：讓這個 WKWebView 可以被 Safari 的「開發」選單掛上
        // 完整的 Web Inspector（網路請求、DOM、真正的中斷點），比自己搭的
        // console 轉送橋接看得更完整——console 轉送完全沒訊息時，代表
        // 問題可能更底層（例如某個 iframe 根本沒載入成功），需要這個
        // 才能繼續往下查。macOS 13.3 以上才有這個 API。
        if #available(macOS 13.3, *) {
            webView.isInspectable = true
        }

        webView.uiDelegate = context.coordinator

        context.coordinator.load(url: url, reloadToken: reloadToken, into: webView)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.load(url: url, reloadToken: reloadToken, into: webView)
    }

    final class Coordinator: NSObject, WKScriptMessageHandler, WKUIDelegate {
        private var lastURL: URL?
        private var lastReloadToken: UUID?

        // Google 登入用 window.open() 開一個彈出視窗跑 OAuth 流程，但
        // WKWebView 預設完全不處理 window.open()——瀏覽器都有內建的彈出
        // 視窗處理邏輯，WKWebView 沒有，不實作這個 delegate 方法的話
        // window.open() 在 JS 那端就直接失敗，Google 的 SDK 會印出
        // "Failed to open popup window... Maybe blocked by the browser?"。
        // 這裡持有已開啟的彈出視窗，避免視窗物件被提早釋放掉。
        private var popupWindows: [NSWindow] = []

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

        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            // 一定要用傳進來的同一個 configuration 物件（不能自己另外造
            // 一個新的）——window.opener/postMessage 這種跨視窗溝通機制
            // 靠的就是這個共用的 configuration/process pool，用不同的
            // configuration 建立的視窗，Google 的 SDK 完成登入後會沒辦法
            // 把結果傳回原本那個視窗。
            let popupWebView = WKWebView(frame: NSRect(x: 0, y: 0, width: 480, height: 640), configuration: configuration)
            popupWebView.uiDelegate = self
            if #available(macOS 13.3, *) {
                popupWebView.isInspectable = true
            }

            let window = NSWindow(
                contentRect: popupWebView.frame,
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "登入"
            window.contentView = popupWebView
            // 這個視窗是我們自己手動 alloc/init 出來、用 popupWindows 陣列
            // 以 ARC 管理生命週期的，不是透過 NSWindowController；一定要
            // 關掉 isReleasedWhenClosed（預設是 true），不然 AppKit 自己
            // 在 close() 時也會嘗試釋放這個視窗物件，兩邊都想釋放同一個
            // 物件，會在關閉動畫收尾、autorelease pool 清理時把它重複
            // 釋放掉，變成存取已經被釋放的記憶體，直接讓整個 App crash
            // （實測抓到：EXC_BAD_ACCESS 在
            // -[_NSWindowTransformAnimation dealloc]，正是這個典型問題）。
            window.isReleasedWhenClosed = false
            window.center()
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)

            popupWindows.append(window)
            return popupWebView
        }

        // Google 的登入流程跑完後，彈出視窗那邊的 JS 會呼叫 window.close()
        // 把自己關掉（跟一般瀏覽器完成 OAuth popup 流程後的行為一樣）。
        func webViewDidClose(_ webView: WKWebView) {
            guard let index = popupWindows.firstIndex(where: { $0.contentView === webView }) else { return }
            popupWindows[index].close()
            popupWindows.remove(at: index)
        }

        // <input type="file"> 點下去要跳出真正的檔案選擇視窗，在 macOS
        // 上一旦 WKWebView 有設定 uiDelegate（我們因為上面的登入彈出視窗
        // 需要，一定要設），內建的檔案選擇行為就不會自動生效，一定要自己
        // 實作這個方法用 NSOpenPanel 接手，不然點擊完全沒反應（這個操作
        // 本來就不會有任何 console 訊息，不管有沒有正常運作都一樣，不是
        // 判斷依據）。
        func webView(
            _ webView: WKWebView,
            runOpenPanelWith parameters: WKOpenPanelParameters,
            initiatedByFrame frame: WKFrameInfo,
            completionHandler: @escaping ([URL]?) -> Void
        ) {
            let panel = NSOpenPanel()
            panel.allowsMultipleSelection = parameters.allowsMultipleSelection
            panel.canChooseDirectories = parameters.allowsDirectories
            panel.canChooseFiles = true

            panel.begin { response in
                completionHandler(response == .OK ? panel.urls : nil)
            }
        }
    }
}
