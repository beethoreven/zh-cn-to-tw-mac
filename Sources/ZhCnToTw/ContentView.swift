import SwiftUI

struct ContentView: View {
    @EnvironmentObject var ocrManager: OCRServiceManager
    @State private var reloadToken = UUID()

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
                Button(action: { reloadToken = UUID() }) {
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

            if let port = ocrManager.port {
                WebView(url: desktopURL(ocrPort: port), reloadToken: reloadToken)
            } else {
                VStack(spacing: 8) {
                    ProgressView()
                    Text("本機 OCR 服務啟動中…")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 900, minHeight: 700)
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
