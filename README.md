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

這幾條後來被整理進 `known-issue-check` skill 的通用清單（不是這個專案獨有的踩坑記錄，而是任何桌面殼 + WKWebView 專案都可能撞到的模式）。

### OCR 服務生命週期

跟網頁前端的討論一起演化過幾次：

- **v1**：App 啟動就拉起 OCR 服務，整個執行期間開著。
- **v2**：加「閒置 30 分鐘自我關閉」+「健康檢查每 30 秒發現沒在跑就重新拉起」——兩個機制互相打架，關掉沒多久又被拉起來，記憶體從沒真的被回收過。
- **v3（目前）**：完全交給網頁前端主動控制。`WebView.swift` 註冊一個 `ocrService` 的 `WKScriptMessageHandler`，`script.js` 在真的要送 PDF 之前才發 `{action: "start"}`，OCR 階段結束（不管成功失敗）就發 `{action: "stop"}`。App 啟動時完全不主動開它。

搭配的還有 port 通知機制：服務起來/關掉時，`OCRServiceManager` 會把最新的 port（或 `null`）透過 `WKWebView.evaluateJavaScript` 直接寫進網頁的 `window.__OCR_PORT__`，**刻意不透過改網址查詢參數再重新載入頁面**（那樣會清掉使用者填到一半的表單狀態）。

還有一個容易忽略的細節：`readabilityHandler`（讀取子行程 stdout 用來抓 port 號）在 pipe 進入 EOF（子行程結束）後，如果沒有主動解除，GCD 會判定這個 fd「隨時可讀」而無限次重複呼叫這個 closure——實測子行程一死，App 的 CPU 從 0% 直接衝到 96% 且不會回落，開了幾小時、中途重啟過幾次的 App 甚至量到 283%。修法是讀到空資料就把 `handle.readabilityHandler = nil`。

### Google 登入

用系統瀏覽器完成 OAuth 流程（不是嵌在 WKWebView 裡跳出的彈窗），完成後把 session token 回傳給網頁前端存進 `localStorage`。見 `GoogleDesktopSignIn.swift`。

### 版本管控與強制更新

版控走 GitHub Releases（DMG 當附件掛上去，還沒做），版本比較邏輯只用 `CFBundleShortVersionString` 的 major/minor 兩碼，不看第三碼——`ContentView.appVersionMajorMinor` 直接用 `.` 切開字串取前兩段，拆不出兩個整數就當 `0.0`（純防禦，理論上不會發生）。`desktopURL()` 組網址時把這兩個數字用 `appMajor`/`appMinor` 帶給網頁，網頁在真的要開始 Stage 1/2 工作前打 `GET /api/version_check` 問 backend 這個版本夠不夠新，過舊就擋下操作並跳窗導去更新頁（完整流程見 `zh-cn-to-tw-web` README「桌面版的強制更新檢查」、`zh-cn-to-tw-backend` README「版本檢查」）。

### 版本分流：13+ 與 12-

一開始整支 App 用同一個 `Package.swift`（`platforms: [.macOS(.v13)]`），`LSMinimumSystemVersion` 也寫死 `13.0`——系統版本不夠新，App 連開都開不起來，包含完全不依賴 OCR 的 Stage 2 校對。這其實是舊系統版本的使用者「連校對都不能做」的唯一理由，不是 Stage 2 本身需要 macOS 13——後來決定拆成兩包獨立版控的 build，讓 macOS 12 以下至少能用 Stage 2：

- **13+**（根目錄 `Package.swift`）：跟原本完全一樣，`platforms .v13`，Stage 1/2 都能用。
- **12-**（`Legacy/Package.swift`）：`platforms: [.macOS(.v10_15)]`，Stage 1 在網頁那層直接鎖住（`stage1-form-group` 整塊隱藏，只留一行「Stage 1功能只支援Mac OS 13以上。」），Stage 2 正常可用。

兩包是**兩個獨立的 SwiftPM package**，不是同一個 `Package.swift` 裡的兩個 target——SwiftPM 的 `platforms` 是整個 package 共用一份，沒有 per-target 的部署目標可以設。`Legacy/Sources/ZhCnToTwLegacy/` 底下，`ContentView.swift`/`WebView.swift`/`GoogleDesktopSignIn.swift`/`OCRServiceManager.swift`/`SystemActivityGuard.swift`/`Uninstaller.swift` 全部是**符號連結**指回 `Sources/ZhCnToTw/` 底下同一份檔案，不是複製維護兩份；真正只有 `12-` 這個 target 專屬的只有一份新的 `App.swift`：

