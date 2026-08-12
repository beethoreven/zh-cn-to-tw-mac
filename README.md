# 中文

## 劇本殺繁化助手 — macOS 桌面殼

用 Swift/SwiftUI + WKWebView 包裝 [`zh-cn-to-tw-web`](https://github.com/beethoreven/zh-cn-to-tw-web) 前端、內嵌 [`zh-cn-to-tw-ocr-service`](https://github.com/beethoreven/zh-cn-to-tw-ocr-service) 當本機 OCR 引擎的 macOS 桌面 App。這份文件分兩部分：

- **[專案報告](#專案報告)**：為什麼需要這個殼、踩過哪些 WKWebView 的坑。
- **[架設 SOP](#架設-sop)**：怎麼本機打包測試。

---

## 專案報告

### 這是什麼、為什麼需要它

`zh-cn-to-tw-web` 本來只是給瀏覽器開的網頁，直接連 Render 後端做全部
工作（含 OCR）。但 Render 免費方案完全扛不住 PaddleOCR（SIGILL、OOM，
詳見 `zh-cn-to-tw-backend` README），解法是把 OCR 這一段搬到使用者
自己的電腦上跑——而「把一支本機 HTTP 服務跟一份網頁前端包裝成使用者
可以雙擊開啟的東西」，就是這個殼的職責。它本身幾乎不含業務邏輯，
純粹是「啟動/管理本機 OCR 子行程」+「載入網頁前端」+「處理 Google
登入這種瀏覽器層級需要系統協助的事」三件事的黏合層。

### 架構總覽

```
ZhCnToTw.app/
├── Contents/MacOS/ZhCnToTw          ← 這個 repo 編譯出來的執行檔
└── Contents/Resources/
    ├── web/                          ← zh-cn-to-tw-web 的 app/ 子資料夾（打包時複製進來）
    └── ocr-service/                  ← zh-cn-to-tw-ocr-service 的 PyInstaller 產出
```

App 啟動時**不會**主動啟動 OCR 服務（見下方「OCR 服務生命週期」），
只做：載入內嵌的網頁前端（`file://`）、準備好 OCR 服務管理器待命。

### 為什麼網頁前端改用 `file://` 載入（origin 穩定性）

最早的設計是桌面殼自己啟動一份本機 backend，用 HTTP 供應網頁（連
`http://127.0.0.1:<動態port>`）。這個 port 每次啟動都不一樣——刻意
如此，這個專案本機測試階段吃過很多次「舊 process 卡住固定 port」的
虧。但 `localStorage` 是照 `scheme+host+port` 算 origin 的，port
每次不同就等於每次啟動都是全新的 origin，使用者登入後拿到的 session
token 完全救不回來，變成每次開 App 都要重新登入（實測抓到：同一個
bundle id 底下累積了三個不同的 `LocalStorage` 資料夾，就是這樣來的）。

改成完全不透過任何本機 HTTP 伺服器，直接用固定的 `file://` 路徑載入
`Resources/web/index.html`——同一份安裝，每次啟動的路徑都一樣，
origin 因此穩定，`localStorage` 能真正跨次啟動保留登入狀態。這個決定
同時也順便解決了本機 backend 持有資料庫/LLM 憑證的問題：`file://`
架構下桌面殼完全不需要本機 backend，backend 唯一的角色就是 Render上
那一份，桌面版 App 裡不含任何值錢的憑證。

### 過程中踩到的 WKWebView 坑

改用 `file://` 之後，連續撞上好幾個以前完全沒遇過的問題，值得完整記錄：

1. **`Bundle.main.resourceURL` 內部是「相對字串 + baseURL」的組合，`isFileURL` 回報 `true` 但一穿過 `URLComponents(resolvingAgainstBaseURL: false)` 就會弄丟 baseURL**，變成一個沒有 scheme 的相對路徑，`WKWebView` 直接回報「無法顯示URL」，而且完全看不出問題出在 URL 格式。改用 `Bundle.main.bundlePath`（純字串）搭配 `URL(fileURLWithPath:)` 從頭建構路徑解決。
2. **`loadFileURL(_:allowingReadAccessTo:)` 要求給的是乾淨的目錄 URL**——如果傳進去的 URL 還黏著查詢字串（`?desktop=1&...`），算出來的「父目錄」格式就不對，會靜默失敗、整個頁面停在 `about:blank`。用 `.path` 先去掉查詢字串再算父目錄解決。
3. **`WKNavigationDelegate` 不實作 `didFail*`/`didFinish` 的話，導覽失敗完全沒有任何跡象**——沒有例外、沒有 log，只有一片空白畫面。這三個方法現在永久保留，純粹用來 print 診斷訊息，是找出上面兩個問題的關鍵工具。
4. **Swift `print()` 在 stdout 不是 TTY（例如被導向檔案/pipe）時是全緩衝，不是行緩衝**——一度讓新加的診斷 print 完全看不到輸出，一度誤以為程式碼沒有執行到那裡。`applicationDidFinishLaunching` 一開始就呼叫 `setvbuf(stdout, nil, _IONBF, 0)` 解決，這行話很可能也順便修好了既有的 console 轉送功能一直沒真正生效的問題。
5. **`file://` 底下，網頁的 JS 執行期完全沒有辦法讀取同目錄的另一個檔案**——`fetch()` 規格明確禁止、`XMLHttpRequest` 被 WKWebView 擋、隱藏 `<iframe>` + `contentDocument` 回傳 `null`（WebKit 把同目錄下不同的 `file://` 檔案當成不同 origin）。這是「阿舍老師的叮嚀」那個功能一路改了三次才修好的根本原因，完整過程見 `zh-cn-to-tw-backend` README。

這幾條後來被整理進 `known-issue-check` skill 的通用清單（不是這個
專案獨有的踩坑記錄，而是任何桌面殼 + WKWebView 專案都可能撞到的
模式）。

### OCR 服務生命週期

跟網頁前端的討論一起演化過幾次：

- **v1**：App 啟動就拉起 OCR 服務，整個執行期間開著。
- **v2**：加「閒置 30 分鐘自我關閉」+「健康檢查每 30 秒發現沒在跑就重新拉起」——兩個機制互相打架，關掉沒多久又被拉起來，記憶體從沒真的被回收過。
- **v3（目前）**：完全交給網頁前端主動控制。`WebView.swift` 註冊一個
  `ocrService` 的 `WKScriptMessageHandler`，`script.js` 在真的要送 PDF
  之前才發 `{action: "start"}`，OCR 階段結束（不管成功失敗）就發
  `{action: "stop"}`。App 啟動時完全不主動開它。

搭配的還有 port 通知機制：服務起來/關掉時，`OCRServiceManager` 會把
最新的 port（或 `null`）透過 `WKWebView.evaluateJavaScript` 直接寫進
網頁的 `window.__OCR_PORT__`，**刻意不透過改網址查詢參數再重新載入
頁面**（那樣會清掉使用者填到一半的表單狀態）。

還有一個容易忽略的細節：`readabilityHandler`（讀取子行程 stdout 用來
抓 port 號）在 pipe 進入 EOF（子行程結束）後，如果沒有主動解除，
GCD 會判定這個 fd「隨時可讀」而無限次重複呼叫這個 closure——實測
子行程一死，App 的 CPU 從 0% 直接衝到 96% 且不會回落，開了幾小時、
中途重啟過幾次的 App 甚至量到 283%。修法是讀到空資料就把
`handle.readabilityHandler = nil`。

### Google 登入

用系統瀏覽器完成 OAuth 流程（不是嵌在 WKWebView 裡跳出的彈窗），完成
後把 session token 回傳給網頁前端存進 `localStorage`。見
`GoogleDesktopSignIn.swift`。

### 已知限制

- Windows 版尚未開始（未來規劃跟這個殼架構相同，只是換一套 UI 框架）。
- DMG 打包、簽章尚未做，目前測試都是直接跑 `.app`。

---

# 架設 SOP / Setup Guide

## 需求

- macOS 13+
- Xcode（含 Swift 5.9+ 工具鏈）
- 已經打包好的 `zh-cn-to-tw-ocr-service`（見該 repo 的 README，
  `dist/zh-cn-to-tw-ocr-service/`）——沒有的話 App 還是能開，只是本機
  OCR 功能會顯示服務啟動失敗。

## 打包成 .app

```bash
cd zh-cn-to-tw-mac
bash packaging/build_app.sh debug
```

會做這些事：

1. `swift build` 編出裸執行檔。
2. 組出 `.app` bundle 結構（`Info.plist`、圖示）。
3. 複製 `../zh-cn-to-tw-ocr-service/dist/zh-cn-to-tw-ocr-service/` 整個目錄進 `Resources/ocr-service/`（可用 `OCR_SERVICE_DIST_DIR` 環境變數覆蓋路徑）。
4. 複製 `../zh-cn-to-tw-web/app/` 的 `index.html`/`script.js`/`style.css`/`favicon.png` 進 `Resources/web/`（可用 `WEB_SRC_DIR` 環境變數覆蓋路徑）——注意是 `app/` 子資料夾，不是 `zh-cn-to-tw-web` 的 repo 根目錄；該 repo 根目錄現在是 GitHub Pages 用的公開佔位頁，見該 repo README。

完成後：

```bash
open .build/ZhCnToTw.app
```

## 開發時的除錯技巧

- App 啟動時把 stdout 導到檔案，能看到所有 `print()` 診斷訊息（包含
  `[webview-nav]`/`[webview-console]`/`[webview-ocr-port]` 這些前綴）：

```bash
.build/ZhCnToTw.app/Contents/MacOS/ZhCnToTw > /tmp/app.log 2>&1 &
tail -f /tmp/app.log
```

- `WebView.swift` 有把 `webView.isInspectable = true`（macOS 13.3+），
  可以用 Safari 的「開發」選單掛上完整 Web Inspector，看網路請求、
  DOM、在主控台直接下 JS 指令。

## 常見開發用環境變數

- `WEB_BASE_URL_OVERRIDE`：不載入內嵌的 `file://` 網頁，改指到一個
  URL（例如本機 `python3 -m http.server` 開的網址），方便前端開發時
  不用每次改完都重新打包整個 App。
- `WEB_API_BASE_OVERRIDE`：桌面版預設一律打正式的 Render 網址，這個
  變數可以覆蓋成本機 backend，測試還沒部署的後端改動。

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
ZhCnToTw.app/
├── Contents/MacOS/ZhCnToTw          ← the executable this repo builds
└── Contents/Resources/
    ├── web/                          ← zh-cn-to-tw-web's app/ subfolder (copied in at package time)
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

### Known Limitations

- A Windows version hasn't been started yet (planned to follow the same architecture, just with a different UI framework).
- DMG packaging and code signing aren't done yet — testing so far has been running the `.app` directly.

---

# Setup Guide

## Requirements

- macOS 13+
- Xcode (with the Swift 5.9+ toolchain)
- A built `zh-cn-to-tw-ocr-service` (see that repo's README, produces
  `dist/zh-cn-to-tw-ocr-service/`) — without it the app still opens,
  but local OCR will show a startup failure.

## Building the .app

```bash
cd zh-cn-to-tw-mac
bash packaging/build_app.sh debug
```

This does:

1. `swift build` to compile the bare executable.
2. Assembles the `.app` bundle structure (`Info.plist`, icon).
3. Copies the entire `../zh-cn-to-tw-ocr-service/dist/zh-cn-to-tw-ocr-service/` directory into `Resources/ocr-service/` (override path via `OCR_SERVICE_DIST_DIR`).
4. Copies `../zh-cn-to-tw-web/app/`'s `index.html`/`script.js`/`style.css`/`favicon.png` into `Resources/web/` (override path via `WEB_SRC_DIR`) — note the `app/` subfolder, not `zh-cn-to-tw-web`'s repo root; that repo's root is now GitHub Pages' public placeholder, see that repo's README.

Then:

```bash
open .build/ZhCnToTw.app
```

## Debugging Tips During Development

- Redirect stdout to a file at launch to see every `print()` diagnostic
  (including the `[webview-nav]`/`[webview-console]`/`[webview-ocr-port]`
  prefixed ones):

```bash
.build/ZhCnToTw.app/Contents/MacOS/ZhCnToTw > /tmp/app.log 2>&1 &
tail -f /tmp/app.log
```

- `WebView.swift` sets `webView.isInspectable = true` (macOS 13.3+), so
  Safari's Develop menu can attach the full Web Inspector — network
  requests, the DOM, and a live JS console.

## Useful Dev-Time Environment Variables

- `WEB_BASE_URL_OVERRIDE`: skip loading the embedded `file://` page and
  point at a URL instead (e.g. a local `python3 -m http.server`), so
  frontend changes don't require rebuilding the whole app every time.
- `WEB_API_BASE_OVERRIDE`: the desktop build always hits the production
  Render URL by default; this overrides it to a local backend for
  testing not-yet-deployed backend changes.
