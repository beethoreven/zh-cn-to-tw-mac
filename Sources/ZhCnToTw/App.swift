import SwiftUI
import AppKit
#if canImport(Darwin)
import Darwin
#endif

@main
struct ZhCnToTwApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appDelegate.ocrManager)
        }
        // 放在「關於」旁邊——使用者會直覺去 App 選單（第一個、以 App
        // 名稱命名的那個）底下找這類跟整個 App 生命週期有關的動作，
        // 跟「關於」「服務」「結束」放在一起最容易被找到。見
        // Uninstaller.swift 的完整說明。
        .commands {
            CommandGroup(after: .appInfo) {
                Button("解除安裝「繁化助手」…") {
                    Uninstaller.run()
                }
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let ocrManager = OCRServiceManager(executableURL: AppDelegate.resolveOCRServiceExecutable())

    func applicationDidFinishLaunching(_ notification: Notification) {
        // stdout 接到管線/檔案（不是終端機）時，C 標準函式庫預設會全緩衝，
        // print() 印出的內容要等緩衝區滿了或 process 結束才會真的寫出來——
        // 這支 App 平常是被殼（open）啟動，沒有終端機可看也就算了，但
        // 診斷問題時常常需要直接在終端機執行、把 stdout 導到檔案裡看，
        // 這時如果不關掉緩衝，關鍵的除錯訊息（例如 WebView 載入失敗的
        // 原因）可能永遠看不到、或要等到強制關閉 process 才會一次噴出來，
        // 非常誤導（實測撞過：加了好幾個理論上該印出來的 print()，卻
        // 完全看不到任何輸出，包括既有的 console 轉發除錯功能，可能也
        // 一直被這個問題悄悄影響）。改成無緩衝，這支工具輸出量很小，
        // 沒有效能疑慮。
        setvbuf(stdout, nil, _IONBF, 0)

        // 目前是用 `swift build` 產出的裸執行檔直接執行（還沒包成正式的
        // .app bundle 給 LaunchServices 開），這種啟動方式下 macOS 常常
        // 不會自動把這個視窗設成使用中/最前面的 App，導致視窗有畫面但
        // 完全收不到滑鼠/鍵盤事件（沒有 hover state、點擊沒反應）。
        // 明確要求變成一般前景 App 並取得焦點，解決這個問題；等之後包成
        // 真正的 .app 由 Finder/Dock 開啟時，這兩行是多餘但無害的。
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        // 刻意不在這裡啟動 ocr-service：它只在 Stage 1 的 OCR 那一步用得到，
        // 網頁真的要用時才會請殼把它拉起來、用完立刻關掉（見 WebView 的
        // ocrService channel）。PaddleOCR 跑完一份大檔案之後記憶體佔用不會
        // 完全還回去，關掉重開才真的收得回來，所以不讓它平白跑著。
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