- SwiftUI 的 `App`/`Scene`/`WindowGroup`/`.commands`/`NSApplicationDelegateAdaptor` 整組宣告式生命週期都要 **macOS 11.0+** 才有（實測 `swift build` 對 `.v10_15` 直接報錯），10.15 的 SwiftUI 1.0 根本沒有這組 API。`Legacy` 的 `App.swift` 改回傳統的 `NSApplicationDelegate` + 手動 `NSWindow` + `NSHostingController`，選單也改成手動組 `NSMenu`（含 Edit 選單，不然 WKWebView 裡的輸入框可能連 Cmd+C/V 都用不了）。
- `WKDownload`/`WKDownloadDelegate` 整組（含 `WKNavigationActionPolicy.download`）要 **macOS 11.3+**（SDK 標頭實測確認），共用的 `WebView.swift` 因此把這幾個方法搬進一段 `@available(macOS 11.3, *) extension WebView.Coordinator: WKDownloadDelegate`——`12-` 那包完全不會編到這段。下載改靠新的 `legacyDownload` message channel：`script.js` 偵測到 `osTier === "12-"` 時，把下載內容轉成 base64 直接 `postMessage` 過去，殼收到後解碼寫進下載資料夾（見 `WebView.swift` 的 `handleLegacyDownload`）；`13+` 跟純瀏覽器都還是走原本 `WKDownload` 那條路，行為不變。
- `Image(systemName:)`、`.help(_:)` 要 11.0+，`ContentView.swift` 的重新整理按鈕因此用 `#available(macOS 11.0, *)` 分兩支（11+ 用原本的圖示按鈕，以下退回純文字按鈕）；`.foregroundStyle` 有的重載要到 14.0 才有，全面換成很舊、行為等價的 `.foregroundColor`，兩包都受惠、沒有可見差異。

`ContentView.swift` 用 `#if LEGACY_BUILD`（`Legacy/Package.swift` 用 `swiftSettings: [.define("LEGACY_BUILD")]` 定義，`13+` 那個 target 沒有）算出 `osTier`（`"13+"` 或 `"12-"`），透過 `desktopURL()` 的 `osTier` 查詢參數帶給網頁；網頁拿它決定要不要鎖 Stage 1、`GET /api/version_check` 要查哪個分流的門檻（帶成 `os_version` 參數，見 `zh-cn-to-tw-backend` README「版本檢查」）、下載要走 `WKDownload` 還是 `legacyDownload`。

**`12-` 那包依然內嵌 `zh-cn-to-tw-ocr-service`**，即使 Stage 1 用不到——`AppDelegate` 的 `ocrManager` 是 eager 初始化，找不到 OCR 執行檔會直接 `fatalError()`，不內嵌的話這包會直接開不起來，不是 Stage 1 按了沒反應那麼溫和。這是刻意的取捨（犧牲一點 DMG 體積換改動範圍最小），之後想瘦身要連 `AppDelegate.resolveOCRServiceExecutable` 的防呆邏輯一起改。

兩包目前用**同一個 `CFBundleIdentifier`**（`com.beethoreven.zh-cn-to-tw`）——真實使用者只會裝其中一包（依自己的 macOS 版本選對應的 DMG），從使用者角度就是同一個 App。這代表在同一台機器上先後裝兩包做測試會共用同一份 `~/Library/WebKit/<bundle-id>` 等資料、後裝的會蓋掉 `/Applications` 裡先裝的那個，不能同時裝著並排比較——只是本機測試才會遇到的限制，不影響正式使用情境。

**還沒有在真正的舊系統（macOS 10.15–12）上實測過。** 部署目標壓低只保證程式碼在該版本的 API 集合下能編譯、能連結，不保證執行期行為完全一致——尤其 `legacyDownload` 這條全新的下載路徑，開發機（Apple Silicon，跑 macOS 26）沒辦法用 Virtualization.framework 跑到 macOS 12 以下（那是 Intel 時代的系統），沒有真實舊硬體無法驗證。已經確認過的是：這包在**新系統**（Tahoe）上能正常裝、開、跑基本流程——因為部署目標只是下限不是上限，`dyld` 只檢查「目前系統版本 ≥ minos」，這是在新機器上先驗證整體邏輯的正常開發流程，但 `#available(macOS 11.3, *)` 這種分支在新系統上永遠會走新的那一支，測不到 `12-` 專屬的 fallback 邏輯本身。

