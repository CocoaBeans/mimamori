#!/bin/zsh
# Captures a window as it looks on screen, glass, vibrancy and shadow included, for README
# screenshots and recordings. Builds Tools/WindowCapture into build/WindowCapture.app when it is
# missing or older than its source, then runs it as an app of its own, so that the Screen
# Recording permission belongs to it alone. macOS asks for that permission on the first run:
# allow WindowCapture in System Settings › Privacy & Security › Screen & System Audio Recording,
# then run the command again.
#
# Usage: Scripts/capture-window.sh list [--all]
#        Scripts/capture-window.sh shot --app com.kevinross.Mimamori --out docs/shot.png
#        Scripts/capture-window.sh record --pid 1234 --out demo.mov --until /tmp/stop --seconds 60
#
# The app is signed with the Apple Development certificate of the Xcode project's team, so the
# permission survives rebuilds. WINDOW_CAPTURE_SIGN=<identity> picks another; without one it is
# signed ad hoc, and macOS asks again after each rebuild.
set -euo pipefail
cd "$(dirname "$0")/.."

SOURCE=Tools/WindowCapture/main.swift
APP=build/WindowCapture.app
BINARY=$APP/Contents/MacOS/WindowCapture

if [[ ! -x $BINARY || $SOURCE -nt $BINARY || $0 -nt $BINARY ]]; then
  mkdir -p $APP/Contents/MacOS
  cat > $APP/Contents/Info.plist <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>com.kevinross.Mimamori.WindowCapture</string>
  <key>CFBundleName</key><string>WindowCapture</string>
  <key>CFBundleExecutable</key><string>WindowCapture</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST
  swiftc -O -swift-version 5 -target "$(uname -m)-apple-macos15.0" $SOURCE -o $BINARY
  identity=${WINDOW_CAPTURE_SIGN:-}
  if [[ -z $identity ]]; then
    team=$(grep -m1 -o 'DEVELOPMENT_TEAM = [A-Z0-9]*' Mimamori.xcodeproj/project.pbxproj | awk '{print $3}')
    valid=$(security find-identity -v -p codesigning 2>/dev/null)
    # The Apple Development certificate, with its key, whose organisational unit is the team.
    pem=""
    security find-certificate -a -c "Apple Development" -p 2>/dev/null | while IFS= read -r line; do
      pem+="$line"$'\n'
      [[ $line == *"END CERTIFICATE"* ]] || continue
      if print -r -- "$pem" | openssl x509 -noout -subject 2>/dev/null | grep -q "OU *= *$team"; then
        hash=$(print -r -- "$pem" | openssl x509 -noout -fingerprint -sha1 | cut -d= -f2 | tr -d :)
        if [[ $valid == *$hash* ]]; then identity=$hash; break; fi
      fi
      pem=""
    done
  fi
  if [[ -n $identity ]]; then
    codesign --force --options runtime --sign "$identity" $APP >/dev/null
  else
    echo "note: no Apple Development certificate for the team; signing ad hoc" >&2
    codesign --force --sign - $APP >/dev/null
  fi
fi

log=$(mktemp -t window-capture)
trap 'rm -f "$log"' EXIT
open -g -W -n -a "$PWD/$APP" --env WINDOW_CAPTURE_CWD="$PWD" --stdout "$log" --stderr "$log" --args "$@"
cat "$log"
! grep -q '^error:' "$log"
