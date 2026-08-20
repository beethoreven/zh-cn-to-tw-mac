#!/bin/bash
# 打包 macOS 10.15 那包（Legacy/Package.swift，platforms .v10_15）。跟
# build_app_11_plus.sh 是姊妹腳本，結構幾乎一樣，差別只在
# --package-path 指到 Legacy/、執行檔名字是 ZhCnToTwLegacy、Info.plist
# 換成 Info-10-15.plist——兩包對應兩個獨立的 SwiftPM package，見
# Legacy/Package.swift 開頭的說明。
#
# 把 SwiftPM 編出來的裸執行檔包成一個真正的 .app bundle。**不**內嵌
# zh-cn-to-tw-ocr-service——這包 Stage 1 改用 VisionOCRManager 原生
# 實作（Apple Vision framework），完全不需要那支 Python service，見
# Legacy/Sources/ZhCnToTwLegacy/App.swift、VisionOCRManager.swift
# 開頭的說明。這也是這包 DMG 明顯比 11+ 那包小的原因。
set -euo pipefail

# 固定用 C locale——原因見 build_app_11_plus.sh 同一段說明，macOS 內建的
# bash 3.2 在 UTF-8 語系 + set -u 下對「$VAR 後面緊接全形字元」有解析 bug。
export LC_ALL=C

# 用 readlink -f 先把符號連結解成真正的實體路徑，才能正確算出這個
# repo 的根目錄——見 build_app_11_plus.sh 同樣的處理。這支腳本本身放在
# packaging/ 底下（不是 Legacy/ 底下），REPO_ROOT 算出來的還是
# zh-cn-to-tw-mac 這個 repo 的根目錄，跟 11+ 那支一致。
REPO_ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
CONFIG="${1:-debug}"
PACKAGE_PATH="$REPO_ROOT/Legacy"

# 裸執行檔的名字（Legacy/Package.swift 的 target 名稱）——刻意跟 11+
# 那包的 ZhCnToTw 分開命名，不是因為使用者看得到（Finder 一樣只看
# .app bundle 本身的名字），是避免兩包各自的建置產物、之後如果哪天要
# 塞進同一個除錯環境時，執行檔名字一樣反而分不清是哪一包。
EXECUTABLE_NAME="ZhCnToTwLegacy"
# .app bundle 資料夾本身的名字，維持跟 11+ 那包一樣是「繁化助手」——
# 使用者只會裝其中一包（依自己的 macOS 版本選對應的 DMG），從使用者
# 角度這就是同一個 App，沒必要讓 Finder 顯示不同的名字。
APP_DISPLAY_NAME="繁化助手"
# 組裝出來的 .app 放在 Legacy/.build/ 底下（不是 REPO_ROOT/.build/），
# 跟 11+ 那包用 REPO_ROOT/.build/ 分開——两個 SwiftPM package 本來就
# 各自有自己的 .build/ 產物目錄，讓組裝出來的 .app 也各自放在對應的
# 目錄下，不會互相覆蓋。
APP_BUNDLE="$PACKAGE_PATH/.build/$APP_DISPLAY_NAME.app"

# 網頁前端原始檔，直接包進 Resources/web/，App 用 file:// 載入——
# 跟 11+ 那包完全同一份網頁（見 build_app_11_plus.sh 同一段說明），
# 網頁那邊自己會用桌面殼傳進來的 osTier 決定本機 OCR 要走 HTTP 輪詢
# 還是 visionOcr message channel。
WEB_SRC_DIR="${WEB_SRC_DIR:-$REPO_ROOT/../zh-cn-to-tw-web}"

echo "==> swift build ($CONFIG，package-path=$PACKAGE_PATH)"
swift build --package-path "$PACKAGE_PATH" -c "$CONFIG"

echo "==> 組裝 .app bundle"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources/web"

cp "$PACKAGE_PATH/.build/$CONFIG/$EXECUTABLE_NAME" "$APP_BUNDLE/Contents/MacOS/$EXECUTABLE_NAME"
cp "$REPO_ROOT/packaging/Info-10-15.plist" "$APP_BUNDLE/Contents/Info.plist"
cp "$REPO_ROOT/packaging/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"

if [ -d "$WEB_SRC_DIR" ]; then
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
# 多出 Info.plist/AppIcon.icns/web/ 這些資源後，簽章跟實際內容對不
# 起來——`codesign -dv` 會報「code has no resources but signature
# indicates they must be present」。本機直接 `open` 測試時，Gatekeeper
# 不太會認真檢查這個（實測撞過：一直沒發現），但只要檔案真的被下載
# 過一次（瀏覽器會加 com.apple.quarantine），系統會做 App
# Translocation 到唯讀的隨機路徑再檢查，這時候簽章不合格就直接判定
#「已損毀，無法打開」，連 Gatekeeper 的「仍要打開」選項都不會出現
# ——不是使用者操作有問題，是這個簽章根本無效。修法是整個 .app
# 組裝完之後重新簽一次（ad-hoc，不需要花錢的開發者憑證），讓簽章
# 涵蓋這次真正打包進去的所有內容。
echo "==> 重新簽章（ad-hoc，涵蓋組裝完的完整 bundle）"
codesign --force --deep --sign - "$APP_BUNDLE"

echo "==> 完成：$APP_BUNDLE"
echo "    開啟方式：open \"$APP_BUNDLE\""