### 已知限制

- Windows 版尚未開始（未來規劃跟這個殼架構相同，只是換一套 UI 框架）。
- **刻意不做程式碼簽章／公證**：需要付費的 Apple Developer 帳號，這個專案跳過。DMG 打包已經做了（`packaging/build_dmg_13_plus.sh`/`build_dmg_12_minus.sh`），但沒有簽章代表使用者第一次打開會被 Gatekeeper 擋下來，DMG 裡附了 `dmg-readme.txt` 說明怎麼在系統設定裡允許。
- DMG 目前只能在本機手動跑腳本產出，還沒有掛到 GitHub Releases 做版本控管（規劃中）。
- `12-` 那包還沒有在真實舊系統上實測過，見上面「版本分流」段落最後一點。

---

# 架設 SOP / Setup Guide

## 需求

- macOS 13+（打包 `13+` 那包）；打包 `12-` 那包本身在 macOS 11.3+ 的機器上就能做（`swift build` 只是編譯，部署目標是「執行期下限」不是「開發機下限」），但沒有真正舊系統沒辦法做最終驗證，見上面「版本分流」的說明。
- Xcode（含 Swift 5.9+ 工具鏈）
- 已經打包好的 `zh-cn-to-tw-ocr-service`（見該 repo的 README，`dist/zh-cn-to-tw-ocr-service/`）——沒有的話 App 還是能開，只是本機 OCR 功能會顯示服務啟動失敗；`12-` 那包更嚴格，完全沒有的話會直接 `fatalError()` 開不起來（見上面的說明）。

## 打包成 .app

兩包分開兩支腳本，不是同一支帶參數切換——對應兩個獨立的 `Package.swift`（`--package-path` 本身就不同），見上面「版本分流」的說明。

```bash
cd zh-cn-to-tw-mac
bash packaging/build_app_13_plus.sh debug   # macOS 13+ 那包
bash packaging/build_app_12_minus.sh debug  # macOS 12 以下那包（Stage 1 鎖住）
```

各自會做這些事：

1. `swift build`（`13+` 用根目錄的 `Package.swift`，`12-` 用 `--package-path Legacy`）編出裸執行檔。
2. 組出 `.app` bundle 結構（對應的 `Info.plist`/`Info-12-minus.plist`、圖示）。
3. 複製 `../zh-cn-to-tw-ocr-service/dist/zh-cn-to-tw-ocr-service/` 整個目錄進 `Resources/ocr-service/`（可用 `OCR_SERVICE_DIST_DIR` 環境變數覆蓋路徑，兩包都會內嵌）。
4. 複製 `../zh-cn-to-tw-web/` 的 `index.html`/`script.js`/`style.css`/`favicon.png` 進 `Resources/web/`（可用 `WEB_SRC_DIR` 環境變數覆蓋路徑）——兩包用同一份網頁原始碼，讀的是 `zh-cn-to-tw-web` 的 `main` 分支，跟 GitHub Pages 服務的 `update-page` 分支無關（見該 repo README）。

完成後：

```bash
open .build/繁化助手.app              # 13+
open Legacy/.build/繁化助手.app       # 12-（兩包分開放在各自 package 的 .build/，不會互相覆蓋）
```

## 打包成 .dmg

`build_dmg_13_plus.sh`/`build_dmg_12_minus.sh` 只做「把已經存在的 `.app`
封成 DMG」這一步，**不會**自動重新 `swift build`、也不會重新複製
`zh-cn-to-tw-web` 的原始碼——先照上面步驟打包出對應的 `.app`，這兩支
才有東西可以包：

```bash
bash packaging/build_dmg_13_plus.sh debug   # 只打 13+ 那包
bash packaging/build_dmg_12_minus.sh debug  # 只打 12- 那包
```

