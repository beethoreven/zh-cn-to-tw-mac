import SwiftUI

struct ContentView: View {
    @EnvironmentObject var ocrManager: OCRServiceManager
    @State private var reloadToken = UUID()

    // 桌面殼載入的是目前上線的 GitHub Pages 網址（不是內嵌網頁資源），前端
    // 改版不需要重新發版整個桌面 App——見 desktop_app_plan 設計文件。如果
    // 之後網站關站、改成殼直接內嵌網頁資源，這裡要換成本機 bundle 裡的
    // file:// 路徑。
    private let webBaseURL = URL(string: "https://beethoreven.github.io/zh-cn-to-tw-web/")!

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
