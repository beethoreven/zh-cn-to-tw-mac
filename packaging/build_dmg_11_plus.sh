#!/bin/bash
# 把 build_app_11_plus.sh 已經打包好的 .app 包成一個可以拖進 Applications
# 安裝的 .dmg（macOS 11+ 那包）。跟 build_app_11_plus.sh 分開兩支腳本：
# 重複打包 DMG（例如只是想再測一次安裝流程）不需要每次都重新
# swift build。macOS 10.15 那包是 build_dmg_10_15.sh，兩支姊妹腳本，
# 差別只在 APP_BUNDLE 來源、DMG 檔名的版本分流後綴——想一次把兩包都
# build 出來，用 build_dmg_all.sh。
#
# 沒有簽章、沒有公證（Apple Developer 帳號要付費，這個專案刻意跳過）——
# 使用者第一次打開會被 Gatekeeper 擋下來，屬於預期行為，見一起塞進 DMG
# 裡的 dmg-readme.txt，裡面寫了怎麼在系統設定裡允許打開。
set -euo pipefail

# 固定用 C locale，不要依賴呼叫端終端機的語系設定。macOS 內建的
# bash 停在 3.2（Apple 因為授權問題，十幾年沒再更新過），這個版本
# 搭配 UTF-8 語系、加上 set -u，對「雙引號字串裡 $VAR 後面緊接全形
# 字元、中間沒有空格」這個組合有解析 bug，會把展開結果後面的位元組
# 誤判成變數名稱的一部分，報出莫名其妙的「XXX？: unbound variable」
# ——實測撞過（$VERSION 後面直接接「）」）。C locale 下 bash 不會做
# 那段有問題的 multibyte 解析，且完全不影響 echo 出來的中文字（那是
# 終端機自己的事，跟 bash 的 LC_ALL 無關），純粹是繞開這個 bash 版本
# 的 bug，不是妥協。
export LC_ALL=C

# 用 readlink -f 先把符號連結（例如頂層 meta-repo 的 build_mac_dmg.sh
# 就是連到這支檔案）解成真正的實體路徑，才能正確算出這個 repo 的根目錄
# ——直接對 BASH_SOURCE[0] 取 dirname 的話，經由 symlink 執行時算出來
# 的會是 symlink 自己所在的位置，不是這支腳本實際所在的位置。
REPO_ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
CONFIG="${1:-debug}"
# 跟 build_app.sh 的 APP_DISPLAY_NAME 保持一致——這是 .app bundle 資料夾
# 本身的名字，也是 DMG 掛載時使用者看到的磁碟區名稱、DMG 檔名本身，
# 三個地方統一，不然「Finder 看到的檔名」「DMG 打開後看到的名稱」
# 「App 開起來的標題」會兜不起來（實測撞過：改了 Info.plist 裡的
# CFBundleName/CFBundleDisplayName，以為就是「改 App 名字」，結果
# .app 檔案本身還是叫 ZhCnToTw.app，Finder/DMG 看到的完全沒變——
# Info.plist 那兩個欄位只影響 App 執行時的身份，不影響檔案本身的
# 名稱）。
APP_DISPLAY_NAME="繁化助手"
APP_BUNDLE="$REPO_ROOT/.build/$APP_DISPLAY_NAME.app"
STAGING_DIR="$REPO_ROOT/.build/dmg-staging"
# 最終要交給使用者的成品放在看得到的 dist/ 資料夾，不是 .build/——
# .build 是 SwiftPM 自己的中間產物目錄，Finder 預設隱藏，適合放編譯
# 過程的雜物，不適合放真正要拿去測試/發布的東西。跟
# zh-cn-to-tw-ocr-service 用 dist/ 放 PyInstaller 成品是同一個慣例。
DIST_DIR="$REPO_ROOT/dist"

if [ ! -d "$APP_BUNDLE" ]; then
  echo "找不到 $APP_BUNDLE，先跑 bash packaging/build_app_11_plus.sh $CONFIG 打包出 .app"
  exit 1
fi

# DMG 檔名帶版本號，方便同時保留好幾個版本、也方便之後掛上 GitHub
# Releases 時一眼看出對應哪一版——直接讀 .app 裡的 Info.plist，不要
# 手動輸入一次版本號，兩個地方各自維護遲早會兜不起來。檔名再帶一個
# 「-11+」後綴區分版本分流（跟 build_dmg_10_15.sh 輸出的
# 「-10.15」對應），不然兩包版本號一樣時 dist/ 底下的檔名會直接撞名、
# 後 build 的那包默默蓋掉先 build 的。
VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP_BUNDLE/Contents/Info.plist")"
mkdir -p "$DIST_DIR"
DMG_PATH="$DIST_DIR/$APP_DISPLAY_NAME-$VERSION-11+.dmg"

echo "==> 準備 DMG 內容（版本 $VERSION）"
rm -rf "$STAGING_DIR"
mkdir -p "$STAGING_DIR"
cp -R "$APP_BUNDLE" "$STAGING_DIR/"
# 使用者把這個捷徑跟旁邊的 .app 一起看到，直接拖 .app 過去就是安裝——
# 這個捷徑本身幾乎不佔空間，純粹是給拖曳用的視覺目標。
ln -s /Applications "$STAGING_DIR/Applications"
cp "$REPO_ROOT/packaging/dmg-readme.txt" "$STAGING_DIR/請先看我 - 安裝說明.txt"
# .command 副檔名是 macOS Terminal 的慣例：Finder 雙擊 .command 檔案
# 會直接開一個 Terminal 視窗執行它，不用使用者自己打開終端機、cd 過去、
# 下 bash 指令——一般使用者不會用終端機，這是讓「解除安裝」對他們來說
# 真的可操作的關鍵。內容直接複製 uninstall.sh，不是另外維護一份，
# 避免兩邊邏輯之後兜不起來；一定要在複製後另外下 chmod +x，來源檔案
# 的可執行權限不會被 cp 之外的方式保留、且 DMG 封裝時的權限最終看的
# 是這裡複製出來的這一份。
cp "$REPO_ROOT/packaging/uninstall.sh" "$STAGING_DIR/解除安裝.command"
chmod +x "$STAGING_DIR/解除安裝.command"

echo "==> 封裝成 DMG"
rm -f "$DMG_PATH"
# UDZO：壓縮過、唯讀的映像格式，一般發布軟體用的就是這種，不是
# 給使用者事後編輯內容用的可寫映像。
hdiutil create -volname "$APP_DISPLAY_NAME" -srcfolder "$STAGING_DIR" -ov -format UDZO "$DMG_PATH"

rm -rf "$STAGING_DIR"

echo "==> 完成：$DMG_PATH"
echo "    測試安裝：open \"$DMG_PATH\""
