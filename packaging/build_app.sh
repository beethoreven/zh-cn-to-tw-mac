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

echo "==> 完成：$APP_BUNDLE"
echo "    開啟方式：open \"$APP_BUNDLE\""
