import Foundation
import PDFKit
import AppKit

/// 10.15 分流的 Stage 1 OCR 實作——呼叫 App 內嵌的 Tesseract 執行檔
/// （`Resources/tesseract/`，由 packaging/build_tesseract_10_15.sh 編譯），
/// 不透過 zh-cn-to-tw-ocr-service 那支 Python service。
///
/// 為什麼不是 11+ 用的 RapidOCR：它底層的 onnxruntime 編譯二進位檔
/// `minos` 寫死 11.0（`otool -l` 查證過），10.15 上跑不動。
///
/// 為什麼不再用 Apple Vision framework（2.0（含）以前的做法）：10.15 的 Vision
/// 只有 `VNRecognizeTextRequestRevision1`，SDK 標頭寫明「only supports
/// English」，支援中文的 Revision2 要 macOS 11。設
/// `recognitionLanguages = ["zh-Hans", "zh-Hant"]` 不會報錯，Vision 會默默
/// 改用英文模型，中文字全部被辨識成英文字母（2026-11 實機回報的「亂碼」）。
/// 當初在新系統上測試時看起來完全正常，是因為新系統的 Vision 預設用
/// Revision3，有中文——部署目標壓低只保證 API 存在，不保證 API 的能力
/// 一樣。
///
/// 跟 OCRServiceManager（11+ 那包用的、管 Python HTTP service 的那個
/// 類別）不共用程式碼：這裡每一頁直接跑一次 tesseract 命令列、讀
/// stdout，沒有 port、沒有 token 交握、沒有常駐行程。
///
/// 進度回報的欄位形狀（phase/currentPage/totalPages/logs/status/pages/
/// error）刻意跟 zh-cn-to-tw-ocr-service 的 job 狀態對齊——前端
/// （zh-cn-to-tw-web 的 js/stages/ocr.js）用同一套 UI 邏輯顯示進度，只有
/// 「資料從哪裡來」不同（HTTP 輪詢 vs. message channel 推播）。訊息通道
/// 的名字 `visionOcr`、`__visionOcrProgress` 是 Vision 時代留下的名稱，
/// 前端跟殼一起打包發布，改名不會有新舊版相容問題，但要兩個 repo 同時
/// 改，這次沒有動。
final class TesseractOCRManager {
    /// 跟 ocr_utils/cover_detect.py 的門檻值對齊（zh-cn-to-tw-ocr-service
    /// 的 configs/config.py 預設值），不要自己另外訂一套，不然同一份
    /// PDF 在兩個分流上可能得出不一致的封面判定。
    private static let coverDarkRatioThreshold = 0.35
    private static let coverSaturationThreshold = 20.0
    private static let coverRelativeMargin = 1.5

    private let workQueue = DispatchQueue(label: "com.beethoreven.zh-cn-to-tw.tesseract-ocr", qos: .userInitiated)

