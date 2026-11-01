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

APP="build/Vigil.app"
rm -rf "$APP"
ditto "build/DerivedData/Build/Products/$CONFIG/Vigil.app" "$APP"
echo "$PWD/$APP"
