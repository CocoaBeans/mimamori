#!/bin/zsh
# Builds Vigil and wraps it in a proper .app bundle at build/Vigil.app.
# Usage: Scripts/make-app.sh [debug|release]   (default: release)
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
swift build -c "$CONFIG" --product Vigil
BIN="$(swift build -c "$CONFIG" --show-bin-path)/Vigil"

APP="build/Vigil.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Vigil"
cp Resources/Info.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
if [[ -f Resources/AppIcon.icns ]]; then
  cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi

# Ad-hoc signature so macOS treats it as a stable identity (notifications, TCC prompts).
codesign --force --sign - --identifier dev.vigil.mac "$APP" >/dev/null 2>&1 || true
echo "$PWD/$APP"
