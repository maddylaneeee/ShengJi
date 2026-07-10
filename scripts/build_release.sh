#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="声迹"
EXEC_NAME="ShengJi"
IDENTIFIER="ca.lixinchen.shengji"
DIST="$ROOT/dist"
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/shengji-release.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
APP="$STAGE/$APP_NAME.app"
FINAL_APP="$DIST/$APP_NAME.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"
BIN="$RESOURCES/bin"
THIRD_PARTY="$RESOURCES/ThirdParty"
ENTITLEMENTS="$STAGE/ShengJi.entitlements"
WHISPER_CLI="$ROOT/vendor/whisper.cpp/build-metal/bin/whisper-cli"
SIGN_IDENTITY="${SIGN_IDENTITY:-}"

if [[ ! -x "$WHISPER_CLI" ]]; then
  echo "Missing whisper-cli. Run ./scripts/bootstrap_whisper_cpp.sh first." >&2
  exit 1
fi

if [[ -z "$SIGN_IDENTITY" ]]; then
  SIGN_IDENTITY="$(security find-identity -v -p codesigning | awk -F'\"' '/valid identities found/{next} /[0-9A-F]{40}/ {print $2; exit}')"
fi

if [[ -z "$SIGN_IDENTITY" ]]; then
  echo "No valid signing identity found. Set SIGN_IDENTITY or create one first." >&2
  exit 1
fi

swift build -c release --arch arm64 --product "$EXEC_NAME"

rm -rf "$FINAL_APP" "$DIST/ShengJi.dmg"
mkdir -p "$MACOS" "$BIN" "$RESOURCES" "$THIRD_PARTY"

cp "$ROOT/.build/arm64-apple-macosx/release/$EXEC_NAME" "$MACOS/$EXEC_NAME"
cp "$WHISPER_CLI" "$BIN/whisper-cli"
cp -P "$ROOT"/vendor/whisper.cpp/build-metal/bin/lib*.dylib "$BIN/"
cp "$ROOT/Resources/AppIcon.icns" "$RESOURCES/AppIcon.icns"
cp "$ROOT/vendor/whisper.cpp/LICENSE" "$THIRD_PARTY/whisper.cpp-LICENSE"
cp "$ROOT/THIRD_PARTY_NOTICES.md" "$THIRD_PARTY/THIRD_PARTY_NOTICES.md"

cat > "$CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleExecutable</key><string>$EXEC_NAME</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleIdentifier</key><string>$IDENTIFIER</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
</dict>
</plist>
PLIST

cat > "$ENTITLEMENTS" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>com.apple.security.cs.disable-library-validation</key>
  <true/>
</dict>
</plist>
PLIST

if command -v xattr >/dev/null; then
  xattr -cr "$APP"
fi

while IFS= read -r old_rpath; do
  [[ -z "$old_rpath" || "$old_rpath" == "@loader_path" ]] && continue
  install_name_tool -delete_rpath "$old_rpath" "$BIN/whisper-cli" 2>/dev/null || true
done < <(otool -l "$BIN/whisper-cli" | awk '/^[[:space:]]*path / { line=$0; sub(/^[[:space:]]*path /, "", line); sub(/[[:space:]]\(offset [0-9]+\)$/, "", line); print line }')
install_name_tool -add_rpath "@loader_path" "$BIN/whisper-cli" 2>/dev/null || true

find "$BIN" -type f -name '*.dylib' -print0 | while IFS= read -r -d '' dylib; do
  codesign --force --timestamp --options runtime --sign "$SIGN_IDENTITY" "$dylib"
done
codesign --force --timestamp --options runtime --entitlements "$ENTITLEMENTS" --sign "$SIGN_IDENTITY" "$BIN/whisper-cli"
codesign --force --timestamp --options runtime --sign "$SIGN_IDENTITY" "$MACOS/$EXEC_NAME"
codesign --force --timestamp --options runtime --entitlements "$ENTITLEMENTS" --sign "$SIGN_IDENTITY" "$APP"
codesign --verify --strict --deep --verbose=2 "$APP"
spctl --assess --type execute --verbose=2 "$APP" || true

hdiutil create -volname "$APP_NAME" -srcfolder "$APP" -ov -format UDZO "$DIST/ShengJi.dmg"
codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DIST/ShengJi.dmg"
codesign --verify --verbose=2 "$DIST/ShengJi.dmg"

ditto --noextattr --noqtn "$APP" "$FINAL_APP"
verified_final=0
for _ in 1 2 3 4 5; do
  if command -v xattr >/dev/null; then
    xattr -cr "$FINAL_APP" || true
  fi
  if codesign --verify --strict --deep --verbose=2 "$FINAL_APP"; then
    verified_final=1
    break
  fi
  sleep 0.5
done
if [[ "$verified_final" != "1" ]]; then
  echo "Warning: final app copy is signed, but iCloud metadata prevented strict verification in dist. The staged app and DMG verified successfully." >&2
fi

echo "Built $FINAL_APP"
echo "Built $DIST/ShengJi.dmg"
