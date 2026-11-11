import AppKit
import SwiftUI

// macOS 10.15 這包的部署目標壓到 10.15（Legacy/Package.swift），SwiftUI 的
// App/Scene/WindowGroup/.commands 整組宣告式生命週期 API 都要 11.0+
// 才有（實測：對一個 platforms .v10_15 的 package 用 WindowGroup，
// swift build 直接報「'WindowGroup' is only available in macOS 11.0 or
// newer」）。11+ 那包（../../App.swift）維持原本的 App/Scene 寫法不動，
// 這包改回傳統的 NSApplicationDelegate + 手動建立的 NSWindow +
// NSHostingController，這是 10.15 那個年代 SwiftUI 唯一支援的整合方式
// （用 NSHostingController 把 SwiftUI 的 View 包進傳統 AppKit 視窗）。
//
// AppDelegate 本體（applicationShouldTerminateAfterLastWindowClosed/
// applicationWillTerminate 的邏輯）刻意跟 11+ 那份幾乎一字不差抄過來，
// 不是各自維護一份。這個 target 不內嵌 ocr-service——Stage 1 改用
// App 內嵌的 Tesseract（見 ContentView.swift 的 osTier、
// TesseractOCRManager.swift 開頭的說明），完全不需要那支 Python service。
// ContentView.swift（symlink 共用）仍然要求注入一個 OCRServiceManager
// 型別的 @EnvironmentObject，這裡繼續建立一個實例是為了滿足這個型別
// 需求，不是真的要用它——resolveOCRServiceExecutable() 找不到執行檔時
// 改成回傳一個占位路徑（不再 fatalError），因為這個 target 的
// OCRServiceManager 實例永遠不會真的呼叫 start()（script.js 對這個
// 分流走 visionOcr channel，不會呼叫 onStartOCRService）。
@main
struct ZhCnToTwLegacyMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let ocrManager = OCRServiceManager(executableURL: AppDelegate.resolveOCRServiceExecutable())
    private var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // stdout 接到管線/檔案時無緩衝——原因跟 11+ 那份 App.swift 一樣，
        // 見那邊的說明。
        setvbuf(stdout, nil, _IONBF, 0)
        Self.redirectOutputToLogFileIfNeeded()

        NSApp.setActivationPolicy(.regular)
        buildMainMenu()

        let contentView = ContentView().environmentObject(ocrManager)
        let hosting = NSHostingController(rootView: contentView)
        // 900x700 放大 20%，跟 11+ 那包 ContentView 的 .frame 設定同一組
        // 數字——這裡另外設一次是因為傳統 NSWindow 不會自動套用 SwiftUI
        // View 的 idealWidth/idealHeight 當作初始視窗大小，要自己指定。
        let window = NSWindow(contentViewController: hosting)
        window.title = "繁化助手"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 1080, height: 840))
        window.minSize = NSSize(width: 1080, height: 840)
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window

        NSApp.activate(ignoringOtherApps: true)
    }

    // Mac 慣例：關掉視窗不等於結束整個 App，跟 11+ 那包一致。
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        ocrManager.stop()
    }

    // 傳統 NSApplicationDelegate 啟動方式沒有 SwiftUI WindowGroup 附贈的
    // 那組標準選單（App/Edit/Window），要自己手動組一份，不然連
    // Cmd+C/Cmd+V/Cmd+Q 這些基本操作都可能不能用——尤其 Cmd+C/V 這種
    // 標準編輯指令的鍵盤快速鍵是靠選單項目的 keyEquivalent 才會被
    // NSApplication 攔下來轉成 copy:/paste: selector，網頁裡的輸入框
    // 要能正常剪貼，這個選單不能省。「解除安裝」放在 App 選單裡、緊接在
    // 關於後面，位置跟 11+ 那包用 .commands 放在 .appInfo 之後是同一個
    // 邏輯（見 Uninstaller.swift 的完整說明）。
    private func buildMainMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenuItem.submenu = appMenu
        appMenu.addItem(
            withTitle: "關於「繁化助手」",
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: ""
        )
        appMenu.addItem(NSMenuItem.separator())
        let uninstallItem = NSMenuItem(
            title: "解除安裝「繁化助手」…", action: #selector(AppDelegate.uninstall), keyEquivalent: ""
        )
        uninstallItem.target = self
        appMenu.addItem(uninstallItem)
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(
            withTitle: "結束「繁化助手」",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )

        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "編輯")
        editMenuItem.submenu = editMenu
        editMenu.addItem(withTitle: "復原", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(withTitle: "剪下", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "拷貝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "貼上", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "全選", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        let windowMenuItem = NSMenuItem()
        mainMenu.addItem(windowMenuItem)
        let windowMenu = NSMenu(title: "視窗")
        windowMenuItem.submenu = windowMenu
        windowMenu.addItem(
            withTitle: "縮到最小", action: #selector(NSWindow.miniaturize(_:)), keyEquivalent: "m"
        )
        windowMenu.addItem(withTitle: "關閉視窗", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = mainMenu
    }

    @objc private func uninstall() {
        Uninstaller.run()
    }

    // 這個 target 不內嵌 ocr-service，這個路徑預期就是找不到——
    // OCRServiceManager 只有真的呼叫 start() 才會嘗試用這個路徑啟動
    // subprocess，而這個 target 永遠不會呼叫（見上面的說明），找不到
    // 執行檔本身完全不影響任何實際功能，不需要 fatalError。
    /// 從 Finder／Dock 打開時 stdout、stderr 沒有接到任何地方，所有 print()
    /// （WebView 載入失敗、網頁 console 轉送、OCR 每一頁的耗時與錯誤）都
    /// 直接消失，也不會出現在 Console.app。10.15 這包的使用者手邊沒有
    /// 開發環境，出問題時只能請對方傳檔案，所以把輸出接到
    /// ~/Library/Logs/ZhCnToTw/app.log（Finder「前往」→「資料庫」→
    /// Logs 就找得到）。從終端機直接執行時維持印在終端機上，方便開發。
    /// 檔案超過 5 MB 就把舊的改名成 app.log.1，只留一份舊檔。
    private static func redirectOutputToLogFileIfNeeded() {
        guard isatty(STDOUT_FILENO) == 0 else { return }
        let fileManager = FileManager.default
        guard let library = fileManager.urls(for: .libraryDirectory, in: .userDomainMask).first else { return }
        let dir = library.appendingPathComponent("Logs/ZhCnToTw", isDirectory: true)
        let logFile = dir.appendingPathComponent("app.log")
        do {
            try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
            if let size = (try? fileManager.attributesOfItem(atPath: logFile.path))?[.size] as? NSNumber,
               size.intValue > 5 * 1024 * 1024 {
                let old = dir.appendingPathComponent("app.log.1")
                try? fileManager.removeItem(at: old)
                try fileManager.moveItem(at: logFile, to: old)
            }
        } catch {
            return
        }
        guard freopen(logFile.path, "a", stdout) != nil else { return }
        setvbuf(stdout, nil, _IONBF, 0)
        dup2(STDOUT_FILENO, STDERR_FILENO)

        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        print("\n===== \(ISO8601DateFormatter().string(from: Date())) 啟動 繁化助手 \(version)（\(build)，10.15 分流），\(os) =====")
    }

    private static func resolveOCRServiceExecutable() -> URL {
        if let devPath = ProcessInfo.processInfo.environment["OCR_SERVICE_DEV_PATH"] {
            return URL(fileURLWithPath: devPath)
        }
        return Bundle.main.resourceURL?
            .appendingPathComponent("ocr-service/zh-cn-to-tw-ocr-service")
            ?? URL(fileURLWithPath: "/nonexistent/zh-cn-to-tw-ocr-service")
    }
}
