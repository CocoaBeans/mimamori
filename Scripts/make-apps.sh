#!/bin/zsh
# Builds Mimamori for the Mac (Scripts/make-app.sh, into build/Mimamori.app) and the iPhone
# companion, installs the companion on an iPhone, and opens both.
#
# Usage: Scripts/make-apps.sh [--device <name or id>] [--no-mac] [--no-phone] [--no-launch] [debug|release]
#        Scripts/make-apps.sh --list
#
#   --list                 list the iPhones that are ready, and build nothing
#   --device <name or id>  the iPhone to install on (also MIMAMORI_DEVICE). Without it, the one
#                          iPhone that is connected and ready; with several, say which.
#   --no-mac               build and install the iPhone app only
#   --no-phone             build the Mac app only, as make-app.sh does
#   --no-launch            build and install, but leave both apps as they are
#
# The iPhone needs Developer Mode on, and to be unlocked and on the cable or the same Wi-Fi.
# It is signed with the project's team: an iPhone app can't be signed ad hoc, and the first build
# registers the iPhone and the app's ID with the team.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG=release
DEVICE="${MIMAMORI_DEVICE:-}"
MAC=1 PHONE=1 LAUNCH=1 LIST_ONLY=0
while (( $# )); do
  case "$1" in
    --device) DEVICE="${2:?--device needs a name or id}"; shift ;;
    --no-mac) MAC=0 ;;
    --no-phone) PHONE=0 ;;
    --no-launch) LAUNCH=0 ;;
    debug|release) CONFIG=$1 ;;
    --list) LIST_ONLY=1 ;;
    -h|--help) sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $1 (see --help)" >&2; exit 2 ;;
  esac
  shift
done

if (( PHONE )) && [[ "${MIMAMORI_SIGN:-team}" == adhoc ]]; then
  echo "An iPhone app can't be signed ad hoc: build it with the team, or use --no-phone." >&2
  exit 2
fi

# The iPhone, before anything is built, so a missing one fails fast. devicectl lists simulators and
# offline devices too; a physical iPhone that is paired and reachable has a tunnel that is
# "disconnected" (ready) or "connected" (in use), and an offline one "unavailable".
DEVICE_ID="" DEVICE_NAME=""
if (( PHONE )); then
  LIST="$(mktemp -t mimamori-devices)"
  trap 'rm -f "$LIST"' EXIT
  xcrun devicectl list devices --quiet --json-output "$LIST" >/dev/null
  field() { plutil -extract "result.devices.$1.$2" raw -o - "$LIST" 2>/dev/null || true }
  candidates=()
  for (( i = 0; ; i++ )); do
    id="$(field $i identifier)"
    [[ -n "$id" ]] || break
    name="$(field $i deviceProperties.name)"
    [[ "$(field $i hardwareProperties.reality)" == physical && "$(field $i hardwareProperties.deviceType)" == iPhone ]] || continue
    if [[ -n "$DEVICE" ]]; then
      [[ "$DEVICE" == "$id" || "$DEVICE" == "$name" || "$DEVICE" == "$(field $i hardwareProperties.udid)" ]] || continue
    fi
    tunnel="$(field $i connectionProperties.tunnelState)"
    if [[ "$tunnel" != disconnected && "$tunnel" != connected ]]; then
      [[ -n "$DEVICE" ]] && { echo "$name isn't reachable: unlock it, and connect it by cable or the same Wi-Fi." >&2; exit 1; }
      continue
    fi
    candidates+=("$id	$name")
  done
  if (( LIST_ONLY )); then
    (( ${#candidates} )) && printf '%s\n' "${candidates[@]//	/  }" || echo "No iPhone is ready."
    exit 0
  fi
  if (( ${#candidates} == 0 )); then
    echo "No iPhone is ready${DEVICE:+ by the name or id $DEVICE}: unlock it, and connect it by cable or the same Wi-Fi." >&2
    exit 1
  elif (( ${#candidates} > 1 )); then
    echo "More than one iPhone is ready; choose one with --device:" >&2
    printf '  %s\n' "${candidates[@]//	/  }" >&2
    exit 1
  fi
  DEVICE_ID="${candidates[1]%%	*}"
  DEVICE_NAME="${candidates[1]#*	}"
  echo "iPhone: $DEVICE_NAME"
fi

if (( MAC )); then
  Scripts/make-app.sh "$CONFIG"
fi

if (( PHONE )); then
  XCCONFIG=${(C)CONFIG}
  # The same DerivedData as make-app.sh, so the shared targets are built once.
  xcodebuild -project Mimamori.xcodeproj -scheme MimamoriCompanion -configuration "$XCCONFIG" \
    -destination 'generic/platform=iOS' -derivedDataPath build/DerivedData -allowProvisioningUpdates -quiet build
  COMPANION="build/DerivedData/Build/Products/$XCCONFIG-iphoneos/MimamoriCompanion.app"
  BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$COMPANION/Info.plist")"
  xcrun devicectl device install app --quiet --device "$DEVICE_ID" "$COMPANION" >/dev/null
  echo "Installed the companion on $DEVICE_NAME"
fi

if (( LAUNCH )); then
  if (( MAC )); then
    # Quit the running Mimamori, which may be another copy, so the new one takes over the hooks.
    MAC_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' build/Mimamori.app/Contents/Info.plist)"
    osascript -l JavaScript -e "ObjC.import('AppKit'); var apps = \$.NSRunningApplication.runningApplicationsWithBundleIdentifier('$MAC_ID'); for (var i = 0; i < apps.count; i++) { apps.objectAtIndex(i).terminate; }" >/dev/null
    for _ in {1..20}; do
      pgrep -qf "MacOS/Mimamori$" || break
      sleep 0.5
    done
    open build/Mimamori.app
  fi
  if (( PHONE )); then
    xcrun devicectl device process launch --quiet --terminate-existing --device "$DEVICE_ID" "$BUNDLE_ID" >/dev/null
    echo "Opened the companion on $DEVICE_NAME"
  fi
fi
