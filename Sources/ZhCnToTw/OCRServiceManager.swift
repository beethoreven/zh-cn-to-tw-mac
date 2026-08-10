import Foundation

/// 管理本機 zh-cn-to-tw-ocr-service subprocess 的生命週期：啟動、從 stdout
/// 讀取實際綁定的 port（絕不預先猜測或寫死，見該 repo 的設計說明）、產生
/// 只有這次啟動才知道的隨機 token、監控存活狀態、結束時確實把子行程關掉。
final class OCRServiceManager: ObservableObject {
    @Published private(set) var port: Int?
    @Published private(set) var lastError: String?

    let token: String = OCRServiceManager.generateToken()

    private let executableURL: URL
    private var process: Process?
    private var stdoutPipe: Pipe?
    private var healthCheckTimer: Timer?

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
        } catch {
            self.process = nil
            lastError = "啟動 ocr-service 失敗：\(error.localizedDescription)"
        }
    }

    /// 每次真的要用（送 PDF 去 OCR）之前呼叫一次：ocr-service 閒置超過設定
    /// 時間會自我關閉以釋放記憶體，這裡確保下一次要用時無感重新拉起，
    /// 使用者不需要重開整個 App。
    func ensureRunning() {
        if process == nil || process?.isRunning != true {
            start()
        }
    }

    func stop() {
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
