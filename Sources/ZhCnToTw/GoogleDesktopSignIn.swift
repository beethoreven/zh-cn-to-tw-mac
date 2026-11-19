import AppKit
import CryptoKit
import Foundation
import Network

/// 桌面版 Google 登入：不在 App 內嵌的 WKWebView 裡走完整個 OAuth 流程
/// （WKWebView 不是真正的瀏覽器，Google 自己會限制/降級內嵌瀏覽器裡的
/// 登入流程——實測撞過 window.open 被擋、CSP base-uri 錯誤、
/// account chooser 視窗越開越多，每修一個都冒出下一個新坑）。改用系統
/// 瀏覽器（Safari／使用者預設瀏覽器）開一個真正的分頁走完整個登入流程，
/// 這是 Google 官方對原生桌面 App 建議的做法（RFC 8252：OAuth 2.0 for
/// Native Apps 明講不建議用內嵌 WebView）。
///
/// 流程：本機開一個一次性的 loopback HTTP 服務 -> 用系統瀏覽器開 Google
/// 的登入網址（redirect_uri 指到這個本機服務，並帶上這次登入專屬的
/// state）-> 使用者在真正的瀏覽器分頁完成登入 -> Google 用
/// response_mode=form_post 把 ID Token 連同 state POST 回這個本機服務
/// -> 確認 state 是自己發出去的那一個、token 的形狀正確，才連同這次登入
/// 的 nonce 原值交給呼叫端（呼叫端會透過 evaluateJavaScript 把兩者塞回
/// 網頁既有的 handleCredentialResponse()，後續驗證/儲存/UI 更新完全沿用
/// 網頁原本的邏輯）。
final class GoogleDesktopSignIn {
    // 刻意用固定 port，不像 ocr-service 那樣動態跟作業系統要一個空
    // port——Google Cloud Console 的「已授權的重新導向 URI」是精確字串
    // 比對，沒辦法登記「任何 port 都可以」，redirect_uri 必須是固定、
    // 事先在 Cloud Console 登記好的值：http://127.0.0.1:53682/callback
    private static let loopbackPort: UInt16 = 53_682
    private static let clientID = "415031055130-73moi9aantfm5hjojmt1r0isk2uo35mr.apps.googleusercontent.com"
    private static let timeoutSeconds: TimeInterval = 300

    /// 一個請求最多收多少。Google 的回呼只有一個 ID Token 加幾個短欄位，
    /// 兩三 KB；超過這個大小的不可能是它，不必繼續收下去。
    static let maxRequestBytes = 64 * 1024
    /// ID Token 的長度上限，同樣遠大於實際值（一兩 KB）。
    static let maxTokenBytes = 16 * 1024

    enum SignInError: Error {
        case listenerFailed(String)
        case timedOut
        case missingToken
    }

    /// 登入成功的結果。nonce 是這次登入產生的原值，要跟 ID Token 一起交給
    /// 後端（見 start(completion:) 裡的說明）。
    struct SignInResult: Equatable {
        let idToken: String
        let nonce: String
    }

    /// 一條連線目前收到的內容，解析成哪一種狀況。
    enum CallbackRequest: Equatable {
        /// 還沒收完整，繼續收。
        case incomplete
        /// 不是 form POST（沒有 Content-Length、長度不合理、整個請求太大）。
        case malformed
        /// 收完整了，body 的欄位。
        case complete(fields: [String: String])
    }

    /// 一個完整的請求要怎麼處理。
    enum CallbackDecision: Equatable {
        /// state 相符、ID Token 形狀正確：這次登入成功。
        case accept(idToken: String)
        /// state 相符但沒有可用的 token（使用者取消、Google 回報錯誤）：
        /// 這次登入失敗，不用再等。
        case reject
        /// state 不符或沒帶：不是這次登入的回呼，當成沒收到，繼續等。
        case ignore
    }

    private let openURL: (URL) -> Void
    private var listener: NWListener?
    private var connections: [NWConnection] = []
    private var timeoutWorkItem: DispatchWorkItem?
    private var didFinish = false

