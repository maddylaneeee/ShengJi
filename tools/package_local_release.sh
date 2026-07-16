#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IDENTITY="${CODESIGN_IDENTITY:-MLCCS Local Code Signing}"
INFO_PLIST="$ROOT/LocalScribe/Resources/Info.plist"
VERSION="${VERSION:-$(plutil -extract CFBundleShortVersionString raw "$INFO_PLIST")}"
BUILD="${BUILD:-$(plutil -extract CFBundleVersion raw "$INFO_PLIST")}"
INSTALL_LOCAL_COPY="${INSTALL_LOCAL_COPY:-0}"
GITHUB_REPOSITORY="${GITHUB_REPOSITORY:-}"
RELEASE_TAG="${RELEASE_TAG:-${GITHUB_REF_NAME:-v${VERSION}}}"
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)"
WORK_ROOT="${TMPDIR:-/tmp}/codex-macos-packager/shengji-${VERSION}-${BUILD}-${RUN_ID}"
ARCHIVE="$WORK_ROOT/声迹.xcarchive"
STAGE="$WORK_ROOT/stage"
VERIFY="$WORK_ROOT/verify"
APP="$STAGE/声迹.app"
OUTPUT="$ROOT/dist/${VERSION}-${BUILD}"
ZIP_NAME="ShengJi-macOS-arm64.zip"
ZIP="$OUTPUT/$ZIP_NAME"
DMG_NAME="ShengJi-macOS-arm64.dmg"
DMG="$OUTPUT/$DMG_NAME"
DMG_STAGE="$WORK_ROOT/dmg"
DMG_MOUNT="$WORK_ROOT/dmg-mount"
UPDATE_MANIFEST="$OUTPUT/update.json"
REPORT="$OUTPUT/BUILD-REPORT-${VERSION}-${BUILD}.md"
MACHO_AUDIT="$OUTPUT/MACHO-AUDIT-${VERSION}-${BUILD}.txt"
LOCAL_DESKTOP_APPS="/Users/mattlixinchen/Desktop/Apps"
ICLOUD_DESKTOP_APPS="/Users/mattlixinchen/Library/Mobile Documents/com~apple~CloudDocs/Desktop/Apps"
LOCAL_APPS="/Users/mattlixinchen/Applications"
CANONICAL_APP="$LOCAL_APPS/声迹-${VERSION}.app"

resolve_desktop_apps() {
  if [[ -d "$LOCAL_DESKTOP_APPS" ]]; then
    print -r -- "$LOCAL_DESKTOP_APPS"
  elif [[ -d "$ICLOUD_DESKTOP_APPS" ]]; then
    print -r -- "$ICLOUD_DESKTOP_APPS"
  else
    print -r -- "$LOCAL_DESKTOP_APPS"
  fi
}

DESKTOP_APPS="$(resolve_desktop_apps)"

mkdir -p "$WORK_ROOT" "$STAGE" "$VERIFY" "$OUTPUT"

plutil -lint \
  "$INFO_PLIST" \
  "$ROOT/LocalScribe/Resources/LocalScribe.entitlements" \
  "$ROOT/LocalScribe/Resources/LocalScribeHelper.entitlements"

if [[ "$IDENTITY" != "-" ]] && ! security find-identity -v -p codesigning | rg -Fq "\"$IDENTITY\""; then
  print -u2 "找不到代码签名证书：$IDENTITY"
  exit 2
fi

if [[ "$IDENTITY" == "-" ]]; then
  SIGNING_DESCRIPTION="ad-hoc（无 Apple Developer ID，不公证）"
else
  SIGNING_DESCRIPTION="$IDENTITY（非 Apple Developer ID，不公证）"
fi

xcodebuild \
  -project "$ROOT/LocalScribe.xcodeproj" \
  -scheme LocalScribe \
  -configuration Release \
  -destination "platform=macOS,arch=arm64" \
  -archivePath "$ARCHIVE" \
  CODE_SIGNING_ALLOWED=NO \
  archive

