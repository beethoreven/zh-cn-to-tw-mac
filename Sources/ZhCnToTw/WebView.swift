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
        // 桌面版登入改用系統瀏覽器（見 GoogleDesktopSignIn.swift 的說明），
        // 網頁那邊偵測到 desktop=1 時會呼叫這個 channel 請殼開始登入流程，
        // 不再使用 Google Identity Services 在內嵌 WebView 裡的彈出視窗。
        contentController.add(context.coordinator, name: "desktopSignIn")
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
        webView.navigationDelegate = context.coordinator

        context.coordinator.load(url: url, reloadToken: reloadToken, into: webView)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.load(url: url, reloadToken: reloadToken, into: webView)
    }

    final class Coordinator: NSObject, WKScriptMessageHandler, WKUIDelegate, WKNavigationDelegate, WKDownloadDelegate {
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
            // WKWebView 有自己的持久化快取（跟 Safari 一樣存在硬碟上，
            // 重開整個 App process 不會清掉）。桌面殼載入的是線上網址，
            // 整個設計的前提就是「前端改版不用重新發版桌面 App」——如果
            // WebView 用舊快取的 CSS/JS，這個前提就不成立了。明確要求
            // 略過本機快取、每次都真的去抓最新版本（實測發現：重開整個
            // App 好幾次，畫面還是抓到舊版 CSS，就是這裡沒做的緣故）。
            var request = URLRequest(url: url)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            webView.load(request)
        }

        private var activeSignIn: GoogleDesktopSignIn?

        func userContentController(
            _ userContentController: WKUserContentController, didReceive message: WKScriptMessage
        ) {
            switch message.name {
            case "desktopSignIn":
                startDesktopSignIn(for: message.webView)
            default:
                print("[webview-console] \(message.body)")
            }
        }

        private func startDesktopSignIn(for webView: WKWebView?) {
            guard let webView else { return }
            let signIn = GoogleDesktopSignIn()
            activeSignIn = signIn
            signIn.start { [weak self] result in
                self?.activeSignIn = nil
                switch result {
                case .success(let idToken):
                    // 網頁那邊原本 Google Identity Services 登入成功時就是
                    // 呼叫這個函式（見 script.js 的 handleCredentialResponse）
                    // ——直接沿用同一套邏輯（存 token、驗證、更新 UI），系統
                    // 瀏覽器登入完成後只是換一種方式把 token 交回網頁，
                    // 後續流程完全不用另外重寫一份。
                    let escaped = idToken.replacingOccurrences(of: "'", with: "\\'")
                    webView.evaluateJavaScript("handleCredentialResponse({credential: '\(escaped)'})")
                    // 登入是在系統瀏覽器完成的，使用者這時候人在瀏覽器那邊；
                    // window.close() 不保證能關掉那個分頁（瀏覽器對非 JS
                    // 開的分頁通常會擋），所以主動把這個 App 切回前景，
                    // 不管瀏覽器分頁關不關得掉，使用者都不用自己手動切換
                    // 回來。
                    NSApp.activate(ignoringOtherApps: true)
                case .failure(let error):
                    print("[desktop-signin] 失敗：\(error)")
                    webView.evaluateJavaScript(
                        "window.alert && window.alert('登入失敗，請重試（\(String(describing: error))）')"
                    )
                }
            }
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

        // 下載按鈕（例如「下載校對後成果」）背後是 fetch 拿到 blob 再用
        // <a download href="blob:..."> 模擬點擊觸發下載，這是一般瀏覽器
        // 支援的標準做法，但 WKWebView 預設不知道怎麼處理這種下載型的
        // 導覽，點了完全沒反應——要靠 shouldPerformDownload 偵測到這類
        // 導覽，明確交給 WKDownload 處理，才會真的觸發下載（跟今晚檔案
        // 選擇按鈕、登入彈出視窗是同一種「WKWebView 沒有瀏覽器內建行為，
        // 要自己實作對應 delegate 方法」的問題）。
        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            decisionHandler(navigationAction.shouldPerformDownload ? .download : .allow)
        }

        func webView(
            _ webView: WKWebView,
            navigationAction: WKNavigationAction,
            didBecome download: WKDownload
        ) {
            download.delegate = self
        }

        func download(
            _ download: WKDownload,
            decideDestinationUsing response: URLResponse,
            suggestedFilename: String,
            completionHandler: @escaping (URL?) -> Void
        ) {
            // 直接存到使用者的「下載項目」資料夾，跟一般瀏覽器預設行為
            // 一致，不特別跳存檔視窗；檔名如果已存在就加上流水號，避免
            // 覆蓋掉使用者之前下載的同名檔案。
            let downloadsDir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            guard let downloadsDir else {
                completionHandler(nil)
                return
            }
            completionHandler(Self.uniqueDestination(in: downloadsDir, filename: suggestedFilename))
        }

        func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
            print("[webview-download] 失敗：\(error)")
        }

        func downloadDidFinish(_ download: WKDownload) {
            print("[webview-download] 完成")
        }

        private static func uniqueDestination(in directory: URL, filename: String) -> URL {
            let ext = (filename as NSString).pathExtension
            let base = (filename as NSString).deletingPathExtension
            var candidate = directory.appendingPathComponent(filename)
            var suffix = 1
            while FileManager.default.fileExists(atPath: candidate.path) {
                let numbered = ext.isEmpty ? "\(base) (\(suffix))" : "\(base) (\(suffix)).\(ext)"
                candidate = directory.appendingPathComponent(numbered)
                suffix += 1
            }
            return candidate
        }
    }
}
