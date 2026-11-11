#!/bin/bash
# 編譯 10.15 分流 Stage 1 用的 Tesseract（含 Leptonica），並下載簡體中文
# 模型。build_app_10_15.sh 會自動呼叫這支，成品快取在
# Legacy/.build/tesseract/<版本>/，版本沒變就不重編。
#
# 為什麼 10.15 要自己帶 OCR 引擎：macOS 10.15 的 Vision framework 只有
# VNRecognizeTextRequestRevision1，SDK 標頭寫明「only supports English」，
# 支援中文的 Revision2 要 macOS 11。設 recognitionLanguages = zh-Hans 不會
# 報錯，Vision 會默默用英文模型辨識，中文字全部變成英文字母（2026-11
# 10.15 實機回報的「亂碼」就是這個）。11+ 用的 RapidOCR 依賴 onnxruntime，
# 它的 minos 是 11.0，10.15 也跑不動。
#
# 為什麼自己從原始碼編、不用 Homebrew：Homebrew 的 bottle 是針對當下的
# macOS 編的（minos 跟著開發機走），還會動態連結一串 /usr/local 的
# dylib。這裡把 Leptonica、Tesseract 都編成靜態、關掉所有外部影像格式
# 與網路功能，最後的執行檔只依賴系統內建的 libSystem、libc++，minos
# 10.15。App 這邊只餵 PNM 灰階圖（Leptonica 內建就能讀，不需要
# libpng/libjpeg）。
#
# 只支援 x86_64：跑 10.15 的 Mac 一定是 Intel（Apple Silicon 出廠就是 11+）。
# 在 Apple Silicon 開發機上一樣可以編（交叉編譯 x86_64），只是本機要靠
# Rosetta 才能實測執行檔。
#
# 版本（2026-11-08 查的當下最新正式版）：
# - Tesseract 5.5.4（2026-10-28 發布）
# - Leptonica 1.87.0（2025-12-24 發布）
# - 模型：tessdata_fast 的 chi_sim。評估時 fast 跟 best 的辨識品質幾乎
#   一樣，best 慢 2-3 倍、檔案大 5 倍，所以用 fast。tessdata 沒有正式
#   release 會更新這個檔案，釘在最新一個 commit。
set -euo pipefail
export LC_ALL=C

REPO_ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"

TESSERACT_VERSION="5.5.4"
TESSERACT_SHA256="a8dbf8b8c8ee427ff6ad1d99116502feaf59440af1adb893caf60a6576826cf4"
LEPTONICA_VERSION="1.87.0"
LEPTONICA_SHA256="c73363397f96eb1295602bf44d708a994ad42046c791bf03ea0505d829bdb6a7"
TESSDATA_COMMIT="87416418657359cb625c412a48b6e1d6d41c29bd"
CHI_SIM_SHA256="a5fcb6f0db1e1d6d8522f39db4e848f05984669172e584e8d76b6b3141e1f730"

# 快取資料夾名稱帶上這支腳本自己的雜湊：之後改了編譯參數但版本號沒變時，
# 只看版本號會沿用舊成品、改動根本沒生效，打包出來的檔案看起來是新的、內容卻是舊的。
SCRIPT_HASH="$(shasum -a 256 "${BASH_SOURCE[0]}" | cut -c1-8)"
OUT_DIR="$REPO_ROOT/Legacy/.build/tesseract/$TESSERACT_VERSION-lept$LEPTONICA_VERSION-$SCRIPT_HASH"
OUT_BIN="$OUT_DIR/bin/tesseract"
OUT_MODEL="$OUT_DIR/tessdata/chi_sim.traineddata"
# build_app_10_15.sh 從這個固定路徑拿成品，不用自己推算版本資料夾名稱。
CURRENT_LINK="$REPO_ROOT/Legacy/.build/tesseract/current"

if [ -x "$OUT_BIN" ] && [ -f "$OUT_MODEL" ]; then
  ln -sfn "$OUT_DIR" "$CURRENT_LINK"
  echo "    Tesseract 已編好（快取）：$OUT_DIR"
  exit 0
fi

for tool in cmake ninja curl shasum; do
  command -v "$tool" >/dev/null || { echo "    缺 $tool，請先安裝（brew install cmake ninja）"; exit 1; }
done

WORK="$OUT_DIR.work"
rm -rf "$WORK" "$OUT_DIR"
mkdir -p "$WORK/src" "$OUT_DIR/bin" "$OUT_DIR/tessdata"

fetch() { # url 目的檔 sha256
  echo "    下載 $1"
  curl -fsSL -o "$2" "$1"
  local got
  got="$(shasum -a 256 "$2" | cut -d' ' -f1)"
  if [ "$got" != "$3" ]; then
    echo "    SHA-256 不符：$2"
    echo "      預期 $3"
    echo "      實際 $got"
    exit 1
  fi
}

