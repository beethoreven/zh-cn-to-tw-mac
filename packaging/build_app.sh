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

# 本機 backend（同時供應網頁介面與 API，見 zh-cn-to-tw-backend）。
BACKEND_DIST_DIR="${BACKEND_DIST_DIR:-$REPO_ROOT/../zh-cn-to-tw-backend/dist/zh-cn-to-tw-backend}"
# 網頁前端原始檔，會被放到 backend 執行檔旁邊的 web/ 由它自己供應。
WEB_SRC_DIR="${WEB_SRC_DIR:-$REPO_ROOT/../zh-cn-to-tw-web}"

echo "==> swift build ($CONFIG)"
swift build --package-path "$REPO_ROOT" -c "$CONFIG"

echo "==> 組裝 .app bundle"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources/ocr-service"

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

if [ -d "$BACKEND_DIST_DIR" ]; then
  mkdir -p "$APP_BUNDLE/Contents/Resources/backend"
  cp -R "$BACKEND_DIST_DIR"/. "$APP_BUNDLE/Contents/Resources/backend/"
  echo "    已內嵌 backend：$BACKEND_DIST_DIR"

  # 網頁前端放在 backend 執行檔旁邊的 web/，backend 啟動時會自動找到這裡
  # 並開始供應（見該 repo configs/config.py 的 WEB_STATIC_DIR）。
  rm -rf "$APP_BUNDLE/Contents/Resources/backend/web"
  if [ -d "$WEB_SRC_DIR" ]; then
    mkdir -p "$APP_BUNDLE/Contents/Resources/backend/web"
    # 只複製網頁真正需要的檔案，不要把整個 repo（.git、README 之類）塞進去
    for f in index.html script.js style.css favicon.png teacher-notice.txt; do
      [ -f "$WEB_SRC_DIR/$f" ] && cp "$WEB_SRC_DIR/$f" "$APP_BUNDLE/Contents/Resources/backend/web/$f"
    done
    echo "    已內嵌網頁前端：$WEB_SRC_DIR"
  else
    echo "    找不到 $WEB_SRC_DIR，這次不內嵌網頁前端（App 會開不起來）"
  fi

  # 刻意「不」把 .env 放進 bundle：資料庫連線字串與 LLM API 金鑰只要進到
  # 使用者拿得到的檔案裡，就一定能被取出來（程式執行時必須能解密才能用，
  # 加密或混淆只是提高門檻，不是防護）。這支本機 backend 只負責供應網頁
  # 靜態檔案，完全不需要任何憑證；所有需要憑證的操作（Google 登入驗證、
  # Neon 資料庫、LLM 呼叫）都由 Render 上的同一份程式處理，桌面端只拿一個
  # 有範圍限制、可撤銷的 session token。這樣打包出來的 .app 可以直接發給
  # 別人，裡面不含任何值錢的東西。
  rm -f "$APP_BUNDLE/Contents/Resources/backend/.env"
else
  echo "    找不到 $BACKEND_DIST_DIR，這次不內嵌 backend"
  echo "    （執行時可用 BACKEND_SERVICE_DEV_PATH 環境變數指到本機打包好的執行檔）"
fi

echo "==> 完成：$APP_BUNDLE"
echo "    開啟方式：open \"$APP_BUNDLE\""