`build_dmg_all.sh`（頂層 meta-repo 的 `build_mac_dmg.sh` 指到這支）
是唯一預期當成「一鍵重新 build 全部」用的入口，跟上面兩支不一樣：
它會先重新跑 `build_app_13_plus.sh`/`build_app_12_minus.sh`（swift
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
dmg_13_plus.sh`/`build_dmg_12_minus.sh` 則保留原本「不自動重新
build」的行為，給只想重新測安裝流程（原始碼沒變）的情況用。

會做這些事：

1. 讀對應 `.app` 裡 `Info.plist` 的 `CFBundleShortVersionString`，決定輸出檔名（`繁化助手-<版本>-13+.dmg`／`繁化助手-<版本>-12-.dmg`）——版本號只在各自的 `Info.plist` 維護一份，不在這裡另外手動輸入一次；檔名帶分流後綴，不然兩包版本號一樣時會直接撞名。
2. 準備一個暫存資料夾：放進 `.app`、一個指向 `/Applications` 的捷徑（使用者拖曳安裝用）、`packaging/dmg-readme.txt`（沒有簽章、第一次打開被 Gatekeeper 擋下來時怎麼在系統設定裡允許，兩包共用同一份說明文字）、`解除安裝.command`。
3. 用 `hdiutil create` 把這個資料夾封裝成壓縮、唯讀的 `.dmg`（`UDZO` 格式，一般軟體發布用的就是這種）。

完成後在 `dist/繁化助手-<版本>-13+.dmg`／`dist/繁化助手-<版本>-12-.dmg`（不是 `.build/`——那是 SwiftPM 自己的中間產物目錄，Finder 預設隱藏；`dist/` 才是放真正成品的地方，跟 `zh-cn-to-tw-ocr-service` 用 `dist/` 放 PyInstaller 產出是同一個慣例），`open` 它會跟使用者實際看到的畫面一樣（掛載、跳出視窗、把 App 拖進 Applications）。頂層 meta-repo 的 `build_mac_dmg.sh`（git 追蹤的符號連結）指到 `build_dmg_all.sh`，一鍵兩包都出。

**沒有簽章、沒有公證**——需要付費的 Apple Developer 帳號，這個專案刻意跳過，所以使用者第一次打開會被 Gatekeeper 擋下來，這是預期行為，DMG 裡的說明文字已經涵蓋怎麼處理。

## 開發時的除錯技巧

- App 啟動時把 stdout 導到檔案，能看到所有 `print()` 診斷訊息（包含 `[webview-nav]`/`[webview-console]`/`[webview-ocr-port]` 這些前綴）：

```bash
.build/繁化助手.app/Contents/MacOS/ZhCnToTw > /tmp/app.log 2>&1 &
tail -f /tmp/app.log
```

- `WebView.swift` 有把 `webView.isInspectable = true`（macOS 13.3+），可以用 Safari 的「開發」選單掛上完整 Web Inspector，看網路請求、DOM、在主控台直接下 JS 指令。

## 常見開發用環境變數

- `WEB_BASE_URL_OVERRIDE`：不載入內嵌的 `file://` 網頁，改指到一個 URL（例如本機 `python3 -m http.server` 開的網址），方便前端開發時不用每次改完都重新打包整個 App。
- `WEB_API_BASE_OVERRIDE`：桌面版預設一律打正式的 Render 網址，這個變數可以覆蓋成本機 backend，測試還沒部署的後端改動。

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

These have since been folded into the `known-issue-check` skill's general checklist — not project-specific trivia, but patterns any desktop-shell-plus-WKWebView project is likely to hit.

### OCR Service Lifecycle

This evolved alongside the frontend discussion through a few iterations:

- **v1**: the app started the OCR service at launch and kept it running for the whole session.
- **v2**: added "self-shutdown after 30 minutes idle" plus "a health check every 30 seconds that respawns it if it's not running" — the two fought each other, respawning shortly after every shutdown, so memory was never actually reclaimed.
- **v3 (current)**: control is handed entirely to the web frontend. `WebView.swift` registers an `ocrService` `WKScriptMessageHandler`; `script.js` sends `{action: "start"}` right before it actually needs to send a PDF, and `{action: "stop"}` once the OCR step ends (success or failure). The app never starts it proactively at launch.

Paired with this is a port-notification mechanism: whenever the service starts or stops, `OCRServiceManager` pushes the current port (or `null`) straight into the page's `window.__OCR_PORT__` via `WKWebView.evaluateJavaScript` — **deliberately not** via a URL query parameter plus a page reload, which would wipe out whatever the user had half-filled into a form.

