import Foundation

/// 管理本機 zh-cn-to-tw-ocr-service subprocess 的生命週期：啟動、從 stdout
/// 讀取實際綁定的 port（絕不預先猜測或寫死，見該 repo 的設計說明）、產生
/// 只有這次啟動才知道的隨機 token、監控存活狀態、結束時確實把子行程關掉。
final class OCRServiceManager: ObservableObject {
    @Published private(set) var port: Int?
    @Published private(set) var lastError: String?

    let token: String = OCRServiceManager.generateToken()

    // 啟動逾時 + 重試：全部都在本機跑，正常情況下 process 起來、綁好
    // port、印出那一行，應該是秒等級的事——如果等超過這個時間還沒拿到
    // port，代表這次啟動大概率是卡住了（不是「還在跑只是比較慢」），
    // 直接強制關掉重來，不要無止盡等下去，也不要讓使用者永遠卡在
    // 「本機 OCR 服務啟動中」那個讀取畫面卻不知道發生什麼事。
    private static let startupTimeoutSeconds: TimeInterval = 20
    private static let maxStartupAttempts = 3

    private let executableURL: URL
    private var process: Process?
    private var stdoutPipe: Pipe?
    private var healthCheckTimer: Timer?
    private var startupTimeoutWorkItem: DispatchWorkItem?
    private var startupAttempt = 0

    init(executableURL: URL) {
        self.executableURL = executableURL
    }

    private static func generateToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    func start() {
        guard process == nil else { return }
        startupAttempt += 1

        let process = Process()
        process.executableURL = executableURL
        // OCR_SERVICE_PORT 故意不設——讓 ocr-service 自己跟作業系統要一個
        // 目前沒人用的空 port，殼從 stdout 讀實際拿到的值。這個專案本機
        // 測試階段吃過很多次「port 被舊 process 卡住」的虧，桌面 App 不能
        // 重蹈覆轍。
        process.environment = ["OCR_SERVICE_TOKEN": token]

        let stdout = Pipe()
        process.standardOutput = stdout
        self.stdoutPipe = stdout

        // readabilityHandler/terminationHandler 都是非同步 callback，
        // 可能延遲觸發——如果這個 process 已經死掉、health check 已經
        // 重新拉起一個新的 process，舊 process 這兩個 callback 才姍姍
        // 來遲，絕對不能無條件覆寫 self.port/self.process，那樣會把
        // 新 process 已經正確設好、正常運作中的狀態蓋掉，導致畫面卡在
        // 「本機 OCR 服務啟動中」但實際上新的服務其實活得好好的（實測
        // 抓到這個情境：ps 看到 process 活著、curl /health 也正常回應，
        // 但 App 畫面沒有反映出來）。用 identity 比對（=== process）
        // 確認這個 callback 還是「目前這一個」process 才生效。
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            for line in text.split(separator: "\n") {
                let prefix = "OCR_SERVICE_PORT="
                if line.hasPrefix(prefix), let value = Int(line.dropFirst(prefix.count)) {
                    DispatchQueue.main.async {
                        guard let self, self.process === process else { return }
                        self.port = value
                        self.lastError = nil
                        // 真的拿到 port 了，這次啟動成功，取消逾時保險、
                        // 重置重試計數，不要讓下一次（例如閒置後重啟）
                        // 的失敗次數繼續往上疊加。
                        self.startupTimeoutWorkItem?.cancel()
                        self.startupAttempt = 0
                    }
                }
            }
        }

        process.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async {
                guard let self, self.process === process else { return }
                self.port = nil
                self.process = nil
                if proc.terminationStatus != 0 {
                    self.lastError = "ocr-service 已結束（exit code \(proc.terminationStatus)）"
                }
            }
        }

        self.process = process
        do {
            try process.run()
            startHealthCheck()
            scheduleStartupTimeout(for: process)
        } catch {
            self.process = nil
            lastError = "啟動 ocr-service 失敗：\(error.localizedDescription)"
        }
    }

    /// process 活著（沒有走 terminationHandler 那條路）但一直沒印出
    /// port，本機服務不應該這麼慢，等超過這個時間就當它卡住了：強制
    /// 關掉、視情況自動重試。
    private func scheduleStartupTimeout(for process: Process) {
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.process === process, self.port == nil else { return }

            process.terminationHandler = nil // 我們自己主動關的，不需要再跑一次一般的終止處理
            process.terminate()
            self.process = nil
            self.stdoutPipe?.fileHandleForReading.readabilityHandler = nil

            if self.startupAttempt < Self.maxStartupAttempts {
                self.lastError = "本機 OCR 服務啟動逾時，正在重試（\(self.startupAttempt)/\(Self.maxStartupAttempts)）"
                self.start()
            } else {
                self.lastError = "本機 OCR 服務啟動逾時，已重試 \(Self.maxStartupAttempts) 次仍失敗，請按重新整理再試一次"
            }
        }
        startupTimeoutWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.startupTimeoutSeconds, execute: workItem)
    }

    /// 每次真的要用（送 PDF 去 OCR）之前呼叫一次：ocr-service 閒置超過設定
    /// 時間會自我關閉以釋放記憶體，這裡確保下一次要用時無感重新拉起，
    /// 使用者不需要重開整個 App。
    func ensureRunning() {
        if process == nil || process?.isRunning != true {
            start()
        }
    }

    /// 讓使用者可以手動重新觸發啟動流程（例如按重新整理），不受
    /// maxStartupAttempts 已經用完的限制——那個上限是防止自動重試無止盡
    /// 空轉，不是要擋住使用者自己主動要求再試一次。
    func retryStart() {
        startupAttempt = 0
        lastError = nil
        start()
    }

    func stop() {
        startupTimeoutWorkItem?.cancel()
        startupTimeoutWorkItem = nil
        healthCheckTimer?.invalidate()
        healthCheckTimer = nil
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        process?.terminate()
        process = nil
        port = nil
    }

    private func startHealthCheck() {
        healthCheckTimer?.invalidate()
        healthCheckTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.ensureRunning()
        }
    }
}
