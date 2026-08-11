#!/bin/bash
# 把 SwiftPM 編出來的裸執行檔包成一個真正的 .app bundle（Finder/Dock 可以
# 開的那種），順便解決裸執行檔啟動時 WKWebView 內建控制項文字（例如檔案
# 選擇按鈕）抓不到語言偏好、退回英文的問題——這需要 Info.plist 的
# CFBundleLocalizations 才能正確運作，光靠 runtime 設定 AppleLanguages
# 不夠。也會把 zh-cn-to-tw-ocr-service 的執行檔一起包進 Resources/，
# 這樣測試不用再手動帶 OCR_SERVICE_DEV_PATH 環境變數。
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${1:-debug}"
APP_NAME="ZhCnToTw"
APP_BUNDLE="$REPO_ROOT/.build/$APP_NAME.app"

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

cp "$REPO_ROOT/.build/$CONFIG/$APP_NAME" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
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
  # 不複製 teacher-notice.txt 本身——桌面版執行期不會讀它（見下面的
  # teacher-notice-content.js 產生步驟），放進去也不會被用到，是死重量。
  for f in index.html script.js style.css favicon.png; do
    [ -f "$WEB_SRC_DIR/$f" ] && cp "$WEB_SRC_DIR/$f" "$APP_BUNDLE/Contents/Resources/web/$f"
  done
  echo "    已內嵌網頁前端：$WEB_SRC_DIR"

  # file:// 底下 JS 執行期沒有任何辦法讀到「同目錄另一個檔案」的內容
  # （fetch 規格禁止對 file:// 發請求；XMLHttpRequest 跟隱藏 <iframe>
  # 實測也都被 WKWebView 擋掉，見 script.js 的 initTeacherNotice() 說明）。
  # 打包時直接把 teacher-notice.txt 的內容注入成一個全域變數，讓
  # script.js 用 <script src> 載入（這條路是「瀏覽器自己的資源載入
  # 管線」，不是 JS 主動發起的請求，file:// 底下能正常運作）。用
  # python3 的 json.dumps 產生安全的 JS 字串字面值，不要自己手動處理
  # 跳脫字元——中文字、引號、換行混在一起很容易漏掉邊界情況。
  if [ -f "$WEB_SRC_DIR/teacher-notice.txt" ]; then
    python3 -c "
import json
with open('$WEB_SRC_DIR/teacher-notice.txt', encoding='utf-8') as f:
    content = f.read()
with open('$APP_BUNDLE/Contents/Resources/web/teacher-notice-content.js', 'w', encoding='utf-8') as f:
    f.write('window.__TEACHER_NOTICE_TEXT__ = ' + json.dumps(content) + ';\n')
"
    echo "    已注入 teacher-notice.txt 內容：$WEB_SRC_DIR/teacher-notice.txt"
  else
    echo "    找不到 $WEB_SRC_DIR/teacher-notice.txt，「阿舍老師的叮嚀」這次會顯示空白"
  fi
else
  echo "    找不到 $WEB_SRC_DIR，這次不內嵌網頁前端（App 會開不起來）"
fi

echo "==> 完成：$APP_BUNDLE"
echo "    開啟方式：open \"$APP_BUNDLE\""