One easily-missed detail: the `readabilityHandler` (used to read the subprocess's stdout for its port number) will, if not explicitly unregistered, cause GCD to treat a pipe that's hit EOF (the subprocess exited) as "always readable" and call the closure in an infinite tight loop — measured: the moment the subprocess dies, the app's CPU jumps from 0% straight to 96% and never comes back down; an app left open for hours, respawned a few times along the way, was measured at 283%. Fixed by clearing `handle.readabilityHandler = nil` the moment an empty read is observed.

### Google Sign-In

Completes the OAuth flow through the system browser (not a popup embedded inside WKWebView), then hands the resulting session token back to the web frontend to store in `localStorage`. See `GoogleDesktopSignIn.swift`.

### Version Control and Forced Updates

Version control goes through GitHub Releases (DMG as a release asset, not done yet). The version-comparison logic only uses the major/minor pair from `CFBundleShortVersionString`, ignoring any third digit — `ContentView.appVersionMajorMinor` just splits the string on `.` and takes the first two segments, falling back to `0.0` if that doesn't parse into two integers (pure defensiveness, shouldn't happen in practice). `desktopURL()` passes those two numbers to the page as `appMajor`/`appMinor`; before starting any Stage 1/2 work, the page calls `GET /api/version_check` to ask the backend whether this version is still new enough, and blocks the action with a dialog pointing to the update page if not (full flow in `zh-cn-to-tw-web`'s README, "Desktop Forced-Update Check," and `zh-cn-to-tw-backend`'s README, "Version Check").

### Version Tiers: 13+ and 12-

The whole app originally shared one `Package.swift` (`platforms: [.macOS(.v13)]`), and `LSMinimumSystemVersion` was hardcoded to `13.0` — too old a system version, and the app wouldn't launch at all, including Stage 2 proofreading, which doesn't depend on OCR in any way. That was really the only reason users on older systems couldn't even proofread — not any actual requirement of Stage 2 itself. The app is now split into two independently-versioned builds so macOS 12 and below can at least use Stage 2:

- **13+** (root `Package.swift`): unchanged from before, `platforms .v13`, Stage 1 and 2 both work.
- **12-** (`Legacy/Package.swift`): `platforms: [.macOS(.v10_15)]`, Stage 1 is locked at the web layer (`stage1-form-group` is hidden entirely, replaced by one line: "Stage 1功能只支援Mac OS 13以上。"), Stage 2 works normally.

The two are **separate SwiftPM packages**, not two targets in one `Package.swift` — SwiftPM's `platforms` setting is package-wide, there's no per-target deployment target. Under `Legacy/Sources/ZhCnToTwLegacy/`, `ContentView.swift`/`WebView.swift`/`GoogleDesktopSignIn.swift`/`OCRServiceManager.swift`/`SystemActivityGuard.swift`/`Uninstaller.swift` are all **symlinks** back to the same files under `Sources/ZhCnToTw/`, not a second copy to maintain; the only file genuinely unique to the `12-` target is a new `App.swift`:

