#!/bin/zsh
# Build the app bundle (debug) and launch it.
set -euo pipefail
cd "$(dirname "$0")/.."
APP="$(Scripts/make-app.sh debug)"
open "$APP"
