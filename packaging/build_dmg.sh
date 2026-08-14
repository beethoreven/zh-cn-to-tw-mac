#!/bin/bash
# 把 build_app.sh 已經打包好的 .app 包成一個可以拖進 Applications 安裝的
# .dmg。跟 build_app.sh 分開兩支腳本：重複打包 DMG（例如只是想再測一次
# 安裝流程）不需要每次都重新 swift build。
#
# 沒有簽章、沒有公證（Apple Developer 帳號要付費，這個專案刻意跳過）——
# 使用者第一次打開會被 Gatekeeper 擋下來，屬於預期行為，見一起塞進 DMG
# 裡的 dmg-readme.txt，裡面寫了怎麼在系統設定裡允許打開。
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${1:-debug}"
APP_NAME="ZhCnToTw"
APP_BUNDLE="$REPO_ROOT/.build/$APP_NAME.app"
STAGING_DIR="$REPO_ROOT/.build/dmg-staging"

if [ ! -d "$APP_BUNDLE" ]; then
  echo "找不到 $APP_BUNDLE，先跑 bash packaging/build_app.sh $CONFIG 打包出 .app"
  exit 1
fi

# DMG 檔名帶版本號，方便同時保留好幾個版本、也方便之後掛上 GitHub
# Releases 時一眼看出對應哪一版——直接讀 .app 裡的 Info.plist，不要
# 手動輸入一次版本號，兩個地方各自維護遲早會兜不起來。
VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP_BUNDLE/Contents/Info.plist")"
DMG_PATH="$REPO_ROOT/.build/$APP_NAME-$VERSION.dmg"

echo "==> 準備 DMG 內容（版本 $VERSION）"
rm -rf "$STAGING_DIR"
mkdir -p "$STAGING_DIR"
cp -R "$APP_BUNDLE" "$STAGING_DIR/"
# 使用者把這個捷徑跟旁邊的 .app 一起看到，直接拖 .app 過去就是安裝——
# 這個捷徑本身幾乎不佔空間，純粹是給拖曳用的視覺目標。
ln -s /Applications "$STAGING_DIR/Applications"
cp "$REPO_ROOT/packaging/dmg-readme.txt" "$STAGING_DIR/請先看我 - 安裝說明.txt"

echo "==> 封裝成 DMG"
rm -f "$DMG_PATH"
# UDZO：壓縮過、唯讀的映像格式，一般發布軟體用的就是這種，不是
# 給使用者事後編輯內容用的可寫映像。
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGING_DIR" -ov -format UDZO "$DMG_PATH"

rm -rf "$STAGING_DIR"

echo "==> 完成：$DMG_PATH"
echo "    測試安裝：open \"$DMG_PATH\""
