import SwiftUI
import WebKit

/// 包一層 WKWebView，避免 reloadToken/url 沒真的變也重新 load 一次
/// （SwiftUI 狀態變化會頻繁重新呼叫 updateNSView）。
struct WebView: NSViewRepresentable {
    let url: URL
    let reloadToken: UUID
    /// ocr-service 目前實際在聽的 port，沒在跑的時候是 nil。這個值會在
    /// 服務起來/關掉時變動，WebView 用 JS 把它推進頁面（window.__OCR_PORT__），
    /// 網頁不用重新載入就能知道現在該打哪個 port——刻意不靠網址上的查詢
    /// 參數，那個值改了就等於要重新載入頁面，會清掉使用者做到一半的狀態。
    let livePort: Int?

    /// 網頁要求啟動本機 OCR 服務（使用者按下上傳、真的要用了才會呼叫）。
    let onStartOCRService: () -> Void
    /// 網頁通知 OCR 階段已經結束、結果也拿走了，可以把服務關掉釋放記憶體。
    let onStopOCRService: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onStartOCRService: onStartOCRService, onStopOCRService: onStopOCRService)
    }

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
        // 網頁在真的要用 OCR 前後，透過這個 channel 請殼開/關本機 OCR 服務。
        contentController.add(context.coordinator, name: "ocrService")
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

        context.coordinator.livePort = livePort
        context.coordinator.load(url: url, reloadToken: reloadToken, into: webView)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.load(url: url, reloadToken: reloadToken, into: webView)
        context.coordinator.updateLivePort(livePort, in: webView)
    }

    final class Coordinator: NSObject, WKScriptMessageHandler, WKUIDelegate, WKNavigationDelegate, WKDownloadDelegate {
        private let onStartOCRService: () -> Void
        private let onStopOCRService: () -> Void

        init(onStartOCRService: @escaping () -> Void, onStopOCRService: @escaping () -> Void) {
            self.onStartOCRService = onStartOCRService
            self.onStopOCRService = onStopOCRService
        }

        private var lastURL: URL?
        private var lastReloadToken: UUID?

        /// 目前最新的 ocr-service port（服務沒在跑時是 nil），跟已經推進
        /// 頁面的那個值分開記：頁面重新載入（或還在載入中）時 window 上的
        /// 變數會消失，所以 didFinish 之後要能重推一次，這裡必須留著最新值。
        var livePort: Int?
        private var pushedPort: Int?
        /// 分辨「還沒推過任何值」跟「推過、而且推的就是 nil」——服務關掉時
        /// 要主動把頁面上的值清成 null，不然網頁會拿著一個已經沒人在聽的
        /// port 一直重試。光看 pushedPort 是不是 nil 沒辦法分辨這兩種情況。
        private var hasPushedAnyValue = false

        // Google 登入用 window.open() 開一個彈出視窗跑 OAuth 流程，但
        // WKWebView 預設完全不處理 window.open()——瀏覽器都有內建的彈出
        // 視窗處理邏輯，WKWebView 沒有，不實作這個 delegate 方法的話
        // window.open() 在 JS 那端就直接失敗，Google 的 SDK 會印出
        // "Failed to open popup window... Maybe blocked by the browser?"。
        // 這裡持有已開啟的彈出視窗，避免視窗物件被提早釋放掉。
        private var popupWindows: [NSWindow] = []

        /// 把最新的 port 寫進頁面的 window.__OCR_PORT__（見 zh-cn-to-tw-web
        /// 的 script.js 的 desktopOcrBase()）。刻意不重新載入頁面——服務自己
        /// 閒置關閉再被拉起是背景行為，不該把使用者做到一半的工作狀態清掉。
        func updateLivePort(_ port: Int?, in webView: WKWebView) {
            livePort = port
            // 頁面還在載入中就先不推：這時候推進去的是舊 document 的 window，
            // 新頁面載好後會被整個換掉。didFinish 會再呼叫一次補上。
            guard !webView.isLoading else { return }
            guard !hasPushedAnyValue || port != pushedPort else { return }
            hasPushedAnyValue = true
            pushedPort = port
            let value = port.map(String.init) ?? "null"
            webView.evaluateJavaScript("window.__OCR_PORT__ = \(value);") { _, error in
                if let error {
                    print("[webview-ocr-port] 寫入失敗（\(value)）：\(error)")
                } else {
                    print("[webview-ocr-port] 已推送 \(value) 進頁面")
                }
            }
        }

        func load(url: URL, reloadToken: UUID, into webView: WKWebView) {
            guard url != lastURL || reloadToken != lastReloadToken else { return }
            lastURL = url
            lastReloadToken = reloadToken
            // 要載入新頁面了，舊 document 上的 window.__OCR_PORT__ 會跟著消失，
            // 這裡把「已推送」狀態歸零，didFinish 才會重新推一次。
            pushedPort = nil
            hasPushedAnyValue = false

            if url.isFileURL {
                // 網頁前端現在是包在 .app 裡直接用 file:// 載入（見
                // ContentView.swift 的說明：改用固定的 file:// origin 是
                // 為了讓 localStorage 裡存的登入 session token 能跨次啟動
                // 保留下來）。file:// 一定要用 loadFileURL，WKWebView.load
                // (URLRequest) 不支援載入本機檔案。allowingReadAccessTo
                // 給整個 web/ 目錄（不是只給這個檔案），因為 index.html
                // 還會用相對路徑載入同目錄下的 script.js/style.css 等。
                //
                // 這裡的 url 已經帶了 ?desktop=1&ocrPort=... 這些查詢參數
                // （見 ContentView.swift 的 desktopURL()），如果直接對它
                // 呼叫 deletingLastPathComponent()，拿到的「目錄」URL尾巴
                // 還會黏著整串查詢字串（file:///.../web/?desktop=1&...），
                // 不是乾淨的目錄路徑，WKWebView 對這種格式不對的授權目錄
                // 會直接靜默失敗、整個頁面停在 about:blank（實測抓到）。
                // 用 url.path 先拿掉查詢字串、重新組一個乾淨的 file URL，
                // 再取父目錄，allowingReadAccessTo 才會是真正合法的目錄。
                let cleanFileURL = URL(fileURLWithPath: url.path)
                webView.loadFileURL(url, allowingReadAccessTo: cleanFileURL.deletingLastPathComponent())
                return
            }

            // WKWebView 有自己的持久化快取（跟 Safari 一樣存在硬碟上，
            // 重開整個 App process 不會清掉）。過去桌面殼載入的是線上
            // 網址，整個設計的前提是「前端改版不用重新發版桌面 App」——
            // 如果 WebView 用舊快取的 CSS/JS，這個前提就不成立了。明確
            // 要求略過本機快取、每次都真的去抓最新版本（實測發現：重開
            // 整個 App 好幾次，畫面還是抓到舊版 CSS，就是這裡沒做的
            // 緣故）。file:// 走上面那個分支，不會經過這裡。
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
            case "ocrService":
                // 本機 OCR 服務改成「用到才開、用完就關」：它只在 Stage 1 的
                // OCR 那一步派得上用場，其他時候（潤飾、Stage 2 校對、下載、
                // 登入）完全沒事做，跑著只是白佔記憶體——而且 PaddleOCR 跑完
                // 一份大檔案之後佔用不會完全還回去，關掉重開才真的收得回來。
                let action = (message.body as? [String: Any])?["action"] as? String
                switch action {
                case "start": onStartOCRService()
                case "stop": onStopOCRService()
                default: print("[webview-ocr-service] 不認得的指令：\(message.body)")
                }
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

        // JS 的 alert()/confirm()/prompt() 在 WKWebView 裡預設完全沒有
        // UI 顯示——不是跳出來又太快消失，是根本不會出現，呼叫了就像
        // 什麼事都沒發生一樣，要自己用 NSAlert 接手才會真的顯示。這個
        // 專案的 script.js 目前有 9 處用 alert() 顯示驗證錯誤/操作結果
        // （例如「請先選擇 PDF 檔案」），這幾個提示在桌面版原本應該完全
        // 靜默失效，屬於同一批「WKWebView 沒有瀏覽器內建行為」的問題，
        // 一次補齊，避免之後在別的地方（例如管理員介面的刪除確認）用到
        // confirm() 又重踩一次同一種坑。
        // 這三個都用 NSAlert.runModal()，會整個卡住等使用者按按鈕才繼續
        // ——明確把 Return/Escape 都設成鍵盤可以觸發的按鈕（不能只靠
        // NSAlert 預設行為，要確定使用者「一定有辦法讓這個視窗消失」，
        // 不會卡在一個看不到、或不知道要點哪裡的視窗前面出不來）。
        func webView(
            _ webView: WKWebView,
            runJavaScriptAlertPanelWithMessage message: String,
            initiatedByFrame frame: WKFrameInfo,
            completionHandler: @escaping () -> Void
        ) {
            let alert = NSAlert()
            alert.messageText = message
            let ok = alert.addButton(withTitle: "好")
            ok.keyEquivalent = "\r"
            // 只有一個按鈕時，Escape 也讓它視同被按下，不強迫使用者
            // 一定要用滑鼠點到那顆按鈕才能繼續。
            NSApp.activate(ignoringOtherApps: true)
            alert.window.makeKeyAndOrderFront(nil)
            alert.runModal()
            completionHandler()
        }

        func webView(
            _ webView: WKWebView,
            runJavaScriptConfirmPanelWithMessage message: String,
            initiatedByFrame frame: WKFrameInfo,
            completionHandler: @escaping (Bool) -> Void
        ) {
            let alert = NSAlert()
            alert.messageText = message
            let confirmBtn = alert.addButton(withTitle: "確定")
            let cancelBtn = alert.addButton(withTitle: "取消")
            confirmBtn.keyEquivalent = "\r"
            cancelBtn.keyEquivalent = "\u{1b}" // Escape 一定要能讓視窗消失
            NSApp.activate(ignoringOtherApps: true)
            alert.window.makeKeyAndOrderFront(nil)
            completionHandler(alert.runModal() == .alertFirstButtonReturn)
        }

        func webView(
            _ webView: WKWebView,
            runJavaScriptTextInputPanelWithPrompt prompt: String,
            defaultText: String?,
            initiatedByFrame frame: WKFrameInfo,
            completionHandler: @escaping (String?) -> Void
        ) {
            let alert = NSAlert()
            alert.messageText = prompt
            let confirmBtn = alert.addButton(withTitle: "確定")
            let cancelBtn = alert.addButton(withTitle: "取消")
            confirmBtn.keyEquivalent = "\r"
            cancelBtn.keyEquivalent = "\u{1b}"
            let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
            input.stringValue = defaultText ?? ""
            alert.accessoryView = input
            NSApp.activate(ignoringOtherApps: true)
            alert.window.makeKeyAndOrderFront(nil)
            completionHandler(alert.runModal() == .alertFirstButtonReturn ? input.stringValue : nil)
        }

        // 下載按鈕（例如「下載校對後成果」）背後是 fetch 拿到 blob 再用
        // <a download href="blob:..."> 模擬點擊觸發下載，這是一般瀏覽器
        // 支援的標準做法，但 WKWebView 預設不知道怎麼處理這種下載型的
        // 導覽，點了完全沒反應——要靠 shouldPerformDownload 偵測到這類
        // 導覽，明確交給 WKDownload 處理，才會真的觸發下載（跟今晚檔案
        // 選擇按鈕、登入彈出視窗是同一種「WKWebView 沒有瀏覽器內建行為，
        // 要自己實作對應 delegate 方法」的問題）。
        //
        // 另外：這個殼沒有網址列、沒有上一頁按鈕，如果頁面上出現連到
        // 別的網域的連結（目前 index.html 裡沒有，但之後可能會加，例如
        // 說明文件連結），使用者點下去如果讓這個 WebView 直接導覽過去，
        // 會被困在別的網站、沒有正常方式回到 App 本身——改成偵測到
        // 「使用者點擊連結」且目標網域跟目前頁面不同時，改用系統瀏覽器
        // 開啟，這個 WebView 本身留在原地不動。
        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            if navigationAction.shouldPerformDownload {
                decisionHandler(.download)
                return
            }
            if navigationAction.navigationType == .linkActivated,
               let targetURL = navigationAction.request.url,
               let targetHost = targetURL.host,
               let currentHost = webView.url?.host,
               targetHost != currentHost {
                NSWorkspace.shared.open(targetURL)
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }

        func webView(
            _ webView: WKWebView,
            navigationAction: WKNavigationAction,
            didBecome download: WKDownload
        ) {
            download.delegate = self
        }

        // 這三個原本完全沒實作——load(url:) 呼叫 loadFileURL 之後，如果
        // 載入失敗，WKWebView 不會拋出 Swift 例外、也不會出現在畫面上，
        // 就是靜默停在 about:blank。沒有這幾個 delegate 方法，這種失敗
        // 完全看不到（實測撞過：換了新的 allowingReadAccessTo 邏輯後
        // 畫面還是空的，只能靠這裡印出來的錯誤才知道問題出在哪）。
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            print("[webview-nav] 載入失敗（provisional）：\(error)")
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            print("[webview-nav] 載入失敗：\(error)")
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            print("[webview-nav] 載入完成：\(webView.url?.absoluteString ?? "(nil)")")
            // 頁面（重新）載好了，window 是全新的，把目前最新的 port 補推
            // 一次——updateNSView 可能在載入途中就來過、當時被跳過了。
            updateLivePort(livePort, in: webView)
        }

        // decideDestinationUsing 選好的路徑記下來，downloadDidFinish 觸發
        // 時才知道要在 toast 裡告訴使用者存到哪裡了——WKDownload 本身沒有
        // 內建「記得自己存去哪」這件事，完成 callback 也不會帶路徑回來。
        private var downloadDestinations: [ObjectIdentifier: URL] = [:]

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
            let destination = Self.uniqueDestination(in: downloadsDir, filename: suggestedFilename)
            downloadDestinations[ObjectIdentifier(download)] = destination
            completionHandler(destination)
        }

        func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
            downloadDestinations[ObjectIdentifier(download)] = nil
            print("[webview-download] 失敗：\(error)")
            let message = "下載失敗：\(error.localizedDescription)".replacingOccurrences(of: "'", with: "\\'")
            download.webView?.evaluateJavaScript("showToast('\(message)', 'error')")
        }

        func downloadDidFinish(_ download: WKDownload) {
            guard let destination = downloadDestinations.removeValue(forKey: ObjectIdentifier(download)) else { return }
            let path = destination.path.replacingOccurrences(of: "'", with: "\\'")
            download.webView?.evaluateJavaScript("showToast('下載完成，檔案位於 \(path)', 'success')")
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