fetch "https://github.com/DanBloomberg/leptonica/releases/download/$LEPTONICA_VERSION/leptonica-$LEPTONICA_VERSION.tar.gz" \
  "$WORK/src/leptonica.tar.gz" "$LEPTONICA_SHA256"
fetch "https://github.com/tesseract-ocr/tesseract/archive/refs/tags/$TESSERACT_VERSION.tar.gz" \
  "$WORK/src/tesseract.tar.gz" "$TESSERACT_SHA256"
fetch "https://github.com/tesseract-ocr/tessdata_fast/raw/$TESSDATA_COMMIT/chi_sim.traineddata" \
  "$OUT_MODEL" "$CHI_SIM_SHA256"

tar xzf "$WORK/src/leptonica.tar.gz" -C "$WORK/src"
tar xzf "$WORK/src/tesseract.tar.gz" -C "$WORK/src"

export MACOSX_DEPLOYMENT_TARGET=10.15
COMMON_ARGS=(
  -G Ninja
  -DCMAKE_BUILD_TYPE=Release
  -DCMAKE_OSX_DEPLOYMENT_TARGET=10.15
  -DCMAKE_OSX_ARCHITECTURES=x86_64
  -DBUILD_SHARED_LIBS=OFF
  -DCMAKE_INSTALL_PREFIX="$WORK/prefix"
)

echo "==> 編譯 Leptonica $LEPTONICA_VERSION（靜態、不帶外部影像格式）"
cmake -S "$WORK/src/leptonica-$LEPTONICA_VERSION" -B "$WORK/build-leptonica" "${COMMON_ARGS[@]}" \
  -DENABLE_ZLIB=OFF -DENABLE_PNG=OFF -DENABLE_GIF=OFF -DENABLE_JPEG=OFF \
  -DENABLE_TIFF=OFF -DENABLE_WEBP=OFF -DENABLE_OPENJPEG=OFF -DSW_BUILD=OFF > "$WORK/leptonica-config.log"
cmake --build "$WORK/build-leptonica" > "$WORK/leptonica-build.log"
cmake --install "$WORK/build-leptonica" > /dev/null

# ENABLE_NATIVE=OFF：不能用 -march=native，開發機的 CPU 指令集比使用者的舊
# MacBook 新，編出來會在對方機器上 SIGILL。Tesseract 自己會在執行期偵測
# AVX/SSE 再挑實作。
echo "==> 編譯 Tesseract $TESSERACT_VERSION（靜態、不帶訓練工具／網路／壓縮檔支援）"
cmake -S "$WORK/src/tesseract-$TESSERACT_VERSION" -B "$WORK/build-tesseract" "${COMMON_ARGS[@]}" \
  -DCMAKE_PREFIX_PATH="$WORK/prefix" \
  -DLeptonica_DIR="$WORK/prefix/lib/cmake/leptonica" \
  -DBUILD_TRAINING_TOOLS=OFF -DDISABLE_ARCHIVE=ON -DDISABLE_CURL=ON -DDISABLE_TIFF=ON \
  -DENABLE_NATIVE=OFF -DGRAPHICS_DISABLED=ON -DOPENMP_BUILD=OFF -DENABLE_CCACHE=OFF \
  -DSW_BUILD=OFF > "$WORK/tesseract-config.log"
cmake --build "$WORK/build-tesseract" > "$WORK/tesseract-build.log"
cmake --install "$WORK/build-tesseract" > /dev/null

cp "$WORK/prefix/bin/tesseract" "$OUT_BIN"

# 驗證成品真的是 10.15 能跑的：minos 必須是 10.15，而且只能連結 /usr/lib
# 底下的系統函式庫。萬一哪天 CMake 偷偷找到 Homebrew 的 libarchive／
# libpng 之類，這裡會直接擋下，不會等到使用者那邊才發現打不開。
MINOS="$(otool -l "$OUT_BIN" | awk '/LC_BUILD_VERSION/{f=1} f&&/minos/{print $2; exit}')"
if [ "$MINOS" != "10.15" ]; then
  echo "    tesseract 的 minos 是 $MINOS，不是 10.15"
  rm -rf "$OUT_DIR"; exit 1
fi
if otool -L "$OUT_BIN" | tail -n +2 | grep -v "^[[:space:]]*/usr/lib/" ; then
  echo "    tesseract 連結到上面這些非系統函式庫，10.15 使用者的電腦上不會有"
  rm -rf "$OUT_DIR"; exit 1
fi

rm -rf "$WORK"
ln -sfn "$OUT_DIR" "$CURRENT_LINK"
echo "    Tesseract 編譯完成：$OUT_DIR（minos $MINOS）"