    /// 開始一份 OCR 工作。整段跑在背景 queue，`onUpdate` 每個階段/每頁
    /// 都會呼叫一次（背景 thread 呼叫，呼叫端自己決定要不要跳回主
    /// thread——這裡呼叫端是 WebView.Coordinator，會在裡面跳回主 thread
    /// 才動 WKWebView）。
    ///
    /// 回傳的 dict 形狀直接對應 zh-cn-to-tw-ocr-service 的 job 狀態欄位：
    /// `phase`（"preparing"/"ocr"）、`currentPage`、`totalPages`、`logs`
    /// （目前累積的完整陣列，不是只有新增的那幾行——跟 Python 那邊
    /// `_update_job(job_id, logs=list(logs))` 的做法一致）、`status`
    /// （"running"/"done"/"failed"）、`pages`（完成時才有）、`error`
    /// （失敗時才有）。
    func startJob(
        pdfData: Data,
        dpi: Int,
        detectCover: Bool,
        splitLeftRight: Bool,
        onUpdate: @escaping ([String: Any]) -> Void
    ) {
        workQueue.async {
            var logs: [String] = []
            func log(_ message: String) {
                logs.append(message)
                onUpdate(["phase": "preparing", "status": "running", "logs": logs])
            }

            // 先確認引擎在，再開始轉圖片：缺檔時直接明確失敗，不要跑完一長串
            // 前置步驟才發現，更不能產出一份空白或亂碼的結果。
            let engine: Engine
            do {
                engine = try Engine.locate()
            } catch {
                print("[tesseract-ocr] 找不到 OCR 引擎：\(error)")
                onUpdate(["status": "failed", "error": "\(error)"])
                return
            }
            print("[tesseract-ocr] 引擎：\(engine.executable.path)")
            log("OCR 引擎：Tesseract（簡體中文模型）")

            guard let document = PDFDocument(data: pdfData) else {
                onUpdate(["status": "failed", "error": "無法讀取 PDF 檔案"])
                return
            }

            var pageImages: [CGImage] = []
            let scale = CGFloat(dpi) / 72.0 // PDF 預設 72 DPI，換算縮放倍率，跟
            // zh-cn-to-tw-ocr-service/ocr_utils/pdf_to_images.py 的 zoom
            // 邏輯一致。
            for pageIndex in 0..<document.pageCount {
                guard let page = document.page(at: pageIndex) else { continue }
                let bounds = page.bounds(for: .mediaBox)
                let targetSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
                guard targetSize.width > 0, targetSize.height > 0 else { continue }
                let thumbnail = page.thumbnail(of: targetSize, for: .mediaBox)
                guard let cgImage = thumbnail.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                    continue
                }
                pageImages.append(cgImage)
            }

            var totalPages = pageImages.count
            var startIndex = 0

            if !detectCover {
                log("「偵測首頁是否為封面」已關閉，略過封面偵測")
            } else if totalPages < 2 {
                log("PDF 只有 \(totalPages) 頁，略過封面偵測")
            } else {
                let result = Self.evaluateCoverPage(first: pageImages[0], reference: pageImages[1])
                log(
                    "封面偵測：首頁墨水覆蓋率=\(String(format: "%.2f", result.darkRatio))、"
                        + "飽和度=\(String(format: "%.1f", result.saturation))"
                        + "（門檻分別為 \(Self.coverDarkRatioThreshold)、\(Self.coverSaturationThreshold)）；"
                        + "參考頁（第 2 頁）墨水覆蓋率=\(String(format: "%.2f", result.referenceDarkRatio))、"
                        + "飽和度=\(String(format: "%.1f", result.referenceSaturation))"
                        + "（相對倍數門檻 \(Self.coverRelativeMargin)）"
                        + " → 判定\(result.isCover ? "為封面" : "不是封面")"
                )
                if result.isCover {
                    startIndex = 1
                    totalPages -= 1
                    log("首頁已自動移除，不列入 OCR 範圍；如果判斷錯誤，請關閉「偵測首頁是否為封面」開關重新處理")
                }
            }

            // 刻意排在封面偵測之後：封面偵測比對的是原始的第 1、2 張，要先決定
            // 整張封面拿不拿掉，剩下的才切成左右兩頁。跟
            // zh-cn-to-tw-ocr-service/app.py 的 _run_local_ocr_job 順序一致。
            var ocrImages = Array(pageImages[startIndex...])
            if splitLeftRight {
                log("「切割左右頁格式」已開啟，\(totalPages) 張將切割成 \(totalPages * 2) 頁")
                ocrImages = ocrImages.flatMap { Self.splitLeftRight($0) }
                totalPages = ocrImages.count
            }

            onUpdate(["phase": "ocr", "status": "running", "logs": logs, "totalPages": totalPages, "currentPage": 0])

            let workDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("zhcntotw-ocr-\(UUID().uuidString)", isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
            } catch {
                onUpdate(["status": "failed", "error": "無法建立 OCR 暫存資料夾：\(error)"])
                return
            }
            defer { try? FileManager.default.removeItem(at: workDir) }

            var pages: [String] = []
            for (index, image) in ocrImages.enumerated() {
                let started = Date()
                do {
                    let text = try engine.recognize(image, workDir: workDir)
                    pages.append(text)
                } catch {
                    print("[tesseract-ocr] 第 \(index + 1) 頁失敗：\(error)")
                    onUpdate(["status": "failed", "error": "OCR 處理失敗（第 \(index + 1) 頁）：\(error)"])
                    return
                }
                print("[tesseract-ocr] 第 \(index + 1)/\(totalPages) 頁完成，\(String(format: "%.1f", Date().timeIntervalSince(started))) 秒，\(pages.last?.count ?? 0) 字")
                onUpdate([
                    "phase": "ocr", "status": "running", "logs": logs,
                    "totalPages": totalPages, "currentPage": pages.count,
                ])
            }

            // 結果幾乎沒有中文字，多半是引擎或模型出了問題（或 PDF 本身就不是
            // 中文），不擋下結果，但要讓使用者在畫面上看得到，不要再出現
            // 「看起來成功、其實整份亂碼」的情況。
            let joined = pages.joined()
            let visible = joined.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }
            let han = visible.filter { Self.isHan($0) }
            if visible.count >= 50, Double(han.count) / Double(visible.count) < 0.2 {
                logs.append("⚠️ 辨識結果幾乎沒有中文字（中文 \(han.count) 字／全部 \(visible.count) 字），請確認 PDF 內容，或把結果檔與原始 PDF 回報給開發者")
            }
            print("[tesseract-ocr] 完成：\(pages.count) 頁，中文 \(han.count) 字／全部 \(visible.count) 字")

