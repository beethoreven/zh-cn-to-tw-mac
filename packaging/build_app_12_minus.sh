#!/bin/bash
# 打包 macOS 12 以下、Stage 1 鎖住只留 Stage 2 的那包（Legacy/Package.swift，
# platforms .v10_15）。跟 build_app_13_plus.sh 是姊妹腳本，結構幾乎一樣，
# 差別只在 --package-path 指到 Legacy/、執行檔名字是 ZhCnToTwLegacy、
# Info.plist 換成 Info-12-minus.plist——兩包對應兩個獨立的 SwiftPM
# package，見 Legacy/Package.swift 開頭的說明。
#
# 把 SwiftPM 編出來的裸執行檔包成一個真正的 .app bundle，同樣把
# zh-cn-to-tw-ocr-service 的執行檔一起包進 Resources/——雖然這包 Stage 1
# 在網頁那層被鎖住不會真的用到 OCR，但 App.swift 的 AppDelegate 在
# init 時就會 eager 解析 ocr-service 執行檔路徑、找不到會直接
# fatalError()（跟 13+ 那包共用同一段邏輯，見 Legacy/Sources/
# ZhCnToTwLegacy/App.swift 開頭的說明），不內嵌的話這包會開不起來，
# 不是單純「Stage 1 按了沒反應」那麼溫和。
set -euo pipefail

# 固定用 C locale——原因見 build_app_13_plus.sh 同一段說明，macOS 內建的
# bash 3.2 在 UTF-8 語系 + set -u 下對「$VAR 後面緊接全形字元」有解析 bug。
export LC_ALL=C

# 用 readlink -f 先把符號連結解成真正的實體路徑，才能正確算出這個
# repo 的根目錄——見 build_app_13_plus.sh 同樣的處理。這支腳本本身放在
# packaging/ 底下（不是 Legacy/ 底下），REPO_ROOT 算出來的還是
# zh-cn-to-tw-mac 這個 repo 的根目錄，跟 13+ 那支一致。
REPO_ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
CONFIG="${1:-debug}"
PACKAGE_PATH="$REPO_ROOT/Legacy"

# 裸執行檔的名字（Legacy/Package.swift 的 target 名稱）——刻意跟 13+
# 那包的 ZhCnToTw 分開命名，不是因為使用者看得到（Finder 一樣只看
# .app bundle 本身的名字），是避免兩包各自的建置產物、之後如果哪天要
# 塞進同一個除錯環境時，執行檔名字一樣反而分不清是哪一包。
EXECUTABLE_NAME="ZhCnToTwLegacy"
# .app bundle 資料夾本身的名字，維持跟 13+ 那包一樣是「繁化助手」——
# 使用者只會裝其中一包（依自己的 macOS 版本選對應的 DMG），從使用者
# 角度這就是同一個 App，沒必要讓 Finder 顯示不同的名字。
APP_DISPLAY_NAME="繁化助手"
# 組裝出來的 .app 放在 Legacy/.build/ 底下（不是 REPO_ROOT/.build/），
# 跟 13+ 那包用 REPO_ROOT/.build/ 分開——两個 SwiftPM package 本來就
# 各自有自己的 .build/ 產物目錄，讓組裝出來的 .app 也各自放在對應的
# 目錄下，不會互相覆蓋。
APP_BUNDLE="$PACKAGE_PATH/.build/$APP_DISPLAY_NAME.app"

# 預設抓本機端 zh-cn-to-tw-ocr-service repo 已經打包好的 PyInstaller
# onedir 產出；可用環境變數覆蓋，方便之後在別台機器上打包。
OCR_SERVICE_DIST_DIR="${OCR_SERVICE_DIST_DIR:-$REPO_ROOT/../zh-cn-to-tw-ocr-service/dist/zh-cn-to-tw-ocr-service}"

# 網頁前端原始檔，直接包進 Resources/web/，App 用 file:// 載入——
# 跟 13+ 那包完全同一份網頁（見 build_app_13_plus.sh 同一段說明），
# 網頁那邊自己會用桌面殼傳進來的 osTier 決定要不要把 Stage 1 鎖住。
WEB_SRC_DIR="${WEB_SRC_DIR:-$REPO_ROOT/../zh-cn-to-tw-web}"

echo "==> swift build ($CONFIG，package-path=$PACKAGE_PATH)"
swift build --package-path "$PACKAGE_PATH" -c "$CONFIG"

echo "==> 組裝 .app bundle"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources/ocr-service"
mkdir -p "$APP_BUNDLE/Contents/Resources/web"

cp "$PACKAGE_PATH/.build/$CONFIG/$EXECUTABLE_NAME" "$APP_BUNDLE/Contents/MacOS/$EXECUTABLE_NAME"
cp "$REPO_ROOT/packaging/Info-12-minus.plist" "$APP_BUNDLE/Contents/Info.plist"
cp "$REPO_ROOT/packaging/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"

if [ -d "$OCR_SERVICE_DIST_DIR" ]; then
  cp -R "$OCR_SERVICE_DIST_DIR"/. "$APP_BUNDLE/Contents/Resources/ocr-service/"
  echo "    已內嵌 ocr-service：$OCR_SERVICE_DIST_DIR"
else
  echo "    找不到 $OCR_SERVICE_DIST_DIR，這次不內嵌 ocr-service"
  echo "    （執行時可用 OCR_SERVICE_DEV_PATH 環境變數指到本機打包好的執行檔；"
  echo "     正式打包一定要有這個資料夾，不然這包 App 會直接 fatalError 開不起來）"
fi

if [ -d "$WEB_SRC_DIR" ]; then
  for f in index.html script.js style.css favicon.png; do
    [ -f "$WEB_SRC_DIR/$f" ] && cp "$WEB_SRC_DIR/$f" "$APP_BUNDLE/Contents/Resources/web/$f"
  done
  echo "    已內嵌網頁前端：$WEB_SRC_DIR"
else
  echo "    找不到 $WEB_SRC_DIR，這次不內嵌網頁前端（App 會開不起來）"
fi

echo "==> 完成：$APP_BUNDLE"
echo "    開啟方式：open \"$APP_BUNDLE\""
