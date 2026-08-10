import AppKit
import Foundation
import Network

/// 桌面版 Google 登入：不在 App 內嵌的 WKWebView 裡走完整個 OAuth 流程
/// （WKWebView 不是真正的瀏覽器，Google 自己會限制/降級內嵌瀏覽器裡的
/// 登入流程——今晚實測撞過 window.open 被擋、CSP base-uri 錯誤、
/// account chooser 視窗越開越多，每修一個都冒出下一個新坑）。改用系統
/// 瀏覽器（Safari／使用者預設瀏覽器）開一個真正的分頁走完整個登入流程，
/// 這是 Google 官方對原生桌面 App 建議的做法（RFC 8252：OAuth 2.0 for
/// Native Apps 明講不建議用內嵌 WebView）。
///
/// 流程：本機開一個一次性的 loopback HTTP 服務 -> 用系統瀏覽器開 Google
/// 的登入網址（redirect_uri 指到這個本機服務）-> 使用者在真正的瀏覽器
/// 分頁完成登入 -> Google 用 response_mode=form_post 把 ID Token POST
/// 回這個本機服務 -> 解析出 token，交給呼叫端（呼叫端會透過
/// evaluateJavaScript 把 token 塞回網頁既有的 handleCredentialResponse()，
/// 後續驗證/儲存/UI 更新完全沿用網頁原本的邏輯，不用改後端一行程式碼。
final class GoogleDesktopSignIn {
    // 刻意用固定 port，不像 ocr-service 那樣動態跟作業系統要一個空
    // port——Google Cloud Console 的「已授權的重新導向 URI」是精確字串
    // 比對，沒辦法登記「任何 port 都可以」，redirect_uri 必須是固定、
    // 事先在 Cloud Console 登記好的值：http://127.0.0.1:53682/callback
    private static let loopbackPort: UInt16 = 53_682
    private static let clientID = "415031055130-73moi9aantfm5hjojmt1r0isk2uo35mr.apps.googleusercontent.com"
    private static let timeoutSeconds: TimeInterval = 300

    enum SignInError: Error {
        case listenerFailed(String)
        case timedOut
        case missingToken
    }

    private var listener: NWListener?
    private var connection: NWConnection?
    private var timeoutWorkItem: DispatchWorkItem?
    private var didFinish = false

    func start(completion: @escaping (Result<String, SignInError>) -> Void) {
        let finish: (Result<String, SignInError>) -> Void = { [weak self] result in
            guard let self, !self.didFinish else { return }
            self.didFinish = true
            self.tearDown()
            DispatchQueue.main.async { completion(result) }
        }

        guard let port = NWEndpoint.Port(rawValue: Self.loopbackPort) else {
            finish(.failure(.listenerFailed("無效的 port 設定")))
            return
        }

        let listener: NWListener
        do {
            let params = NWParameters.tcp
            params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: port)
            listener = try NWListener(using: params, on: port)
        } catch {
            finish(.failure(.listenerFailed(
                "無法監聽本機 127.0.0.1:\(Self.loopbackPort)（可能被其他程式占用）：\(error.localizedDescription)"
            )))
            return
        }
        self.listener = listener

        listener.stateUpdateHandler = { state in
            if case .failed(let error) = state {
                finish(.failure(.listenerFailed(error.localizedDescription)))
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection: connection, finish: finish)
        }
        listener.start(queue: .main)

        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: Self.clientID),
            URLQueryItem(name: "redirect_uri", value: "http://127.0.0.1:\(Self.loopbackPort)/callback"),
            URLQueryItem(name: "response_type", value: "id_token"),
            URLQueryItem(name: "response_mode", value: "form_post"),
            URLQueryItem(name: "scope", value: "openid email profile"),
            URLQueryItem(name: "nonce", value: Self.randomToken()),
            URLQueryItem(name: "state", value: Self.randomToken()),
            URLQueryItem(name: "prompt", value: "select_account"),
        ]
        NSWorkspace.shared.open(components.url!)

        let timeout = DispatchWorkItem { finish(.failure(.timedOut)) }
        timeoutWorkItem = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.timeoutSeconds, execute: timeout)
    }

    private func handle(connection: NWConnection, finish: @escaping (Result<String, SignInError>) -> Void) {
        self.connection = connection
        connection.start(queue: .main)
        receive(on: connection, buffer: Data(), finish: finish)
    }

    private func receive(on connection: NWConnection, buffer: Data, finish: @escaping (Result<String, SignInError>) -> Void) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data, !data.isEmpty {
                buffer.append(data)
            }

            if let token = self.extractIDToken(from: buffer) {
                self.respond(on: connection, success: true)
                finish(.success(token))
                return
            }

            if isComplete || error != nil {
                self.respond(on: connection, success: false)
                finish(.failure(.missingToken))
                return
            }

            self.receive(on: connection, buffer: buffer, finish: finish)
        }
    }

    /// 只處理這個一次性用途需要的最小 HTTP 解析：找 headers/body 分界、
    /// 讀 Content-Length 對應長度的 body，從 form-urlencoded 格式解析出
    /// id_token 欄位——不是通用 HTTP 伺服器，夠用就好。
    private func extractIDToken(from data: Data) -> String? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        guard let headerEndRange = text.range(of: "\r\n\r\n") else { return nil }

        let headerPart = String(text[text.startIndex..<headerEndRange.lowerBound])
        let bodyPart = String(text[headerEndRange.upperBound...])

        guard let contentLength = Self.contentLength(fromHeaders: headerPart) else { return nil }
        guard bodyPart.utf8.count >= contentLength else { return nil } // body 還沒收完整，等下一輪

        for pair in bodyPart.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            guard kv.count == 2, kv[0] == "id_token" else { continue }
            // application/x-www-form-urlencoded：+ 代表空白，要先換成空白
            // 再做 percent-decoding，順序不能反過來。
            let normalized = String(kv[1]).replacingOccurrences(of: "+", with: " ")
            return normalized.removingPercentEncoding
        }
        return nil
    }

    private static func contentLength(fromHeaders headers: String) -> Int? {
        for line in headers.split(separator: "\r\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces).lowercased() == "content-length" else { continue }
            return Int(parts[1].trimmingCharacters(in: .whitespaces))
        }
        return nil
    }

    private func respond(on connection: NWConnection, success: Bool) {
        let message = success
            ? "登入完成，可以關閉這個分頁，回到「劇本殺繁化助手」繼續使用。"
            : "登入失敗，請回到「劇本殺繁化助手」重試。"
        let body = "<html><body style=\"font-family:-apple-system,sans-serif;text-align:center;padding-top:80px;\">\(message)</body></html>"
        let status = success ? "200 OK" : "400 Bad Request"
        let response = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        connection.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func tearDown() {
        timeoutWorkItem?.cancel()
        timeoutWorkItem = nil
        connection?.cancel()
        connection = nil
        listener?.cancel()
        listener = nil
    }

    private static func randomToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}
