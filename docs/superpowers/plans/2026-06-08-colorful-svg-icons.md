# Colorful SVG Icons Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Restore colorful icons that render identically on Android/iOS/desktop without reintroducing the Android color-emoji crash, by rendering illustrative icons as bundled color SVG (Twemoji) while keeping functional chrome on the crash-safe tinted FontAwesome backend.

**Architecture:** `Icon.qml` stays the single swap point. It picks a backend from the name: names in `Constants.colorIconSet` render as `assets/icons/<name>.svg` via `Image` (texture path — crash-safe, full color); every other name falls through to `Constants.iconMap` → Felgo `AppIcon` (FontAwesome, monochrome, tinted by `color`). No call site changes — every screen already routes through `Icon`.

**Tech Stack:** Felgo + Qt 6.8.3, QML. Twemoji 14.0.2 color SVGs (CC-BY 4.0). Qt SVG image plugin (`qsvg`) confirmed present in the Felgo install.

---

## Verification model (read first)

No QML unit-test harness exists and icon rendering is visual. "Tests" here are concrete runnable checks (same model as the prior FontAwesome migration):

1. **`qmllint`** on changed QML — no new errors. Binary:
   `"/c/Felgo/Felgo/mingw_64/bin/qmllint.exe" -I qml <file>`
2. **Asset-completeness script** (`scripts/check-icons.sh`) — every `colorIconSet` name has a matching `assets/icons/<name>.svg`, and every SVG maps back to a name. This is the closest thing to a unit test for this work.
3. **Desktop run** — visit former-emoji screens; confirm color icons render. Desktop does NOT reproduce the crash; it validates rendering only.
4. **Android device build** — the only place the original crash reproduced and the only proof the SVG plugin is packaged. **Blank color icons on Android = `qsvg` plugin not packaged** → contingency in Task 6.

---

## Environment note (network)

This Windows box's `curl` fails TLS revocation checks (`CRYPT_E_NO_REVOCATION_CHECK`). All fetch commands below use `--ssl-no-revoke`. Verified: `https://cdn.jsdelivr.net/gh/twitter/twemoji@14.0.2/assets/svg/<codepoint>.svg` returns HTTP 200 for all 30 codepoints.

---

## File Structure

**Created:**
- `assets/icons/*.svg` — 37 color SVG files (30 unique Twemoji glyphs; 7 duplicated under shared semantic names). Auto-bundled by `CMakeLists.txt:34` (`AssetsFiles`) — no CMake change.
- `assets/icons/ATTRIBUTION.md` — Twemoji CC-BY 4.0 credit (license requirement).
- `scripts/fetch-icons.sh` — reproducible fetch of the icon set (committed for future re-runs).
- `scripts/check-icons.sh` — asset-completeness check (the repeatable verification).

**Modified:**
- `qml/helper/Constants.qml` — add `colorIconSet`, `isColorIcon(name)`, `colorIconSource(name)`. `iconMap` unchanged.
- `qml/components/Icon.qml` — rewrite from single `AppIcon` to a two-backend `Item` + `Loader` selector. Public surface (`name`, `size`, `color`) unchanged.

**Verified, NOT modified:**
- `qml/components/FloatingTabbar.qml` — active state already uses label color + bold (`:85`,`:91`,`:93`). Icon `color` becomes a no-op for color SVGs; this is fine (decision: label-based active state). Confirmed in Task 5, not edited.
- `CMakeLists.txt` — no change unless Android packaging drops `qsvg` (Task 6 contingency only).

---

## Canonical icon table (source of truth for Tasks 1–2)

37 semantic names → 30 unique Twemoji codepoints. Aliases share the primary's file.

| Codepoint | Primary name | Alias name(s) (same file) |
|---|---|---|
| 1f4f7 | camera | |
| 1f4c5 | calendar | |
| 1f514 | bell | |
| 1f4e6 | box | products |
| 1f4ed | empty-inbox | |
| 1f389 | celebrate | |
| 1f465 | staff | team |
| 1f3e2 | workspace | |
| 1f4ca | analytics | |
| 1f4c8 | analysis | report |
| 1f5bc | gallery | photo_change |
| 1f310 | web | language |
| 1f4cb | clipboard | |
| 1f4dc | history | |
| 1f3f7 | tag | |
| 1f9fe | orders | |
| 1f464 | profile | staff-added |
| 1f512 | security | secure |
| 1f3a8 | appearance | |
| 1f4b1 | currency | |
| 1f4c4 | file | |
| 1f5d1 | delete | |
| 1f3e0 | home | |
| 1f195 | created | |
| 1f4e5 | purchase | |
| 1f4e4 | sale | |
| 1f9ee | stock_adjustment | |
| 2795  | product-added | |
| 1f504 | restocked | |
| 1f535 | activity | |

