#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR="$ROOT/vendor"
WHISPER="$VENDOR/whisper.cpp"

mkdir -p "$VENDOR"

if [[ ! -d "$WHISPER/.git" ]]; then
  git clone --depth 1 https://github.com/ggml-org/whisper.cpp.git "$WHISPER"
else
  git -C "$WHISPER" pull --ff-only
fi

cmake -S "$WHISPER" -B "$WHISPER/build-metal" \
  -DCMAKE_BUILD_TYPE=Release \
  -DGGML_METAL=ON \
  -DGGML_ACCELERATE=ON \
  -DWHISPER_BUILD_TESTS=OFF \
  -DWHISPER_BUILD_EXAMPLES=ON

cmake --build "$WHISPER/build-metal" --config Release --target whisper-cli -j"$(sysctl -n hw.ncpu)"

"$WHISPER/build-metal/bin/whisper-cli" --help | sed -n '1,80p'
