#!/bin/zsh
# Builds a release: archives Mimamori, exports it signed with Developer ID (the app and its widget
# extension, each with its own entitlements and the hardened runtime), notarizes and staples it,
# then packs it in a DMG that is notarized and stapled in turn. Signs the DMG for Sparkle and
# writes the appcast that offers it, with the release notes from docs/releases/<version>.md
# embedded for the update window. Leaves build/Mimamori-<version>.dmg and build/appcast.xml, and
# prints the DMG's SHA-256 for the Homebrew cask and the command that publishes both, with the same
# notes on the release page.
#
# The version is the project's MARKETING_VERSION and the build number its CURRENT_PROJECT_VERSION
# (Scripts/set-version.sh changes them); Sparkle compares build numbers, so each release needs a
# higher one.
#
# Requirements:
#   - A "Developer ID Application" certificate for the project's team: in the login keychain, or
#     cloud-managed, which xcodebuild can sign with when the API key below has the Admin role.
#   - Sparkle's signing key, made once with Sparkle's generate_keys --account mimamori, in the
#     login keychain (its public half is SUPublicEDKey in Resources/Info.plist), or exported to
#     a file that SPARKLE_KEY_FILE names, as the release workflow does.
#   - An App Store Connect API key, for xcodebuild's signing and for notarytool:
#       ASC_KEY_ID      the key id (the file is read from
#                       ~/.appstoreconnect/private_keys/AuthKey_<ASC_KEY_ID>.p8,
#                       or point ASC_KEY_PATH at it)
#       ASC_ISSUER_ID   the issuer id
#
# Usage: ASC_KEY_ID=XXXXXXXXXX ASC_ISSUER_ID=... Scripts/release.sh
#        RELEASE_DRY_RUN=1 Scripts/release.sh
#
# On a Mac, Xcode signs the archive with your Apple Development certificate and the export with
# Developer ID. RELEASE_SIGNING=manual signs both with Developer ID instead (RELEASE_IDENTITY,
# by name or SHA-1, "Developer ID Application" if unset), for a machine with no development
# certificate, such as the release workflow's runner. The API key then only notarizes.
#
# A dry run exports with the everyday development signing and skips notarization, to check the
# archive, the entitlements and the DMG without a Developer ID certificate. A release refuses a
# working tree with uncommitted changes, so the commit in About is the one released.
set -euo pipefail
cd "$(dirname "$0")/.."

DRY_RUN="${RELEASE_DRY_RUN:-0}"
SIGNING="${RELEASE_SIGNING:-automatic}"
SIGNING_IDENTITY="${RELEASE_IDENTITY:-Developer ID Application}"
setting() { grep -m1 -o "$1 = [^;]*" Mimamori.xcodeproj/project.pbxproj | sed "s/^$1 = //" }
VERSION="$(setting MARKETING_VERSION)"
BUILD="$(setting CURRENT_PROJECT_VERSION)"
TEAM="$(setting DEVELOPMENT_TEAM)"
MINIMUM_SYSTEM="$(setting MACOSX_DEPLOYMENT_TARGET)"
# Releases are published on GitHub, where the app looks for its feed. RELEASE_FEED_URL builds
# one that looks elsewhere instead, with the DMG beside the feed: to try an update locally.
FEED="${RELEASE_FEED_URL:-$(setting MIMAMORI_FEED_URL | tr -d '"')}"
if [[ $FEED == */releases/latest/download/appcast.xml ]]; then
  REPOSITORY="${FEED%/releases/latest/download/appcast.xml}"
  DOWNLOAD="$REPOSITORY/releases/download/v$VERSION/Mimamori-$VERSION.dmg"
  HISTORY="$REPOSITORY/releases"
else
  REPOSITORY="${FEED%/*}"
  DOWNLOAD="$REPOSITORY/Mimamori-$VERSION.dmg"
  HISTORY=""
fi
# The release notes, in Markdown: on the release page, and embedded in the appcast so the update
# window shows them alone rather than the whole GitHub page. A dry run can do without.
NOTES_FILE="${RELEASE_NOTES:-docs/releases/$VERSION.md}"
if [[ -f $NOTES_FILE ]]; then
  DESCRIPTION="$(Scripts/release-notes.sh "$NOTES_FILE")"
elif [[ $DRY_RUN == 1 ]]; then
  DESCRIPTION=""
else
  echo "Write the release notes in $NOTES_FILE first (or point RELEASE_NOTES at them)." >&2
  exit 1
fi
# The changelog's short record needs a dated section for this version, renamed from Unreleased.
if ! grep -qE "^## \[${VERSION//./\\.}\] - [0-9]{4}-[0-9]{2}-[0-9]{2}$" CHANGELOG.md; then
  if [[ $DRY_RUN == 1 ]]; then
    echo "Note: CHANGELOG.md has no '## [$VERSION] - <date>' section yet; a release would stop here." >&2
  else
    echo "Add a '## [$VERSION] - $(date +%F)' section to CHANGELOG.md first, from what is under Unreleased." >&2
    exit 1
  fi