BUILT_APP="$(find "$ARCHIVE/Products/Applications" -maxdepth 1 -type d -name '*.app' -print -quit)"
if [[ -z "$BUILT_APP" ]]; then
  print -u2 "Archive 中没有找到 App。"
  exit 3
fi
ditto --norsrc "$BUILT_APP" "$APP"

# Repository-only helper source and caches are not required by the frozen runtime.
rm -f "$APP/Contents/Resources/NLLBTranslator/translate_helper.py"
rm -rf "$APP/Contents/Resources/NLLBTranslator/__pycache__"
find "$APP" -name '.DS_Store' -delete
xattr -dr com.apple.FinderInfo "$APP" 2>/dev/null || true
xattr -dr com.apple.ResourceFork "$APP" 2>/dev/null || true

MACHO_LIST="$WORK_ROOT/macho-files.txt"
: > "$MACHO_LIST"
while IFS= read -r -d '' candidate; do
  if [[ "$(file -b "$candidate")" == *"Mach-O"* ]]; then
    print -r -- "$candidate" >> "$MACHO_LIST"
  fi
done < <(find "$APP" -type f -print0)

# Sign leaf code first. Symlinks are deliberately excluded by `find -type f`.
while IFS= read -r binary; do
  codesign --force --sign "$IDENTITY" --options runtime --timestamp=none "$binary"
done < "$MACHO_LIST"

# A local certificate without an Apple Team ID cannot satisfy dyld library
# validation for the bundled Sherpa/ONNX and NLLB/Python runtimes.  Keep the
# exception local to those isolated helper processes; the main App does not
# receive it.
HELPER_ENTITLEMENTS="$ROOT/LocalScribe/Resources/LocalScribeHelper.entitlements"
SHERPA_HELPER="$APP/Contents/Resources/SherpaOnnx/bin/sherpa-onnx-offline"
NLLB_HELPER="$APP/Contents/Resources/NLLBTranslator/runtime/LocalScribeNLLB/LocalScribeNLLB"
for helper in "$SHERPA_HELPER" "$NLLB_HELPER"; do
  [[ -f "$helper" ]]
  codesign --force --sign "$IDENTITY" --options runtime --timestamp=none \
    --entitlements "$HELPER_ENTITLEMENTS" "$helper"
done

while IFS= read -r framework; do
  codesign --force --sign "$IDENTITY" --options runtime --timestamp=none "$framework"
done < <(find "$APP" -type d -name '*.framework' | awk '{ print length, $0 }' | sort -rn | cut -d' ' -f2-)

codesign --force --sign "$IDENTITY" --options runtime --timestamp=none \
  --entitlements "$ROOT/LocalScribe/Resources/LocalScribe.entitlements" "$APP"

codesign --verify --deep --strict --verbose=2 "$APP"
while IFS= read -r binary; do
  codesign --verify --strict --verbose=1 "$binary"
done < "$MACHO_LIST"
codesign -d --entitlements :- "$SHERPA_HELPER" > "$WORK_ROOT/sherpa-entitlements.plist" 2>/dev/null
codesign -d --entitlements :- "$NLLB_HELPER" > "$WORK_ROOT/nllb-entitlements.plist" 2>/dev/null
codesign -d --entitlements :- "$APP" > "$WORK_ROOT/app-entitlements.plist" 2>/dev/null
plutil -p "$WORK_ROOT/sherpa-entitlements.plist" | \
  rg -q '"com\.apple\.security\.cs\.disable-library-validation" => true'
plutil -p "$WORK_ROOT/nllb-entitlements.plist" | \
  rg -q '"com\.apple\.security\.cs\.disable-library-validation" => true'
if plutil -p "$WORK_ROOT/app-entitlements.plist" | \
  rg -q '"com\.apple\.security\.cs\.disable-library-validation" => true'; then
  print -u2 "主 App 不应禁用 library validation。"
  exit 4
