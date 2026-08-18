// swift-tools-version:5.9
import PackageDescription

// macOS 10.15 那包（見 zh-cn-to-tw-mac/README 的「版本分流」說明）。
// 跟根目錄的 Package.swift（11+，platforms .v11）刻意是兩個獨立的
// SwiftPM package，不是同一個 package 裡的兩個 target——SwiftPM 的
// platforms 是整個 package 共用一份，沒有 per-target 的部署目標，
// 沒辦法在同一個 Package.swift 裡讓兩個 target 各自要求不同的最低
// 系統版本。
//
// 大部分原始碼（ContentView/WebView/GoogleDesktopSignIn/
// OCRServiceManager/SystemActivityGuard/Uninstaller）用符號連結指回
// ../Sources/ZhCnToTw/ 底下同一份檔案，不是複製一份維護兩份——這些檔案
// 本身已經用 #available/@available 處理過兩包各自的版本差異（見
// WebView.swift 裡 WKDownloadDelegate 那段 extension 的說明）。真正
// 只有這個 target 專屬的只有 App.swift（進入點本身用傳統
// NSApplicationDelegate，不是 SwiftUI 的 App/Scene——那組 API 要
// 11.0+，見 App.swift 開頭的說明）。
let package = Package(
    name: "ZhCnToTwLegacy",
    platforms: [.macOS(.v10_15)],
    targets: [
        .executableTarget(
            name: "ZhCnToTwLegacy",
            path: "Sources/ZhCnToTwLegacy",
            // ContentView.swift 用這個 flag 判斷自己是哪一包（osTier），
            // 藉此決定要送哪個 os_version 給 version_check API、本機
            // OCR 要走 HTTP 輪詢還是 visionOcr message channel——見
            // ContentView.swift 的 osTier 說明。根目錄那個 11+ target
            // 沒有定義這個 flag，同一份原始碼在那邊會走 #else 分支。
            swiftSettings: [.define("LEGACY_BUILD")]
        )
    ]
)