- SwiftUI's `App`/`Scene`/`WindowGroup`/`.commands`/`NSApplicationDelegateAdaptor` — the whole declarative app-lifecycle API — all need **macOS 11.0+** (confirmed by actually running `swift build` against `.v10_15` and getting a hard error); Catalina's SwiftUI 1.0 simply doesn't have this API surface. `Legacy`'s `App.swift` goes back to a classic `NSApplicationDelegate` + manually-created `NSWindow` + `NSHostingController`, with the menu bar built by hand too (including an Edit menu — without it, Cmd+C/V might not even work in WKWebView's own text fields).
- The whole `WKDownload`/`WKDownloadDelegate` API (including `WKNavigationActionPolicy.download`) needs **macOS 11.3+** (confirmed against the SDK headers), so the shared `WebView.swift` moved those methods into an `@available(macOS 11.3, *) extension WebView.Coordinator: WKDownloadDelegate` — the `12-` build simply doesn't compile that extension in. Downloads there go through a new `legacyDownload` message channel instead: `script.js` detects `osTier === "12-"` and posts the download content as base64 directly, which the shell decodes and writes to the Downloads folder (see `handleLegacyDownload` in `WebView.swift`); `13+` and plain browsers still use `WKDownload` exactly as before.
- `Image(systemName:)` and `.help(_:)` need 11.0+, so the reload button in `ContentView.swift` branches on `#available(macOS 11.0, *)` (the icon button above that line, a plain text button below); some `.foregroundStyle` overloads need macOS 14.0, so all of them were replaced with the much older, behaviorally-identical `.foregroundColor` — both builds benefit, with no visible difference.

`ContentView.swift` computes `osTier` (`"13+"` or `"12-"`) via `#if LEGACY_BUILD` (defined by `Legacy/Package.swift`'s `swiftSettings: [.define("LEGACY_BUILD")]`; the `13+` target doesn't define it) and passes it to the page through `desktopURL()`'s `osTier` query parameter; the page uses it to decide whether to lock Stage 1, which tier's threshold to query via `GET /api/version_check` (sent as an `os_version` parameter — see `zh-cn-to-tw-backend`'s README, "Version Check"), and whether to download via `WKDownload` or `legacyDownload`.

**The `12-` build still embeds `zh-cn-to-tw-ocr-service`**, even though Stage 1 never uses it there — `AppDelegate`'s `ocrManager` is initialized eagerly, and a missing OCR executable triggers a `fatalError()` immediately at launch. Skipping the bundle would make this build crash on open, not just fail to do OCR gracefully. This is a deliberate tradeoff (a bit more DMG size in exchange for the smallest possible diff) — trimming it later would mean also touching `AppDelegate.resolveOCRServiceExecutable`'s fallback logic.

Both builds currently share the **same `CFBundleIdentifier`** (`com.beethoreven.zh-cn-to-tw`) — a real user only ever installs one of the two (whichever matches their macOS version), so from their perspective it's the same app. That does mean installing both on one machine for testing shares the same `~/Library/WebKit/<bundle-id>` data etc., and the second install in `/Applications` overwrites the first — a testing-only limitation, not something that affects real usage.

**Not yet tested on a genuinely old system (macOS 10.15–12).** Lowering the deployment target only guarantees the code compiles and links against that OS version's API surface — it doesn't guarantee identical runtime behavior, especially the brand-new `legacyDownload` path. The dev machine (Apple Silicon, running macOS 26) can't run macOS 12 and below via Virtualization.framework (that's Intel-era software), so there's no way to verify without real old hardware. What has been confirmed: this build installs, opens, and runs the basic flow fine on a *newer* system (Tahoe) — because a deployment target is a floor, not a ceiling, `dyld` only checks "current OS ≥ minos," which is the normal way to sanity-check overall logic without old hardware on hand. But branches like `#available(macOS 11.3, *)` always take the modern path on a newer OS, so this can't exercise the `12-`-only fallback logic itself.

### Known Limitations

- A Windows version hasn't been started yet (planned to follow the same architecture, just with a different UI framework).
- **Deliberately no code signing or notarization**: that needs a paid Apple Developer account, which this project skips. DMG packaging is done (`packaging/build_dmg_13_plus.sh`/`build_dmg_12_minus.sh`), but being unsigned means Gatekeeper blocks first launch; the DMG bundles a `dmg-readme.txt` explaining how to allow it in System Settings.
- The DMG can currently only be produced by running the script locally — it isn't published to GitHub Releases for version control yet (planned).
- The `12-` build hasn't been tested on a real old system yet — see the last point under "Version Tiers" above.

---

# Setup Guide

## Requirements

- macOS 13+ to build the `13+` package; building the `12-` package works fine on macOS 11.3+ dev machines too (`swift build` only compiles — a deployment target is a runtime floor, not a "minimum dev machine" requirement), but final verification needs real old hardware, see "Version Tiers" above.
- Xcode (with the Swift 5.9+ toolchain)
- A built `zh-cn-to-tw-ocr-service` (see that repo's README, produces `dist/zh-cn-to-tw-ocr-service/`) — without it the `13+` app still opens, local OCR just shows a startup failure; the `12-` build is stricter and `fatalError()`s at launch without it (see above).

## Building the .app

Two separate scripts, not one script with a flag — they correspond to two independent `Package.swift` files (a different `--package-path` each), see "Version Tiers" above.

```bash
cd zh-cn-to-tw-mac
bash packaging/build_app_13_plus.sh debug   # macOS 13+ build
bash packaging/build_app_12_minus.sh debug  # macOS 12-and-below build (Stage 1 locked)
```

Each does:

1. `swift build` (`13+` uses the root `Package.swift`; `12-` uses `--package-path Legacy`) to compile the bare executable.
2. Assembles the `.app` bundle structure (the matching `Info.plist`/`Info-12-minus.plist`, icon).
3. Copies the entire `../zh-cn-to-tw-ocr-service/dist/zh-cn-to-tw-ocr-service/` directory into `Resources/ocr-service/` (override path via `OCR_SERVICE_DIST_DIR`; both builds embed it).
4. Copies `../zh-cn-to-tw-web/`'s `index.html`/`script.js`/`style.css`/`favicon.png` into `Resources/web/` (override path via `WEB_SRC_DIR`) — both builds share the same web source, reading `zh-cn-to-tw-web`'s `main` branch, unrelated to the `update-page` branch GitHub Pages serves (see that repo's README).

Then:

```bash
open .build/繁化助手.app              # 13+
open Legacy/.build/繁化助手.app       # 12- (each package keeps its own .build/, so they never collide)
```

## Building the .dmg

`build_dmg_13_plus.sh`/`build_dmg_12_minus.sh` only do the "wrap an
already-built `.app` into a DMG" step — they do **not** re-run
`swift build` or re-copy `zh-cn-to-tw-web`'s source. Build the matching
`.app` first per the steps above, then:

```bash
bash packaging/build_dmg_13_plus.sh debug   # 13+ only
bash packaging/build_dmg_12_minus.sh debug  # 12- only
```

`build_dmg_all.sh` (the top-level meta-repo's `build_mac_dmg.sh` points
here) is the only entry point meant to be used as "rebuild everything
in one command" — unlike the two above, it re-runs
`build_app_13_plus.sh`/`build_app_12_minus.sh` first (swift build +
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
all.sh` now always rebuilds from current source; `build_dmg_13_plus.sh`/
`build_dmg_12_minus.sh` keep their original "never auto-rebuild"
behavior, for when you just want to re-test the install flow itself
with unchanged source.

This does:

1. Reads `CFBundleShortVersionString` from the matching `.app`'s `Info.plist` to name the output (`繁化助手-<version>-13+.dmg` / `繁化助手-<version>-12-.dmg`) — each version number is maintained in exactly one place, not typed in again here; the tier suffix keeps the two from colliding when their version numbers match.
2. Prepares a staging folder: the `.app`, a symlink to `/Applications` (the drag target users see), `packaging/dmg-readme.txt` (how to allow the app in System Settings when Gatekeeper blocks first launch, shared by both), and `解除安裝.command`.
3. Packages that folder into a compressed, read-only `.dmg` with `hdiutil create` (`UDZO` format — the standard one used for shipping software).

The result lands at `dist/繁化助手-<version>-13+.dmg` / `dist/繁化助手-<version>-12-.dmg` (not `.build/` — that's SwiftPM's own intermediate-artifact directory, hidden by Finder by default; `dist/` is where the actual shippable output goes, the same convention `zh-cn-to-tw-ocr-service` uses for its PyInstaller output); `open`ing it shows exactly what an end user would see. The top-level meta-repo's `build_mac_dmg.sh` (a git-tracked symlink) points at `build_dmg_all.sh`, building both in one shot.

**No code signing, no notarization** — that needs a paid Apple Developer account, which this project deliberately skips, so users get blocked by Gatekeeper on first launch. That's expected; the bundled readme text already covers what to do about it.

## Debugging Tips During Development

- Redirect stdout to a file at launch to see every `print()` diagnostic (including the `[webview-nav]`/`[webview-console]`/`[webview-ocr-port]` prefixed ones):

```bash
.build/繁化助手.app/Contents/MacOS/ZhCnToTw > /tmp/app.log 2>&1 &
tail -f /tmp/app.log
```

- `WebView.swift` sets `webView.isInspectable = true` (macOS 13.3+), so Safari's Develop menu can attach the full Web Inspector — network requests, the DOM, and a live JS console.

## Useful Dev-Time Environment Variables

- `WEB_BASE_URL_OVERRIDE`: skip loading the embedded `file://` page and point at a URL instead (e.g. a local `python3 -m http.server`), so frontend changes don't require rebuilding the whole app every time.
- `WEB_API_BASE_OVERRIDE`: the desktop build always hits the production Render URL by default; this overrides it to a local backend for testing not-yet-deployed backend changes.
