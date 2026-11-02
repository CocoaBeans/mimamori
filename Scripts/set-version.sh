#!/bin/zsh
# Sets the version for the next release and raises the build number by one, in the project's
# build settings, which both Info.plists and the release script read.
# Usage: Scripts/set-version.sh 1.0.1      (the build number goes up on its own)
#        Scripts/set-version.sh            (prints the current version and build)
set -euo pipefail
cd "$(dirname "$0")/.."
PROJECT=Mimamori.xcodeproj/project.pbxproj
setting() { grep -m1 -o "$1 = [^;]*" $PROJECT | sed "s/^$1 = //" }

if [[ $# -eq 0 ]]; then
  echo "$(setting MARKETING_VERSION) ($(setting CURRENT_PROJECT_VERSION))"
  exit 0
fi
[[ $1 =~ '^[0-9]+\.[0-9]+(\.[0-9]+)?$' ]] || { echo "usage: $0 <version, like 1.0.1>" >&2; exit 2; }
BUILD=$(( $(setting CURRENT_PROJECT_VERSION) + 1 ))
sed -i '' -E "s/MARKETING_VERSION = [^;]*;/MARKETING_VERSION = $1;/; s/CURRENT_PROJECT_VERSION = [^;]*;/CURRENT_PROJECT_VERSION = $BUILD;/" $PROJECT
echo "$(setting MARKETING_VERSION) ($(setting CURRENT_PROJECT_VERSION))"