    /// openURL：怎麼把登入網址交給使用者。預設用系統瀏覽器開啟。
    init(openURL: @escaping (URL) -> Void = { url in _ = NSWorkspace.shared.open(url) }) {
        self.openURL = openURL
    }

    func start(completion: @escaping (Result<SignInResult, SignInError>) -> Void) {
        // nonce 原值只留在 App 裡：登入網址帶的是它的 SHA-256，Google 把
        // 這個雜湊原樣放進 ID Token；登入成功後原值跟 token 一起交給後端，
        // 後端確認兩者對得上才換發 session。token 會經過系統瀏覽器跟本機的
        // 回呼，原值不會，所以只拿到 token 的人換不到 session。
        let nonce = Self.randomToken()
        let finish: (Result<String, SignInError>) -> Void = { [weak self] result in
            guard let self, !self.didFinish else { return }
            self.didFinish = true
            self.tearDown()
            let signedIn = result.map { SignInResult(idToken: $0, nonce: nonce) }
            DispatchQueue.main.async { completion(signedIn) }
        }

        guard let port = NWEndpoint.Port(rawValue: Self.loopbackPort) else {
            finish(.failure(.listenerFailed("無效的 port 設定")))
            return
        }

        let listener: NWListener
        do {
            // 只能用一種方式指定 port，不能兩邊都設：requiredLocalEndpoint
            // 已經同時帶了 host + port，若再額外傳 on: port 給
            // NWListener 的初始化參數，兩邊互相衝突，底層網路堆疊會直接
            // 回報「參數不合法」（NWError 22 / EINVAL），不是真的 port
            // 被占用（實測抓到：這個錯誤訊息很容易誤導成是 port 衝突）。
            let params = NWParameters.tcp
            params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: port)
            listener = try NWListener(using: params)
        } catch {
            finish(.failure(.listenerFailed(
                "無法監聽本機 127.0.0.1:\(Self.loopbackPort)（可能被其他程式占用）：\(error.localizedDescription)"
            )))
            return
        }
        self.listener = listener

        // state 是這一次登入專屬的隨機值：放進登入網址，Google 會原樣放在
        // 回呼裡送回來。這個 port 是固定的，同一台電腦上的其他程式、使用者
        // 開著的其他網頁都連得到它；回呼裡的 state 跟這裡記住的一樣，才能
        // 確定它是這次登入的結果，不是別人送進來的內容。
        let state = Self.randomToken()

