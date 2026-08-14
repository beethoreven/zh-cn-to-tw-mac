import AppKit
import Foundation

/// 使用者從選單列觸發的解除安裝：清掉這個 App 依 Bundle Identifier
/// 存在 ~/Library 各處的資料（WebKit 的 localStorage/cookies、快取、
/// 偏好設定）——這些資料不在 .app bundle 裡面，單純把 .app 拖到垃圾桶
/// 不會連帶清掉，這是 macOS 對非沙盒 App 的一般行為，不是沒做好（只有
/// 走 App Store 沙盒 Container 的 App 才有「刪除即完整清除」的保證）。
///
/// 跟 packaging/uninstall.sh（DMG 裡給使用者雙擊執行的版本）刻意各自
/// 獨立，不是共用同一份程式碼、也不是互相呼叫：App 沒辦法一邊執行、
/// 一邊刪掉自己正在跑的 .app bundle 本身，這裡只清資料，最後一步
/// （把 .app 拖到垃圾桶）留給使用者自己做，並且用 Finder 幫忙選好
/// 該拖哪個檔案，降低漏做這一步的機率。
enum Uninstaller {
    static func run() {
        let confirm = NSAlert()
        confirm.messageText = "確定要解除安裝「繁化助手」嗎？"
        confirm.informativeText = "會清除本機儲存的登入狀態與快取資料，這個動作無法復原。"
            + "清除完成後 App 會自動結束，最後要請你自己把「繁化助手」從 Applications 拖到垃圾桶。"
        confirm.alertStyle = .warning
        confirm.addButton(withTitle: "解除安裝")
        confirm.addButton(withTitle: "取消")
        guard confirm.runModal() == .alertFirstButtonReturn else { return }

        let bundleID = Bundle.main.bundleIdentifier ?? "com.beethoreven.zh-cn-to-tw"
        let fm = FileManager.default
        let library = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library")

        var targets: [URL] = [
            library.appendingPathComponent("WebKit/\(bundleID)"),
            library.appendingPathComponent("Caches/\(bundleID)"),
            library.appendingPathComponent("Preferences/\(bundleID).plist"),
            library.appendingPathComponent("Saved Application State/\(bundleID).savedState"),
        ]

        // HTTPStorages 底下的檔名不是單純 <bundle-id>，還有
        // <bundle-id>.binarycookies_tmp_<pid>.dat 這種暫存變體，數量
        // 不固定，用前綴比對找，不能寫死成固定路徑（跟
        // packaging/uninstall.sh 用 shell glob 做的是同一件事）。
        let httpStorages = library.appendingPathComponent("HTTPStorages")
        if let entries = try? fm.contentsOfDirectory(at: httpStorages, includingPropertiesForKeys: nil) {
            targets.append(contentsOf: entries.filter { $0.lastPathComponent.hasPrefix(bundleID) })
        }

        for target in targets {
            try? fm.removeItem(at: target)
        }

        // 幫使用者把 Finder 打開、選好這個 App 本身——最後一步「拖到
        // 垃圾桶」沒辦法由 App 自己代勞（正在執行中的 .app 沒辦法刪
        // 自己），但至少不用讓使用者自己去 Applications 資料夾裡找。
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])

        let done = NSAlert()
        done.messageText = "本機資料已清除"
        done.informativeText = "最後一步：請把「繁化助手」拖到垃圾桶（Finder 已經幫你選好了）。"
        done.addButton(withTitle: "好")
        done.runModal()

        NSApp.terminate(nil)
    }
}
