# 中文

## 劇本殺繁化助手 — macOS 桌面殼

用 Swift/SwiftUI + WKWebView 包裝 [`zh-cn-to-tw-web`](https://github.com/beethoreven/zh-cn-to-tw-web) 前端、內嵌 [`zh-cn-to-tw-ocr-service`](https://github.com/beethoreven/zh-cn-to-tw-ocr-service) 當本機 OCR 引擎的 macOS 桌面 App。這份文件分兩部分：

- **[專案報告](#專案報告)**：為什麼需要這個殼、踩過哪些 WKWebView 的坑。
- **[架設 SOP](#架設-sop)**：怎麼本機打包測試。

---

## 專案報告

### 這是什麼、為什麼需要它

`zh-cn-to-tw-web` 本來只是給瀏覽器開的網頁，直接連 Render 後端做全部工作（含 OCR）。但 Render 免費方案完全扛不住 PaddleOCR（SIGILL、OOM，詳見 `zh-cn-to-tw-backend` README），解法是把 OCR 這一段搬到使用者自己的電腦上跑——而「把一支本機 HTTP 服務跟一份網頁前端包裝成使用者可以雙擊開啟的東西」，就是這個殼的職責。它本身幾乎不含業務邏輯，純粹是「啟動/管理本機 OCR 子行程」+「載入網頁前端」+「處理 Google 登入這種瀏覽器層級需要系統協助的事」三件事的黏合層。

### 架構總覽

```
繁化助手.app/                          ← bundle 資料夾本身的名字（Finder/DMG 看到的），跟裡面的執行檔名稱是兩件事
├── Contents/MacOS/ZhCnToTw          ← 這個 repo 編譯出來的執行檔，內部實作細節，維持這個名字不用跟著改
└── Contents/Resources/
    ├── web/                          ← zh-cn-to-tw-web 的靜態檔案（打包時複製進來）
    └── ocr-service/                  ← zh-cn-to-tw-ocr-service 的 PyInstaller 產出
```

App 啟動時**不會**主動啟動 OCR 服務（見下方「OCR 服務生命週期」），只做：載入內嵌的網頁前端（`file://`）、準備好 OCR 服務管理器待命。

### 為什麼網頁前端改用 `file://` 載入（origin 穩定性）

最早的設計是桌面殼自己啟動一份本機 backend，用 HTTP 供應網頁（連 `http://127.0.0.1:<動態port>`）。這個 port 每次啟動都不一樣——刻意如此，這個專案本機測試階段吃過很多次「舊 process 卡住固定 port」的虧。但 `localStorage` 是照 `scheme+host+port` 算 origin 的，port 每次不同就等於每次啟動都是全新的 origin，使用者登入後拿到的 session token 完全救不回來，變成每次開 App 都要重新登入（實測抓到：同一個 bundle id 底下累積了三個不同的 `LocalStorage` 資料夾，就是這樣來的）。

改成完全不透過任何本機 HTTP 伺服器，直接用固定的 `file://` 路徑載入 `Resources/web/index.html`——同一份安裝，每次啟動的路徑都一樣，origin 因此穩定，`localStorage` 能真正跨次啟動保留登入狀態。這個決定同時也順便解決了本機 backend 持有資料庫/LLM 憑證的問題：`file://` 架構下桌面殼完全不需要本機 backend，backend 唯一的角色就是 Render上那一份，桌面版 App 裡不含任何值錢的憑證。

### 過程中踩到的 WKWebView 坑

改用 `file://` 之後，連續撞上好幾個以前完全沒遇過的問題，值得完整記錄：

1. **`Bundle.main.resourceURL` 內部是「相對字串 + baseURL」的組合，`isFileURL` 回報 `true` 但一穿過 `URLComponents(resolvingAgainstBaseURL: false)` 就會弄丟 baseURL**，變成一個沒有 scheme 的相對路徑，`WKWebView` 直接回報「無法顯示URL」，而且完全看不出問題出在 URL 格式。改用 `Bundle.main.bundlePath`（純字串）搭配 `URL(fileURLWithPath:)` 從頭建構路徑解決。
2. **`loadFileURL(_:allowingReadAccessTo:)` 要求給的是乾淨的目錄 URL**——如果傳進去的 URL 還黏著查詢字串（`?desktop=1&...`），算出來的「父目錄」格式就不對，會靜默失敗、整個頁面停在 `about:blank`。用 `.path` 先去掉查詢字串再算父目錄解決。
3. **`WKNavigationDelegate` 不實作 `didFail*`/`didFinish` 的話，導覽失敗完全沒有任何跡象**——沒有例外、沒有 log，只有一片空白畫面。這三個方法現在永久保留，純粹用來 print 診斷訊息，是找出上面兩個問題的關鍵工具。
4. **Swift `print()` 在 stdout 不是 TTY（例如被導向檔案/pipe）時是全緩衝，不是行緩衝**——一度讓新加的診斷 print 完全看不到輸出，一度誤以為程式碼沒有執行到那裡。`applicationDidFinishLaunching` 一開始就呼叫 `setvbuf(stdout, nil, _IONBF, 0)` 解決，這行話很可能也順便修好了既有的 console 轉送功能一直沒真正生效的問題。
5. **`file://` 底下，網頁的 JS 執行期完全沒有辦法讀取同目錄的另一個檔案**——`fetch()` 規格明確禁止、`XMLHttpRequest` 被 WKWebView 擋、隱藏 `<iframe>` + `contentDocument` 回傳 `null`（WebKit 把同目錄下不同的 `file://` 檔案當成不同 origin）。這是「阿舍老師的叮嚀」那個功能一路改了三次才修好的根本原因，完整過程見 `zh-cn-to-tw-backend` README。
6. **沒實作 `webViewWebContentProcessDidTerminate`，App 放一整晚後畫面變空白、按重新整理也救不回來**——WKWebView 真正跑網頁的是獨立的 Web Content process，macOS 在記憶體壓力大或這個 process 閒置很久時可能單獨把它砍掉，App 自己完全不會 crash，只是 WKWebView 那塊區域變空白。沒有這個 delegate 的話，這個狀態不會自動恢復：既有的 `load(url:reloadToken:into:)` 靠 lastURL/lastReloadToken 判斷要不要重新載入，process 被砍掉不會改變這兩個值，使用者按重新整理鍵也不會真的觸發 `loadFileURL`。修法分三層：**(a)** 真的有 Stage 1/2 工作在跑時，用 `SystemActivityGuard`（`ProcessInfo.beginActivity` 搭配 `.idleSystemSleepDisabled`）請系統別把整台機器睡掉，從源頭降低這個 process 被砍的機率；**(b)** 這個保護在工作一完成就解除，但「工作跑完」到「使用者真的下載」中間還有一段空窗（可能比工作本身跑的時間還長），`WebView.Coordinator` 額外接了 `NSWorkspace.willSleepNotification`，系統真的要睡前呼叫網頁的 `window.__attemptAutoSaveBeforeSleep()`（見 `zh-cn-to-tw-web` README），幫使用者把還沒下載的結果先存到本機——刻意只用這個簡單版通知，不用 IOKit 的電源管理 API 去真的要求延後睡眠（那一套複雜得多），所以這一步是 best-effort，不保證來得及；**(c)** 萬一 process 還是被砍掉，`webViewWebContentProcessDidTerminate` 觸發時不在同一個（狀態可能已經不穩定的）WKWebView 上硬重試，而是通知 `ContentView` 把整個 WebView 從畫面上拆掉，換成不吃任何資源的原生 SwiftUI 提示文字，使用者按重新整理才讓 SwiftUI 重新 `makeNSView` 生出一個全新的 WKWebView，從乾淨狀態重新 `loadFileURL`（也就順便拿到全新的 `allowingReadAccessTo` 授權，不用另外處理舊授權失效的問題）。

這幾條不是這個專案獨有的踩坑，任何桌面殼 + WKWebView 的程式都可能撞到。

### OCR 服務生命週期

跟網頁前端的討論一起演化過幾次：

- **v1**：App 啟動就拉起 OCR 服務，整個執行期間開著。
- **v2**：加「閒置 30 分鐘自我關閉」+「健康檢查每 30 秒發現沒在跑就重新拉起」——兩個機制互相打架，關掉沒多久又被拉起來，記憶體從沒真的被回收過。
- **v3（目前）**：完全交給網頁前端主動控制。`WebView.swift` 註冊一個 `ocrService` 的 `WKScriptMessageHandler`，`zh-cn-to-tw-web` 的 `js/stages/ocr.js` 在真的要送 PDF 之前才發 `{action: "start"}`，OCR 階段結束（不管成功失敗）就發 `{action: "stop"}`。App 啟動時完全不主動開它。

搭配的還有 port 通知機制：服務起來/關掉時，`OCRServiceManager` 會把最新的 port（或 `null`）透過 `WKWebView.evaluateJavaScript` 直接寫進網頁的 `window.__OCR_PORT__`，**刻意不透過改網址查詢參數再重新載入頁面**（那樣會清掉使用者填到一半的表單狀態）。

還有一個容易忽略的細節：`readabilityHandler`（讀取子行程 stdout 用來抓 port 號）在 pipe 進入 EOF（子行程結束）後，如果沒有主動解除，GCD 會判定這個 fd「隨時可讀」而無限次重複呼叫這個 closure——實測子行程一死，App 的 CPU 從 0% 直接衝到 96% 且不會回落，開了幾小時、中途重啟過幾次的 App 甚至量到 283%。修法是讀到空資料就把 `handle.readabilityHandler = nil`。

### Google 登入

用系統瀏覽器完成 OAuth 流程（不是嵌在 WKWebView 裡跳出的彈窗），完成後把 Google 的 ID Token 交回網頁前端，由前端向後端換成 session token 存進 `localStorage`。見 `GoogleDesktopSignIn.swift`。

Google 的回呼是送到本機固定的 `127.0.0.1:53682`。這個 port 同一台電腦上的其他程式、使用者開著的其他網頁都連得到，所以登入網址會帶一個這次登入專屬的隨機 `state`（Google 會原樣放在回呼裡送回來），殼只採用 `state` 相符、而且 `id_token` 是 JWT 形狀（三段 base64url）的那一個請求。其他請求——瀏覽器預先開好卻沒用到的連線、不是 form POST 的請求、`state` 不符的請求——一律略過並繼續等，直到 300 秒逾時；`state` 相符但沒有 token（使用者取消、Google 回報錯誤）則立即回報登入失敗。每一種略過都會留一行 log，只記發生了什麼，不記請求內容。

登入網址另外帶 nonce：殼每次登入產生一個隨機原值，只留在 App 裡，網址帶的是原值的 SHA-256（base64url、不帶 `=`），Google 會原樣放進 ID Token。登入成功後，殼把 token 連同原值交給網頁，網頁一起送給後端；後端確認雜湊對得上才換發 session（見 `zh-cn-to-tw-backend` 的 README「登入」一節）。token 會經過系統瀏覽器跟本機回呼，原值不會，所以只拿到 token 的人換不到 session。雜湊算法兩邊要一字不差（`GoogleDesktopSignIn.hashedNonce` 對應後端 `auth_utils/auth.py` 的 `hashed_nonce`）；實測（2026-11-19）同幾組原值（含中文與 `+/=`）兩邊算出來完全相同，真的開 `127.0.0.1:53682` 跑一次登入回呼，殼交出來的原值雜湊之後也正好等於登入網址裡的 nonce。還沒有用真的 Google 帳號登入過。

### 殼只收自己頁面送來的訊息

網頁透過 `window.webkit.messageHandlers.<channel>` 請殼做事：開始登入、啟動或關閉本機 OCR、防止系統睡眠；`10.15` 那包另外有寫檔（`legacyDownload`）與 OCR（`visionOcr`）兩個 channel。這些 channel 掛在 `WKUserContentController` 上，同一份設定底下的每個 frame、每個彈出視窗都呼叫得到，所以 `WebView.swift` 處理每一則訊息之前先確認三件事：是殼自己的那個 `WKWebView`、是最外層的 frame、來源跟殼載入的網址相同。不成立就略過，並留一行 log。

反方向也一樣小心：殼交給網頁的字串（登入拿到的 token、檔名、系統的錯誤訊息）一律先用 JSON 編碼成 JavaScript 的字串字面值，再放進要執行的那段程式——自己跳脫字元只要漏掉一種，字串就會在預期之外的地方結束。

實測（2026-11-19，macOS 26.6.2，用真的 `WKWebView` 載入自訂 scheme 的頁面）：WebKit 對 `zhcntotw://app` 回報的來源是 scheme `zhcntotw`、主機 `app`；自己的頁面送的訊息收得到，頁面裡的 iframe、被帶到別的來源的頁面、同一份設定開出來的第二個 `WKWebView` 送的都收不到。舊版 WebKit 回報的來源如果沒有主機名稱，會退回比對 frame 自己的網址（`ShellSafety.isOwnPage`）；這條退路還沒有在真正的 macOS 10.15／11 上驗證過。

### 正式安裝的 App 收起開發用入口，只打開自己的頁面

- **開發用的入口只在開發版生效**：`WEB_BASE_URL_OVERRIDE`、`WEB_API_BASE_OVERRIDE`、`OCR_SERVICE_DEV_PATH`、10.15 那包的 `ZHCNTOTW_TESSERACT_DIR`，以及 Safari 的網頁檢查器（`isInspectable`），只有不是打包好的 .app 時（例如 `swift run`）才有作用（`ShellSafety.developmentOverride`、`ShellSafety.isPackagedApp`）。這些環境變數能讓 App 連到別的後端、載入別的網頁、執行別的程式；檢查器能讀到 localStorage 裡的登入 session、在頁面裡執行任意程式。不能用 `#if DEBUG` 分辨：打包腳本預設用 debug 設定編譯（`packaging/build_app_*.sh` 的 `CONFIG`），裝到使用者電腦上的 App 也可能是 debug 版。實測（2026-11-21）：同一支程式包成 .app 執行時四個變數全部被忽略，直接執行裸執行檔時都讀得到。
- **只打開自己的頁面**：導覽只放行殼載入的那個來源（`zhcntotw://app`；開發時是 `WEB_BASE_URL_OVERRIDE` 的來源）、`about:`，以及自己頁面產生的 `blob:` 網址（`ShellSafety.isAllowedInAppNavigation`）。使用者自己點的 http(s) 連結交給系統瀏覽器，其他（頁面程式改網址、表單送出、轉址）直接擋下。原本只攔「使用者點連結到別的網域」，其他導覽都放行；這個殼沒有網址列，任何網站在這裡打開，使用者都分不出那是不是這個 App 的畫面。
- **不開新視窗**：`window.open()` 與 `target="_blank"` 一律不在 App 裡開，使用者點的 http(s) 連結交給系統瀏覽器。新視窗是早期在內嵌 WebView 裡跑 Google 登入留下的，那時候會用同一份設定開一個新的 WKWebView；登入改走系統瀏覽器之後已經用不到。
- 網頁本身另外有 CSP（見 `zh-cn-to-tw-web` 的 README「頁面的安全設定」）。WebKit 的 `'self'` 不認自訂 scheme，CSP 裡要明寫 `zhcntotw:`，不然 App 自己的腳本會全部被擋下。

實測（2026-11-21，macOS 26.6.2，真的 WKWebView 用 `WebAssetSchemeHandler` 載入打包在 .app 裡的網頁）：App 自己的 ES module 照常執行，殼的 `evaluateJavaScript` 與頁面開始時注入的腳本不受 CSP 影響；塞進頁面的 inline script、外部 script、送往外部的圖片與 fetch 都被 CSP 擋下；頁面程式導去別的網站被擋下、`window.open` 回傳 null、沒有多出視窗；自己來源的網址照常放行。11+ 的 `WKDownload` 與 10.15 的 `legacyDownload` 照常存檔。

### 版本管控與強制更新

版控走 GitHub Releases（`zh-cn-to-tw-mac` repo 底下，每個版本分流各自一個 Release，DMG 當附件掛上去，見下面「打包成 .dmg」），版本比較邏輯只用 `CFBundleShortVersionString` 的 major/minor 兩碼，不看第三碼——`ContentView.appVersionMajorMinor` 直接用 `.` 切開字串取前兩段，拆不出兩個整數就當 `0.0`（純防禦，理論上不會發生）。`desktopURL()` 組網址時把這兩個數字用 `appMajor`/`appMinor` 帶給網頁，網頁在真的要開始 Stage 1/2 工作前打 `GET /api/version_check` 問 backend 這個版本夠不夠新，過舊就擋下操作並跳窗導去更新頁（完整流程見 `zh-cn-to-tw-web` README「桌面版的強制更新檢查」、`zh-cn-to-tw-backend` README「版本檢查」）。

### 版本分流：11+ 與 10.15

一開始整支 App 用同一個 `Package.swift`（`platforms: [.macOS(.v13)]`），`LSMinimumSystemVersion` 也寫死 `13.0`。後來查證發現這個 `13.0` 門檻是當初隨手選的保守值，翻遍程式碼找不到任何一行真的需要 13.0 的 API（SwiftUI 的 `App`/`Scene`/`WindowGroup` 只要 11.0+、`WKDownload` 只要 11.3+）——於是把主線那包的部署目標下修到 `.v11`，同時把原本鎖住 Stage 1 的 `12-` 分流改造成 `10.15` 分流：Stage 1 不再依賴 `zh-cn-to-tw-ocr-service` 那支 Python service，改用 App 內嵌的 Tesseract 做 OCR（2.0（含）以前用 Apple Vision framework，見下面「10.15 的 OCR 為什麼是 Tesseract」）。之所以還是需要分兩包：RapidOCR 依賴的 onnxruntime 編譯二進位檔 `minos` 寫死 `11.0`（`otool -l` 查證過），10.15 上跑不動任何 Python-based OCR 引擎，這是硬限制，不是選擇：

- **11+**（根目錄 `Package.swift`）：`platforms .v11`，Stage 1/2 都能用，Stage 1 用本機的 `zh-cn-to-tw-ocr-service`（RapidOCR）。
- **10.15**（`Legacy/Package.swift`）：`platforms: [.macOS(.v10_15)]`，Stage 1/2 都能用，但 Stage 1 改用 App 內嵌的 Tesseract 做 OCR，辨識品質比 `11+` 差（見下面）。

兩包是**兩個獨立的 SwiftPM package**，不是同一個 `Package.swift` 裡的兩個 target——SwiftPM 的 `platforms` 是整個 package 共用一份，沒有 per-target 的部署目標可以設。`Legacy/Sources/ZhCnToTwLegacy/` 底下，`ContentView.swift`/`WebView.swift`/`GoogleDesktopSignIn.swift`/`SystemActivityGuard.swift`/`Uninstaller.swift` 全部是**符號連結**指回 `Sources/ZhCnToTw/` 底下同一份檔案，不是複製維護兩份；這個 target 專屬、不 symlink 的檔案有兩個：`App.swift`（進入點）跟 `TesseractOCRManager.swift`（呼叫內嵌 Tesseract 的 OCR 實作）：

- SwiftUI 的 `App`/`Scene`/`WindowGroup`/`.commands`/`NSApplicationDelegateAdaptor` 整組宣告式生命週期都要 **macOS 11.0+** 才有（實測 `swift build` 對 `.v10_15` 直接報錯），10.15 的 SwiftUI 1.0 根本沒有這組 API。`Legacy` 的 `App.swift` 改回傳統的 `NSApplicationDelegate` + 手動 `NSWindow` + `NSHostingController`，選單也改成手動組 `NSMenu`（含 Edit 選單，不然 WKWebView 裡的輸入框可能連 Cmd+C/V 都用不了）。
- `WKDownload`/`WKDownloadDelegate` 整組（含 `WKNavigationActionPolicy.download`）要 **macOS 11.3+**（SDK 標頭實測確認），共用的 `WebView.swift` 因此把這幾個方法搬進一段 `@available(macOS 11.3, *) extension WebView.Coordinator: WKDownloadDelegate`——`10.15` 那包完全不會編到這段。下載改靠 `legacyDownload` message channel：`script.js` 偵測到 `osTier === "10.15"` 時，把下載內容轉成 base64 直接 `postMessage` 過去，殼收到後解碼寫進下載資料夾（見 `WebView.swift` 的 `handleLegacyDownload`）；`11+` 跟純瀏覽器都還是走原本 `WKDownload` 那條路。這個 channel 只在 `10.15` 那包註冊——`11+` 用不到，讓網頁直接叫殼寫檔的管道，沒有需要就不開。檔名是網頁給的（最源頭是伺服器的回應），殼只拿它的最後一段當檔名、只收 `.txt`／`.docx`（這個 App 只會產生這兩種檔案，網頁那邊也只收這兩種，殼再擋一次），寫入前再確認目的地真的在下載資料夾這一層；`WKDownload` 那條路的建議檔名也做同樣的處理（`ShellSafety.downloadDestination`）。不收的一律不寫檔，並請網頁顯示一則錯誤提示。實測（2026-11-19，macOS 26.6.2，真的 `WKWebView` 分別用 `<a download>` 與 `legacyDownload` 觸發）：`.txt`／`.docx` 照常存檔，`.command`、`.app`、`.sh`、用控制字元藏起來的 `.command` 一律擋下，帶 `../` 的名字只留最後一段；沒有副檔名的名字，WebKit 會依 MIME 類型自己補成 `.txt`。`WKDownload` 決定位置時傳回 nil 取消下載，不會再觸發 `didFailWithError`，所以錯誤提示要在取消的地方自己送。
- `Image(systemName:)`、`.help(_:)` 要 11.0+，`ContentView.swift` 的重新整理按鈕因此用 `#available(macOS 11.0, *)` 分兩支（11+ 用原本的圖示按鈕，以下退回純文字按鈕）；`.foregroundStyle` 有的重載要到 14.0 才有，全面換成很舊、行為等價的 `.foregroundColor`，兩包都受惠、沒有可見差異。

`ContentView.swift` 用 `#if LEGACY_BUILD`（`Legacy/Package.swift` 用 `swiftSettings: [.define("LEGACY_BUILD")]` 定義，`11+` 那個 target 沒有）算出 `osTier`（`"11+"` 或 `"10.15"`），透過 `desktopURL()` 的 `osTier` 查詢參數帶給網頁；網頁拿它決定 `GET /api/version_check` 要查哪個分流的門檻（帶成 `os_version` 參數，見 `zh-cn-to-tw-backend` README「版本檢查」）、本機 OCR 要走 HTTP 輪詢還是 `visionOcr` message channel、下載要走 `WKDownload` 還是 `legacyDownload`。

**`10.15` 那包不內嵌 `zh-cn-to-tw-ocr-service`**——Stage 1 靠 `TesseractOCRManager.swift` 呼叫內嵌的 Tesseract（`Contents/Resources/tesseract/`，執行檔約 5 MB + 簡體中文模型約 2.5 MB），不需要那支 Python service，DMG 體積因此明顯小於 `11+` 那包。

#### 10.15 的 OCR 為什麼是 Tesseract

2.0（含）以前 `10.15` 那包用 Apple Vision framework（`VNRecognizeTextRequest`，設 `recognitionLanguages = ["zh-Hans", "zh-Hant"]`）。2026-11 第一次有 10.15 實機回報，處理結果整份是「亂碼」：內容其實是一行行的英文大寫字母，夾著 Stage 2 轉出來的全形標點。原因是 10.15 的 Vision 只有 `VNRecognizeTextRequestRevision1`，SDK 標頭寫明「only supports English」，支援中文的 Revision2 要 macOS 11（在開發機上呼叫 `supportedRecognitionLanguages(for: .accurate, revision: 1)` 也只回 `["en-US"]`）。指定不支援的語言不會報錯，Vision 會默默改用英文模型。之前在新系統上測試看起來完全正常，是因為新系統的 Vision 預設用 Revision3，有中文——部署目標壓低只保證 API 存在，不保證 API 的能力一樣。

改用 Tesseract 5.5.4 + Leptonica 1.87.0，由 `packaging/build_tesseract_10_15.sh` 從原始碼編譯（版本與 SHA-256 釘在腳本裡）：兩者都編成靜態、關掉所有外部影像格式與網路功能，成品只依賴系統的 `libSystem`、`libc++`，`minos` 10.15，腳本最後會自動檢查這兩點，不合格就中止。只編 x86_64：跑 10.15 的 Mac 一定是 Intel。模型用 `tessdata_fast` 的 `chi_sim`。

評估時拿 5 頁實際劇本跟 `11+` 的 RapidOCR 比對（共同認出的中文字比例）：乾淨的單欄掃描 0.96–0.97，一般內頁 0.88–0.90，手機拍的歪斜跨頁只有 0.78（開「切割左右頁」也沒改善）。`tessdata_best` 品質幾乎一樣但慢 2–3 倍，所以用 fast。速度反而比 RapidOCR 快（每頁 2–6 秒 vs. 12–31 秒，同一台 Intel 開發機）。

Tesseract 的 `chi_sim` 會在中文字之間插入空格，`TesseractOCRManager.cleanUp` 會拿掉中文字（含全形標點）之間的空格，英文單字之間的空格不動；半形標點不轉，Stage 2 本來就會轉。辨識完如果結果幾乎沒有中文字（中文少於兩成），會在進度紀錄裡顯示警告，不會再「看起來成功、其實整份亂碼」。

網頁送來的 dpi 會先夾在 100–400 之間（跟前端 DPI 欄位、`zh-cn-to-tw-ocr-service` 的範圍一致）再交給 PDFKit 畫圖：值是網頁給的，太大會畫出一張巨大的點陣圖，一頁就能吃掉好幾 GB 記憶體。

#### 10.15 那包的日誌檔

從 Finder／Dock 打開的 App，stdout、stderr 沒有接到任何地方，`print()` 的內容不會出現在任何地方（也不在 Console.app）。`10.15` 那包啟動時如果 stdout 不是終端機，會把 stdout、stderr 接到 `~/Library/Logs/ZhCnToTw/app.log`（超過 5 MB 換成 `app.log.1`），內容包括 WebView 載入狀態、網頁 console 轉送、每一頁 OCR 的耗時與錯誤。請使用者回報問題時，請對方在 Finder 按「前往」→「前往檔案夾⋯」輸入 `~/Library/Logs/ZhCnToTw`，把 `app.log` 傳過來。從終端機直接執行時維持印在終端機上。`11+` 那包還沒有這個機制。

兩包目前用**同一個 `CFBundleIdentifier`**（`com.beethoreven.zh-cn-to-tw`）——真實使用者只會裝其中一包（依自己的 macOS 版本選對應的 DMG），從使用者角度就是同一個 App。這代表在同一台機器上先後裝兩包做測試會共用同一份 `~/Library/WebKit/<bundle-id>` 等資料、後裝的會蓋掉 `/Applications` 裡先裝的那個，不能同時裝著並排比較——只是本機測試才會遇到的限制，不影響正式使用情境。

**還沒有在真正的舊系統（macOS 10.15）上實測過。** 部署目標壓低只保證程式碼在該版本的 API 集合下能編譯、能連結，不保證執行期行為完全一致——尤其 `legacyDownload` 這條下載路徑跟內嵌的 Tesseract 執行檔，開發機（Apple Silicon，跑 macOS 26）沒辦法用 Virtualization.framework 跑到 macOS 12 以下（那是 Intel 時代的系統），沒有真實舊硬體無法驗證。已經確認過的是：這包在**新系統**（Tahoe）上能正常裝、開、跑基本流程（含 Stage 1 的 Tesseract OCR）——因為部署目標只是下限不是上限，`dyld` 只檢查「目前系統版本 ≥ minos」。但這個做法有盲點，而且真的出過事：Vision framework 版本在新系統上看起來完全正常，10.15 上卻只認得英文（見上面「10.15 的 OCR 為什麼是 Tesseract」）。改用 Tesseract 之後，辨識能力不再依賴系統版本，剩下的風險是內嵌執行檔能不能在 10.15 上啟動（`std::filesystem` 這類 10.15 才有的 libc++ 功能，編譯期檢查有過，執行期還沒實機驗證）。

### 已知限制

- Windows 版尚未開始（未來規劃跟這個殼架構相同，只是換一套 UI 框架）。
- **刻意不做程式碼簽章／公證**：需要付費的 Apple Developer 帳號，這個專案跳過。DMG 打包已經做了（`packaging/build_dmg_11_plus.sh`/`build_dmg_10_15.sh`），但沒有簽章代表使用者第一次打開會被 Gatekeeper 擋下來，DMG 裡附了 `dmg-readme.txt` 說明怎麼在系統設定裡允許。
- DMG 在本機手動跑腳本產出後，手動 `gh release create`/`gh release upload` 掛到 GitHub Releases（`v<版本>-11-plus`／`v<版本>-10-15` 這兩個 tag）——還沒接自動化 CI，每次出新版都是手動流程；下載頁（`zh-cn-to-tw-web` 的 `update-page` 分支）的連結也要跟著手動同步。Release 資產檔名刻意用 ASCII（`ZhCnToTw-<版本>-11+.dmg`／`ZhCnToTw-<版本>-10.15.dmg`），不是本機習慣的中文檔名——`gh` CLI（實測 2.96.0）上傳時會把檔名開頭的 CJK 位元組吃掉，換成 ASCII 檔名完全避開這個 bug。
- `10.15` 那包還沒有在真實舊系統上實測過，見上面「版本分流」段落最後一點。

---

# 架設 SOP / Setup Guide

## 需求

- macOS 11+（打包 `11+` 那包）；打包 `10.15` 那包本身在 macOS 11.3+ 的機器上就能做（`swift build` 只是編譯，部署目標是「執行期下限」不是「開發機下限」），但沒有真正舊系統沒辦法做最終驗證，見上面「版本分流」的說明。
- Xcode（含 Swift 5.9+ 工具鏈）
- 打包 `11+` 那包需要已經打包好的 `zh-cn-to-tw-ocr-service`（見該 repo的 README，`dist/zh-cn-to-tw-ocr-service/`）——沒有的話 App 還是能開，只是本機 OCR 功能會顯示服務啟動失敗。`10.15` 那包不需要這支 Python service，但需要 `cmake`、`ninja`（`brew install cmake ninja`）：第一次打包時 `build_app_10_15.sh` 會呼叫 `build_tesseract_10_15.sh` 下載原始碼、編譯 Tesseract（約 3 分鐘），成品快取在 `Legacy/.build/tesseract/`，之後不重編。

## 打包成 .app

兩包分開兩支腳本，不是同一支帶參數切換——對應兩個獨立的 `Package.swift`（`--package-path` 本身就不同），見上面「版本分流」的說明。

```bash
cd zh-cn-to-tw-mac
bash packaging/build_app_11_plus.sh debug   # macOS 11+ 那包
bash packaging/build_app_10_15.sh debug     # macOS 10.15 那包（內嵌 Tesseract OCR）
```

各自會做這些事：

1. `swift build`（`11+` 用根目錄的 `Package.swift`，`10.15` 用 `--package-path Legacy`）編出裸執行檔。
2. 組出 `.app` bundle 結構（對應的 `Info.plist`/`Info-10-15.plist`、圖示）。
3. `11+` 那包複製 `../zh-cn-to-tw-ocr-service/dist/zh-cn-to-tw-ocr-service/` 整個目錄進 `Resources/ocr-service/`（可用 `OCR_SERVICE_DIST_DIR` 環境變數覆蓋路徑）；`10.15` 那包不需要這一步。
4. 複製 `../zh-cn-to-tw-web/` 的 `index.html` 與 `assets/`、`css/`、`js/` 三個資料夾進 `Resources/web/`（可用 `WEB_SRC_DIR` 環境變數覆蓋路徑；缺任何一個就中止打包，少了 App 會整頁空白）——兩包用同一份網頁原始碼，讀的是 `zh-cn-to-tw-web` 的 `main` 分支，跟 GitHub Pages 服務的 `update-page` 分支無關（見該 repo README）。

完成後：

```bash
open .build/繁化助手.app              # 11+
open Legacy/.build/繁化助手.app       # 10.15（兩包分開放在各自 package 的 .build/，不會互相覆蓋）
```

## 打包成 .dmg

`build_dmg_11_plus.sh`/`build_dmg_10_15.sh` 只做「把已經存在的 `.app`
封成 DMG」這一步，**不會**自動重新 `swift build`、也不會重新複製
`zh-cn-to-tw-web` 的原始碼——先照上面步驟打包出對應的 `.app`，這兩支
才有東西可以包：

```bash
bash packaging/build_dmg_11_plus.sh debug   # 只打 11+ 那包
bash packaging/build_dmg_10_15.sh debug     # 只打 10.15 那包
```

`build_dmg_all.sh`（頂層 meta-repo 的 `build_mac_dmg.sh` 重建完內嵌的 OCR 服務後會呼叫這支）
是唯一預期當成「一鍵重新 build 全部」用的入口，跟上面兩支不一樣：
它會先重新跑 `build_app_11_plus.sh`/`build_app_10_15.sh`（swift
build + 組裝 `.app`，含重新複製最新的網頁前端原始碼），再封裝兩包
DMG，保證原始碼一有改動，這個指令的輸出就一定跟著更新：

```bash
bash packaging/build_dmg_all.sh debug       # 從 swift build 到兩包 DMG，一次做完
```

**這是實測撞過的教訓**：`build_dmg_all.sh` 曾經也只是依序呼叫上面
那兩支「只封裝、不重新 build」的腳本，改完 Swift 或網頁前端原始碼、
只跑這支頂層腳本，會用舊的 `.app` 靜靜包出一個檔案時間戳記是新的、
但內容其實沒變的 DMG，改動完全不會反映在測試結果裡，而且不會有
任何錯誤或警告提醒——裝出來一測，行為還是舊的，看起來像是「改的
東西沒生效」，其實是這支腳本本身沒有真的重新 build。改成上面這樣
之後，`build_dmg_all.sh` 保證每次都是從最新原始碼重新 build，`build_
dmg_11_plus.sh`/`build_dmg_10_15.sh` 則保留原本「不自動重新
build」的行為，給只想重新測安裝流程（原始碼沒變）的情況用。

會做這些事：

1. 讀對應 `.app` 裡 `Info.plist` 的 `CFBundleShortVersionString`，決定輸出檔名（`繁化助手-<版本>-11+.dmg`／`繁化助手-<版本>-10.15.dmg`）——版本號只在各自的 `Info.plist` 維護一份，不在這裡另外手動輸入一次；檔名帶分流後綴，不然兩包版本號一樣時會直接撞名。
2. 準備一個暫存資料夾：放進 `.app`、一個指向 `/Applications` 的捷徑（使用者拖曳安裝用）、`packaging/dmg-readme.txt`（沒有簽章、第一次打開被 Gatekeeper 擋下來時怎麼在系統設定裡允許，兩包共用同一份說明文字）、`解除安裝.command`。
3. 用 `hdiutil create` 把這個資料夾封裝成壓縮、唯讀的 `.dmg`（`UDZO` 格式，一般軟體發布用的就是這種）。

完成後在 `dist/繁化助手-<版本>-11+.dmg`／`dist/繁化助手-<版本>-10.15.dmg`（不是 `.build/`——那是 SwiftPM 自己的中間產物目錄，Finder 預設隱藏；`dist/` 才是放真正成品的地方，跟 `zh-cn-to-tw-ocr-service` 用 `dist/` 放 PyInstaller 產出是同一個慣例），`open` 它會跟使用者實際看到的畫面一樣（掛載、跳出視窗、把 App 拖進 Applications）。頂層 meta-repo 的 `build_mac_dmg.sh` 是發布用的一鍵入口：先清掉兩包的 `.build/`，照 `requirements.txt`、`requirements-build.txt` 同步 `zh-cn-to-tw-ocr-service` 的 venv 套件（PyInstaller 包進去的是 venv 裡實際裝著的版本，不是 requirements 檔寫的版本），重新打包 OCR 服務並實際啟動一次確認 `/health` 正常，再呼叫 `build_dmg_all.sh` 兩包都出。

**沒有簽章、沒有公證**——需要付費的 Apple Developer 帳號，這個專案刻意跳過，所以使用者第一次打開會被 Gatekeeper 擋下來，這是預期行為，DMG 裡的說明文字已經涵蓋怎麼處理。

## 開發時的除錯技巧

- App 啟動時把 stdout 導到檔案，能看到所有 `print()` 診斷訊息（包含 `[webview-nav]`/`[webview-console]`/`[webview-ocr-port]` 這些前綴）：

```bash
.build/繁化助手.app/Contents/MacOS/ZhCnToTw > /tmp/app.log 2>&1 &
tail -f /tmp/app.log
```

- 用 `swift run` 執行時（不是打包好的 .app），`WebView.swift` 會把 `webView.isInspectable` 打開（macOS 13.3+），可以用 Safari 的「開發」選單掛上完整 Web Inspector，看網路請求、DOM、在主控台直接下 JS 指令。打包好的 .app 不開，理由見專案報告「正式安裝的 App 收起開發用入口」。

## 常見開發用環境變數

下面這些變數只有用 `swift run` 執行時（不是打包好的 .app）才有作用，打包好的 .app 一律忽略，理由見專案報告「正式安裝的 App 收起開發用入口」。開發版沒有內嵌網頁與 OCR 服務，通常三個一起設。

- `WEB_BASE_URL_OVERRIDE`：不載入內嵌的網頁（`zhcntotw://app`），改指到一個 URL（例如本機 `python3 -m http.server` 開的網址），方便前端開發時不用每次改完都重新打包整個 App。
- `WEB_API_BASE_OVERRIDE`：桌面版預設一律打正式的 Render 網址，這個變數可以覆蓋成本機 backend，測試還沒部署的後端改動。
- `OCR_SERVICE_DEV_PATH`：指到本機用 PyInstaller 打包好的 `zh-cn-to-tw-ocr-service` 執行檔（見該 repo 的 README）。
- `ZHCNTOTW_TESSERACT_DIR`（只有 10.15 那包）：指到 `packaging/build_tesseract_10_15.sh` 的成品（`Legacy/.build/tesseract/current`）。

---

# English

## Script Murder Mystery Traditionalization Assistant — macOS Desktop Shell

A macOS desktop app that wraps the [`zh-cn-to-tw-web`](https://github.com/beethoreven/zh-cn-to-tw-web) frontend in Swift/SwiftUI + WKWebView, and embeds [`zh-cn-to-tw-ocr-service`](https://github.com/beethoreven/zh-cn-to-tw-ocr-service) as a local OCR engine. This document has two parts:

- **[Project Report](#project-report)**: why this shell exists and which WKWebView quirks it ran into.
- **[Setup Guide](#setup-guide)**: how to build and test it locally.

## Project Report

### What This Is, and Why It's Needed

`zh-cn-to-tw-web` was originally a plain browser page talking entirely to the Render backend, including OCR. Render's free tier turned out to be unable to run PaddleOCR at all (SIGILL, OOM — see `zh-cn-to-tw-backend`'s README), and the fix was moving OCR to the user's own machine — and "package a local HTTP service plus a web frontend into something a user can just double-click open" is exactly this shell's job. It carries almost no business logic itself; it's purely the glue for three things: starting/managing the local OCR subprocess, loading the web frontend, and handling the parts of Google sign-in that need OS-level help beyond what a webview alone provides.

### Architecture Overview

```
繁化助手.app/                          ← the bundle folder's own name (what Finder/the DMG show), separate from the executable's name inside it
├── Contents/MacOS/ZhCnToTw          ← the executable this repo builds; an internal implementation detail, kept as-is
└── Contents/Resources/
    ├── web/                          ← zh-cn-to-tw-web's static files (copied in at package time)
    └── ocr-service/                  ← zh-cn-to-tw-ocr-service's PyInstaller output
```

The app **does not** proactively start the OCR service at launch (see "OCR Service Lifecycle" below) — it only loads the embedded web frontend (`file://`) and has the OCR service manager standing by.

### Why the Web Frontend Loads via `file://` (Origin Stability)

The original design had the shell launch its own local backend, serving the web page over HTTP (`http://127.0.0.1:<dynamic port>`). That port is different on every launch — deliberately, this project got burned repeatedly during local testing by stale processes squatting a fixed port. But `localStorage` keys its origin by `scheme+host+port` — a different port every launch means a brand-new origin every launch, so the session token obtained after login could never be recovered, and the user had to log in again every single time (confirmed by inspection: three separate `LocalStorage` folders had accumulated under the same bundle ID).

The fix was to drop any local HTTP server entirely and load `Resources/web/index.html` from a fixed `file://` path — the same installation always resolves to the same path on every launch, so the origin is stable and `localStorage` can actually survive across restarts. This decision also incidentally resolved the local-backend-holding-credentials problem: under a `file://` architecture the shell has no need for a local backend at all, so the only backend that exists is the one on Render — the desktop app itself never contains anything worth stealing.

### WKWebView Pitfalls Hit Along the Way

Switching to `file://` triggered a string of problems never seen before, worth recording in full:

1. **`Bundle.main.resourceURL` is internally a "relative string + baseURL" composite** — `isFileURL` reports `true`, but passing it through `URLComponents(resolvingAgainstBaseURL: false)` silently drops the baseURL, yielding a scheme-less relative path. `WKWebView` reports "cannot display URL" with no indication the problem is the URL's structure. Fixed by building the path from `Bundle.main.bundlePath` (a plain string) via `URL(fileURLWithPath:)` instead.
2. **`loadFileURL(_:allowingReadAccessTo:)` needs a clean directory URL** — if the URL passed in still carries a query string (`?desktop=1&...`), the computed "parent directory" is malformed, and the load fails silently, leaving the page stuck at `about:blank`. Fixed by stripping the query via `.path` before computing the parent directory.
3. **Without implementing `didFail*`/`didFinish` on `WKNavigationDelegate`, a failed navigation gives zero indication anything went wrong** — no exception, no log, just a blank screen. These three methods are now permanently kept, purely to print diagnostics — they were the key tool that surfaced both problems above.
4. **Swift's `print()` is fully buffered (not line-buffered) when stdout isn't a TTY** (e.g. redirected to a file/pipe) — this once made newly-added diagnostic prints appear to produce nothing, briefly suggesting the code wasn't even being reached. Fixed by calling `setvbuf(stdout, nil, _IONBF, 0)` at the very start of `applicationDidFinishLaunching` — this likely also fixed a pre-existing console-forwarding feature that had silently never actually worked.
5. **Under `file://`, a page's JS has no way at runtime to read another file in the same directory** — `fetch()` is spec-prohibited, `XMLHttpRequest` is blocked by WKWebView, a hidden `<iframe>` + `contentDocument` returns `null` (WebKit treats different `file://` files, even in the same directory, as different origins). This is the root cause behind the "Teacher's Notes" feature needing three rewrites before it worked — full story in `zh-cn-to-tw-backend`'s README.
6. **Without implementing `webViewWebContentProcessDidTerminate`, the app goes blank after being left open overnight, and the reload button doesn't fix it** — the page WKWebView actually renders in is a separate Web Content process; under memory pressure or after sitting idle a long time, macOS can kill that process on its own without crashing the host app at all — the WKWebView area just goes blank. Without this delegate, nothing recovers automatically: the existing `load(url:reloadToken:into:)` decides whether to reload based on whether `lastURL`/`lastReloadToken` changed, and killing the content process changes neither, so clicking reload never actually triggers a fresh `loadFileURL`. Fixed on three layers: **(a)** while a Stage 1/2 job is genuinely running, `SystemActivityGuard` (`ProcessInfo.beginActivity` with `.idleSystemSleepDisabled`) asks the system not to let the whole machine sleep, reducing the odds this process gets killed in the first place; **(b)** that protection lifts the moment the job finishes, but there's a gap between "job done" and "user actually downloaded it" that can easily outlast the job itself — `WebView.Coordinator` also observes `NSWorkspace.willSleepNotification` and, right before the system actually sleeps, calls the page's `window.__attemptAutoSaveBeforeSleep()` (see `zh-cn-to-tw-web`'s README) to save any undownloaded result to disk on the user's behalf; this deliberately uses the simple notification rather than IOKit's power-management API to actually request a sleep delay (far more complex), so it's best-effort and not guaranteed to finish in time; **(c)** if the process still gets killed, `webViewWebContentProcessDidTerminate` doesn't hard-retry on the same (possibly now-unstable) WKWebView — it notifies `ContentView`, which tears the WebView out of the view hierarchy entirely and shows a zero-cost native SwiftUI message instead; clicking reload has SwiftUI call `makeNSView` again for a brand-new WKWebView, doing a clean `loadFileURL` from scratch (which incidentally means a fresh `allowingReadAccessTo` grant too, sidestepping the old grant dying with the old process).

None of these are specific to this project; any desktop shell built on WKWebView is likely to hit them.

### OCR Service Lifecycle

This evolved alongside the frontend discussion through a few iterations:

- **v1**: the app started the OCR service at launch and kept it running for the whole session.
- **v2**: added "self-shutdown after 30 minutes idle" plus "a health check every 30 seconds that respawns it if it's not running" — the two fought each other, respawning shortly after every shutdown, so memory was never actually reclaimed.
- **v3 (current)**: control is handed entirely to the web frontend. `WebView.swift` registers an `ocrService` `WKScriptMessageHandler`; `zh-cn-to-tw-web`'s `js/stages/ocr.js` sends `{action: "start"}` right before it actually needs to send a PDF, and `{action: "stop"}` once the OCR step ends (success or failure). The app never starts it proactively at launch.

Paired with this is a port-notification mechanism: whenever the service starts or stops, `OCRServiceManager` pushes the current port (or `null`) straight into the page's `window.__OCR_PORT__` via `WKWebView.evaluateJavaScript` — **deliberately not** via a URL query parameter plus a page reload, which would wipe out whatever the user had half-filled into a form.

One easily-missed detail: the `readabilityHandler` (used to read the subprocess's stdout for its port number) will, if not explicitly unregistered, cause GCD to treat a pipe that's hit EOF (the subprocess exited) as "always readable" and call the closure in an infinite tight loop — measured: the moment the subprocess dies, the app's CPU jumps from 0% straight to 96% and never comes back down; an app left open for hours, respawned a few times along the way, was measured at 283%. Fixed by clearing `handle.readabilityHandler = nil` the moment an empty read is observed.

### Google Sign-In

Completes the OAuth flow through the system browser (not a popup embedded inside WKWebView), then hands Google's ID token back to the web frontend, which exchanges it with the backend for a session token stored in `localStorage`. See `GoogleDesktopSignIn.swift`.

Google's callback is delivered to a fixed local address, `127.0.0.1:53682`. Any other program on the same machine, and any web page the user has open, can reach that port, so the sign-in URL carries a random `state` unique to this attempt (Google echoes it back in the callback), and the shell only accepts the one request whose `state` matches and whose `id_token` has the shape of a JWT (three base64url segments). Everything else — a connection the browser opened in advance and never used, a request that isn't a form POST, a request with the wrong `state` — is ignored and the shell keeps waiting, up to the 300-second timeout; a matching `state` without a token (the user cancelled, or Google reported an error) fails the sign-in immediately. Each ignored request leaves one log line saying what happened, never the request's contents.

The sign-in URL also carries a nonce: for each sign-in the shell generates a random raw value that stays inside the app, and the URL carries its SHA-256 (base64url, no `=`), which Google copies verbatim into the ID Token. After sign-in, the shell hands the token together with the raw value to the page, which sends both to the backend; the backend issues a session only if the hash matches (see the "Sign-In" section of `zh-cn-to-tw-backend`'s README). The token passes through the system browser and the local callback, but the raw value does not, so someone who only obtains the token cannot exchange it for a session. The hash must be computed identically on both sides (`GoogleDesktopSignIn.hashedNonce` matches `hashed_nonce` in the backend's `auth_utils/auth.py`); measured (2026-11-19): for several raw values (including Chinese text and `+/=`) both sides produce exactly the same result, and in a real run of the sign-in callback on `127.0.0.1:53682`, the raw value the shell hands over hashes to exactly the nonce in the sign-in URL. Not yet tried with a real Google account.

### The Shell Only Accepts Messages from Its Own Page

The page asks the shell to do things through `window.webkit.messageHandlers.<channel>`: start sign-in, start or stop the local OCR service, keep the system awake; the `10.15` build additionally has a file-writing channel (`legacyDownload`) and an OCR channel (`visionOcr`). These channels hang off the `WKUserContentController`, so every frame and every popup created from the same configuration can call them. Before handling any message, `WebView.swift` therefore checks three things: it came from the shell's own `WKWebView`, from the outermost frame, and from the same origin as the URL the shell loaded. Otherwise the message is ignored and one log line is written.

The other direction gets the same care: every string the shell hands to the page (the token from sign-in, a file name, a system error message) is first JSON-encoded into a JavaScript string literal before being placed into the code to run — hand-escaping only has to miss one character for the string to end somewhere unexpected.

Measured (2026-11-19, macOS 26.6.2, a real `WKWebView` loading pages from the custom scheme): WebKit reports the origin of `zhcntotw://app` as scheme `zhcntotw`, host `app`; messages from the shell's own page are accepted, while messages from an iframe inside it, from a page the view was navigated to on another origin, and from a second `WKWebView` created with the same configuration are all ignored. If an older WebKit reports an origin without a host, the check falls back to comparing the frame's own URL (`ShellSafety.isOwnPage`); that fallback has not yet been verified on a real macOS 10.15/11 machine.

### An Installed App Keeps Developer Entry Points Closed and Opens Only Its Own Page

- **Developer entry points work only in development builds**: `WEB_BASE_URL_OVERRIDE`, `WEB_API_BASE_OVERRIDE`, `OCR_SERVICE_DEV_PATH`, the 10.15 build's `ZHCNTOTW_TESSERACT_DIR`, and Safari's Web Inspector (`isInspectable`) only take effect when the app is not running from a packaged .app (e.g. `swift run`) (`ShellSafety.developmentOverride`, `ShellSafety.isPackagedApp`). These variables can make the app talk to another backend, load another page, or run another program; the inspector can read the login session in localStorage and run arbitrary code in the page. `#if DEBUG` can't tell the difference: the packaging scripts build with the debug configuration by default (`CONFIG` in `packaging/build_app_*.sh`), so an app installed on a user's machine may well be a debug build. Measured (2026-11-21): the same binary ignores all four variables when run as a .app and reads them all when run as a bare executable.
- **Only its own page is opened**: navigation is allowed only to the origin the shell loaded (`zhcntotw://app`; during development, the origin of `WEB_BASE_URL_OVERRIDE`), `about:`, and `blob:` URLs created by the shell's own page (`ShellSafety.isAllowedInAppNavigation`). http(s) links the user clicks open in the system browser; anything else (the page's own code changing the URL, form submissions, redirects) is blocked. Previously only "the user clicking a link to another domain" was intercepted and every other navigation went through; this shell has no address bar, so with any website opened inside it the user couldn't tell whether they were still looking at this app.
- **No new windows**: `window.open()` and `target="_blank"` never open inside the app; http(s) links the user clicks go to the system browser. New windows were left over from running Google sign-in inside an embedded WebView, which opened another WKWebView with the same configuration; since sign-in moved to the system browser they are no longer needed.
- The page itself also has a CSP (see "Page Security Settings" in `zh-cn-to-tw-web`'s README). WebKit's `'self'` doesn't match the custom scheme, so the CSP must spell out `zhcntotw:`, or all of the app's own scripts are blocked.

Measured (2026-11-21, macOS 26.6.2, a real WKWebView loading the page bundled in a .app through `WebAssetSchemeHandler`): the app's own ES modules run, and the shell's `evaluateJavaScript` and document-start injected script are unaffected by the CSP; inline scripts, external scripts, images sent outward, and fetches sent outward that are injected into the page are all blocked by the CSP; the page's code navigating to another site is blocked, `window.open` returns null and no extra window appears; URLs on the app's own origin still load. `WKDownload` on 11+ and `legacyDownload` on 10.15 still save files.

### Version Control and Forced Updates

Version control goes through GitHub Releases (under the `zh-cn-to-tw-mac` repo, one Release per version tier, with the DMG as a release asset — see "Building the .dmg" below). The version-comparison logic only uses the major/minor pair from `CFBundleShortVersionString`, ignoring any third digit — `ContentView.appVersionMajorMinor` just splits the string on `.` and takes the first two segments, falling back to `0.0` if that doesn't parse into two integers (pure defensiveness, shouldn't happen in practice). `desktopURL()` passes those two numbers to the page as `appMajor`/`appMinor`; before starting any Stage 1/2 work, the page calls `GET /api/version_check` to ask the backend whether this version is still new enough, and blocks the action with a dialog pointing to the update page if not (full flow in `zh-cn-to-tw-web`'s README, "Desktop Forced-Update Check," and `zh-cn-to-tw-backend`'s README, "Version Check").

### Version Tiers: 11+ and 10.15

The whole app originally shared one `Package.swift` (`platforms: [.macOS(.v13)]`), and `LSMinimumSystemVersion` was hardcoded to `13.0`. Later investigation found that `13.0` floor was just a conservative default picked at the start — a full sweep of the codebase turned up nothing that actually needs 13.0 (SwiftUI's `App`/`Scene`/`WindowGroup` only need 11.0+, `WKDownload` only needs 11.3+). So the main build's deployment target got lowered to `.v11`, and the tier that used to lock Stage 1 entirely (`12-`) was reworked into a `10.15` tier instead: Stage 1 no longer depends on the `zh-cn-to-tw-ocr-service` Python service and uses a bundled Tesseract instead (up to and including 2.0 it used Apple's Vision framework — see "Why 10.15 OCR uses Tesseract" below). The split still has to exist because RapidOCR's onnxruntime dependency has its `minos` hardcoded to `11.0` in its compiled binary (confirmed with `otool -l`) — no Python-based OCR engine runs on 10.15 at all, that's a hard constraint, not a design choice:

- **11+** (root `Package.swift`): `platforms .v11`, Stage 1 and 2 both work, Stage 1 uses the local `zh-cn-to-tw-ocr-service` (RapidOCR).
- **10.15** (`Legacy/Package.swift`): `platforms: [.macOS(.v10_15)]`, Stage 1 and 2 both work, but Stage 1 uses a bundled Tesseract instead, with lower recognition quality than `11+` (see below).

The two are **separate SwiftPM packages**, not two targets in one `Package.swift` — SwiftPM's `platforms` setting is package-wide, there's no per-target deployment target. Under `Legacy/Sources/ZhCnToTwLegacy/`, `ContentView.swift`/`WebView.swift`/`GoogleDesktopSignIn.swift`/`SystemActivityGuard.swift`/`Uninstaller.swift` are all **symlinks** back to the same files under `Sources/ZhCnToTw/`, not a second copy to maintain; two files are genuinely unique to this target and not symlinked: `App.swift` (the entry point) and `TesseractOCRManager.swift` (the OCR implementation that calls the bundled Tesseract):

- SwiftUI's `App`/`Scene`/`WindowGroup`/`.commands`/`NSApplicationDelegateAdaptor` — the whole declarative app-lifecycle API — all need **macOS 11.0+** (confirmed by actually running `swift build` against `.v10_15` and getting a hard error); Catalina's SwiftUI 1.0 simply doesn't have this API surface. `Legacy`'s `App.swift` goes back to a classic `NSApplicationDelegate` + manually-created `NSWindow` + `NSHostingController`, with the menu bar built by hand too (including an Edit menu — without it, Cmd+C/V might not even work in WKWebView's own text fields).
- The whole `WKDownload`/`WKDownloadDelegate` API (including `WKNavigationActionPolicy.download`) needs **macOS 11.3+** (confirmed against the SDK headers), so the shared `WebView.swift` moved those methods into an `@available(macOS 11.3, *) extension WebView.Coordinator: WKDownloadDelegate` — the `10.15` build simply doesn't compile that extension in. Downloads there go through a `legacyDownload` message channel instead: `script.js` detects `osTier === "10.15"` and posts the download content as base64 directly, which the shell decodes and writes to the Downloads folder (see `handleLegacyDownload` in `WebView.swift`); `11+` and plain browsers still use `WKDownload`. The channel is registered only in the `10.15` build — `11+` has no use for it, and a channel that lets the page tell the shell to write a file stays closed unless it is needed. The file name comes from the page (ultimately from the server's response), so the shell keeps only its last path component, accepts only `.txt`/`.docx` (the only two kinds of file this app produces; the page accepts only these too, and the shell checks again), and, before writing, confirms the destination really sits directly inside the Downloads folder; the suggested file name on the `WKDownload` path gets the same treatment (`ShellSafety.downloadDestination`). Anything rejected is not written, and the page is asked to show an error message. Measured (2026-11-19, macOS 26.6.2, a real `WKWebView` triggered through both `<a download>` and `legacyDownload`): `.txt`/`.docx` save normally; `.command`, `.app`, `.sh`, and a `.command` hidden behind a control character are all rejected; a name containing `../` keeps only its last component; for a name with no extension, WebKit itself appends `.txt` based on the MIME type. Cancelling a `WKDownload` by returning nil from the destination decision does not trigger `didFailWithError`, so the error message has to be sent from the place that cancels.
- `Image(systemName:)` and `.help(_:)` need 11.0+, so the reload button in `ContentView.swift` branches on `#available(macOS 11.0, *)` (the icon button above that line, a plain text button below); some `.foregroundStyle` overloads need macOS 14.0, so all of them were replaced with the much older, behaviorally-identical `.foregroundColor` — both builds benefit, with no visible difference.

`ContentView.swift` computes `osTier` (`"11+"` or `"10.15"`) via `#if LEGACY_BUILD` (defined by `Legacy/Package.swift`'s `swiftSettings: [.define("LEGACY_BUILD")]`; the `11+` target doesn't define it) and passes it to the page through `desktopURL()`'s `osTier` query parameter; the page uses it to decide which tier's threshold to query via `GET /api/version_check` (sent as an `os_version` parameter — see `zh-cn-to-tw-backend`'s README, "Version Check"), whether local OCR goes through HTTP polling or the `visionOcr` message channel, and whether to download via `WKDownload` or `legacyDownload`.

**The `10.15` build does not embed `zh-cn-to-tw-ocr-service`** — Stage 1 there runs through `TesseractOCRManager.swift` calling the bundled Tesseract (`Contents/Resources/tesseract/`, about 5 MB of executable plus a 2.5 MB Simplified Chinese model), so it doesn't need that Python service at all, and the DMG is noticeably smaller than the `11+` build as a result.

#### Why 10.15 OCR uses Tesseract

Up to and including 2.0, the `10.15` build used Apple's Vision framework (`VNRecognizeTextRequest` with `recognitionLanguages = ["zh-Hans", "zh-Hant"]`). In 2026-11 the first report from a real 10.15 machine said the output was "garbled": it was actually lines of uppercase Latin letters mixed with full-width punctuation added by Stage 2. The cause: 10.15's Vision only has `VNRecognizeTextRequestRevision1`, whose SDK header says it "only supports English"; the Chinese-capable Revision2 requires macOS 11 (calling `supportedRecognitionLanguages(for: .accurate, revision: 1)` on the dev machine also returns only `["en-US"]`). Requesting an unsupported language doesn't error — Vision silently falls back to its English model. Earlier testing on a newer system looked perfectly fine because newer Vision defaults to Revision3, which has Chinese — lowering the deployment target guarantees the API exists, not that it has the same capabilities.

It now uses Tesseract 5.5.4 + Leptonica 1.87.0, built from source by `packaging/build_tesseract_10_15.sh` (versions and SHA-256 pinned in the script): both built static with all external image formats and networking disabled, so the result depends only on the system `libSystem` and `libc++` with `minos` 10.15; the script checks both at the end and aborts if either fails. x86_64 only: any Mac running 10.15 is Intel. The model is `chi_sim` from `tessdata_fast`.

Evaluation against `11+`'s RapidOCR on 5 real script pages (share of Chinese characters both recognized): clean single-column scans 0.96–0.97, typical pages 0.88–0.90, phone-photographed skewed spreads only 0.78 ("split left/right pages" didn't help). `tessdata_best` was nearly identical but 2–3× slower, hence fast. It's actually faster than RapidOCR (2–6 s vs. 12–31 s per page on the same Intel dev machine).

Tesseract's `chi_sim` inserts spaces between Chinese characters; `TesseractOCRManager.cleanUp` removes spaces between Chinese characters (including full-width punctuation) but leaves spaces between English words alone, and doesn't convert half-width punctuation since Stage 2 already does. If the result has almost no Chinese (under 20%), a warning appears in the progress log, so a run can no longer "look successful but be entirely garbled."

The dpi sent by the page is clamped to 100–400 (the same range as the frontend's DPI field and `zh-cn-to-tw-ocr-service`) before PDFKit renders with it: the value comes from the page, and a huge one would render an enormous bitmap — a single page could eat several GB of memory.

#### The 10.15 build's log file

When the app is opened from Finder/Dock, stdout and stderr go nowhere and `print()` output is lost (it's not in Console.app either). At launch, if stdout isn't a terminal, the `10.15` build redirects stdout and stderr to `~/Library/Logs/ZhCnToTw/app.log` (rotated to `app.log.1` past 5 MB) — WebView load status, forwarded page console output, and per-page OCR timing and errors. To collect it from a user, have them use Finder's "Go" → "Go to Folder…" with `~/Library/Logs/ZhCnToTw` and send `app.log`. Running directly from a terminal keeps printing there. The `11+` build doesn't have this yet.

Both builds currently share the **same `CFBundleIdentifier`** (`com.beethoreven.zh-cn-to-tw`) — a real user only ever installs one of the two (whichever matches their macOS version), so from their perspective it's the same app. That does mean installing both on one machine for testing shares the same `~/Library/WebKit/<bundle-id>` data etc., and the second install in `/Applications` overwrites the first — a testing-only limitation, not something that affects real usage.

**Not yet tested on a genuinely old system (macOS 10.15).** Lowering the deployment target only guarantees the code compiles and links against that OS version's API surface — it doesn't guarantee identical runtime behavior, especially the `legacyDownload` path and the bundled Tesseract executable. The dev machine (Apple Silicon, running macOS 26) can't run macOS 12 and below via Virtualization.framework (that's Intel-era software), so there's no way to verify without real old hardware. What has been confirmed: this build installs, opens, and runs the basic flow fine — including Stage 1's Tesseract OCR — on a *newer* system (Tahoe), because a deployment target is a floor, not a ceiling, and `dyld` only checks "current OS ≥ minos." But that approach has a blind spot, and it did bite: the Vision framework version looked perfectly fine on a newer system yet only recognized English on 10.15 (see "Why 10.15 OCR uses Tesseract" above). With Tesseract, recognition no longer depends on the OS version; the remaining risk is whether the bundled executable launches on 10.15 at all (10.15-era libc++ features like `std::filesystem` pass the compile-time checks but haven't been verified on real hardware).

### Known Limitations

- A Windows version hasn't been started yet (planned to follow the same architecture, just with a different UI framework).
- **Deliberately no code signing or notarization**: that needs a paid Apple Developer account, which this project skips. DMG packaging is done (`packaging/build_dmg_11_plus.sh`/`build_dmg_10_15.sh`), but being unsigned means Gatekeeper blocks first launch; the DMG bundles a `dmg-readme.txt` explaining how to allow it in System Settings.
- The DMG is produced locally by running the script, then manually published to GitHub Releases via `gh release create`/`gh release upload` (tags `v<version>-11-plus`/`v<version>-10-15`) — no CI automation yet, so every new version is a manual step, and the download page's links (the `update-page` branch of `zh-cn-to-tw-web`) need to be kept in sync by hand too. Release asset filenames are deliberately ASCII (`ZhCnToTw-<version>-11+.dmg`/`ZhCnToTw-<version>-10.15.dmg`), not the CJK filenames used locally — the `gh` CLI (tested against 2.96.0) silently truncates the leading CJK bytes off an uploaded asset's name, and an ASCII filename sidesteps that bug entirely.
- The `10.15` build hasn't been tested on a real old system yet — see the last point under "Version Tiers" above.

---

# Setup Guide

## Requirements

- macOS 11+ to build the `11+` package; building the `10.15` package works fine on macOS 11.3+ dev machines too (`swift build` only compiles — a deployment target is a runtime floor, not a "minimum dev machine" requirement), but final verification needs real old hardware, see "Version Tiers" above.
- Xcode (with the Swift 5.9+ toolchain)
- Building the `11+` package needs a built `zh-cn-to-tw-ocr-service` (see that repo's README, produces `dist/zh-cn-to-tw-ocr-service/`) — without it the app still opens, local OCR just shows a startup failure. The `10.15` package doesn't need that Python service, but does need `cmake` and `ninja` (`brew install cmake ninja`): on the first build, `build_app_10_15.sh` calls `build_tesseract_10_15.sh` to download sources and compile Tesseract (about 3 minutes), cached under `Legacy/.build/tesseract/` and not rebuilt afterward.

## Building the .app

Two separate scripts, not one script with a flag — they correspond to two independent `Package.swift` files (a different `--package-path` each), see "Version Tiers" above.

```bash
cd zh-cn-to-tw-mac
bash packaging/build_app_11_plus.sh debug   # macOS 11+ build
bash packaging/build_app_10_15.sh debug     # macOS 10.15 build (bundled Tesseract OCR)
```

Each does:

1. `swift build` (`11+` uses the root `Package.swift`; `10.15` uses `--package-path Legacy`) to compile the bare executable.
2. Assembles the `.app` bundle structure (the matching `Info.plist`/`Info-10-15.plist`, icon).
3. The `11+` build copies the entire `../zh-cn-to-tw-ocr-service/dist/zh-cn-to-tw-ocr-service/` directory into `Resources/ocr-service/` (override path via `OCR_SERVICE_DIST_DIR`); the `10.15` build skips this step.
4. Copies `../zh-cn-to-tw-web/`'s `index.html` and its `assets/`, `css/`, `js/` folders into `Resources/web/` (override path via `WEB_SRC_DIR`; if any is missing the build stops, since the app would open to a blank page) — both builds share the same web source, reading `zh-cn-to-tw-web`'s `main` branch, unrelated to the `update-page` branch GitHub Pages serves (see that repo's README).

Then:

```bash
open .build/繁化助手.app              # 11+
open Legacy/.build/繁化助手.app       # 10.15 (each package keeps its own .build/, so they never collide)
```

## Building the .dmg

`build_dmg_11_plus.sh`/`build_dmg_10_15.sh` only do the "wrap an
already-built `.app` into a DMG" step — they do **not** re-run
`swift build` or re-copy `zh-cn-to-tw-web`'s source. Build the matching
`.app` first per the steps above, then:

```bash
bash packaging/build_dmg_11_plus.sh debug   # 11+ only
bash packaging/build_dmg_10_15.sh debug     # 10.15 only
```

`build_dmg_all.sh` (the top-level meta-repo's `build_mac_dmg.sh` calls it
after rebuilding the embedded OCR service) is the only entry point meant to be used as "rebuild everything
in one command" — unlike the two above, it re-runs
`build_app_11_plus.sh`/`build_app_10_15.sh` first (swift build +
re-assembling the `.app`, including a fresh copy of the web frontend
source), then packages both DMGs, so any source change is guaranteed
to show up in its output:

```bash
bash packaging/build_dmg_all.sh debug       # swift build through both DMGs, one shot
```

**This is a lesson from a real incident**: `build_dmg_all.sh` used to
just call the two "package only, never rebuild" scripts above in
sequence. Change the Swift or web frontend source, run only that
top-level script, and it would quietly wrap the *old* `.app` into a
DMG with a fresh file timestamp but stale content inside — no error,
no warning, the change simply never showed up in the installed result,
looking exactly like "the fix didn't take" when the real problem was
that this script never rebuilt anything. Fixed as above: `build_dmg_
all.sh` now always rebuilds from current source; `build_dmg_11_plus.sh`/
`build_dmg_10_15.sh` keep their original "never auto-rebuild"
behavior, for when you just want to re-test the install flow itself
with unchanged source.

This does:

1. Reads `CFBundleShortVersionString` from the matching `.app`'s `Info.plist` to name the output (`繁化助手-<version>-11+.dmg` / `繁化助手-<version>-10.15.dmg`) — each version number is maintained in exactly one place, not typed in again here; the tier suffix keeps the two from colliding when their version numbers match.
2. Prepares a staging folder: the `.app`, a symlink to `/Applications` (the drag target users see), `packaging/dmg-readme.txt` (how to allow the app in System Settings when Gatekeeper blocks first launch, shared by both), and `解除安裝.command`.
3. Packages that folder into a compressed, read-only `.dmg` with `hdiutil create` (`UDZO` format — the standard one used for shipping software).

The result lands at `dist/繁化助手-<version>-11+.dmg` / `dist/繁化助手-<version>-10.15.dmg` (not `.build/` — that's SwiftPM's own intermediate-artifact directory, hidden by Finder by default; `dist/` is where the actual shippable output goes, the same convention `zh-cn-to-tw-ocr-service` uses for its PyInstaller output); `open`ing it shows exactly what an end user would see. The top-level meta-repo's `build_mac_dmg.sh` is the one-command entry point for releases: it clears both packages' `.build/`, syncs `zh-cn-to-tw-ocr-service`'s venv with `requirements.txt` and `requirements-build.txt` (PyInstaller bundles the versions actually installed in the venv, not the ones the requirements files name), re-packages the OCR service and starts it once to confirm `/health` responds, then calls `build_dmg_all.sh` to build both.

**No code signing, no notarization** — that needs a paid Apple Developer account, which this project deliberately skips, so users get blocked by Gatekeeper on first launch. That's expected; the bundled readme text already covers what to do about it.

## Debugging Tips During Development

- Redirect stdout to a file at launch to see every `print()` diagnostic (including the `[webview-nav]`/`[webview-console]`/`[webview-ocr-port]` prefixed ones):

```bash
.build/繁化助手.app/Contents/MacOS/ZhCnToTw > /tmp/app.log 2>&1 &
tail -f /tmp/app.log
```

- When run via `swift run` (not a packaged .app), `WebView.swift` turns on `webView.isInspectable` (macOS 13.3+), so Safari's Develop menu can attach the full Web Inspector — network requests, the DOM, and a live JS console. A packaged .app doesn't; see "An Installed App Keeps Developer Entry Points Closed" in the Project Report.

## Useful Dev-Time Environment Variables

These variables only take effect when running via `swift run` (not a packaged .app); a packaged .app ignores them all — see "An Installed App Keeps Developer Entry Points Closed" in the Project Report. A development build has no bundled page or OCR service, so the first three are usually set together.

- `WEB_BASE_URL_OVERRIDE`: skip loading the embedded page (`zhcntotw://app`) and point at a URL instead (e.g. a local `python3 -m http.server`), so frontend changes don't require rebuilding the whole app every time.
- `WEB_API_BASE_OVERRIDE`: the desktop build always hits the production Render URL by default; this overrides it to a local backend for testing not-yet-deployed backend changes.
- `OCR_SERVICE_DEV_PATH`: points at a locally PyInstaller-built `zh-cn-to-tw-ocr-service` executable (see that repo's README).
- `ZHCNTOTW_TESSERACT_DIR` (10.15 build only): points at the output of `packaging/build_tesseract_10_15.sh` (`Legacy/.build/tesseract/current`).