            onUpdate(["status": "done", "logs": logs, "pages": pages])
        }
    }

    // MARK: - 切割左右頁

    /// 從正中間切開，回傳 [左半, 右半]——左頁是前一頁、右頁是後一頁。跟
    /// zh-cn-to-tw-ocr-service/ocr_utils/pdf_to_images.py 的
    /// split_left_right_pages 切法一致（奇數寬度時多出來那一欄歸右半）。
    /// cropping(to:) 跟原圖共用底層像素資料，不會多複製一份記憶體。
    private static func splitLeftRight(_ image: CGImage) -> [CGImage] {
        let mid = image.width / 2
        let left = CGRect(x: 0, y: 0, width: mid, height: image.height)
        let right = CGRect(x: mid, y: 0, width: image.width - mid, height: image.height)
        return [left, right].compactMap { image.cropping(to: $0) }
    }

    // MARK: - 封面偵測

    private struct CoverResult {
        let isCover: Bool
        let darkRatio: Double
        let saturation: Double
        let referenceDarkRatio: Double
        let referenceSaturation: Double
    }

    /// 複刻 zh-cn-to-tw-ocr-service/ocr_utils/cover_detect.py 的算法：
    /// 墨水覆蓋率（灰階值 < 200 的像素比例）+ 平均飽和度（HSV 的 S
    /// 通道，0-255 尺度，對齊 PIL 的 "HSV" mode），任一訊號超過絕對
    /// 門檻、或明顯高於參考頁（乘上 relative margin）就判定為封面。
    /// 不強求兩個訊號同時出現——封面可能是彩色插畫（飽和度訊號強）
    /// 也可能是黑白照片/滿版圖（墨水覆蓋率訊號強）。
    private static func evaluateCoverPage(first: CGImage, reference: CGImage) -> CoverResult {
        let firstStats = pixelStats(of: first)
        let refStats = pixelStats(of: reference)

        var isCover = firstStats.darkRatio >= coverDarkRatioThreshold || firstStats.saturation >= coverSaturationThreshold
        if !isCover {
            if refStats.darkRatio > 0, firstStats.darkRatio >= refStats.darkRatio * coverRelativeMargin {
                isCover = true
            } else if refStats.saturation > 0, firstStats.saturation >= refStats.saturation * coverRelativeMargin {
                isCover = true
            }
        }

        return CoverResult(
            isCover: isCover,
            darkRatio: firstStats.darkRatio,
            saturation: firstStats.saturation,
            referenceDarkRatio: refStats.darkRatio,
            referenceSaturation: refStats.saturation
        )
    }

    private struct PixelStats {
        let darkRatio: Double
        let saturation: Double
    }

    /// 一次掃過所有像素同時算出墨水覆蓋率跟平均飽和度，不像 Python 那邊
    /// 分兩次轉色彩空間（先轉 "L" 算墨水覆蓋率、再轉 "HSV" 算飽和度）——
    /// 這裡是原生記憶體操作，一次到位比較划算，數學上是等價的。
    private static func pixelStats(of image: CGImage) -> PixelStats {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return PixelStats(darkRatio: 0, saturation: 0) }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bytesPerPixel = 4
        let bytesPerRow = bytesPerPixel * width
        var rawData = [UInt8](repeating: 0, count: height * bytesPerRow)
        guard let context = CGContext(
            data: &rawData, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: bytesPerRow, space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return PixelStats(darkRatio: 0, saturation: 0)
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        var darkPixels = 0
        var saturationSum: Double = 0
        let totalPixels = width * height

        for pixelIndex in 0..<totalPixels {
            let offset = pixelIndex * bytesPerPixel
            let r = Double(rawData[offset])
            let g = Double(rawData[offset + 1])
            let b = Double(rawData[offset + 2])

            // 灰階值用標準亮度加權公式（跟 PIL 的 "L" 轉換係數一致）。
            let gray = 0.299 * r + 0.587 * g + 0.114 * b
            if gray < 200 { darkPixels += 1 }

            // HSV 的 S 通道，0-255 尺度：(max-min)/max * 255，跟 PIL 的
            // "HSV" mode 換算方式一致。
            let maxC = max(r, g, b)
            let minC = min(r, g, b)
            let saturation = maxC > 0 ? (maxC - minC) / maxC * 255 : 0
            saturationSum += saturation
        }

        return PixelStats(
            darkRatio: Double(darkPixels) / Double(totalPixels),
            saturation: saturationSum / Double(totalPixels)
        )
    }

    // MARK: - OCR

    private static func isHan(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0x20000...0x2FA1F: return true
        default: return false
        }
    }

    enum OCRError: Error, CustomStringConvertible {
        case engineMissing(String)
        case imageConversionFailed
        case processFailed(status: Int32, stderr: String)

        var description: String {
            switch self {
            case .engineMissing(let path):
                return "找不到內嵌的 OCR 引擎（\(path)），App 可能沒有完整安裝，請重新下載安裝"
            case .imageConversionFailed:
                return "頁面圖片轉換失敗"
            case .processFailed(let status, let stderr):
                return "Tesseract 結束代碼 \(status)：\(stderr.trimmingCharacters(in: .whitespacesAndNewlines))"
            }
        }
    }

    /// 內嵌的 tesseract 執行檔 + 模型資料夾。
    struct Engine {
        let executable: URL
        let tessdata: URL

        /// 正式打包的 .app 從 Resources/tesseract/ 找；`swift run` 開發模式
        /// 沒有 bundle，改用環境變數 ZHCNTOTW_TESSERACT_DIR 指到
        /// build_tesseract_10_15.sh 的成品（Legacy/.build/tesseract/current）。
        static func locate() throws -> Engine {
            let base: URL
            if let override = ProcessInfo.processInfo.environment["ZHCNTOTW_TESSERACT_DIR"] {
                base = URL(fileURLWithPath: override, isDirectory: true)
            } else if let resources = Bundle.main.resourceURL {
                base = resources.appendingPathComponent("tesseract", isDirectory: true)
            } else {
                throw OCRError.engineMissing("Bundle.main.resourceURL 為 nil")
            }
            let executable = base.appendingPathComponent("bin/tesseract")
            let tessdata = base.appendingPathComponent("tessdata", isDirectory: true)
            guard FileManager.default.isExecutableFile(atPath: executable.path) else {
                throw OCRError.engineMissing(executable.path)
            }
            let model = tessdata.appendingPathComponent("chi_sim.traineddata")
            guard FileManager.default.fileExists(atPath: model.path) else {
                throw OCRError.engineMissing(model.path)
            }
            return Engine(executable: executable, tessdata: tessdata)
        }

        /// 辨識單一頁面：存成 PNM 灰階圖（Leptonica 不需要任何外部影像
        /// 函式庫就能讀），跑一次 tesseract，讀 stdout。
        ///
        /// `--psm 3`（全自動版面分析）：評估時跟 `--psm 6`（當成單一文字
        /// 區塊）品質差不多，但 3 對雙欄、標題置中這類版面比較穩。
        /// Tesseract 自己決定閱讀順序，不用像 Vision 那樣自己依座標排序。
        func recognize(_ image: CGImage, workDir: URL) throws -> String {
            let input = workDir.appendingPathComponent("page.pnm")
            let stderrFile = workDir.appendingPathComponent("stderr.txt")
            try TesseractOCRManager.writeGrayPNM(image, to: input)
            FileManager.default.createFile(atPath: stderrFile.path, contents: nil)

            let process = Process()
            process.executableURL = executable
            process.arguments = [
                input.path, "stdout",
                "--tessdata-dir", tessdata.path,
                "-l", "chi_sim",
                "--psm", "3",
            ]
            let stdout = Pipe()
            process.standardOutput = stdout
            // stderr 寫到檔案、不用第二個 Pipe：同時讀兩個 Pipe 時，如果其中
            // 一個的緩衝區滿了而我們正卡在讀另一個，雙方會互等。
            let stderrHandle = try FileHandle(forWritingTo: stderrFile)
            process.standardError = stderrHandle
            try process.run()
            let data = stdout.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            try? stderrHandle.close()

            guard process.terminationStatus == 0 else {
                let err = (try? String(contentsOf: stderrFile, encoding: .utf8)) ?? ""
                throw OCRError.processFailed(status: process.terminationStatus, stderr: err)
            }
            return TesseractOCRManager.cleanUp(String(decoding: data, as: UTF8.self))
        }
    }

    /// CGImage 轉 8-bit 灰階、寫成二進位 PNM（P5）。先鋪白底：PDF 頁面
    /// 沒有背景時透明區域在灰階 context 裡會變黑，整頁黑底會讓辨識全毀。
    static func writeGrayPNM(_ image: CGImage, to url: URL) throws {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0,
              let context = CGContext(
                  data: nil, width: width, height: height, bitsPerComponent: 8,
                  bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                  bitmapInfo: CGImageAlphaInfo.none.rawValue
              )
        else { throw OCRError.imageConversionFailed }
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(rect)
        context.draw(image, in: rect)
        guard let pixels = context.data else { throw OCRError.imageConversionFailed }
        let bytesPerRow = context.bytesPerRow

        var data = Data("P5\n\(width) \(height)\n255\n".utf8)
        data.reserveCapacity(data.count + width * height)
        let base = pixels.assumingMemoryBound(to: UInt8.self)
        for row in 0..<height {
            data.append(base + row * bytesPerRow, count: width)
        }
        try data.write(to: url)
    }

    private static let cjkGap = try! NSRegularExpression(
        pattern: "(?<=[\\p{Han}\\u3000-\\u303F\\uFF00-\\uFFEF“”‘’])[ \\t]+(?=[\\p{Han}\\u3000-\\u303F\\uFF00-\\uFFEF“”‘’])"
    )
    private static let gapAroundHalfWidthPunct = try! NSRegularExpression(
        pattern: "(?<=\\p{Han}[,.:;!?])[ \\t]+(?=\\p{Han})|(?<=\\p{Han})[ \\t]+(?=[,.:;!?])"
    )

    /// 整理 Tesseract 的輸出，讓格式接近 ocr-service（RapidOCR）的結果：
    /// - 拿掉結尾的換頁字元（\f）與段落之間的空行
    /// - 拿掉中文字之間多出來的空格：chi_sim 模型常在字與字、字與標點
    ///   之間插入空格（例如「上可爱且 温柔」「室息, 那一刻」）。英文單字
    ///   之間的空格不動，劇本裡常有英文。
    /// 半形標點不在這裡轉全形，Stage 2 本來就會做。
    static func cleanUp(_ raw: String) -> String {
        raw.replacingOccurrences(of: "\u{0C}", with: "")
            .components(separatedBy: .newlines)
            .map { line -> String in
                var text = line.trimmingCharacters(in: .whitespaces)
                for regex in [cjkGap, gapAroundHalfWidthPunct] {
                    let range = NSRange(text.startIndex..., in: text)
                    text = regex.stringByReplacingMatches(in: text, range: range, withTemplate: "")
                }
                return text
            }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }
}
