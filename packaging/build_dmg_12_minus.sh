#!/bin/bash
# 把 build_app_12_minus.sh 已經打包好的 .app 包成一個可以拖進 Applications
# 安裝的 .dmg（macOS 12 以下、Stage 1 鎖住那包）。跟 build_dmg_13_plus.sh
# 是姊妹腳本，結構幾乎一樣，差別只在 APP_BUNDLE 讀 Legacy/.build/、
# DMG 檔名後綴是 -12-。
#
# 沒有簽章、沒有公證——原因跟 build_dmg_13_plus.sh 一樣，見那支腳本的
# 說明；一起塞進 DMG 的 dmg-readme.txt 是同一份，兩包共用。
set -euo pipefail

# 固定用 C locale——原因見 build_dmg_13_plus.sh 同一段說明。
export LC_ALL=C

# 用 readlink -f 先把符號連結解成真正的實體路徑——見 build_dmg_13_plus.sh
# 同樣的處理。這支腳本放在 packaging/ 底下，REPO_ROOT 算出來的是
# zh-cn-to-tw-mac 這個 repo 的根目錄，跟 13+ 那支一致。
REPO_ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
CONFIG="${1:-debug}"
# 跟 build_app_12_minus.sh 的 APP_DISPLAY_NAME 保持一致——原因見
# build_dmg_13_plus.sh 同一段說明。
APP_DISPLAY_NAME="繁化助手"
# build_app_12_minus.sh 把組好的 .app 放在 Legacy/.build/ 底下（不是
# REPO_ROOT/.build/），見那支腳本的說明——這裡讀同一個位置。
APP_BUNDLE="$REPO_ROOT/Legacy/.build/$APP_DISPLAY_NAME.app"
STAGING_DIR="$REPO_ROOT/Legacy/.build/dmg-staging"
# 最終成品跟 13+ 那包一樣放進看得到的 dist/ 資料夾，同一個目錄，
# 靠檔名的版本分流後綴（-13+/-12-）分辨。
DIST_DIR="$REPO_ROOT/dist"

if [ ! -d "$APP_BUNDLE" ]; then
  echo "找不到 $APP_BUNDLE，先跑 bash packaging/build_app_12_minus.sh $CONFIG 打包出 .app"
  exit 1
fi

VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP_BUNDLE/Contents/Info.plist")"
mkdir -p "$DIST_DIR"
DMG_PATH="$DIST_DIR/$APP_DISPLAY_NAME-$VERSION-12-.dmg"

echo "==> 準備 DMG 內容（版本 $VERSION，12- 分流）"
rm -rf "$STAGING_DIR"
mkdir -p "$STAGING_DIR"
cp -R "$APP_BUNDLE" "$STAGING_DIR/"
ln -s /Applications "$STAGING_DIR/Applications"
cp "$REPO_ROOT/packaging/dmg-readme.txt" "$STAGING_DIR/請先看我 - 安裝說明.txt"
cp "$REPO_ROOT/packaging/uninstall.sh" "$STAGING_DIR/解除安裝.command"
chmod +x "$STAGING_DIR/解除安裝.command"

echo "==> 封裝成 DMG"
rm -f "$DMG_PATH"
hdiutil create -volname "$APP_DISPLAY_NAME" -srcfolder "$STAGING_DIR" -ov -format UDZO "$DMG_PATH"

rm -rf "$STAGING_DIR"

echo "==> 完成：$DMG_PATH"
echo "    測試安裝：open \"$DMG_PATH\""
