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
