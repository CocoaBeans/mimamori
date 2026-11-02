#!/bin/zsh
# Builds a release: archives Mimamori, exports it signed with Developer ID (the app and its widget
# extension, each with its own entitlements and the hardened runtime), notarizes and staples it,
# then packs it in a DMG that is notarized and stapled in turn. Leaves build/Mimamori-<version>.dmg
# and prints its SHA-256 for the Homebrew cask.
#
# Requirements:
#   - A "Developer ID Application" certificate for the project's team: in the login keychain, or
#     cloud-managed, which xcodebuild can sign with when the API key below has the Admin role.
#   - An App Store Connect API key, for xcodebuild's signing and for notarytool:
#       ASC_KEY_ID      the key id (the file is read from
#                       ~/.appstoreconnect/private_keys/AuthKey_<ASC_KEY_ID>.p8,
#                       or point ASC_KEY_PATH at it)
#       ASC_ISSUER_ID   the issuer id
#
# Usage: ASC_KEY_ID=XXXXXXXXXX ASC_ISSUER_ID=... Scripts/release.sh
#        RELEASE_DRY_RUN=1 Scripts/release.sh
#
# A dry run exports with the everyday development signing and skips notarization, to check the
# archive, the entitlements and the DMG without a Developer ID certificate. A release refuses a
# working tree with uncommitted changes, so the commit in About is the one released.
set -euo pipefail
cd "$(dirname "$0")/.."

DRY_RUN="${RELEASE_DRY_RUN:-0}"
VERSION="$(plutil -extract CFBundleShortVersionString raw Resources/Info.plist)"
BUILD="$(plutil -extract CFBundleVersion raw Resources/Info.plist)"
TEAM="$(grep -m1 -o 'DEVELOPMENT_TEAM = [A-Z0-9]*' Mimamori.xcodeproj/project.pbxproj | awk '{print $3}')"
OUT=build/release
ARCHIVE=$OUT/Mimamori.xcarchive
EXPORT=$OUT/export
APP=$EXPORT/Mimamori.app
WIDGETS=$APP/Contents/PlugIns/MimamoriWidgets.appex
STAGE=$OUT/dmg
DMG=build/Mimamori-$VERSION.dmg

COMMIT="$(git rev-parse --short=8 HEAD)"
if [[ -n "$(git status --porcelain --untracked-files=no)" ]]; then
  if [[ $DRY_RUN != 1 ]]; then
    echo "The working tree has uncommitted changes. Commit them first, so the release matches its commit." >&2
    exit 1
  fi
  COMMIT="$COMMIT-dirty"
fi

# With an API key, xcodebuild may fetch or create the certificate and profiles signing needs.
AUTH=()
if [[ -n "${ASC_KEY_ID:-}" ]]; then
  : "${ASC_ISSUER_ID:?Set ASC_ISSUER_ID to your App Store Connect issuer id}"
  ASC_KEY_PATH="${ASC_KEY_PATH:-$HOME/.appstoreconnect/private_keys/AuthKey_$ASC_KEY_ID.p8}"
  [[ -f "$ASC_KEY_PATH" ]] || { echo "API key not found at $ASC_KEY_PATH" >&2; exit 1; }
  AUTH=(-allowProvisioningUpdates -authenticationKeyPath "$ASC_KEY_PATH"
        -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID")
elif [[ $DRY_RUN != 1 ]]; then
  echo "Set ASC_KEY_ID and ASC_ISSUER_ID to your App Store Connect API key, for signing and notarization." >&2
  exit 1
fi

# Sends a zip or DMG to Apple and waits; on a rejection, prints Apple's log of what was wrong.
notarize() {
  echo "Notarizing $1…"
  local result id status_
  result="$(xcrun notarytool submit "$1" --key "$ASC_KEY_PATH" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER_ID" \
    --wait --output-format json)"
  id="$(plutil -extract id raw - <<< "$result")"
  status_="$(plutil -extract status raw - <<< "$result")"
  if [[ $status_ != Accepted ]]; then
    echo "Notarization of $1 ended $status_ ($id):" >&2
    xcrun notarytool log "$id" --key "$ASC_KEY_PATH" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER_ID" >&2 || true
    exit 1
  fi
}