        listener.stateUpdateHandler = { listenerState in
            if case .failed(let error) = listenerState {
                finish(.failure(.listenerFailed(error.localizedDescription)))
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection: connection, expectedState: state, finish: finish)
        }
        listener.start(queue: .main)

        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: Self.clientID),
            URLQueryItem(name: "redirect_uri", value: "http://127.0.0.1:\(Self.loopbackPort)/callback"),
            URLQueryItem(name: "response_type", value: "id_token"),
            URLQueryItem(name: "response_mode", value: "form_post"),
            URLQueryItem(name: "scope", value: "openid email profile"),
            URLQueryItem(name: "nonce", value: Self.hashedNonce(nonce)),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "prompt", value: "select_account"),
            // hl（host language）明確指定 Google 這個登入/同意畫面要用
            // 什麼語言顯示，不受瀏覽器語言設定或使用者 Google 帳號本身的
            // 語言偏好影響——實測發現不加這個，畫面預設會是英文。
            URLQueryItem(name: "hl", value: "zh-TW"),
        ]
        openURL(components.url!)

        let timeout = DispatchWorkItem { finish(.failure(.timedOut)) }
        timeoutWorkItem = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.timeoutSeconds, execute: timeout)
    }

    private func handle(
        connection: NWConnection,
        expectedState: String,
        finish: @escaping (Result<String, SignInError>) -> Void
    ) {
        // 不是只收第一條連線：真正的回呼之前可能先有別的連線進來（瀏覽器
        // 預先開好的連線、其他程式或網頁送來的請求）。每一條都各自讀完、
        // 各自判斷，只有通過檢查的那一條會結束這次登入。
        connections.append(connection)
        connection.start(queue: .main)
        receive(on: connection, buffer: Data(), expectedState: expectedState, finish: finish)
    }

    private func receive(
        on connection: NWConnection,
        buffer: Data,
        expectedState: String,
        finish: @escaping (Result<String, SignInError>) -> Void
    ) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data, !data.isEmpty {
                buffer.append(data)
            }

            // 下面每一種「不採用」都留一行 log：登入卡住時，要能從 log 看出
            // 是完全沒有請求進來，還是進來了但被略過。只記發生了什麼，不記
            // 請求的內容（裡面可能有 token）。
            switch Self.parseCallback(buffer) {
            case .incomplete:
                if isComplete || error != nil {
                    // 連線結束了還湊不出一個完整的請求（瀏覽器預先開好、
                    // 最後沒用到的連線就是這樣）。它不是回呼，放掉這一條，
                    // 繼續等真正的那一條。
                    print("[desktop-signin] 一條連線沒有送來完整的請求就結束，略過")
                    self.drop(connection)
                } else {
                    self.receive(on: connection, buffer: buffer, expectedState: expectedState, finish: finish)
                }

            case .malformed:
                print("[desktop-signin] 收到不是回呼的請求（不是 form POST 或太大），略過")
                self.respond(on: connection, success: false) {
                    self.drop(connection)
                }

            case .complete(let fields):
                let decision = Self.decide(fields: fields, expectedState: expectedState)
                switch decision {
                case .accept:
                    print("[desktop-signin] 收到這次登入的回呼")
                case .reject:
                    let reported = fields["error"].map { String($0.prefix(80)) } ?? "沒有 error 欄位"
                    print("[desktop-signin] 這次登入的回呼沒有可用的 id_token（\(reported)；欄位：\(fields.keys.sorted())）")
                case .ignore:
                    print("[desktop-signin] 收到 state 不符或沒帶 state 的請求，不是這次登入的回呼，略過")
                }
                switch decision {
                case .accept(let idToken):
                    // finish() 會呼叫 tearDown()，把這個連線 cancel 掉——一定要
                    // 等 respond() 真的把回應送出去之後才呼叫，不能緊接著同時
                    // 觸發，不然會變成兩邊搶著操作同一個連線：respond() 的
                    // send() 是非同步的，回應內容可能都還沒送達瀏覽器，
                    // tearDown() 就先把連線關了，瀏覽器那頭會看到空的回應
                    // （實測抓到：App 端 token 拿到、登入成功，但瀏覽器分頁
                    // 顯示 ERR_EMPTY_RESPONSE——token 解析在記憶體裡同步完成
                    // 不受影響，受影響的只有回應瀏覽器這一步）。
                    self.respond(on: connection, success: true) {
                        finish(.success(idToken))
                    }
                case .reject:
                    self.respond(on: connection, success: false) {
                        finish(.failure(.missingToken))
                    }
                case .ignore:
                    self.respond(on: connection, success: false) {
                        self.drop(connection)
                    }
                }
            }
        }
    }

    /// 只處理這個一次性用途需要的最小 HTTP 解析：找 headers/body 分界、
    /// 讀 Content-Length 對應長度的 body、拆出 form-urlencoded 的欄位——
    /// 不是通用 HTTP 伺服器，夠用就好。長度一律照位元組算（Content-Length
    /// 講的是位元組，不是字元）。
    static func parseCallback(_ data: Data) -> CallbackRequest {
        guard data.count <= maxRequestBytes else { return .malformed }
        guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)) else { return .incomplete }

        let headers = String(decoding: data[data.startIndex..<headerEnd.lowerBound], as: UTF8.self)
        guard let contentLength = contentLength(fromHeaders: headers),
              contentLength >= 0, contentLength <= maxRequestBytes
        else { return .malformed }

        let body = data[headerEnd.upperBound...]
        guard body.count >= contentLength else { return .incomplete } // body 還沒收完整，等下一輪
        return .complete(fields: formFields(String(decoding: body.prefix(contentLength), as: UTF8.self)))
    }

    static func decide(fields: [String: String], expectedState: String) -> CallbackDecision {
        guard let state = fields["state"], state == expectedState else { return .ignore }
        guard let idToken = fields["id_token"], isCompactJWT(idToken) else { return .reject }
        return .accept(idToken: idToken)
    }

    /// ID Token 是 JWT：三段 base64url，中間用「.」隔開，只會有英數、
    /// 「-」、「_」。形狀不對的一律不收——這個值接下來會交給網頁，不該讓
    /// 任何其他字元有機會跟著進去。
    static func isCompactJWT(_ token: String) -> Bool {
        guard token.utf8.count <= maxTokenBytes else { return false }
        let segments = token.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count == 3 else { return false }
        return segments.allSatisfy { segment in
            !segment.isEmpty && segment.utf8.allSatisfy { byte in
                (byte >= 0x30 && byte <= 0x39)      // 0-9
                    || (byte >= 0x41 && byte <= 0x5A)   // A-Z
                    || (byte >= 0x61 && byte <= 0x7A)   // a-z
                    || byte == 0x2D || byte == 0x5F     // - _
            }
        }
    }

    static func formFields(_ body: String) -> [String: String] {
        var fields: [String: String] = [:]
        for pair in body.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard kv.count == 2,
                  let key = decodeFormComponent(kv[0]),
                  let value = decodeFormComponent(kv[1])
            else { continue }
            // 同名欄位只認第一個
            if fields[key] == nil {
                fields[key] = value
            }
        }
        return fields
    }

    private static func decodeFormComponent(_ component: Substring) -> String? {
        // application/x-www-form-urlencoded：+ 代表空白，要先換成空白
        // 再做 percent-decoding，順序不能反過來。
        String(component).replacingOccurrences(of: "+", with: " ").removingPercentEncoding
    }

    private static func contentLength(fromHeaders headers: String) -> Int? {
        for line in headers.split(separator: "\r\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces).lowercased() == "content-length" else { continue }
            return Int(parts[1].trimmingCharacters(in: .whitespaces))
        }
        return nil
    }

    private func respond(on connection: NWConnection, success: Bool, then completion: @escaping () -> Void) {
        let message = success
            ? "登入完成，請關閉此頁面。"
            : "登入失敗，請回到「繁化助手」重試。"
        // window.close() 實測對這個分頁沒用——這個分頁是系統瀏覽器直接
        // 開的，不是被 JS（window.open()）開的，瀏覽器基於安全考量不會
        // 讓網頁關掉這種分頁，沒有其他純 JS 端的繞過方式。真正可靠的是
        // 下面 App 端主動把自己切回前景（見 start(completion:) 呼叫端），
        // 不管這個分頁關不關得掉，使用者都不用自己手動切換視窗。
        let body = "<html><body style=\"font-family:-apple-system,sans-serif;text-align:center;padding-top:80px;\">\(message)</body></html>"
        let status = success ? "200 OK" : "400 Bad Request"
        let response = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        connection.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in
            connection.cancel()
            completion()
        })
    }

    /// 放掉一條不是回呼的連線，監聽照常繼續。
    private func drop(_ connection: NWConnection) {
        connection.cancel()
        connections.removeAll { $0 === connection }
    }

    private func tearDown() {
        timeoutWorkItem?.cancel()
        timeoutWorkItem = nil
        connections.forEach { $0.cancel() }
        connections.removeAll()
        listener?.cancel()
        listener = nil
    }

    private static func randomToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// nonce 原值的 SHA-256，base64url、不帶「=」。後端用同一個算法比對
    /// （zh-cn-to-tw-backend 的 auth_utils/auth.py 的 hashed_nonce），兩邊
    /// 任何一點不同（大小寫、補不補「=」）登入都會失敗。
    static func hashedNonce(_ raw: String) -> String {
        Data(SHA256.hash(data: Data(raw.utf8))).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
