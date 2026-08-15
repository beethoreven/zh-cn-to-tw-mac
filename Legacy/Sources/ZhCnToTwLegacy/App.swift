import AppKit
import SwiftUI

// macOS 12- 這包的部署目標壓到 10.15（Legacy/Package.swift），SwiftUI 的
// App/Scene/WindowGroup/.commands 整組宣告式生命週期 API 都要 11.0+
// 才有（實測：對一個 platforms .v10_15 的 package 用 WindowGroup，
// swift build 直接報「'WindowGroup' is only available in macOS 11.0 or
// newer」）。13+ 那包（../../App.swift）維持原本的 App/Scene 寫法不動，
// 這包改回傳統的 NSApplicationDelegate + 手動建立的 NSWindow +
// NSHostingController，這是 10.15 那個年代 SwiftUI 唯一支援的整合方式
// （用 NSHostingController 把 SwiftUI 的 View 包進傳統 AppKit 視窗）。
//
// AppDelegate 本體（ocrManager 初始化、resolveOCRServiceExecutable、
// applicationShouldTerminateAfterLastWindowClosed/applicationWillTerminate
// 的邏輯）刻意跟 13+ 那份幾乎一字不差抄過來，不是各自維護一份——這個
// target 仍然內嵌 ocr-service（雖然 Stage 1 在這包會被鎖住不會真的用到，
// 見 ContentView.swift 的 osTier），是為了不用去動
// resolveOCRServiceExecutable 那個「找不到就 fatalError」的邏輯：拆掉
// ocr-service 打包會讓這包一啟動就當掉，除非同時把那段防呆邏輯也改掉。
// 目前選擇「兩包都內嵌 ocr-service、犧牲一點 DMG 體積」換取改動範圍
// 最小，之後真的想瘦身再回來處理。
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
        // stdout 接到管線/檔案時無緩衝——原因跟 13+ 那份 App.swift 一樣，
        // 見那邊的說明。
        setvbuf(stdout, nil, _IONBF, 0)

        NSApp.setActivationPolicy(.regular)
        buildMainMenu()

        let contentView = ContentView().environmentObject(ocrManager)
        let hosting = NSHostingController(rootView: contentView)
        // 900x700 放大 20%，跟 13+ 那包 ContentView 的 .frame 設定同一組
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

    // Mac 慣例：關掉視窗不等於結束整個 App，跟 13+ 那包一致。
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
    // 關於後面，位置跟 13+ 那包用 .commands 放在 .appInfo 之後是同一個
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

    private static func resolveOCRServiceExecutable() -> URL {
        let bundled = Bundle.main.resourceURL?
            .appendingPathComponent("ocr-service/zh-cn-to-tw-ocr-service")
        if let bundled, FileManager.default.isExecutableFile(atPath: bundled.path) {
            return bundled
        }
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
