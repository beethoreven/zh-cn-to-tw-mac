import SwiftUI

struct ContentView: View {
    @EnvironmentObject var ocrManager: OCRServiceManager
    @State private var reloadToken = UUID()

    // 一旦拿到第一次成功的 port 就固定住，之後 ocrManager.port 若因為
    // 服務短暫掛掉、重啟（甚至換了新 port）而變動，WebView 都不會因此被砍掉
    // 重建——不然使用者畫面上所有還沒存的東西（表單填到一半、Stage 1/2 還沒
    // 下載的結果）會直接消失。服務真的斷線的話，使用者的操作會看到 API 失敗
    // 的錯誤，這是可以接受的（中斷那個操作沒關係），但不能整個畫面被拔掉重來。
    @State private var stableOcrPort: Int?

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
                    // 手動重新整理時，順便換成目前最新的 OCR port（例如
                    // ocr-service 中途重啟換了新 port）——這是使用者自己
                    // 主動選擇要重新載入，接受這次會是全新的頁面狀態，
                    // 跟「服務自己掛掉時不該自動砍畫面」是兩回事。
                    if let currentPort = ocrManager.port {
                        stableOcrPort = currentPort
                    }
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

            if let ocrPort = stableOcrPort, let webURL {
                WebView(url: desktopURL(base: webURL, ocrPort: ocrPort), reloadToken: reloadToken)
            } else {
                VStack(spacing: 8) {
                    ProgressView()
                    Text("本機 OCR 服務啟動中…")
                        .foregroundStyle(.secondary)
                    // ocrManager 內部有逾時 + 自動重試，這裡的按鈕是自動
                    // 重試都用完之後，給使用者一個手動再試一次的辦法，不用逼
                    // 使用者重開整個 App。
                    if ocrManager.lastError != nil {
                        Button("重試") { ocrManager.retryStart() }
                            .padding(.top, 4)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        // 900x700 放大 20%（原本預設大小偏小）。用 idealWidth/idealHeight
        // 讓這組數字也是視窗第一次開啟時的大小，不是只當作最小值。
        .frame(minWidth: 1080, idealWidth: 1080, minHeight: 840, idealHeight: 840)
        .onChange(of: ocrManager.port) { newPort in
            if stableOcrPort == nil, let newPort {
                stableOcrPort = newPort
            }
        }
        .onAppear {
            // onChange 只會在「這個 View 已經至少 render 過一次之後、值才真的
            // 改變」才會觸發——如果服務啟動得夠快，applicationDidFinishLaunching
            // 呼叫 start() 到真正報回 port，可能比 SwiftUI 第一次 render 這個
            // 畫面還快，這種情況下 port 從一開始就已經是「有值」的狀態，
            // onChange 完全不會觸發（它只認「有沒有變」，不認「現在是什麼
            // 值」），畫面就會永遠卡在讀取狀態——即使服務本身其實完全正常
            // （實測抓過這個情境）。onAppear 補上這個「一開始就已經有值」
            // 的情況。
            if stableOcrPort == nil, let currentPort = ocrManager.port {
                stableOcrPort = currentPort
            }
        }
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

    private func desktopURL(base: URL, ocrPort: Int) -> URL {
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "desktop", value: "1"),
            URLQueryItem(name: "ocrPort", value: String(ocrPort)),
            URLQueryItem(name: "ocrToken", value: ocrManager.token),
            URLQueryItem(name: "apiBase", value: apiBase),
        ]
        return components.url!
    }
}
