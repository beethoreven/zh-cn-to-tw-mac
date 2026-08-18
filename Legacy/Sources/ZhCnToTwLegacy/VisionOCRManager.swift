import Foundation
import PDFKit
import Vision
import AppKit

/// 10.15 分流的 Stage 1 OCR 實作——用 Apple 原生 Vision framework
/// （`VNRecognizeTextRequest`），不透過 zh-cn-to-tw-ocr-service 那支
/// Python service。原因：那支 service 依賴的 rapidocr_onnxruntime
/// 底層的 onnxruntime 編譯二進位檔 `minos` 寫死 11.0（`otool -l` 查證
/// 過），10.15 上跑不動任何 Python-based OCR 引擎，跟選哪個 Python OCR
/// 套件無關，是硬限制。
///
/// 跟 OCRServiceManager（11+ 那包用的、管 Python subprocess 的那個類別）
/// 完全獨立、不共用任何程式碼——這支是同一個 process 裡直接呼叫原生
/// API，沒有 subprocess、沒有 port、沒有 token 交握，架構本質上不同，
/// 硬套同一個介面反而會讓兩邊都變得不自然。
///
/// 進度回報的欄位形狀（phase/currentPage/totalPages/logs/status/pages/
/// error）刻意跟 zh-cn-to-tw-ocr-service 的 job 狀態對齊，不是巧合——
/// 這樣 zh-cn-to-tw-web 的 script.js 才能用同一套既有的 UI 更新邏輯
/// （renderNewLocalOcrLogs/statusText 那些函式）顯示進度，只有「資料
/// 從哪裡來」不同（HTTP 輪詢 vs. message channel 推播），不用為了這個
/// 分流重寫一套畫面邏輯。
final class VisionOCRManager {
    struct JobError: Error {
        let message: String
    }

    /// 跟 ocr_utils/cover_detect.py 的門檻值對齊（zh-cn-to-tw-ocr-service
    /// 的 configs/config.py 預設值），不要自己另外訂一套，不然同一份
    /// PDF 在兩個分流上可能得出不一致的封面判定。
    private static let coverDarkRatioThreshold = 0.35
    private static let coverSaturationThreshold = 20.0
    private static let coverRelativeMargin = 1.5

    private let workQueue = DispatchQueue(label: "com.beethoreven.zh-cn-to-tw.vision-ocr", qos: .userInitiated)

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
        onUpdate: @escaping ([String: Any]) -> Void
    ) {
        workQueue.async {
            var logs: [String] = []
            func log(_ message: String) {
                logs.append(message)
                onUpdate(["phase": "preparing", "status": "running", "logs": logs])
            }

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

            onUpdate(["phase": "ocr", "status": "running", "logs": logs, "totalPages": totalPages, "currentPage": 0])

            var pages: [String] = []
            for offset in startIndex..<pageImages.count {
                do {
                    let text = try Self.recognizeText(in: pageImages[offset])
                    pages.append(text)
                } catch {
                    onUpdate(["status": "failed", "error": "OCR 處理失敗（第 \(offset - startIndex + 1) 頁）：\(error)"])
                    return
                }
                onUpdate([
                    "phase": "ocr", "status": "running", "logs": logs,
                    "totalPages": totalPages, "currentPage": pages.count,
                ])
            }

            onUpdate(["status": "done", "logs": logs, "pages": pages])
        }
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

    /// 用 VNRecognizeTextRequest 辨識單一頁面圖片，依閱讀順序（由上到下、
    /// 由左到右）組合文字。Vision 的 boundingBox 是正規化座標、原點在
    /// 左下角（跟 PyMuPDF/PIL 慣用的左上角相反），排序前要先轉換成
    /// 「越靠頁面上方數值越小」的座標，才能跟 ocr_engine.py 的
    /// `_line_key`（top, left 排序）行為一致。
    private static func recognizeText(in image: CGImage) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans", "zh-Hant"]
        request.usesLanguageCorrection = false // OCR 逐字辨識，不需要語言模型自動「修正」文字

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])

        guard let observations = request.results else { return "" }

        let sorted = observations.sorted { lhs, rhs in
            // boundingBox.origin.y 是左下角、值越大代表越靠頁面上方，
            // 這裡轉成「由上到下」用 (1 - top) 排序；同一行再依 x 由左到右。
            let lhsTop = 1 - (lhs.boundingBox.origin.y + lhs.boundingBox.height)
            let rhsTop = 1 - (rhs.boundingBox.origin.y + rhs.boundingBox.height)
            if abs(lhsTop - rhsTop) > 0.005 { return lhsTop < rhsTop }
            return lhs.boundingBox.origin.x < rhs.boundingBox.origin.x
        }

        let lines = sorted.compactMap { $0.topCandidates(1).first?.string }
        return lines.joined(separator: "\n")
    }
}
