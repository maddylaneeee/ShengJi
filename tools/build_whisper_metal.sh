#!/bin/zsh
set -euo pipefail

VERSION="v1.9.1"
WORK_ROOT="${TMPDIR:-/tmp}/localscribe-whisper-build"
CMAKE_BIN="${HOME}/Library/Python/3.9/bin/cmake"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

if [[ ! -x "$CMAKE_BIN" ]]; then
  python3 -m pip install --user cmake
fi

rm -rf "$WORK_ROOT"
git clone --depth 1 --branch "$VERSION" https://github.com/ggml-org/whisper.cpp.git "$WORK_ROOT/source"

"$CMAKE_BIN" -S "$WORK_ROOT/source" -B "$WORK_ROOT/build" -G Xcode \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=15.5 \
  -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DBUILD_SHARED_LIBS=OFF \
  -DWHISPER_BUILD_EXAMPLES=OFF \
  -DWHISPER_BUILD_TESTS=OFF \
  -DWHISPER_BUILD_SERVER=OFF \
  -DWHISPER_COREML=OFF \
  -DGGML_METAL=ON \
  -DGGML_METAL_EMBED_LIBRARY=ON \
  -DGGML_METAL_USE_BF16=ON \
  -DGGML_BLAS_DEFAULT=ON \
  -DGGML_NATIVE=OFF \
  -DGGML_OPENMP=OFF

"$CMAKE_BIN" --build "$WORK_ROOT/build" --config Release --parallel 8

mkdir -p "$REPO_ROOT/Vendor/WhisperMetal/lib" "$REPO_ROOT/Vendor/WhisperMetal/include"
libtool -static -o "$REPO_ROOT/Vendor/WhisperMetal/lib/libWhisperMetal.a" \
  "$WORK_ROOT/build/src/Release/libwhisper.a" \
  "$WORK_ROOT/build/ggml/src/Release/libggml.a" \
  "$WORK_ROOT/build/ggml/src/Release/libggml-base.a" \
  "$WORK_ROOT/build/ggml/src/Release/libggml-cpu.a" \
  "$WORK_ROOT/build/ggml/src/ggml-metal/Release/libggml-metal.a" \
  "$WORK_ROOT/build/ggml/src/ggml-blas/Release/libggml-blas.a"

cp "$WORK_ROOT/source/include/whisper.h" "$REPO_ROOT/Vendor/WhisperMetal/include/"
cp "$WORK_ROOT/source/ggml/include/"{ggml.h,ggml-cpu.h,ggml-backend.h,ggml-alloc.h,gguf.h} "$REPO_ROOT/Vendor/WhisperMetal/include/"
cp "$WORK_ROOT/source/LICENSE" "$REPO_ROOT/Vendor/WhisperMetal/LICENSE.whisper.cpp"
echo "Whisper Metal library rebuilt."
