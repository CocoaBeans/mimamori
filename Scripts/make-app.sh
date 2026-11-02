#!/bin/zsh
# Builds Mimamori.app from Mimamori.xcodeproj and copies it to build/Mimamori.app.
# Usage: Scripts/make-app.sh [debug|release]   (default: release)
#
# The app is signed with the project's team (automatic signing, an Apple Development certificate).
# MIMAMORI_SIGN=adhoc signs it ad hoc instead, for CI or a Mac without the team's certificate.
set -euo pipefail
cd "$(dirname "$0")/.."

case "${1:-release}" in
  debug) CONFIG=Debug ;;
  release) CONFIG=Release ;;
  *) echo "usage: $0 [debug|release]" >&2; exit 2 ;;
esac

SIGNING=()
if [[ "${MIMAMORI_SIGN:-team}" == adhoc ]]; then
  SIGNING=(CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=)
fi

# The commit the app is built from, for its About window and Copy Diagnostics, with "-dirty"
# when tracked files have changes not yet committed. Info.plist takes it as MimamoriCommit.
COMMIT="$(git rev-parse --short=8 HEAD 2>/dev/null || true)"
if [[ -n "$COMMIT" && -n "$(git status --porcelain --untracked-files=no 2>/dev/null)" ]]; then
  COMMIT="$COMMIT-dirty"
fi

xcodebuild -project Mimamori.xcodeproj -scheme Mimamori -configuration "$CONFIG" \
  -derivedDataPath build/DerivedData "${SIGNING[@]}" MIMAMORI_COMMIT="$COMMIT" -quiet build

BUILT="build/DerivedData/Build/Products/$CONFIG/Mimamori.app"
APP="build/Mimamori.app"
rm -rf "$APP"
ditto "$BUILT" "$APP"

# xcodebuild registers what it builds with Launch Services, so macOS would run the desktop widget
# from a DerivedData copy (this build's, or a Debug build's), which breaks when that folder is
# cleaned and may be older code. Unregister them all and register this copy instead.
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
for built in "$PWD"/build/DerivedData/Build/Products/*/Mimamori.app(N); do
  "$LSREGISTER" -u "$built" >/dev/null 2>&1 || true
done
"$LSREGISTER" -f "$PWD/$APP" >/dev/null 2>&1 || true
echo "$PWD/$APP"
