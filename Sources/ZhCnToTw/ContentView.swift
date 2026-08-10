import SwiftUI

struct ContentView: View {
    @EnvironmentObject var ocrManager: OCRServiceManager
    @State private var reloadToken = UUID()
    // 一旦拿到第一次成功的 port 就固定住，之後 ocrManager.port 若因為
    // ocr-service 短暫掛掉、重啟（甚至換了新 port）而變動，WebView 都
    // 不會因此被砍掉重建——不然使用者畫面上所有還沒存的東西（表單填到
    // 一半、Stage 1/2 還沒下載的結果）會直接消失。ocr-service 真的斷線
    // 的話，使用者點「上傳」之類需要它的操作會看到 API 失敗的錯誤，這是
    // 可以接受的（中斷那個操作沒關係），但不能整個畫面被拔掉重來。
    @State private var stableOcrPort: Int?

    // 桌面殼載入的是目前上線的 GitHub Pages 網址（不是內嵌網頁資源），前端
    // 改版不需要重新發版整個桌面 App——見 desktop_app_plan 設計文件。如果
    // 之後網站關站、改成殼直接內嵌網頁資源，這裡要換成本機 bundle 裡的
    // file:// 路徑。
    //
    // WEB_BASE_URL_OVERRIDE 只在開發階段用：指到本機跑的
    // `python3 -m http.server` 網址（例如 http://localhost:8123/），
    // 這樣本機測試時載入的前端才會是還沒 push 上 GitHub Pages 的最新
    // 程式碼；script.js 本身已經會偵測 hostname 是 localhost/127.0.0.1
    // 就自動改打本機 backend（127.0.0.1:5001），不需要在這裡額外處理。
    private let webBaseURL: URL = {
        if let override = ProcessInfo.processInfo.environment["WEB_BASE_URL_OVERRIDE"],
           let url = URL(string: override) {
            return url
        }
        return URL(string: "https://beethoreven.github.io/zh-cn-to-tw-web/")!
    }()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button(action: {
                    // 手動重新整理時，順便換成目前最新的 port（例如
                    // ocr-service 中途重啟換了新 port）——這是使用者
                    // 自己主動選擇要重新載入，接受這次會是全新的頁面
                    // 狀態，跟「服務自己掛掉時不該自動砍畫面」是兩回事。
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

            if let port = stableOcrPort {
                WebView(url: desktopURL(ocrPort: port), reloadToken: reloadToken)
            } else {
                VStack(spacing: 8) {
                    ProgressView()
                    Text("本機 OCR 服務啟動中…")
                        .foregroundStyle(.secondary)
                    // ocrManager 內部有 20 秒逾時 + 最多 3 次自動重試（見
                    // OCRServiceManager.swift），這裡的按鈕是自動重試都
                    // 用完之後，給使用者一個手動再試一次的辦法，不用逼
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
            // 只在「第一次」拿到 port 時採用，之後 ocrManager.port 的
            // 任何變動（服務重啟、暫時斷線變 nil）都不會再動到已經固定
            // 住的 stableOcrPort，見上面 stableOcrPort 的宣告說明。
            if stableOcrPort == nil, let newPort {
                stableOcrPort = newPort
            }
        }
        .onAppear {
            // onChange 只會在「這個 View 已經至少 render 過一次之後、值
            // 才真的改變」才會觸發——如果 ocr-service 啟動得夠快，
            // applicationDidFinishLaunching 呼叫 ocrManager.start() 到
            // 真正報回 port，可能比 SwiftUI 第一次 render 這個畫面還快，
            // 這種情況下 port 從一開始就已經是「有值」的狀態，onChange
            // 完全不會觸發（它只認「有沒有變」，不認「現在是什麼值」），
            // stableOcrPort 就會永遠卡在 nil，畫面卡死在讀取畫面——即使
            // ocr-service 本身其實完全正常（實測抓到：process 活著、
            // port 有在監聽、curl /health 也正常回應，問題純粹出在這裡
            // 沒有把已經存在的值撈出來）。onAppear 補上這個「一開始就
            // 已經有值」的情況。
            if stableOcrPort == nil, let currentPort = ocrManager.port {
                stableOcrPort = currentPort
            }
        }
    }

    private func desktopURL(ocrPort: Int) -> URL {
        var components = URLComponents(url: webBaseURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "desktop", value: "1"),
            URLQueryItem(name: "ocrPort", value: String(ocrPort)),
            URLQueryItem(name: "ocrToken", value: ocrManager.token),
        ]
        return components.url!
    }
}
