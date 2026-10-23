#!/bin/zsh
# Builds a release, signs it with a Developer ID certificate, notarizes it with
# Apple, staples the ticket and leaves a zip ready for a GitHub release.
#
# Requirements:
#   - A "Developer ID Application" identity in the login keychain (or IDENTITY=...).
#   - An App Store Connect API key for notarytool:
#       ASC_KEY_ID      the key id (the file is expected at
#                       ~/.appstoreconnect/private_keys/AuthKey_<ASC_KEY_ID>.p8,
#                       or point ASC_KEY_PATH at it)
#       ASC_ISSUER_ID   the issuer id
#
# Usage: ASC_KEY_ID=XXXXXXXXXX ASC_ISSUER_ID=... Scripts/release.sh
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="$(plutil -extract CFBundleShortVersionString raw Resources/Info.plist)"
BUNDLE_ID="$(plutil -extract CFBundleIdentifier raw Resources/Info.plist)"
APP="$(Scripts/make-app.sh release)"
ZIP="build/Vigil-$VERSION.zip"

IDENTITY="${IDENTITY:-$(security find-identity -v -p codesigning | grep -o '"Developer ID Application: [^"]*"' | head -1 | tr -d '"')}"
if [[ -z "$IDENTITY" ]]; then
  echo "No 'Developer ID Application' identity found. Set IDENTITY=... or install the certificate." >&2
  exit 1
fi
: "${ASC_KEY_ID:?Set ASC_KEY_ID to your App Store Connect API key id}"
: "${ASC_ISSUER_ID:?Set ASC_ISSUER_ID to your App Store Connect issuer id}"
ASC_KEY_PATH="${ASC_KEY_PATH:-$HOME/.appstoreconnect/private_keys/AuthKey_$ASC_KEY_ID.p8}"
[[ -f "$ASC_KEY_PATH" ]] || { echo "API key not found at $ASC_KEY_PATH" >&2; exit 1; }

echo "Signing with: $IDENTITY"
codesign --force --options runtime --timestamp --sign "$IDENTITY" --identifier "$BUNDLE_ID" "$APP/Contents/MacOS/Vigil"
codesign --force --options runtime --timestamp --sign "$IDENTITY" --identifier "$BUNDLE_ID" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
echo "Submitting $ZIP for notarization…"
xcrun notarytool submit "$ZIP" --key "$ASC_KEY_PATH" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER_ID" --wait
xcrun stapler staple "$APP"
spctl --assess --type execute --verbose=2 "$APP"

rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
echo "Ready: $PWD/$ZIP"
