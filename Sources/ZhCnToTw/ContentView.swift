import SwiftUI

struct ContentView: View {
    @EnvironmentObject var ocrManager: OCRServiceManager
    @State private var reloadToken = UUID()
    // 有工作在跑時擋掉系統睡眠，見 SystemActivityGuard 的說明。純粹是
    // ProcessInfo activity token 的包裝，不需要 SwiftUI 的變化通知
    // （@State 這裡只是用來讓這個 class 實例跨重繪存活，不是要它驅動
    // 畫面更新）。
    @State private var activityGuard = SystemActivityGuard()
    // WKWebView 背後的 Web Content process 被系統砍掉時設成 true——見
    // WebView.swift 的 webViewWebContentProcessDidTerminate。true 的
    // 時候把 WebView 整個從畫面上拆掉（連帶釋放掉可能已經不穩定的
    // WKWebView 執行個體），換成不吃任何資源的原生提示文字；使用者按
    // 重新整理才重新建立一個全新的 WebView。
    @State private var webContentProcessDied = false

    // 網頁前端整份包在 .app 裡（Resources/web/），用固定的 file:// 路徑
    // 直接載入，不再透過本機 backend 用 HTTP 供應。
    //
    // 這是刻意改過的：原本用本機 backend 供應網頁時，backend 的監聽 port
    // 是每次啟動隨機配的（避免舊 process 卡住固定 port，這個專案本機測試
    // 階段吃過很多次這種虧）。但 localStorage 是照「scheme+host+port」
    // 算 origin 的，port 每次不一樣就等於每次啟動都是全新的 origin——
    // 存在裡面的登入 session token 因此完全救不回來，變成每次開 App
    // 都要重新登入一次（實測抓到：同一個 bundle id 底下累積了三個不同
    // 的 LocalStorage 資料夾，就是這樣來的）。file:// 的路徑是 App 安裝
    // 位置決定的，同一份安裝每次啟動都一樣，origin 因此穩定，
    // localStorage 才留得住。
    //
    // 這個改動也讓本機 backend 完全不需要了：它原本除了供應網頁以外
    // 已經不再持有任何憑證（見 apiBase 的說明），現在連供應網頁這件事
    // 都不用它做，整支 143MB 的 Python backend 就不用再打包進 .app、
    // 也不用再啟動它了。
    //
    // WEB_BASE_URL_OVERRIDE 只在開發階段用：指到本機另外跑的網頁伺服器
    // （例如 python3 -m http.server），測試還沒放進 bundle 的前端改動。
    private var webURL: URL? {
        if let override = ProcessInfo.processInfo.environment["WEB_BASE_URL_OVERRIDE"],
           let url = URL(string: override) {
            return url
        }
        // 用 bundlePath（純字串）手動組路徑，不要用 Bundle.main.resourceURL
        // 這個 URL 物件去 appendingPathComponent。實測抓到：在這個環境下
        // Bundle.main.resourceURL 回傳的 URL 內部是「相對字串 + baseURL」
        // 的組合形式，不是單純的絕對路徑；這種 URL 表面上看起來正常
        // （isFileURL 也回報 true），但只要經過 URLComponents(url:
        // resolvingAgainstBaseURL: false) 這種明確不解析 baseURL 的操作
        // （desktopURL() 為了組 ?desktop=1&ocrPort=... 這些查詢參數會這樣
        // 做），那個 baseURL 就會被整個弄丟，只剩下相對的那一段字串，
        // 變成完全沒有 file:// scheme 的路徑，WKWebView 會直接回報
        // 「無法顯示URL」（WebKitErrorDomain code 101），而且從表面上
        // 看不出問題出在 URL 本身格式不對。用 bundlePath 這個純字串手動
        // 組、再用 URL(fileURLWithPath:) 建構，從源頭就是真正的絕對路徑，
        // 沒有「相對+base」這種模稜兩可的中間狀態可以被弄丟。
        let indexPath = (Bundle.main.bundlePath as NSString)
            .appendingPathComponent("Contents/Resources/web/index.html")
        return URL(fileURLWithPath: indexPath)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button(action: {
                    // 單純重新載入網頁。刻意不在這裡碰 OCR 服務：它是「用到
                    // 才開、用完就關」，網頁真的要 OCR 前會自己請殼把它拉起來
                    // （見 WebView 的 ocrService channel），使用者不需要、也
                    // 不該為了讓 OCR 能用而先按這個按鈕。
                    //
                    // webContentProcessDied 順便在這裡清掉：如果目前正顯示
                    // 的是「Web Content process 被砍掉」的提示畫面，這個按鈕
                    // 除了平常的重新整理，也要負責把 WebView 重新放回畫面上
                    // （見下面 body 的條件式渲染），兩個按鈕刻意合而為一，
                    // 使用者不用去記「現在該按哪一個」。
                    webContentProcessDied = false
                    reloadToken = UUID()
                }) {
                    Image(systemName: "arrow.clockwise")
                }
                .help("重新整理")
                Spacer()
                if let error = ocrManager.lastError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            .padding(8)

            if webContentProcessDied {
                // 不用 WebView/WKWebView 顯示這段訊息，是刻意的：這個畫面
                // 本來就是「WKWebView 背後的 process 剛被系統砍掉」之後
                // 才會出現，用純原生 SwiftUI 文字取代它，這段期間完全不
                // 需要（也不依賴）任何 WKWebView 執行個體存在，不吃額外
                // 的記憶體/process，也不會重演同一個問題。
                VStack(spacing: 8) {
                    Text("閒置超過作業系統時間上限")
                        .foregroundStyle(.secondary)
                    Text("若有放置執行之工作結果已儲存至下載資料夾")
                        .foregroundStyle(.secondary)
                    Text("請點選左上角重新整理按鍵回到系統")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let webURL {
                // 刻意不等 OCR 服務起來才顯示網頁：服務現在是「用到才開」，
                // 平常根本沒在跑，等它等於永遠等不到。網頁大部分功能
                // （登入、Stage 1 潤飾、Stage 2 校對、下載）本來就跟它無關。
                // 服務起來/關掉時的 port 變動靠 livePort 用 JS 推進頁面。
                WebView(
                    url: desktopURL(base: webURL),
                    reloadToken: reloadToken,
                    livePort: ocrManager.port,
                    onStartOCRService: { ocrManager.ensureRunning() },
                    onStopOCRService: { ocrManager.stop() },
                    onJobActivityStart: { activityGuard.start() },
                    onJobActivityStop: { activityGuard.stop() },
                    onWebContentProcessTerminated: { webContentProcessDied = true }
                )
            } else {
                VStack(spacing: 8) {
                    Text("找不到內建的網頁資源")
                        .foregroundStyle(.secondary)
                    Text("這是打包問題，請重新安裝一次")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        // 900x700 放大 20%（原本預設大小偏小）。用 idealWidth/idealHeight
        // 讓這組數字也是視窗第一次開啟時的大小，不是只當作最小值。
        .frame(minWidth: 1080, idealWidth: 1080, minHeight: 840, idealHeight: 840)
    }

    /// API 一律打 Render，本機這裡不再有任何伺服器持有憑證。
    ///
    /// 這是刻意的安全取捨：資料庫連線字串與 LLM API 金鑰只要放進使用者
    /// 拿得到的檔案裡，就一定能被取出來（程式執行時必須能解密才能用，
    /// 加密或混淆只是提高門檻，不是防護）。所以憑證留在 Render，桌面版
    /// App 只拿一個有範圍限制、可撤銷的 session token。這樣 .app 就算
    /// 直接發給別人也不含任何值錢的東西。
    ///
    /// 當初把 OCR 搬到本機是因為 PaddleOCR 會把 Render 免費方案的記憶體
    /// 打爆；LLM 呼叫與資料庫查詢對 Render 來說都很輕，留在那裡沒有負載
    /// 問題。
    ///
    /// WEB_API_BASE_OVERRIDE 只在開發階段用：指到本機跑的 backend
    /// （例如 http://127.0.0.1:5001），測試還沒部署上去的後端改動。
    private var apiBase: String {
        ProcessInfo.processInfo.environment["WEB_API_BASE_OVERRIDE"]
            ?? "https://zh-cn-to-tw-backend.onrender.com"
    }

    /// 刻意不帶 ocrPort：那個值會隨著服務開開關關一直變，寫進網址就等於
    /// 每次變動都要重新載入頁面、清掉使用者做到一半的狀態。改成由 WebView
    /// 用 JS 推進頁面的 window.__OCR_PORT__（見 WebView.updateLivePort）。
    /// ocrToken 則是整個 App 生命週期固定的，放網址沒問題。
    private func desktopURL(base: URL) -> URL {
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "desktop", value: "1"),
            URLQueryItem(name: "ocrToken", value: ocrManager.token),
            URLQueryItem(name: "apiBase", value: apiBase),
        ]
        return components.url!
    }
}
