#!/usr/bin/env bash
# Fetch Twemoji 14.0.2 color SVGs for the app icon set.
# Twemoji is CC-BY 4.0 — see assets/icons/ATTRIBUTION.md.
# Re-run to refresh assets. Aliases are byte-identical copies of the primary.
set -euo pipefail
cd "$(dirname "$0")/.."   # repo root
mkdir -p assets/icons
BASE="https://cdn.jsdelivr.net/gh/twitter/twemoji@14.0.2/assets/svg"

fetch() {                       # fetch <codepoint> <primary-name> [alias...]
  local code="$1"; shift
  local primary="$1"; shift
  curl -fsS --ssl-no-revoke -m 20 -o "assets/icons/${primary}.svg" "${BASE}/${code}.svg"
  for alias in "$@"; do
    cp -f "assets/icons/${primary}.svg" "assets/icons/${alias}.svg"
  done
}

fetch 1f4f7 camera
fetch 1f4c5 calendar
fetch 1f514 bell
fetch 1f4e6 box products
fetch 1f4ed empty-inbox
fetch 1f389 celebrate
fetch 1f465 staff team
fetch 1f3e2 workspace
fetch 1f4ca analytics
fetch 1f4c8 analysis report
fetch 1f5bc gallery photo_change
fetch 1f310 web language
fetch 1f4cb clipboard
fetch 1f4dc history
fetch 1f3f7 tag
fetch 1f9fe orders
fetch 1f464 profile staff-added
fetch 1f512 security secure
fetch 1f3a8 appearance
fetch 1f4b1 currency
fetch 1f4c4 file
fetch 1f5d1 delete
fetch 1f3e0 home
fetch 1f195 created
fetch 1f4e5 purchase import
fetch 1f4e4 sale export
fetch 1f9ee stock_adjustment
fetch 2795 product-added
fetch 1f504 restocked
fetch 1f535 activity
fetch 2699 settings
fetch 26a1 quick

echo "Done. $(ls assets/icons/*.svg | wc -l) svg files written."
