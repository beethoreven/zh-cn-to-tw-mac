#!/bin/bash
# 解除安裝：清掉這個 App 在 .app 本身之外、散落在 ~/Library 各處的資料。
#
# 為什麼需要這支腳本：WKWebView 的 localStorage/cookies、系統的快取、
# 偏好設定，都是照 Bundle Identifier（com.beethoreven.zh-cn-to-tw）
# 存在 .app 之外（例如 ~/Library/WebKit/<bundle-id>/），不是放在 .app
# bundle 裡面——單純把 .app 拖到垃圾桶完全不會動到這些，實測撞過：
# 刪掉 .app、重新安裝一次，登入狀態還在，因為 WebKit 資料庫根本沒被
# 刪掉，新安裝的 App（Bundle ID 沒變）直接找到同一份舊資料接著用。
# 這是 macOS 的一般慣例，只有 App Store 上架、走沙盒 Container 的
# App 才有「刪除等於完整清除」的保證，我們這種直接發 .app/DMG 的
# 沒有這個保證，需要自己提供解除安裝流程。
set -euo pipefail

# 固定用 C locale，理由跟 build_app.sh/build_dmg.sh 一樣——見那兩支
# 腳本的說明（macOS 系統 bash 3.2 + UTF-8 語系 + set -u 對「$VAR 後面
# 緊接全形字元」有解析 bug）。
export LC_ALL=C

BUNDLE_ID="com.beethoreven.zh-cn-to-tw"
APP_PATH="${1:-/Applications/繁化助手.app}"

TARGETS=(
  "$APP_PATH"
  "$HOME/Library/WebKit/$BUNDLE_ID"
  "$HOME/Library/Caches/$BUNDLE_ID"
  "$HOME/Library/Preferences/$BUNDLE_ID.plist"
  "$HOME/Library/Saved Application State/$BUNDLE_ID.savedState"
)

# HTTPStorages 底下除了 <bundle-id>.binarycookies 本體，還會有
# <bundle-id>.binarycookies_tmp_<pid>.dat 這種暫存變體，數量不固定，
# 用 glob 找，不能寫死成陣列裡的固定路徑。
HTTP_STORAGE_GLOB="$HOME/Library/HTTPStorages/$BUNDLE_ID"*

echo "即將刪除以下項目（只列出實際存在的）："
found_any=0
for t in "${TARGETS[@]}"; do
  if [ -e "$t" ]; then
    echo "  - $t"
    found_any=1
  fi
done
for f in $HTTP_STORAGE_GLOB; do
  if [ -e "$f" ]; then
    echo "  - $f"
    found_any=1
  fi
done

if [ "$found_any" -eq 0 ]; then
  echo "找不到任何要清的東西（可能已經清過，或這台機器沒裝過）。"
  exit 0
fi

read -r -p "確定要刪除以上項目嗎？這個動作無法復原 (y/N) " confirm
if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
  echo "已取消，沒有刪除任何東西。"
  exit 0
fi

# 先確認 App 沒在跑——Library 底下的資料庫檔案如果還被鎖著，刪了
# 也可能刪不乾淨或留下鎖檔。用執行檔名稱比對（見 build_app.sh 的
# EXECUTABLE_NAME 說明，不管 .app bundle 本身叫什麼名字，裡面的
# 執行檔固定叫這個），不依賴 .app 資料夾的檔名。
pkill -f "Contents/MacOS/ZhCnToTw" 2>/dev/null || true

for t in "${TARGETS[@]}"; do
  if [ -e "$t" ]; then
    rm -rf "$t"
    echo "已刪除：$t"
  fi
done
for f in $HTTP_STORAGE_GLOB; do
  if [ -e "$f" ]; then
    rm -f "$f"
    echo "已刪除：$f"
  fi
done

echo "==> 解除安裝完成"
