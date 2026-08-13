import Foundation

/// 在真的有工作在跑（網頁的 Stage 1 或 Stage 2 任一個正在進行中）時，
/// 請系統不要把這個 App 睡掉——WKWebView 顯示網頁靠的是獨立的 Web
/// Content process，系統進入睡眠或這個 App 被晾在背景太久時，這個
/// process 常常被優先回收，導致畫面空白（見 WebView.swift 的
/// webViewWebContentProcessDidTerminate 說明）。真的有工作在跑時被
/// 打斷，代價是已經付費的 LLM 呼叫全部作廢，比單純被系統睡掉更貴，
/// 值得為了這段期間暫時擋掉系統睡眠。
///
/// 刻意只在「真的有工作進行中」這段期間生效，不是整個 App 執行期間
/// 都掛著——沒有任何工作在跑時，讓系統正常睡眠/回收資源是預期行為，
/// 沒有東西會因此遺失，沒必要為了「以防萬一」一直不讓使用者的電腦
/// 休息。也刻意只擋系統睡眠（.idleSystemSleepDisabled），不擋螢幕
/// 休眠，螢幕暗掉不影響背景工作繼續跑，沒必要整晚讓螢幕亮著。
///
/// 用計數器而不是單純的布林值：Stage 1 跟 Stage 2 可能短暫重疊進行
/// （「直接進行校對」開啟時，Stage 1 完成瞬間 Stage 2 就接著開始，
/// 兩段輪詢會短暫同時存在），用計數器才不會讓其中一個先結束時，
/// 錯誤地把另一個還在跑的工作的保護也一起解除。
final class SystemActivityGuard {
    private var activeCount = 0
    private var activityToken: NSObjectProtocol?

    func start() {
        activeCount += 1
        guard activityToken == nil else { return }
        activityToken = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled],
            reason: "Stage 1/2 工作進行中"
        )
    }

    func stop() {
        activeCount = max(0, activeCount - 1)
        guard activeCount == 0, let token = activityToken else { return }
        ProcessInfo.processInfo.endActivity(token)
        activityToken = nil
    }
}