fi

[[ "$(plutil -extract CFBundleIdentifier raw "$APP/Contents/Info.plist")" == "ca.lixinchen.localscribe" ]]
[[ "$(plutil -extract CFBundleShortVersionString raw "$APP/Contents/Info.plist")" == "$VERSION" ]]
[[ "$(plutil -extract CFBundleVersion raw "$APP/Contents/Info.plist")" == "$BUILD" ]]
[[ "$(plutil -extract LSMinimumSystemVersion raw "$APP/Contents/Info.plist")" == "15.5" ]]
VAD_MODEL="$APP/Contents/Resources/WhisperVAD/ggml-silero-v6.2.0.bin"
[[ -f "$VAD_MODEL" ]]
[[ "$(stat -f %z "$VAD_MODEL")" == "885098" ]]
[[ "$(shasum -a 256 "$VAD_MODEL" | awk '{print $1}')" == "2aa269b785eeb53a82983a20501ddf7c1d9c48e33ab63a41391ac6c9f7fb6987" ]]

if find "$APP" -type f \( -name '*.swift' -o -name '*.c' -o -name '*.cpp' -o -name 'translate_helper.py' \) -print -quit | rg -q .; then
  print -u2 "发布包中发现不应包含的源码。"
  exit 5
fi

: > "$MACHO_AUDIT"
while IFS= read -r binary; do
  relative="${binary#$APP/}"
  print -r -- "===== $relative =====" >> "$MACHO_AUDIT"
  file -b "$binary" >> "$MACHO_AUDIT"
  lipo "$binary" -verify_arch arm64
  build_info="$(vtool -show-build "$binary" 2>/dev/null || true)"
  print -r -- "$build_info" >> "$MACHO_AUDIT"
  minos="$(print -r -- "$build_info" | awk '$1 == "minos" { print $2; exit }')"
  if [[ -n "$minos" ]]; then
    if ! awk -v version="$minos" 'BEGIN {
      split(version, parts, ".")
      major = parts[1] + 0
      minor = parts[2] + 0
      exit !((major < 15) || (major == 15 && minor <= 5))
    }'; then
      print -u2 "Mach-O 最低系统版本高于 15.5：$relative ($minos)"
      exit 6
    fi
  fi
  print >> "$MACHO_AUDIT"
done < "$MACHO_LIST"

rm -f "$ZIP"
COPYFILE_DISABLE=1 ditto -c -k --norsrc --keepParent "$APP" "$ZIP"
unzip -t "$ZIP" > "$WORK_ROOT/zip-test.txt"
ditto -x -k "$ZIP" "$VERIFY"
EXTRACTED_APP="$(find "$VERIFY" -maxdepth 1 -type d -name '*.app' -print -quit)"
xattr -dr com.apple.FinderInfo "$EXTRACTED_APP" 2>/dev/null || true
xattr -dr com.apple.ResourceFork "$EXTRACTED_APP" 2>/dev/null || true
codesign --verify --deep --strict --verbose=2 "$EXTRACTED_APP"
[[ "$(shasum -a 256 "$EXTRACTED_APP/Contents/Resources/WhisperVAD/ggml-silero-v6.2.0.bin" | awk '{print $1}')" == "2aa269b785eeb53a82983a20501ddf7c1d9c48e33ab63a41391ac6c9f7fb6987" ]]

"$EXTRACTED_APP/Contents/MacOS/LocalScribe" --cli help > "$WORK_ROOT/cli-help.txt"
set +e
"$EXTRACTED_APP/Contents/Resources/SherpaOnnx/bin/sherpa-onnx-offline" --help > "$WORK_ROOT/sherpa-help.txt" 2>&1
SHERPA_STATUS=$?
set -e
if rg -qi 'dyld|library not loaded|different Team IDs|code signature.*not valid' "$WORK_ROOT/sherpa-help.txt"; then
  print -u2 "Sherpa helper 无法加载其动态库。"
  cat "$WORK_ROOT/sherpa-help.txt" >&2
  exit 7
