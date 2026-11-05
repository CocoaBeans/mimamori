#!/bin/zsh
# Turns a release's notes (Markdown, docs/releases/<version>.md) into the HTML that Sparkle's update
# window shows, embedded in the appcast. GitHub renders the Markdown, as it does on the release page,
# and a small stylesheet fits it to the window, in light and dark. The "Install" section is left out:
# whoever sees the window has Mimamori already.
# Usage: Scripts/release-notes.sh docs/releases/1.1.0.md > notes.html
set -euo pipefail

NOTES_FILE="$1"
[[ -f $NOTES_FILE ]] || { echo "No release notes at $NOTES_FILE" >&2; exit 1; }

markdown="$(awk '/^## /{ skip = ($0 ~ /^## Install/) } !skip' "$NOTES_FILE")"
html="$(gh api markdown -f mode=gfm -f text="$markdown")"
# The appcast wraps the notes in CDATA, which this would end early.
[[ $html != *']]>'* ]] || { echo "The rendered notes contain ]]>, which the appcast can't hold" >&2; exit 1; }

cat <<HTML
<meta charset="utf-8">
<style>
  :root { color-scheme: light dark; }
  body { font: 13px/1.45 -apple-system, sans-serif; margin: 2px 6px; }
  h2 { font-size: 14px; margin: 16px 0 6px; }
  p { margin: 6px 0; }
  ul { margin: 4px 0; padding-left: 18px; }
  li { margin: 4px 0; }
  li > ul { margin: 2px 0; }
  code { font: 12px ui-monospace, Menlo, monospace; }
</style>
$html
HTML
