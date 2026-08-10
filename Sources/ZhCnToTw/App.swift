import SwiftUI
import AppKit

@main
struct ZhCnToTwApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appDelegate.ocrManager)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let ocrManager = OCRServiceManager(executableURL: AppDelegate.resolveOCRServiceExecutable())

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 目前是用 `swift build` 產出的裸執行檔直接執行（還沒包成正式的
        // .app bundle 給 LaunchServices 開），這種啟動方式下 macOS 常常
        // 不會自動把這個視窗設成使用中/最前面的 App，導致視窗有畫面但
        // 完全收不到滑鼠/鍵盤事件（沒有 hover state、點擊沒反應）。
        // 明確要求變成一般前景 App 並取得焦點，解決這個問題；等之後包成
        // 真正的 .app 由 Finder/Dock 開啟時，這兩行是多餘但無害的。
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        // WKWebView 的 <script src>/<link> 這類子資源，實測發現不會確實
        // 跟著 WebView.swift 那邊 URLRequest.cachePolicy 的設定走（那個
        // 只確實影響最上層文件本身），導致改完 script.js/style.css、
        // 甚至整個 App 重開好幾次，畫面還是抓到舊版——這裡直接把整個
        // process 共用的 URLCache 容量歸零，從根本上不讓任何資源被快取，
        // 確保每次都是真的去抓伺服器上最新的內容。不影響 cookie/
        // localStorage（登入狀態靠這兩個機制存，跟 URLCache 是分開的）。
        URLCache.shared = URLCache(memoryCapacity: 0, diskCapacity: 0)

        ocrManager.start()
    }

    // Mac 慣例：關掉視窗不等於結束整個 App（跟 Safari/Mail/Finder 一致），
    // 只有 Cmd+Q 或 Dock 圖示右鍵 Quit 才會真的結束整個 App 跟底下的
    // ocr-service subprocess——Windows 版刻意不跟這裡一樣，關窗就整個結束，
    // 各自照平台慣例，不強迫兩邊行為一致。
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        ocrManager.stop()
    }

    private static func resolveOCRServiceExecutable() -> URL {
        let bundled = Bundle.main.resourceURL?
            .appendingPathComponent("ocr-service/zh-cn-to-tw-ocr-service")
        if let bundled, FileManager.default.isExecutableFile(atPath: bundled.path) {
            return bundled
        }
        // 開發模式（swift run，還沒有真正打包成 .app）：靠環境變數指到本機
        // 已經用 PyInstaller 打包好的執行檔，方便在正式做 Xcode 專案整合
        // 之前先跑通殼本身的邏輯（subprocess 管理、WKWebView 載入）。
        if let devPath = ProcessInfo.processInfo.environment["OCR_SERVICE_DEV_PATH"] {
            return URL(fileURLWithPath: devPath)
        }
        fatalError(
            "找不到 zh-cn-to-tw-ocr-service 執行檔。正式打包時應該被放進 App Bundle 的 "
                + "Resources/ocr-service/ 底下；開發階段請設定 OCR_SERVICE_DEV_PATH 環境變數"
                + "指到本機 PyInstaller 產出的執行檔。"
        )
    }
}
