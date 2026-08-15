#!/bin/bash
# 從頭到尾一次把 13+ 跟 12- 兩包都打出來：swift build -> 組裝 .app ->
# 封成 DMG，兩包都做。頂層 meta-repo 的 build_mac_dmg.sh（git 追蹤的
# 符號連結）指到這支腳本——這是唯一預期會被當成「一鍵重新 build 全部」
# 使用的進入點，所以刻意每次都真的重新跑 build_app_*.sh，不偷懶只包
# 現有的 .app。
#
# 這支腳本曾經只依序呼叫 build_dmg_13_plus.sh / build_dmg_12_minus.sh
# （只做「把已經存在的 .app 封成 DMG」這一步，不會重新 swift build、
# 也不會重新複製 zh-cn-to-tw-web 的原始碼進去）——結果是：只要有人
# 改了原始碼（Swift 或網頁前端）卻沒有另外手動先跑 build_app_*.sh，
# 這支腳本會用舊的 .app 靜靜包出一個看起來全新（檔案時間戳記是新的）
# 但內容其實沒變的 DMG，改動完全不會反映在測試結果裡，卻沒有任何錯誤
# 或警告——這正是實測撞過的情況：改完 script.js/app.py 卻只跑這支
# 頂層腳本，裝出來的東西還是舊行為。個別想跳過重新 build、只想重新
# 封裝現有 .app（測安裝流程本身，原始碼沒變）的情況，直接呼叫
# build_dmg_13_plus.sh / build_dmg_12_minus.sh 即可，那兩支維持原本
# 「不自動重新 build」的行為不變。
set -euo pipefail

export LC_ALL=C

REPO_ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
CONFIG="${1:-debug}"

echo "==> [1/4] swift build + 組裝 .app（13+）"
bash "$REPO_ROOT/packaging/build_app_13_plus.sh" "$CONFIG"

echo
echo "==> [2/4] swift build + 組裝 .app（12-）"
bash "$REPO_ROOT/packaging/build_app_12_minus.sh" "$CONFIG"

echo
echo "==> [3/4] 封裝 DMG（13+）"
bash "$REPO_ROOT/packaging/build_dmg_13_plus.sh" "$CONFIG"

echo
echo "==> [4/4] 封裝 DMG（12-）"
bash "$REPO_ROOT/packaging/build_dmg_12_minus.sh" "$CONFIG"

echo
echo "==> 兩包都完成，見 $REPO_ROOT/dist/"
