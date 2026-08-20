#!/bin/bash
# 打包 macOS 11+ 那包（根目錄 Package.swift，platforms .v11）。macOS
# 10.15、改用 Vision framework 做 Stage 1 OCR 的那包是
# build_app_10_15.sh，兩支分開維護——不是同一支腳本帶參數切換，因為
# 兩包對應的是兩個獨立的 SwiftPM package（Legacy/Package.swift 是另一個
# 部署目標壓到 10.15 的 package，原因見那支檔案開頭的說明），swift build
# 呼叫的 --package-path 本身就不同，共用一支腳本反而要塞一堆 if/else
# 分支，不如兩支各自單純。
#
# 把 SwiftPM 編出來的裸執行檔包成一個真正的 .app bundle（Finder/Dock 可以
# 開的那種），順便解決裸執行檔啟動時 WKWebView 內建控制項文字（例如檔案
# 選擇按鈕）抓不到語言偏好、退回英文的問題——這需要 Info.plist 的
# CFBundleLocalizations 才能正確運作，光靠 runtime 設定 AppleLanguages
# 不夠。也會把 zh-cn-to-tw-ocr-service 的執行檔一起包進 Resources/，
# 這樣測試不用再手動帶 OCR_SERVICE_DEV_PATH 環境變數。
set -euo pipefail

# 固定用 C locale，不要依賴呼叫端終端機的語系設定——macOS 內建的 bash
# 停在 3.2（Apple 因為授權問題，十幾年沒再更新過），這個版本搭配
# UTF-8 語系、加上 set -u，對「雙引號字串裡 $VAR 後面緊接全形字元、
# 中間沒有空格」這個組合有解析 bug，會把展開結果後面的位元組誤判成
# 變數名稱的一部分，報出莫名其妙的「XXX？: unbound variable」（在
# build_dmg.sh 實測撞過，見那支腳本的說明）。C locale 下不會觸發那段
# 有問題的 multibyte 解析，且完全不影響 echo 出來的中文字。
export LC_ALL=C

# 用 readlink -f 先把符號連結解成真正的實體路徑，才能正確算出這個
# repo 的根目錄——直接對 BASH_SOURCE[0] 取 dirname 的話，經由 symlink
# 執行時算出來的會是 symlink 自己所在的位置，不是這支腳本實際所在的
# 位置（見 build_dmg.sh 同樣的處理）。
REPO_ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
CONFIG="${1:-debug}"
# 裸執行檔的名字（Package.swift 的 target 名稱、也是 Info.plist 的
# CFBundleExecutable）——這是內部實作細節，使用者從來不會直接看到這個
# 檔名（Finder 只會顯示 .app bundle 本身的名字），維持 ZhCnToTw 不用
# 跟著 App 顯示名稱changed。
EXECUTABLE_NAME="ZhCnToTw"
# .app bundle 資料夾本身的名字，這才是 Finder/Dock 實際顯示給使用者
# 看的檔名——跟 Info.plist 的 CFBundleName/CFBundleDisplayName（App
# 執行時的視窗標題）要維持一致，不然「檔案總管看到的名字」跟「App
# 開起來之後的標題」會對不起來。
APP_DISPLAY_NAME="繁化助手"
APP_BUNDLE="$REPO_ROOT/.build/$APP_DISPLAY_NAME.app"

# 預設抓本機端 zh-cn-to-tw-ocr-service repo 已經打包好的 PyInstaller
# onedir 產出；可用環境變數覆蓋，方便之後在別台機器上打包。
OCR_SERVICE_DIST_DIR="${OCR_SERVICE_DIST_DIR:-$REPO_ROOT/../zh-cn-to-tw-ocr-service/dist/zh-cn-to-tw-ocr-service}"

