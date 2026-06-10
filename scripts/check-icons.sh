#!/usr/bin/env bash
# Verify every color-icon name in Constants.qml has a matching SVG asset, and
# every SVG asset maps back to a colorIconSet name (no orphans). The closest
# thing to a unit test for the color-icon system.
set -euo pipefail
cd "$(dirname "$0")/.."

CONST="qml/helper/Constants.qml"
ICONS_DIR="assets/icons"
fail=0

# Names declared in colorIconSet — entries look like:  "camera": true,
# (-o handles multiple entries per line). Only colorIconSet uses `": true`.
names=$(grep -oE '"[a-z0-9_-]+": true' "$CONST" | sed -E 's/"([a-z0-9_-]+).*/\1/' | sort -u)

# 1. Every declared name has a file.
for n in $names; do
  if [ ! -f "$ICONS_DIR/$n.svg" ]; then
    echo "MISSING asset: $ICONS_DIR/$n.svg (declared in colorIconSet)"
    fail=1
  fi
done

# 2. Every svg file is declared.
for f in "$ICONS_DIR"/*.svg; do
  base=$(basename "$f" .svg)
  if ! echo "$names" | grep -qx "$base"; then
    echo "ORPHAN asset: $f (no colorIconSet entry)"
    fail=1
  fi
done

if [ "$fail" -eq 0 ]; then
  echo "OK: $(echo "$names" | wc -w) names <-> $(ls "$ICONS_DIR"/*.svg | wc -l) svg files all matched."
fi
exit $fail
