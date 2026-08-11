import Foundation

/// 管理本機 zh-cn-to-tw-backend subprocess 的生命週期。
///
/// 這支服務同時負責兩件事：提供網頁介面本身（HTML/CSS/JS，包在 .app 裡，
/// 不再從 GitHub Pages 線上抓）以及所有 API。網頁跟 API 因此是同一個
/// origin，前端用相對路徑呼叫即可，連 CORS 都不需要。
///
/// 它唯一會連外的三件事，都是本來就一定要連外的：Google（驗證登入
/// 憑證簽章）、Neon（資料庫）、Gemini/Anthropic（LLM API）。其餘全部
/// 在本機完成。
///
/// 行為刻意跟 OCRServiceManager 保持一致（動態 port、從 stdout 讀取實際
/// 綁定的 port、identity 比對避免舊 callback 蓋掉新狀態、啟動逾時 +
/// 自動重試），那些模式都是實測踩過坑之後定下來的，見該檔說明。
final class BackendServiceManager: ObservableObject {
    @Published private(set) var port: Int?
    @Published private(set) var lastError: String?

    // backend 啟動比 ocr-service 慢：第一次連 Neon 建立連線 + 確認 schema
    // 實測可能要近 10 秒（Neon 免費方案的運算單元會休眠，冷啟動更久），
    // 所以逾時放寬到 60 秒，不能沿用 ocr-service 的 20 秒，不然會在正常
    // 的冷啟動途中被誤判成卡住而重啟，反而永遠起不來。
    private static let startupTimeoutSeconds: TimeInterval = 60
    private static let maxStartupAttempts = 3

    private let executableURL: URL
    private var process: Process?
    private var stdoutPipe: Pipe?
    private var startupTimeoutWorkItem: DispatchWorkItem?
    private var startupAttempt = 0

    init(executableURL: URL) {
        self.executableURL = executableURL
    }

    func start() {
        guard process == nil else { return }
        startupAttempt += 1

        let process = Process()
        process.executableURL = executableURL
        // DESKTOP_SERVICE=1 讓 backend 走「桌面版」啟動路徑：跟作業系統要
        // 一個空 port、只綁 127.0.0.1、把實際 port 印到 stdout（見該 repo
        // app.py 的 __main__）。其餘設定（DATABASE_URL、API 金鑰）由執行檔
        // 旁邊的 .env 提供，不從這裡傳。
        var environment = ProcessInfo.processInfo.environment
        environment["DESKTOP_SERVICE"] = "1"
        process.environment = environment

        let stdout = Pipe()
        process.standardOutput = stdout
        self.stdoutPipe = stdout

        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            for line in text.split(separator: "\n") {
                let prefix = "BACKEND_PORT="
                if line.hasPrefix(prefix), let value = Int(line.dropFirst(prefix.count)) {
                    DispatchQueue.main.async {
                        // identity 比對：這個 callback 可能是已經被取代掉的
                        // 舊 process 遲來的通知，不能無條件覆寫目前狀態。
                        guard let self, self.process === process else { return }
                        self.port = value
                        self.lastError = nil
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
                    self.lastError = "本機服務已結束（exit code \(proc.terminationStatus)）"
                }
            }
        }

        self.process = process
        do {
            try process.run()
            scheduleStartupTimeout(for: process)
        } catch {
            self.process = nil
            lastError = "啟動本機服務失敗：\(error.localizedDescription)"
        }
    }

    private func scheduleStartupTimeout(for process: Process) {
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.process === process, self.port == nil else { return }

            process.terminationHandler = nil // 我們自己主動關的，不用再跑一般的終止處理
            process.terminate()
            self.process = nil
            self.stdoutPipe?.fileHandleForReading.readabilityHandler = nil

            if self.startupAttempt < Self.maxStartupAttempts {
                self.lastError = "本機服務啟動逾時，正在重試（\(self.startupAttempt)/\(Self.maxStartupAttempts)）"
                self.start()
            } else {
                self.lastError = "本機服務啟動逾時，已重試 \(Self.maxStartupAttempts) 次仍失敗，請按重新整理再試一次"
            }
        }
        startupTimeoutWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.startupTimeoutSeconds, execute: workItem)
    }

    func retryStart() {
        startupAttempt = 0
        lastError = nil
        start()
    }

    func stop() {
        startupTimeoutWorkItem?.cancel()
        startupTimeoutWorkItem = nil
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        process?.terminate()
        process = nil
        port = nil
    }
}