Everything NOT in this table stays on FontAwesome (chrome): `dropdown, add, remove, close, check, edit, settings, quick, import, export, back, chevron, star, warn, search, reveal, hide, pause, pause-status, product-updated, staff-updated, field_change`.

---

### Task 1: Fetch the Twemoji icon set into `assets/icons/`

**Files:**
- Create: `scripts/fetch-icons.sh`
- Create: `assets/icons/*.svg` (output of the script)
- Create: `assets/icons/ATTRIBUTION.md`

- [ ] **Step 1: Write the fetch script**

Create `scripts/fetch-icons.sh`:

```bash
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
fetch 1f4e5 purchase
fetch 1f4e4 sale
fetch 1f9ee stock_adjustment
fetch 2795 product-added
fetch 1f504 restocked
fetch 1f535 activity

echo "Done. $(ls assets/icons/*.svg | wc -l) svg files written."
```

- [ ] **Step 2: Run the fetch script**

Run: `bash scripts/fetch-icons.sh`
Expected final line: `Done. 37 svg files written.`

- [ ] **Step 3: Verify file count and that files are real SVG**

Run:
```bash
ls assets/icons/*.svg | wc -l
head -c 60 assets/icons/box.svg; echo
```
Expected: `37`, and the head shows `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 36 36">…`.

- [ ] **Step 4: Write the attribution file**

Create `assets/icons/ATTRIBUTION.md`:

```markdown
# Icon Attribution

The color icons in this directory are **Twemoji** by Twitter, Inc. and other
contributors, version 14.0.2.

- Source: https://github.com/twitter/twemoji
- License: CC-BY 4.0 — https://creativecommons.org/licenses/by/4.0/

Graphics are licensed under CC-BY 4.0. Each `<name>.svg` is an unmodified
Twemoji glyph renamed to the app's semantic icon name (see
`qml/helper/Constants.qml` → `colorIconSet`). Some files are byte-identical
duplicates under multiple semantic names (e.g. `staff.svg`/`team.svg`).
```

- [ ] **Step 5: Commit**

```bash
git add scripts/fetch-icons.sh assets/icons/
git commit -m "feat(icons): fetch Twemoji color SVG icon set + attribution"
```

---

### Task 2: Add the color-icon map + resolvers to Constants

**Files:**
- Modify: `qml/helper/Constants.qml` (insert before the final closing `}` of the root `Item`, after the existing `icon(name)` function at `:191-193`)

- [ ] **Step 1: Add `colorIconSet`, `isColorIcon`, `colorIconSource`**

In `qml/helper/Constants.qml`, immediately after the existing `icon(name)` function (line ~193) and before the file's final `}`, add:

```qml

    // ── Color icon set (full-color Twemoji SVG) ──────────────────────────────
    // Names in this set render as a color SVG image (assets/icons/<name>.svg)
    // instead of a tinted FontAwesome glyph. The `color` property has NO effect
    // on these — they are full-color artwork. Anything not listed here falls
    // through to iconMap (monochrome, tintable). See
    // docs/superpowers/specs/2026-06-08-colorful-svg-icons-design.md.
    readonly property var colorIconSet: ({
        "camera": true, "calendar": true, "bell": true,
        "box": true, "products": true,
        "empty-inbox": true, "celebrate": true,
        "staff": true, "team": true,
        "workspace": true, "analytics": true,
        "analysis": true, "report": true,
        "gallery": true, "photo_change": true,
        "web": true, "language": true,
        "clipboard": true, "history": true, "tag": true,
        "orders": true, "profile": true, "staff-added": true,
        "security": true, "secure": true,
        "appearance": true, "currency": true,
        "file": true, "delete": true, "home": true,
        "created": true, "purchase": true, "sale": true,
        "stock_adjustment": true, "product-added": true,
        "restocked": true, "activity": true
    })

    // Is this semantic name a full-color SVG icon?
    function isColorIcon(name) {
        return colorIconSet[name] === true
    }

    // URL of the color SVG asset for a name. Resolved relative to THIS file
    // (qml/helper/), so it is correct regardless of which component calls it.
    function colorIconSource(name) {
        return Qt.resolvedUrl("../../assets/icons/" + name + ".svg")
    }
```

- [ ] **Step 2: qmllint Constants**