fi
OUT=build/release
ARCHIVE=$OUT/Mimamori.xcarchive
EXPORT=$OUT/export
APP=$EXPORT/Mimamori.app
WIDGETS=$APP/Contents/PlugIns/MimamoriWidgets.appex
STAGE=$OUT/dmg
DMG=build/Mimamori-$VERSION.dmg
APPCAST=build/appcast.xml

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
ARCHIVE_SIGNING=()
[[ $SIGNING == manual ]] && ARCHIVE_SIGNING=(CODE_SIGN_STYLE=Manual "CODE_SIGN_IDENTITY=$SIGNING_IDENTITY")
echo "Archiving Mimamori $VERSION ($BUILD) from $COMMIT…"
xcodebuild -project Mimamori.xcodeproj -scheme Mimamori -configuration Release -archivePath $ARCHIVE \
  -derivedDataPath build/DerivedData MIMAMORI_COMMIT="$COMMIT" MIMAMORI_RELEASE_BUILD=YES \
  MIMAMORI_FEED_URL="$FEED" "${ARCHIVE_SIGNING[@]}" "${AUTH[@]}" -quiet archive

# Xcode signs every part of the app, inside out, for the chosen way of distributing it.
cat > $OUT/ExportOptions.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>$([[ $DRY_RUN == 1 ]] && echo debugging || echo developer-id)</string>
  <key>teamID</key><string>$TEAM</string>
  <key>signingStyle</key><string>$SIGNING</string>
$([[ $SIGNING == manual ]] && echo "  <key>signingCertificate</key><string>$SIGNING_IDENTITY</string>")
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
# With more than one certificate of the kind (an old one beside its renewal), Xcode signs with the
# newest; the DMG is signed below with the same one, named by its SHA-1.
codesign -d --extract-certificates=$OUT/certificate $APP 2>/dev/null
CERTIFICATE="$(shasum -a 1 < $OUT/certificate0 | cut -d' ' -f1 | tr a-f A-F)"
for line in ${(f)"$(codesign -dvv $APP 2>&1)"}; do
  [[ $line == Authority=* ]] && { echo "Signed by: ${line#Authority=}, $(openssl x509 -inform DER -in $OUT/certificate0 -noout -enddate | sed 's/notAfter=/until /')"; break; }
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
  # Signing the DMG needs the app's certificate in the keychain; a cloud-managed one cannot. By
  # name, codesign would refuse when an older certificate shares it. The notarization ticket
  # stapled to the DMG is what Gatekeeper checks either way.
  if [[ "$(security find-identity -v -p codesigning)" == *" $CERTIFICATE "* ]]; then
    codesign --sign "$CERTIFICATE" --timestamp $DMG
  else
    echo "The app's certificate is not in the keychain: the DMG itself is left unsigned."
  fi
  notarize $DMG
  xcrun stapler staple $DMG
  spctl --assess --type execute --verbose=1 $APP
fi

# Sparkle checks an update against the app's public key before it installs anything, so the
# DMG, as stapled, is signed with the private key: from the keychain, or from SPARKLE_KEY_FILE.
# The appcast offers it.
SPARKLE=build/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin
SPARKLE_KEY=(--account mimamori)
[[ -n "${SPARKLE_KEY_FILE:-}" ]] && SPARKLE_KEY=(--ed-key-file "$SPARKLE_KEY_FILE")
ENCLOSURE="$($SPARKLE/sign_update "${SPARKLE_KEY[@]}" $DMG)"
[[ $ENCLOSURE == *edSignature=* ]] || { echo "Sparkle could not sign the DMG: $ENCLOSURE" >&2; exit 1; }
cat > $APPCAST <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Mimamori</title>
    <link>$REPOSITORY</link>
    <item>
      <title>Mimamori $VERSION</title>
      <pubDate>$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$MINIMUM_SYSTEM</sparkle:minimumSystemVersion>
$([[ -n $HISTORY ]] && echo "      <sparkle:fullReleaseNotesLink>$HISTORY</sparkle:fullReleaseNotesLink>")
$([[ -n $DESCRIPTION ]] && printf '      <description><![CDATA[%s]]></description>' "$DESCRIPTION")
      <enclosure url="$DOWNLOAD" type="application/octet-stream" $ENCLOSURE/>
    </item>
  </channel>
</rss>
XML
xmllint --noout $APPCAST

# The archive and export are app copies Launch Services would otherwise offer to run, widget
# included; keep build/Mimamori.app as the one it knows, as make-app.sh does.
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
for built in $OUT/**/Mimamori.app(N) build/DerivedData/**/Mimamori.app(N); do
  "$LSREGISTER" -u "$PWD/$built" >/dev/null 2>&1 || true
done
[[ -d build/Mimamori.app ]] && { "$LSREGISTER" -f "$PWD/build/Mimamori.app" >/dev/null 2>&1 || true; }

echo "Ready: $PWD/$DMG$([[ $DRY_RUN == 1 ]] && echo ' (dry run: development signing, not notarized)')"
echo "Appcast: $PWD/$APPCAST (Mimamori $VERSION, build $BUILD)"
echo "SHA-256: $(shasum -a 256 $DMG | cut -d' ' -f1)"
[[ $DRY_RUN == 1 || -z $HISTORY ]] || echo "Publish: gh release create v$VERSION $DMG $APPCAST --repo ${REPOSITORY#https://github.com/} --title 'Mimamori $VERSION' --notes-file $NOTES_FILE"
