import SwiftUI

struct ContentView: View {
    @EnvironmentObject var ocrManager: OCRServiceManager
    @EnvironmentObject var backendManager: BackendServiceManager
    @State private var reloadToken = UUID()

    // 一旦拿到第一次成功的 port 就固定住，之後這兩個 manager 的 port 若因為
    // 服務短暫掛掉、重啟（甚至換了新 port）而變動，WebView 都不會因此被砍掉
    // 重建——不然使用者畫面上所有還沒存的東西（表單填到一半、Stage 1/2 還沒
    // 下載的結果）會直接消失。服務真的斷線的話，使用者的操作會看到 API 失敗
    // 的錯誤，這是可以接受的（中斷那個操作沒關係），但不能整個畫面被拔掉重來。
    @State private var stableOcrPort: Int?
    @State private var stableBackendPort: Int?

    // 網頁介面本身現在也是由本機 backend 供應的（整份前端包在 .app 裡，
    // 見 zh-cn-to-tw-backend 的 WEB_STATIC_DIR），不再從 GitHub Pages 線上
    // 抓——網頁跟 API 因此是同一個 origin，前端用相對路徑呼叫 API 即可。
    //
    // WEB_BASE_URL_OVERRIDE 只在開發階段用：指到本機另外跑的網頁伺服器，
    // 方便測試還沒放進 bundle 的前端改動。
    private var webBaseURL: URL? {
        if let override = ProcessInfo.processInfo.environment["WEB_BASE_URL_OVERRIDE"],
           let url = URL(string: override) {
            return url
        }
        guard let backendPort = stableBackendPort else { return nil }
        return URL(string: "http://127.0.0.1:\(backendPort)/")
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button(action: {
                    // 手動重新整理時，順便換成目前最新的 port（例如某個服務
                    // 中途重啟換了新 port）——這是使用者自己主動選擇要重新
                    // 載入，接受這次會是全新的頁面狀態，跟「服務自己掛掉時
                    // 不該自動砍畫面」是兩回事。
                    if let currentPort = ocrManager.port {
                        stableOcrPort = currentPort
                    }
                    if let currentPort = backendManager.port {
                        stableBackendPort = currentPort
                    }
                    reloadToken = UUID()
                }) {
                    Image(systemName: "arrow.clockwise")
                }
                .help("重新整理")
                Spacer()
                if let error = backendManager.lastError ?? ocrManager.lastError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            .padding(8)

            if let ocrPort = stableOcrPort, let baseURL = webBaseURL {
                WebView(url: desktopURL(base: baseURL, ocrPort: ocrPort), reloadToken: reloadToken)
            } else {
                VStack(spacing: 8) {
                    ProgressView()
                    Text(loadingMessage)
                        .foregroundStyle(.secondary)
                    // 兩個 manager 內部都有逾時 + 自動重試，這裡的按鈕是自動
                    // 重試都用完之後，給使用者一個手動再試一次的辦法，不用逼
                    // 使用者重開整個 App。
                    if backendManager.lastError != nil || ocrManager.lastError != nil {
                        Button("重試") {
                            if backendManager.lastError != nil { backendManager.retryStart() }
                            if ocrManager.lastError != nil { ocrManager.retryStart() }
                        }
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
        .onChange(of: backendManager.port) { newPort in
            if stableBackendPort == nil, let newPort {
                stableBackendPort = newPort
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
            if stableBackendPort == nil, let currentPort = backendManager.port {
                stableBackendPort = currentPort
            }
        }
    }

    /// 讀取畫面上的文字要講清楚現在在等什麼，不要一律顯示同一句話——
    /// backend 第一次啟動要連 Neon（冷啟動可能近 10 秒），OCR 服務則是載入
    /// PaddleOCR 模型，兩者等待時間差很多，講明白使用者才知道是正常的。
    private var loadingMessage: String {
        if stableBackendPort == nil && stableOcrPort == nil {
            return "本機服務啟動中…"
        }
        if stableBackendPort == nil {
            return "本機主服務啟動中（首次連線資料庫可能需要幾秒）…"
        }
        return "本機 OCR 服務啟動中…"
    }

    /// API 一律打 Render，不打本機 backend——本機那支只負責供應網頁靜態
    /// 檔案，不持有任何憑證。
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
