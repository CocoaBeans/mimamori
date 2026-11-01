#!/bin/zsh
# Builds Vigil.app from Vigil.xcodeproj and copies it to build/Vigil.app.
# Usage: Scripts/make-app.sh [debug|release]   (default: release)
#
# The app is signed with the project's team (automatic signing, an Apple Development certificate).
# VIGIL_SIGN=adhoc signs it ad hoc instead, for CI or a Mac without the team's certificate.
set -euo pipefail
cd "$(dirname "$0")/.."

case "${1:-release}" in
  debug) CONFIG=Debug ;;
  release) CONFIG=Release ;;
  *) echo "usage: $0 [debug|release]" >&2; exit 2 ;;
esac

SIGNING=()
if [[ "${VIGIL_SIGN:-team}" == adhoc ]]; then
  SIGNING=(CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=)
fi

xcodebuild -project Vigil.xcodeproj -scheme Vigil -configuration "$CONFIG" \
  -derivedDataPath build/DerivedData "${SIGNING[@]}" -quiet build

BUILT="build/DerivedData/Build/Products/$CONFIG/Vigil.app"
APP="build/Vigil.app"
rm -rf "$APP"
ditto "$BUILT" "$APP"

# xcodebuild registers what it builds with Launch Services, so macOS would run the desktop widget
# from the DerivedData copy, which breaks when that folder is cleaned. Register this copy instead.
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
"$LSREGISTER" -u "$PWD/$BUILT" >/dev/null 2>&1 || true
"$LSREGISTER" -f "$PWD/$APP" >/dev/null 2>&1 || true
echo "$PWD/$APP"
