#!/bin/bash
# Builds "Harbor.app" into ./build
#   ./build.sh              native Intel (x86_64) release build
#   UNIVERSAL=1 ./build.sh  Intel + Apple silicon
#   ./build.sh --install    also copy the app to /Applications
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="Harbor"
APP="build/$APP_NAME.app"

if [[ "${UNIVERSAL:-0}" == "1" ]]; then
  ARCH_FLAGS=(--arch x86_64 --arch arm64)
else
  ARCH_FLAGS=(--arch x86_64)
fi

CONFIG="${CONFIG:-release}"   # CONFIG=debug for fast iteration
echo "▸ Compiling $CONFIG (${ARCH_FLAGS[*]})"
swift build -c "$CONFIG" "${ARCH_FLAGS[@]}"
BIN_DIR="$(swift build -c "$CONFIG" "${ARCH_FLAGS[@]}" --show-bin-path)"

echo "▸ Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Harbor" "$APP/Contents/MacOS/Harbor"
cp Resources/Info.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

if [[ ! -f build/AppIcon.icns || scripts/make_icon.swift -nt build/AppIcon.icns ]]; then
  echo "▸ Rendering icon"
  ICONSET="build/AppIcon.iconset"
  rm -rf "$ICONSET" && mkdir -p "$ICONSET"
  swift scripts/make_icon.swift build/icon_1024.png >/dev/null
  for s in 16 32 128 256 512; do
    sips -z $s $s build/icon_1024.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    sips -z $((s*2)) $((s*2)) build/icon_1024.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o build/AppIcon.icns
fi
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Sign with the local identity from scripts/setup-signing.sh when present: its
# designated requirement stays the same across rebuilds, so macOS keeps the
# Accessibility / Screen Recording grants. Falls back to ad-hoc signing.
SIGNING_DIR=".signing"
SIGNING_KEYCHAIN="$PWD/$SIGNING_DIR/signing.keychain-db"
if [[ -z "${SIGN_IDENTITY:-}" && -f "$SIGNING_KEYCHAIN" ]]; then
  echo "▸ Signing (Harbor Local Signing)"
  security unlock-keychain -p "$(cat "$SIGNING_DIR/keychain-password")" "$SIGNING_KEYCHAIN"
  # codesign only finds identities in the search list, so add the signing
  # keychain for the moment it takes, then put the list back exactly.
  ORIG_KEYCHAINS=()
  while IFS= read -r line; do
    line="${line#"${line%%[![:space:]]*}"}"; line="${line#\"}"; line="${line%\"}"
    [[ -n "$line" ]] && ORIG_KEYCHAINS+=("$line")
  done < <(security list-keychains -d user)
  restore_keychains() { security list-keychains -d user -s "${ORIG_KEYCHAINS[@]}"; }
  trap restore_keychains EXIT
  security list-keychains -d user -s "${ORIG_KEYCHAINS[@]}" "$SIGNING_KEYCHAIN"
  codesign --force --sign "Harbor Local Signing" --timestamp=none "$APP"
  restore_keychains
  trap - EXIT
else
  echo "▸ Signing (${SIGN_IDENTITY:-ad-hoc})"
  codesign --force --sign "${SIGN_IDENTITY:--}" --timestamp=none "$APP"
fi

if [[ "${1:-}" == "--install" ]]; then
  echo "▸ Installing to /Applications"
  pkill -x Harbor 2>/dev/null || true
  rm -rf "/Applications/$APP_NAME.app"
  cp -R "$APP" /Applications/
  APP="/Applications/$APP_NAME.app"
fi

echo "✓ Built $APP ($(lipo -archs "$APP/Contents/MacOS/Harbor"))"