# 網頁前端原始檔，直接包進 Resources/web/，App 用 file:// 載入（見
# ContentView.swift 的說明）。刻意不再透過本機 backend 用 HTTP 供應——
# backend 的 port 每次啟動都不一樣，會讓 localStorage 的 origin 跟著變、
# 存在裡面的登入 session 因此每次啟動都救不回來（實測撞過這個問題）。
# 這也代表本機不再需要打包/啟動任何 backend：它原本除了供應網頁以外
# 已經不持有任何憑證（API 一律打 Render，見 ContentView.swift 的
# apiBase），現在連供應網頁都不用它做了。
WEB_SRC_DIR="${WEB_SRC_DIR:-$REPO_ROOT/../zh-cn-to-tw-web}"

echo "==> swift build ($CONFIG)"
swift build --package-path "$REPO_ROOT" -c "$CONFIG"

echo "==> 組裝 .app bundle"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources/ocr-service"
mkdir -p "$APP_BUNDLE/Contents/Resources/web"

cp "$REPO_ROOT/.build/$CONFIG/$EXECUTABLE_NAME" "$APP_BUNDLE/Contents/MacOS/$EXECUTABLE_NAME"
cp "$REPO_ROOT/packaging/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
cp "$REPO_ROOT/packaging/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"

if [ -d "$OCR_SERVICE_DIST_DIR" ]; then
  # PyInstaller onedir 產出的執行檔跟 _internal/ 資料夾要維持同層關係，
  # 整個資料夾內容原封不動複製過去，不能只複製執行檔本身。
  cp -R "$OCR_SERVICE_DIST_DIR"/. "$APP_BUNDLE/Contents/Resources/ocr-service/"
  echo "    已內嵌 ocr-service：$OCR_SERVICE_DIST_DIR"
else
  echo "    找不到 $OCR_SERVICE_DIST_DIR，這次不內嵌 ocr-service"
  echo "    （執行時可用 OCR_SERVICE_DEV_PATH 環境變數指到本機打包好的執行檔）"
fi

if [ -d "$WEB_SRC_DIR" ]; then
  # 只複製網頁真正需要的檔案，不要把整個 repo（.git、README 之類）塞進去。
  # 不複製 ta-notice.txt——它現在放在 zh-cn-to-tw-backend repo 裡，
  # 桌面版跟瀏覽器版一樣，改成執行期打 Render 的 /api/ta-notice
  # 拿內容（見 script.js 的 initTaNotice() 說明），打包時不用管它。
  for f in index.html script.js style.css favicon.png; do
    [ -f "$WEB_SRC_DIR/$f" ] && cp "$WEB_SRC_DIR/$f" "$APP_BUNDLE/Contents/Resources/web/$f"
  done
  echo "    已內嵌網頁前端：$WEB_SRC_DIR"
else
  echo "    找不到 $WEB_SRC_DIR，這次不內嵌網頁前端（App 會開不起來）"
fi

# swift build 產出的裸執行檔本身已經帶一個 ad-hoc 簽章（Apple Silicon
# 上執行任何東西都要求至少有簽章），但那個簽章是對「裸執行檔自己」
# 簽的，Sealed Resources=none。把它原封不動 cp 進 .app bundle、旁邊
# 多出 Info.plist/AppIcon.icns/web/ocr-service 這些資源後，簽章跟
# 實際內容對不起來——`codesign -dv` 會報「code has no resources but
# signature indicates they must be present」。本機直接 `open` 測試時，
# Gatekeeper 不太會認真檢查這個（實測撞過：一直沒發現），但只要檔案
# 真的被下載過一次（瀏覽器會加 com.apple.quarantine），系統會做 App
# Translocation 到唯讀的隨機路徑再檢查，這時候簽章不合格就直接判定
#「已損毀，無法打開」，連 Gatekeeper 的「仍要打開」選項都不會出現
# ——不是使用者操作有問題，是這個簽章根本無效。修法是整個 .app
# 組裝完之後重新簽一次（ad-hoc，不需要花錢的開發者憑證），讓簽章
# 涵蓋這次真正打包進去的所有內容。
echo "==> 重新簽章（ad-hoc，涵蓋組裝完的完整 bundle）"
codesign --force --deep --sign - "$APP_BUNDLE"

echo "==> 完成：$APP_BUNDLE"
echo "    開啟方式：open \"$APP_BUNDLE\""