rm -rf $OUT
mkdir -p $OUT
echo "Archiving Mimamori $VERSION ($BUILD) from $COMMIT…"
xcodebuild -project Mimamori.xcodeproj -scheme Mimamori -configuration Release -archivePath $ARCHIVE \
  -derivedDataPath build/DerivedData MIMAMORI_COMMIT="$COMMIT" "${AUTH[@]}" -quiet archive

# Xcode signs every part of the app, inside out, for the chosen way of distributing it.
cat > $OUT/ExportOptions.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>$([[ $DRY_RUN == 1 ]] && echo debugging || echo developer-id)</string>
  <key>teamID</key><string>$TEAM</string>
  <key>signingStyle</key><string>automatic</string>
  <key>destination</key><string>export</string>
</dict>
</plist>
PLIST
xcodebuild -exportArchive -archivePath $ARCHIVE -exportPath $EXPORT -exportOptionsPlist $OUT/ExportOptions.plist \
  "${AUTH[@]}" -quiet

# The widget reads what the app writes through their shared app group: both must keep it.
codesign --verify --deep --strict --verbose=1 $APP
for part in $APP $WIDGETS; do
  # Read whole, not piped into grep -q: with pipefail, its early exit would fail the pipe.
  entitlements="$(codesign -d --entitlements - --xml $part 2>/dev/null)"
  details="$(codesign -dvv $part 2>&1)"
  [[ $entitlements == *application-groups* ]] || { echo "$part was signed without its app group entitlement" >&2; exit 1; }
  [[ $details == *flags=*runtime* ]] || { echo "$part was signed without the hardened runtime" >&2; exit 1; }
done
for line in ${(f)"$(codesign -dvv $APP 2>&1)"}; do
  [[ $line == Authority=* ]] && { echo "Signed by: ${line#Authority=}"; break; }
done

if [[ $DRY_RUN != 1 ]]; then
  ditto -c -k --keepParent $APP $OUT/Mimamori.zip
  notarize $OUT/Mimamori.zip
  xcrun stapler staple $APP
fi

# The DMG: the app beside a link to Applications, to drag it onto.
mkdir -p $STAGE
ditto $APP $STAGE/Mimamori.app
ln -s /Applications $STAGE/Applications
rm -f $DMG
hdiutil create -volname "Mimamori $VERSION" -srcfolder $STAGE -fs HFS+ -format UDZO -ov -quiet $DMG

if [[ $DRY_RUN != 1 ]]; then
  # Signing the DMG needs the certificate in the keychain; a cloud-managed one cannot. The
  # notarization ticket stapled to it is what Gatekeeper checks either way.
  IDENTITY="$(security find-identity -v -p codesigning | grep -o '"Developer ID Application: [^"]*"' | head -1 | tr -d '"')"
  if [[ -n $IDENTITY ]]; then
    codesign --sign "$IDENTITY" --timestamp $DMG
  else
    echo "No Developer ID certificate in the keychain: the DMG itself is left unsigned."
  fi
  notarize $DMG
  xcrun stapler staple $DMG
  spctl --assess --type execute --verbose=1 $APP
fi

# The archive and export are app copies Launch Services would otherwise offer to run, widget
# included; keep build/Mimamori.app as the one it knows, as make-app.sh does.
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
for built in $OUT/**/Mimamori.app(N) build/DerivedData/**/Mimamori.app(N); do
  "$LSREGISTER" -u "$PWD/$built" >/dev/null 2>&1 || true
done
[[ -d build/Mimamori.app ]] && { "$LSREGISTER" -f "$PWD/build/Mimamori.app" >/dev/null 2>&1 || true; }

echo "Ready: $PWD/$DMG$([[ $DRY_RUN == 1 ]] && echo ' (dry run: development signing, not notarized)')"
echo "SHA-256: $(shasum -a 256 $DMG | cut -d' ' -f1)"