Run: `"/c/Felgo/Felgo/mingw_64/bin/qmllint.exe" -I qml qml/helper/Constants.qml`
Expected: no new errors (pre-existing notes unrelated to this change are acceptable).

- [ ] **Step 3: Commit**

```bash
git add qml/helper/Constants.qml
git commit -m "feat(icons): add colorIconSet + SVG source resolvers to Constants"
```

---

### Task 3: Rewrite `Icon.qml` as a two-backend selector

**Files:**
- Modify: `qml/components/Icon.qml` (full replacement)

- [ ] **Step 1: Replace the file contents**

Overwrite `qml/components/Icon.qml` with:

```qml
import QtQuick
import Felgo

import "../helper"

// The single icon-rendering element for the whole app. Two backends, chosen by
// name:
//   • Color SVG (Twemoji)   — illustrative icons; full-color; `color` IGNORED.
//   • FontAwesome (AppIcon) — functional chrome; monochrome; tinted by `color`.
//
// Names in Constants.colorIconSet render as assets/icons/<name>.svg; everything
// else resolves through Constants.iconMap. Never put a raw Unicode glyph in a
// Text element — color emoji crash on Android (see the colorful-svg-icons spec).
//
//   Icon { name: "dropdown"; size: sp(14); color: Constants.textSecondary }  // chrome, tinted
//   Icon { name: "box";      size: sp(28) }                                   // color SVG (color ignored)
Item {
    id: root

    property string name: ""
    property real size: sp(16)
    property color color: Constants.textPrimary   // chrome only — ignored for color SVG

    implicitWidth: size
    implicitHeight: size

    readonly property bool _isColor: Constants.isColorIcon(name)

    Loader {
        anchors.fill: parent
        sourceComponent: root._isColor ? colorIcon : glyphIcon
    }

    Component {
        id: glyphIcon
        AppIcon {
            anchors.centerIn: parent
            iconType: Constants.icon(root.name)
            size: root.size
            color: root.color
        }
    }

    Component {
        id: colorIcon
        Image {
            anchors.centerIn: parent
            width: root.size
            height: root.size
            source: Constants.colorIconSource(root.name)
            sourceSize.width: root.size      // pin SVG rasterization to render size — crisp, no blur
            sourceSize.height: root.size
            fillMode: Image.PreserveAspectFit
            smooth: true
            asynchronous: true
            cache: true
        }
    }
}
```

- [ ] **Step 2: qmllint the component**

Run: `"/c/Felgo/Felgo/mingw_64/bin/qmllint.exe" -I qml qml/components/Icon.qml`
Expected: no errors. **If qmllint reports a type-name collision** between this `Icon` and Felgo's `AppIcon`/`Icon`, rename the file to `UiIcon.qml` (type `UiIcon`), update all call sites (`grep -rln "Icon {" qml --include=*.qml`), and record the rename. (The prior migration shipped this file as type `Icon` without collision, so this is a contingency only.)

- [ ] **Step 3: Commit**

```bash
git add qml/components/Icon.qml
git commit -m "feat(icons): Icon renders color SVG for emoji set, FontAwesome for chrome"
```

---

### Task 4: Asset-completeness check script

**Files:**
- Create: `scripts/check-icons.sh`

- [ ] **Step 1: Write the check script**

Create `scripts/check-icons.sh`:

```bash
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
```

- [ ] **Step 2: Run the check**

Run: `bash scripts/check-icons.sh`
Expected: `OK: 37 names <-> 37 svg files all matched.` and exit code 0.

- [ ] **Step 3: Commit**

```bash
git add scripts/check-icons.sh
git commit -m "test(icons): add asset-completeness check (names <-> svg files)"
```

---

### Task 5: Desktop render verification + nav-tab active state

**Files:**
- Verify only: `qml/components/FloatingTabbar.qml`, all former-emoji screens

- [ ] **Step 1: Build and run the desktop target**

Build and run the desktop (mingw) target via the project's configured run task (`.vscode/tasks.json`) or the Felgo/Qt Creator desktop kit. Expected: app launches without error.

- [ ] **Step 2: Confirm color icons render across screens**

Visit each screen and confirm the color icons appear (full-color, crisp, centered) — not blank, not a fallback question-circle:
- Dashboard — bell, clipboard, quick-action tiles (box/staff/orders/report)
- Orders — empty-state inbox; Inventory — box hero + avatar fallback
- Sales — analytics hero; Staff — staff hero; Activity — inbox empty-state
- Add/Edit Product — camera, box/tag/history; Add Staff — calendar
- Notifications — celebrate; Profile — workspace/security/bell/appearance/language/currency settings rows
- Photo source sheet — camera/gallery/web/delete