fi
if [[ ! -s "$WORK_ROOT/sherpa-help.txt" ]]; then
  print -u2 "Sherpa helper 未产生帮助或诊断输出（status=$SHERPA_STATUS）。"
  exit 7
fi
"$EXTRACTED_APP/Contents/Resources/NLLBTranslator/runtime/LocalScribeNLLB/LocalScribeNLLB" < /dev/null > "$WORK_ROOT/nllb-smoke.txt" 2>&1

SHA256="$(shasum -a 256 "$ZIP" | awk '{print $1}')"
print -r -- "$SHA256  $ZIP_NAME" > "$ZIP.sha256"

rm -rf "$DMG_STAGE" "$DMG_MOUNT"
mkdir -p "$DMG_STAGE" "$DMG_MOUNT"
ditto --norsrc "$APP" "$DMG_STAGE/声迹.app"
ln -s /Applications "$DMG_STAGE/Applications"
rm -f "$DMG"
hdiutil create -quiet -fs HFS+ -format UDZO -volname "声迹 ${VERSION}" \
  -srcfolder "$DMG_STAGE" "$DMG"
hdiutil verify "$DMG"
MOUNT_DEVICE="$(hdiutil attach -quiet -readonly -nobrowse -mountpoint "$DMG_MOUNT" "$DMG" | awk 'NR == 1 { print $1 }')"
detach_dmg() {
  [[ -z "${MOUNT_DEVICE:-}" ]] && return 0
  local attempt
  for attempt in 1 2 3; do
    if hdiutil detach -quiet "$MOUNT_DEVICE" 2>/dev/null; then
      MOUNT_DEVICE=""
      return 0
    fi
    sleep 1
  done
  hdiutil detach -quiet -force "$MOUNT_DEVICE"
  MOUNT_DEVICE=""
}
trap 'detach_dmg || true' EXIT
codesign --verify --deep --strict --verbose=2 "$DMG_MOUNT/声迹.app"
[[ -L "$DMG_MOUNT/Applications" ]]
detach_dmg
DMG_SHA256="$(shasum -a 256 "$DMG" | awk '{print $1}')"
print -r -- "$DMG_SHA256  $DMG_NAME" > "$DMG.sha256"

if [[ -n "$GITHUB_REPOSITORY" ]]; then
  DOWNLOAD_URL="https://github.com/${GITHUB_REPOSITORY}/releases/download/${RELEASE_TAG}/${ZIP_NAME}"
else
  DOWNLOAD_URL="file://$ZIP"
fi

cat > "$UPDATE_MANIFEST" <<EOF
{
  "version": "$VERSION",
  "build": "$BUILD",
  "download_url": "$DOWNLOAD_URL",
  "sha256": "$SHA256",
  "release_notes": "声迹 1.4.0：新增完整英文界面，并根据 macOS 首选语言自动切换；本地化资源采用可扩展结构，方便后续继续添加语言。",
  "minimum_system_version": "15.5",
  "published_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "size_bytes": $(stat -f %z "$ZIP")
}
EOF

MACHO_COUNT="$(wc -l < "$MACHO_LIST" | tr -d ' ')"
cat > "$REPORT" <<EOF
# 声迹 ${VERSION}（${BUILD}）本机发布报告

