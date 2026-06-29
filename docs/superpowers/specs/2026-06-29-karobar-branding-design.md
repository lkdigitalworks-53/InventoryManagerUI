# Karobar Branding — App Icons, Wordmark & Rename

**Date:** 2026-06-29
**Status:** Approved (design)
**Scope:** Cross-platform app icons (Android, iOS, Windows, macOS), an in-app
wordmark, and renaming the user-visible app name to **Karobar**.

---

## Goal

Rebrand the app — currently shipped as **BusinessManagement** with placeholder
icons — to **Karobar** with a custom, on-brand identity:

- A single **"K" lettermark** app icon, generated for every platform/size.
- A matching **wordmark** lockup for the in-app login screen (and iOS launch
  screen as iOS-only polish).
- The user-visible **display name** changed to "Karobar".

The bundle identifier / Android package / CMake target name **do not change**
— this is a cosmetic rebrand, not a new app identity, so there is no store
migration.

## Chosen design — "D3"

The icon mark, validated visually during brainstorming (variant **D3**):

- **Tile:** square, full-bleed, dark indigo `#1e1b4b` with a subtle radial
  sheen from `#312e81` (top-left, ~30%/30%) fading to `#1e1b4b`. Gives a
  premium, tactile depth.
- **K:** a sharp (miter join, butt cap) geometric lettermark — one vertical
  stem plus a chevron (upper + lower diagonal) — stroked in a brightened
  brand gradient `#818cf8 → #a78bfa → #f472b6` (top-left → bottom-right).
- The K sits inside the **Android adaptive-icon safe zone** so it survives
  circular / squircle / teardrop launcher masks without clipping.

The gradient is a brightened variant of the app's existing brand tokens
(`Constants.brand1/2/3` = `#6366f1 / #8b5cf6 / #ec4899`) so the mark reads as
the same family while staying legible on the dark tile.

### K geometry (master coordinates, 200×200 viewBox)

The brainstorm preview used a parametric K; the final master is hand-tuned for
optical balance but stays within these bounds:

- Stem: vertical line at x≈68, y 46→154, stroke width ≈28.
- Chevron: polyline `(146,46) → (80,100) → (146,154)`, same stroke width.
- Tile rect: `x=4 y=4 w=192 h=192 rx=44` (rounded for composite/raster targets
  that are not self-masked).

Final artwork may nudge these for optical centering; the values above are the
starting point, not a hard contract.

---

## Architecture

A **single master SVG** is the source of truth. A small Node script rasterizes
it to every platform's required sizes and packs container formats (`.ico`,
`.icns`). This is deterministic, version-controlled, and re-runnable.

### Why this toolchain

Probed on the dev machine:

- **Absent:** ImageMagick, Inkscape, rsvg-convert, Python/cairosvg/Pillow.
  (Windows' own `convert.exe` is on PATH but is the disk tool, not ImageMagick.)
- **Present:** Node v22.14 + npm 10.9, npm registry reachable.

So the pipeline is **Node + npm-local dependencies** — no system installs:

- [`sharp`](https://www.npmjs.com/package/sharp) (libvips) — SVG → PNG at any
  size, the core rasterizer.
- [`png-to-ico`](https://www.npmjs.com/package/png-to-ico) — pack PNGs → Windows
  `.ico`.
- [`@fiahfy/icns-convert`](https://www.npmjs.com/package/@fiahfy/icns-convert)
  (or equivalent pure-JS ICNS packer) — pack PNGs → macOS `.icns`. If a
  suitable pure-JS packer is unavailable at implementation time, fall back to
  documenting the `.icns` step as manual and still emit the PNG set.

Dependencies are declared in a dedicated `scripts/package.json` (the repo root
is a Qt/Felgo project, not a Node project — keep icon-gen deps isolated there).

---

## Components / units

### 1. Brand source SVGs — `assets/brand/` (new directory)

| File | Purpose |
|------|---------|
| `icon-background.svg` | Square full-bleed: indigo tile + radial sheen. The Android adaptive **background** layer. |
| `icon-foreground.svg` | Transparent square: the gradient **K** only, positioned inside the 66/108 dp safe zone. The Android adaptive **foreground** layer. |
| `icon.svg` | The composite (background + foreground, with `rx=44` rounding) — the master for iOS, Windows, macOS, and in-app use. This is "D3". |
| `wordmark.svg` | Horizontal lockup: the K mark + the word "Karobar" set in the brand gradient. For login / splash. |

These four SVGs are the **only** hand-authored artwork. Everything else is
generated.

> Note: `assets/**` is already globbed into the build by `CMakeLists.txt`
> (`AssetsFiles`, `CONFIGURE_DEPENDS`), so new files under `assets/brand/` are
> packaged automatically — relevant only for `icon.svg`/`wordmark.svg` which are
> used in-app. The platform icon outputs live outside `assets/` (see below) and
> are consumed by each platform's native packaging, not the QML resource system.

### 2. Generation script — `scripts/gen-icons.mjs`

Run with `node scripts/gen-icons.mjs` (after `npm install` in `scripts/`).
Reads the source SVGs and writes outputs **in place** into the existing
platform folders. Idempotent — safe to re-run.

A small built-in self-check (assert-based, runs at the end of the script)
verifies every expected output file exists and has the expected pixel
dimensions; it exits non-zero if any are missing or mis-sized.

#### Android — adaptive icon (`android/res/`)

`minSdkVersion = 28`, so adaptive icons are fully supported.

- `mipmap-anydpi-v26/ic_launcher.xml` — `<adaptive-icon>` referencing
  `@drawable/ic_launcher_foreground` + `@drawable/ic_launcher_background`.
- `drawable-{mdpi,hdpi,xhdpi,xxhdpi,xxxhdpi}/ic_launcher_foreground.png`
- `drawable-{mdpi,hdpi,xhdpi,xxhdpi,xxxhdpi}/ic_launcher_background.png`
  (foreground/background canvas = 108dp; densities 48→144 px baseline ×scale.)
- **Legacy fallback:** refresh `drawable-{mdpi,hdpi,xhdpi,xxhdpi}/ic_launcher.png`
  with the rounded composite, for pre-26 launchers and any code path that reads
  the flat icon. (xxxhdpi added for the adaptive layers; legacy set keeps its
  existing four densities.)

The manifest already references `@drawable/ic_launcher`; the `anydpi-v26`
override takes precedence on API 26+ automatically. No manifest edit required
beyond what already exists.

#### iOS — `ios/Assets.xcassets/AppIcon.appiconset/`

Regenerate all PNGs enumerated in the existing `Contents.json` (18 files:
20/29/40/60/76/83.5 pt at their scales + 1024 marketing). Square, **opaque**,
**no corner rounding** (iOS applies the mask). `Contents.json` is unchanged —
filenames are kept identical.

#### Windows — `win/app_icon.ico`

Pack 16/32/48/256 px (rounded composite) into the multi-resolution `.ico`.
`win/app_icon.rc` already references `app_icon.ico` — no change.

#### macOS — `macx/app_icon.icns`

Pack the standard icns ladder (16→1024, @1x/@2x) from the rounded composite.

### 3. Rename to "Karobar"

Display name only. Three edits:

| File | Field | New value |
|------|-------|-----------|
| `android/res/values/strings.xml` | `app_name` | `Karobar` |
| `ios/Project-Info.plist` | `CFBundleDisplayName` | `Karobar` |
| `qml/config.json` | `title` | `Karobar` |

**Not changed:** `CMakeLists.txt` project/target name (`BusinessManagement` /
`appBusinessManagement`), `PRODUCT_IDENTIFIER`
(`com.lkdigitalworks.business.management.app`), Android `package`,
`.vscode/*` task labels (dev-only, not user-visible).

### 4. In-app brand wiring

- **`qml/pages/LoginPage.qml`** (lines ~151–168): the brand mark is currently a
  72×72 gradient `Rectangle` containing the text **"BM"**. Replace it with an
  `Image` of `assets/brand/icon.svg` at the same 72×72 footprint (the slot is
  square, so the K mark fits — the horizontal wordmark does not). The existing
  `Rectangle`'s gradient + radius can be dropped since the SVG carries its own
  tile; keep the `Layout.alignment`/sizing. This is a content swap, not a layout
  change. (The wordmark is used on the iOS launch screen, below.)
- **`ios/Launch Screen.storyboard`** (currently a blank white view): place the
  wordmark. **iOS-only polish** — requires adding an image to the asset catalog
  and an `imageView` to the storyboard; lower priority than the icon + login
  swap and may be split into a follow-up if it balloons.

---

## Data flow

```text
assets/brand/*.svg  (hand-authored master)
        │
        ▼
scripts/gen-icons.mjs  (sharp + png-to-ico + icns packer)
        │
        ├─► android/res/mipmap-anydpi-v26/ic_launcher.xml
        ├─► android/res/drawable-*/ic_launcher_foreground.png
        ├─► android/res/drawable-*/ic_launcher_background.png
        ├─► android/res/drawable-*/ic_launcher.png        (legacy fallback)
        ├─► ios/Assets.xcassets/AppIcon.appiconset/*.png   (18 files)
        ├─► win/app_icon.ico
        └─► macx/app_icon.icns

assets/brand/icon.svg + wordmark.svg
        │
        └─► consumed in-app by QML (LoginPage) + iOS launch storyboard
```

## Error handling / edge cases

- **Missing rasterizer dep:** `npm install` in `scripts/` must succeed; the
  script fails loudly (non-zero exit) if `sharp` can't load.
- **`.icns` packer availability:** if no pure-JS ICNS packer installs cleanly,
  emit the PNG ladder and document the final `.icns` pack as a manual step
  rather than blocking the whole run. (macOS is the lowest-traffic target.)
- **Android safe zone:** the foreground K must stay within the inner 66dp of the
  108dp canvas, else launcher masks clip it. Verified visually against a circle
  mask during brainstorming; the script bakes the padding into the foreground
  layer.
- **iOS opaque requirement:** iOS icons must have no alpha. The composite for
  iOS fills the full square with the tile (no transparent corners).
- **Idempotency:** re-running overwrites outputs deterministically; no stale
  files left behind for the size sets we own.

## Testing / verification

1. **Script self-check:** asserts every expected output path exists at the
   correct dimensions; non-zero exit on failure.
2. **Visual spot-check:** open generated PNGs at 28 px and 48 px; confirm the K
   is legible and the gradient reads. Confirm the Android foreground inside a
   circular mask is not clipped.
3. **Build + run:** build the app; confirm (a) the launcher/window shows
   "Karobar", and (b) the login screen shows the K mark instead of "BM".
4. **Per-platform packaging** is out of scope to fully exercise here (no CI for
   all four OSes); the deterministic size/format outputs + the existing native
   packaging conventions are the contract.

## Out of scope

- Bundle identifier / package / store listing changes.
- CMake project or target rename.
- Any data migration (the app is in a fresh-data MVP phase).
- A full design system / multiple logo lockups beyond the single wordmark.
- Splash-screen work on Android/Windows beyond what already exists.

## Files touched (summary)

**New (6):** `assets/brand/icon.svg`, `assets/brand/icon-foreground.svg`,
`assets/brand/icon-background.svg`, `assets/brand/wordmark.svg`,
`scripts/gen-icons.mjs`, `scripts/package.json`
(+ generated `android/res/mipmap-anydpi-v26/ic_launcher.xml`).

**Regenerated in place:** Android `res/drawable-*` PNGs, iOS appiconset PNGs,
`win/app_icon.ico`, `macx/app_icon.icns`.

**Edited (4 text):** `android/res/values/strings.xml`,
`ios/Project-Info.plist`, `qml/config.json`, `qml/pages/LoginPage.qml`
(+ `ios/Launch Screen.storyboard` for the iOS-only wordmark polish).