- [ ] **Step 3: Confirm chrome icons still render + tint**

Confirm functional chrome is still monochrome and correctly tinted: close (✕) on sheets, add/remove steppers, chevron (›) rows, dropdown (▾) carets, check (✓), back (←), search (🔍), settings/quick on Orders. These go through FontAwesome unchanged.

- [ ] **Step 4: Confirm nav-tab active state reads correctly**

On the bottom tabbar, the four tabs (Home/Orders/Stock/Analysis) now show **color SVG** icons. Confirm the **active** tab is distinguishable via its **label color (brand violet) + bold label** (`FloatingTabbar.qml:91-93`). The icon no longer tints — verify the label-based active state is clear enough. If the active tab is hard to distinguish, the minimal fix (only if needed) is to set the active delegate's `background` Rectangle `color` to `Qt.rgba(0.39, 0.40, 0.95, 0.10)` when `tab.isActive` (mirroring the existing `pressed` style at `:75`). Apply only if Step 4 shows it's needed; otherwise leave FloatingTabbar unmodified.

- [ ] **Step 5: Commit (only if FloatingTabbar changed in Step 4)**

```bash
git add qml/components/FloatingTabbar.qml
git commit -m "fix(icons): add active-tab background since color SVG can't tint"
```

If no change was needed, skip this commit.

---

### Task 6: Android build + device smoke test

**Files:**
- Verify only (contingency): `CMakeLists.txt`

- [ ] **Step 1: Build the Android target and deploy to a device**

Build the Android target (Felgo/Qt Creator Android kit or Felgo Cloud Builds) and deploy to a connected device. Expected: build + deploy succeed.

- [ ] **Step 2: Device smoke test — no crash + color icons render**

On the Android device, confirm **no crash** and **icons render** on every former-emoji screen (same list as Task 5 Step 2–4). This is the real verification — desktop cannot reproduce the original crash.

- [ ] **Step 3: Contingency — if color icons are BLANK on Android**

Blank (but no crash) means the SVG image plugin was not packaged. Add to `CMakeLists.txt` after `felgo_configure_executable(appBusinessManagement)` (`:53`):

```cmake
# Ensure the Qt SVG image plugin is packaged for Android — color icons are SVG.
qt_import_plugins(appBusinessManagement INCLUDE Qt6::QSvgPlugin)
```

Rebuild + redeploy; confirm color icons now render. (`qsvg.dll` is present in the Felgo install, so this is a packaging directive, not a missing dependency.)

- [ ] **Step 4: Final commit (only if CMake/device fixes were needed)**

```bash
git add CMakeLists.txt
git commit -m "build(icons): force-include Qt SVG plugin for Android packaging"
```

If no change was needed, skip this commit.

---

## Self-Review Notes

- **Spec coverage:**
  - §3 two-backend architecture → Task 3 (Icon.qml) + Task 2 (resolvers).
  - §4a color set + codepoint table → Task 1 (fetch) + Task 2 (`colorIconSet`); canonical table in this plan matches spec §4a exactly (37 names, 30 codepoints, 7 aliases).
  - §4b chrome stays FontAwesome → unchanged `iconMap`; listed under the canonical table.
  - §4c nav tabs color SVG + label-based active → Task 5 Step 4.
  - §5 asset pipeline (location, sourcing, license, Tiny-SVG profile) → Task 1 (fetch + ATTRIBUTION) + Task 5 (render check catches non-parsing assets).
  - §6 Icon.qml implementation → Task 3 (verbatim).
  - §7 verification (qmllint, completeness, desktop, Android + qsvg knob) → Tasks 2/3 (qmllint), 4 (completeness), 5 (desktop), 6 (Android + contingency).
- **Placeholder scan:** none. Every script, QML block, command, and expected output is concrete. Conditional steps (5.4, 5.5, 6.3, 6.4) state the exact change and the exact trigger condition.
- **Type/name consistency:** `colorIconSet`, `isColorIcon(name)`, `colorIconSource(name)` are defined identically in Task 2 and consumed identically in Task 3 and Task 4's grep. The 37-name set in Task 2 matches the 37 files produced by Task 1's fetch script and the count asserted in Task 4 (`OK: 37 names <-> 37 svg files`). `Icon` public surface (`name`/`size`/`color`) preserved → no call-site churn.
- **DRY:** `fetch-icons.sh` and `colorIconSet` are the two sources of truth; `check-icons.sh` derives names from `Constants.qml` (not a third hardcoded list) so they cannot silently diverge.
