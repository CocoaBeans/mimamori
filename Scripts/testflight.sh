#!/bin/zsh
# Uploads the iPhone companion to App Store Connect: archives it, then exports it signed for App
# Store Connect and uploads it in one step.
#
# By default it uploads the full build, from the MimamoriCompanion scheme, for internal testers
# only. That keeps the silent-audio keep-alive and its `audio` background mode, which App Review
# turns down (guideline 2.5.4); internal testers need no review, so they can have it.
#
# With --app-store it uploads the App Store build instead, from the "MimamoriCompanion (App
# Store)" scheme and its AppStore configuration, whose Info.plist has no background modes, so the
# keep-alive and its setting are left out. That build can go to external testers and to review.
#
# TestFlight builds expire after 90 days.
#
# The version is the project's MARKETING_VERSION, shared with the Mac app. Xcode picks the build
# number as it uploads, one above the highest App Store Connect has for that version, so the
# Mac's CURRENT_PROJECT_VERSION stays as it is.
#
# Requirements:
#   - The app's record in App Store Connect, for the bundle ID com.kevinross.Mimamori.Companion.
#   - The team's Apple ID signed in to Xcode (Settings › Accounts). Xcode signs with a
#     cloud-managed distribution certificate, and uploads, through that account.
#   - Or an App Store Connect API key instead, which needs the Admin role for cloud signing:
#       ASC_KEY_ID      the key id (the file is read from
#                       ~/.appstoreconnect/private_keys/AuthKey_<ASC_KEY_ID>.p8,
#                       or point ASC_KEY_PATH at it)
#       ASC_ISSUER_ID   the issuer id
#
# Usage: Scripts/testflight.sh [--app-store]
#        ASC_KEY_ID=XXXXXXXXXX ASC_ISSUER_ID=... Scripts/testflight.sh [--app-store]
#        TESTFLIGHT_DRY_RUN=1 Scripts/testflight.sh [--app-store]
#
# A dry run exports with the everyday development signing and uploads nothing, to check the
# archive. An upload refuses a working tree with uncommitted changes, so each build matches a commit.
set -euo pipefail
cd "$(dirname "$0")/.."

DRY_RUN="${TESTFLIGHT_DRY_RUN:-0}"
SCHEME=MimamoriCompanion CONFIG=Release INTERNAL_ONLY=true
while (( $# )); do
  case "$1" in
    --app-store) SCHEME="MimamoriCompanion (App Store)" CONFIG=AppStore INTERNAL_ONLY=false ;;
    -h|--help) sed -n '2,34p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $1 (see --help)" >&2; exit 2 ;;
  esac
  shift
done
setting() { grep -m1 -o "$1 = [^;]*" Mimamori.xcodeproj/project.pbxproj | sed "s/^$1 = //" }
VERSION="$(setting MARKETING_VERSION)"
TEAM="$(setting DEVELOPMENT_TEAM)"
OUT=build/testflight
ARCHIVE=$OUT/MimamoriCompanion.xcarchive
EXPORT=$OUT/export

COMMIT="$(git rev-parse --short=8 HEAD)"
if [[ -n "$(git status --porcelain --untracked-files=no)" ]]; then
  if [[ $DRY_RUN != 1 ]]; then
    echo "The working tree has uncommitted changes. Commit them first, so the build matches its commit." >&2
    exit 1
  fi
  COMMIT="$COMMIT-dirty"
fi

# xcodebuild may fetch or create the certificate and profiles signing needs, through the account
# signed in to Xcode, or the API key when one is given. A key without the Admin role can't use
# cloud signing, and the export fails with "Cloud signing permission error".
AUTH=(-allowProvisioningUpdates)
if [[ -n "${ASC_KEY_ID:-}" ]]; then
  : "${ASC_ISSUER_ID:?Set ASC_ISSUER_ID to your App Store Connect issuer id}"
  ASC_KEY_PATH="${ASC_KEY_PATH:-$HOME/.appstoreconnect/private_keys/AuthKey_$ASC_KEY_ID.p8}"
  [[ -f "$ASC_KEY_PATH" ]] || { echo "API key not found at $ASC_KEY_PATH" >&2; exit 1; }
  AUTH+=(-authenticationKeyPath "$ASC_KEY_PATH" -authenticationKeyID "$ASC_KEY_ID"
         -authenticationKeyIssuerID "$ASC_ISSUER_ID")
fi

rm -rf $OUT
mkdir -p $OUT
echo "Archiving the iPhone companion $VERSION ($CONFIG) from $COMMIT…"
xcodebuild -project Mimamori.xcodeproj -scheme "$SCHEME" -configuration $CONFIG \
  -destination 'generic/platform=iOS' -archivePath $ARCHIVE -derivedDataPath build/DerivedData-iOS \
  "${AUTH[@]}" -quiet archive

# App Review turns down a build that declares background audio it doesn't play out loud.
if [[ $CONFIG == AppStore ]]; then
  INFO=$ARCHIVE/Products/Applications/MimamoriCompanion.app/Info.plist
  if plutil -extract UIBackgroundModes raw -o - $INFO >/dev/null 2>&1; then
    echo "The App Store build declares background modes; its Info.plist should have none." >&2
    exit 1
  fi
fi

# Signing the export for App Store Connect also uploads it, when the destination is upload.
if [[ $DRY_RUN == 1 ]]; then
  METHOD=debugging DESTINATION=export
else
  METHOD=app-store-connect DESTINATION=upload
fi
cat > $OUT/ExportOptions.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>$METHOD</string>
  <key>destination</key><string>$DESTINATION</string>
  <key>teamID</key><string>$TEAM</string>
  <key>signingStyle</key><string>automatic</string>
  <key>manageAppVersionAndBuildNumber</key><true/>
  <key>testFlightInternalTestingOnly</key><$INTERNAL_ONLY/>
  <key>uploadSymbols</key><true/>
</dict>
</plist>
PLIST
xcodebuild -exportArchive -archivePath $ARCHIVE -exportPath $EXPORT -exportOptionsPlist $OUT/ExportOptions.plist \
  "${AUTH[@]}" -quiet

if [[ $DRY_RUN == 1 ]]; then
  echo "Dry run: exported to $EXPORT, nothing uploaded."
else
  echo "Uploaded $VERSION ($CONFIG). App Store Connect processes it for a few minutes, then offers it to internal testers."
fi