- 源码：$ROOT
- 构建时间（UTC）：$(date -u +%Y-%m-%dT%H:%M:%SZ)
- Bundle ID：ca.lixinchen.localscribe
- 架构：arm64
- 最低系统：macOS 15.5
- 签名：$SIGNING_DESCRIPTION；Hardened Runtime；timestamp=none
- Library Validation：仅 Sherpa 与 NLLB helper 局部禁用（无 Team ID 本机证书兼容）；主 App 未禁用
- 嵌套 Mach-O 数量：$MACHO_COUNT
- Whisper：whisper.cpp v1.9.1，Metal→CPU；内置 Silero VAD v6.2.0；整段文件由 whisper.cpp 自动推进窗口
- SenseVoice/Parakeet：自动优先尝试 Core ML，失败后回退 CPU；实际计算单元由系统选择
- NLLB：CTranslate2 CPU/int8
- ZIP：$ZIP_NAME
- SHA-256：$SHA256
- DMG：$DMG_NAME
- DMG SHA-256：$DMG_SHA256
- 静态验证：Bundle 元数据、arm64、Mach-O 最低系统版本、源码泄漏、逐层签名、严格深层签名均通过
- 解压验证：在非 iCloud 临时目录解压后严格验签和 CLI/helper 启动通过
- 本机交付：默认仅生成更新 ZIP，优先通过应用内更新安装；仅在 INSTALL_LOCAL_COPY=1 时覆盖 $DESKTOP_APPS/声迹.app
- Gatekeeper：本机自签名证书不是 Developer ID，spctl 拒绝属于预期，不作为包损坏判据
- 运行验证：见 RUNTIME-VERIFICATION-${VERSION}-${BUILD}.md；Debug、Release、Analyze、单元测试和真实 GUI/CLI Whisper 回归结果记录在该报告中
- 差异摘要：见 FILE-DIFF-${VERSION}-${BUILD}.md
- macOS 15.5：本轮按用户选择完成静态兼容性审计；真实功能回归在 macOS 26.5.2 完成，未创建 15.5 VM
EOF

if [[ "$INSTALL_LOCAL_COPY" == "1" ]]; then
  mkdir -p "$DESKTOP_APPS" "$LOCAL_APPS"
  for supplemental_report in \
    "$OUTPUT/RUNTIME-VERIFICATION-${VERSION}-${BUILD}.md" \
    "$OUTPUT/FILE-DIFF-${VERSION}-${BUILD}.md"; do
    if [[ -f "$supplemental_report" ]]; then
      cp "$supplemental_report" "$DESKTOP_APPS/"
    fi
  done
  if [[ -e "$CANONICAL_APP" || -L "$CANONICAL_APP" ]]; then
    mv "$CANONICAL_APP" "$LOCAL_APPS/声迹-${VERSION}-previous-${RUN_ID}.app"
  fi
  ditto --norsrc "$EXTRACTED_APP" "$CANONICAL_APP"
  xattr -dr com.apple.FinderInfo "$CANONICAL_APP" 2>/dev/null || true
  xattr -dr com.apple.ResourceFork "$CANONICAL_APP" 2>/dev/null || true
  codesign --verify --deep --strict --verbose=2 "$CANONICAL_APP"

  if [[ -e "$DESKTOP_APPS/声迹.app" || -L "$DESKTOP_APPS/声迹.app" ]]; then
    mv "$DESKTOP_APPS/声迹.app" "$DESKTOP_APPS/声迹-previous-${RUN_ID}.app"
  fi
  ditto --norsrc "$CANONICAL_APP" "$DESKTOP_APPS/声迹.app"
  xattr -dr com.apple.FinderInfo "$DESKTOP_APPS/声迹.app" 2>/dev/null || true
  xattr -dr com.apple.ResourceFork "$DESKTOP_APPS/声迹.app" 2>/dev/null || true
  codesign --verify --deep --strict --verbose=2 "$DESKTOP_APPS/声迹.app"
fi

print "发布完成：$ZIP"
print "DMG：$DMG"
if [[ "$INSTALL_LOCAL_COPY" == "1" ]]; then
  print "桌面 App：$DESKTOP_APPS/声迹.app（备用覆盖安装）"
else
  print "未覆盖桌面 App；请优先使用应用内更新。"
fi
print "SHA-256：$SHA256"
