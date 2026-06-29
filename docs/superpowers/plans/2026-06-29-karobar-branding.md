# Karobar Branding Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rebrand the app from "BusinessManagement" to "Karobar" — a custom "K" lettermark app icon generated for Android/iOS/Windows/macOS from one master SVG, an in-app brand mark, and a user-visible display-name rename.

**Architecture:** Three hand-authored master SVGs (`icon-background`, `icon-foreground`, rounded `icon`) are the single source of truth. A Node script (`scripts/gen-icons.mjs`) rasterizes them to every platform's required sizes using `sharp`, packs `win/app_icon.ico` via `png-to-ico` and `macx/app_icon.icns` via `@fiahfy/icns-convert`, and ends with an assert-based self-check. Outputs are written in place into the existing native folders; no CMake change. The rename is three text edits; the in-app mark is one QML swap.

**Tech Stack:** Node.js 22 (ESM `.mjs`), `sharp` 0.35, `png-to-ico` 3, `@fiahfy/icns-convert` 0.0.12; SVG; Felgo/Qt QML; Android resources; iOS asset catalog.

## Global Constraints

- **Brand colors (verbatim):** tile base `#1e1b4b`; sheen `#312e81` → `#1e1b4b`; K gradient `#818cf8` → `#a78bfa` → `#f472b6` (top-left → bottom-right).
- **K geometry (1024×1024 master canvas):** stroke width `116`, `butt` cap, `miter` join; stem `line x1=360 y1=300 x2=360 y2=724`; chevron `polyline 700,300 430,512 700,724`. Identical coordinates in every SVG that draws the K.
- **Display name:** `Karobar` exactly. **Do NOT change** bundle id `com.lkdigitalworks.business.management.app`, the Android `package`, or the CMake project/target names (`BusinessManagement` / `appBusinessManagement`).
- **iOS icons:** opaque, square, **no** rounded corners (iOS masks). **Windows/macOS/in-app:** rounded (`rx=228`).
- **Android:** `minSdkVersion=28`; adaptive icon canvas 108dp, keep the K inside the central safe zone; the adaptive XML lives at `res/drawable-anydpi-v26/ic_launcher.xml` (the manifest references `@drawable/ic_launcher`, so the override must be the `drawable` resource type — no manifest edit).
- **Node deps are isolated** in `scripts/package.json`; `scripts/node_modules/` must be gitignored. Never re-glob into the Qt build.
- Master SVG canvas is **1024×1024** so every raster is a crisp downscale.

---

## File Structure

**New:**
- `assets/brand/icon-background.svg` — opaque tile + sheen (Android adaptive background; iOS composite base).
- `assets/brand/icon-foreground.svg` — transparent; the gradient K only (Android adaptive foreground; iOS composite overlay).
- `assets/brand/icon.svg` — rounded composite (Windows, macOS, in-app QML mark).
- `assets/brand/wordmark.svg` — K mark + "Karobar" lockup (iOS launch screen only).
- `scripts/gen-icons.mjs` — the generator.
- `scripts/package.json` — isolated Node deps.
- `android/res/drawable-anydpi-v26/ic_launcher.xml` — adaptive icon descriptor (committed; not generated).

**Regenerated in place (by the script):** `android/res/drawable-*/ic_launcher_foreground.png`, `ic_launcher_background.png`, `ic_launcher.png`; `ios/Assets.xcassets/AppIcon.appiconset/*.png` (18); `win/app_icon.ico`; `macx/app_icon.icns`.

**Edited (text):** `.gitignore`; `android/res/values/strings.xml`; `ios/Project-Info.plist`; `qml/config.json`; `qml/pages/LoginPage.qml`; `ios/Launch Screen.storyboard`.

---

### Task 1: Author the master SVGs

The highest-risk creative deliverable — gate the artwork before generating 40+ files from it.

**Files:**
- Create: `assets/brand/icon-background.svg`
- Create: `assets/brand/icon-foreground.svg`
- Create: `assets/brand/icon.svg`

**Interfaces:**
- Produces: three SVGs at `assets/brand/`, intrinsic size 1024×1024, consumed by `scripts/gen-icons.mjs` (Task 2+) and `qml/pages/LoginPage.qml` (Task 6).

- [ ] **Step 1: Create `assets/brand/icon-background.svg`**

```svg
<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">
  <defs>
    <radialGradient id="sheen" cx="35%" cy="30%" r="90%">
      <stop offset="0" stop-color="#312e81"/>
      <stop offset="1" stop-color="#1e1b4b"/>
    </radialGradient>
  </defs>
  <rect width="1024" height="1024" fill="#1e1b4b"/>
  <rect width="1024" height="1024" fill="url(#sheen)"/>
</svg>
```

- [ ] **Step 2: Create `assets/brand/icon-foreground.svg`** (transparent; K only)

```svg
<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">
  <defs>
    <linearGradient id="k" x1="0" y1="0" x2="1024" y2="1024" gradientUnits="userSpaceOnUse">
      <stop offset="0" stop-color="#818cf8"/>
      <stop offset="0.5" stop-color="#a78bfa"/>
      <stop offset="1" stop-color="#f472b6"/>
    </linearGradient>
  </defs>
  <g fill="none" stroke="url(#k)" stroke-width="116" stroke-linecap="butt" stroke-linejoin="miter">
    <line x1="360" y1="300" x2="360" y2="724"/>
    <polyline points="700,300 430,512 700,724"/>
  </g>
</svg>
```

- [ ] **Step 3: Create `assets/brand/icon.svg`** (rounded composite — tile + sheen + K)

```svg
<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">
  <defs>
    <radialGradient id="sheen" cx="35%" cy="30%" r="90%">
      <stop offset="0" stop-color="#312e81"/>
      <stop offset="1" stop-color="#1e1b4b"/>
    </radialGradient>
    <linearGradient id="k" x1="0" y1="0" x2="1024" y2="1024" gradientUnits="userSpaceOnUse">
      <stop offset="0" stop-color="#818cf8"/>
      <stop offset="0.5" stop-color="#a78bfa"/>
      <stop offset="1" stop-color="#f472b6"/>
    </linearGradient>
  </defs>
  <rect width="1024" height="1024" rx="228" fill="#1e1b4b"/>
  <rect width="1024" height="1024" rx="228" fill="url(#sheen)"/>
  <g fill="none" stroke="url(#k)" stroke-width="116" stroke-linecap="butt" stroke-linejoin="miter">
    <line x1="360" y1="300" x2="360" y2="724"/>
    <polyline points="700,300 430,512 700,724"/>
  </g>
</svg>
```

- [ ] **Step 4: Visually verify** — open all three in a browser (drag the files into a tab, or `start assets/brand/icon.svg` on Windows). Confirm: `icon.svg` shows the rounded dark-indigo tile with a gradient K; `icon-foreground.svg` shows the K on transparency (checkerboard); the K is centered and balanced. Sanity-check the K sits within the central ~60% (Android safe zone): the K's farthest point from center (700,724) is ~283px from center (512,512) < the ~317px safe radius. OK.

- [ ] **Step 5: Commit**

```bash
git add assets/brand/icon-background.svg assets/brand/icon-foreground.svg assets/brand/icon.svg
git commit -m "feat(brand): add Karobar master icon SVGs"
```

---

### Task 2: Generator scaffold + Android adaptive icons

**Files:**
- Create: `scripts/package.json`
- Create: `scripts/gen-icons.mjs`
- Create: `android/res/drawable-anydpi-v26/ic_launcher.xml`
- Modify: `.gitignore` (append `scripts/node_modules/`)
- Generates: `android/res/drawable-{mdpi,hdpi,xhdpi,xxhdpi,xxxhdpi}/ic_launcher_foreground.png`, `…/ic_launcher_background.png`; `android/res/drawable-{mdpi,hdpi,xhdpi,xxhdpi}/ic_launcher.png`

**Interfaces:**
- Consumes: `assets/brand/*.svg` (Task 1).
- Produces: `scripts/gen-icons.mjs` exporting nothing (run as a program); internal helpers `renderPng(svgPath, px) -> Promise<Buffer>`, `roundedComposite()` usage, and a module-level `OUT` list of `{path, px}` that the Task-2/3/4 self-checks extend. Run with `node scripts/gen-icons.mjs` from repo root.

- [ ] **Step 1: Append to `.gitignore`**

Add this line (the file already ignores `*package-lock.json` and `build/`):

```gitignore
scripts/node_modules/
```

- [ ] **Step 2: Create `scripts/package.json`**

```json
{
  "name": "karobar-icon-gen",
  "version": "1.0.0",
  "private": true,
  "type": "module",
  "description": "Rasterizes assets/brand SVGs into platform app-icon sets.",
  "scripts": {
    "gen": "node gen-icons.mjs"
  },
  "dependencies": {
    "@fiahfy/icns-convert": "0.0.12",
    "png-to-ico": "3.0.1",
    "sharp": "0.35.2"
  }
}
```

- [ ] **Step 3: Install deps**

Run:
```bash
cd scripts && npm install && cd ..
```
Expected: `node_modules/` appears under `scripts/`; no error. (If `sharp` fails to load later, the run aborts non-zero — that's the signal to reinstall.)

- [ ] **Step 4: Create `scripts/gen-icons.mjs`** with the scaffold + Android section

```javascript
// Rasterizes assets/brand/*.svg into every platform's app-icon set.
// Run from the repo root:  node scripts/gen-icons.mjs
// Idempotent — overwrites outputs deterministically.
import { fileURLToPath } from 'node:url'
import { dirname, join, resolve } from 'node:path'
import { mkdir, writeFile } from 'node:fs/promises'
import assert from 'node:assert/strict'
import sharp from 'sharp'
import pngToIco from 'png-to-ico'
import { convert as icnsConvert } from '@fiahfy/icns-convert'

const HERE = dirname(fileURLToPath(import.meta.url))
const ROOT = resolve(HERE, '..')
const BRAND = join(ROOT, 'assets', 'brand')
const SVG = {
  bg: join(BRAND, 'icon-background.svg'),
  fg: join(BRAND, 'icon-foreground.svg'),
  icon: join(BRAND, 'icon.svg'),
}

// Every file we write, with its expected square pixel size — drives the self-check.
const OUT = []

// Rasterize an SVG to a square PNG buffer at `px`. Intrinsic SVG is 1024, so
// this is always a crisp downscale.
async function renderPng(svgPath, px) {
  return sharp(svgPath).resize(px, px, { fit: 'fill' }).png().toBuffer()
}

async function writePng(svgPath, px, outPath) {
  await mkdir(dirname(outPath), { recursive: true })
  const buf = await renderPng(svgPath, px)
  await writeFile(outPath, buf)
  OUT.push({ path: outPath, px })
}

// Composite fg over bg, flattened opaque (iOS requires no alpha).
async function writeOpaqueComposite(px, outPath) {
  await mkdir(dirname(outPath), { recursive: true })
  const bg = await renderPng(SVG.bg, px)
  const fg = await renderPng(SVG.fg, px)
  const buf = await sharp(bg)
    .composite([{ input: fg }])
    .flatten({ background: '#1e1b4b' })
    .png()
    .toBuffer()
  await writeFile(outPath, buf)
  OUT.push({ path: outPath, px })
}

// ── Android adaptive + legacy ────────────────────────────────────────────────
const ANDROID = join(ROOT, 'android', 'res')
// Adaptive layer canvas = 108dp at each density.
const ADAPTIVE_DENSITIES = [
  ['mdpi', 108], ['hdpi', 162], ['xhdpi', 216], ['xxhdpi', 324], ['xxxhdpi', 432],
]
// Legacy flat icon = 48dp (keep the four densities already in the repo).
const LEGACY_DENSITIES = [
  ['mdpi', 48], ['hdpi', 72], ['xhdpi', 96], ['xxhdpi', 144],
]

async function genAndroid() {
  for (const [d, px] of ADAPTIVE_DENSITIES) {
    await writePng(SVG.bg, px, join(ANDROID, `drawable-${d}`, 'ic_launcher_background.png'))
    await writePng(SVG.fg, px, join(ANDROID, `drawable-${d}`, 'ic_launcher_foreground.png'))
  }
  for (const [d, px] of LEGACY_DENSITIES) {
    // Legacy launchers don't mask — use the rounded composite.
    await writePng(SVG.icon, px, join(ANDROID, `drawable-${d}`, 'ic_launcher.png'))
  }
}

// ── Self-check ───────────────────────────────────────────────────────────────
async function selfCheck() {
  for (const { path, px } of OUT) {
    const meta = await sharp(path).metadata()
    assert.equal(meta.width, px, `width mismatch: ${path} (${meta.width} != ${px})`)
    assert.equal(meta.height, px, `height mismatch: ${path} (${meta.height} != ${px})`)
  }
  console.log(`OK: ${OUT.length} PNG outputs verified.`)
}

async function main() {
  await genAndroid()
  await selfCheck()
  console.log('Done.')
}

main().catch((err) => { console.error(err); process.exit(1) })
```

- [ ] **Step 5: Create `android/res/drawable-anydpi-v26/ic_launcher.xml`**

```xml
<?xml version="1.0" encoding="utf-8"?>
<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">
    <background android:drawable="@drawable/ic_launcher_background"/>
    <foreground android:drawable="@drawable/ic_launcher_foreground"/>
</adaptive-icon>
```

- [ ] **Step 6: Run the generator**

Run:
```bash
node scripts/gen-icons.mjs
```
Expected: `OK: 14 PNG outputs verified.` then `Done.` (5 densities × 2 adaptive layers = 10, + 4 legacy = 14.)

- [ ] **Step 7: Visually verify the Android mask** — open `android/res/drawable-xxhdpi/ic_launcher_foreground.png` and `ic_launcher_background.png`. Confirm the foreground K is centered on transparency and the background is the full indigo tile. Mentally (or in a browser with `border-radius:50%`) confirm the K is not clipped by a circle.

- [ ] **Step 8: Commit**

```bash
git add .gitignore scripts/package.json scripts/gen-icons.mjs android/res/drawable-anydpi-v26/ic_launcher.xml android/res/drawable-*/ic_launcher*.png
git commit -m "feat(brand): generate Android adaptive + legacy launcher icons"
```

---

### Task 3: iOS app icon set

**Files:**
- Modify: `scripts/gen-icons.mjs` (add iOS section + call)
- Generates: `ios/Assets.xcassets/AppIcon.appiconset/*.png` (18 files)

**Interfaces:**
- Consumes: `renderPng`, `writeOpaqueComposite`, `OUT`, `ROOT`, `SVG` (Task 2).
- Produces: the 18 PNGs named exactly as the existing `Contents.json` references (unchanged). Filenames sharing pixel dimensions (e.g. `@2x` and `@2x-1` iPad duplicates) are written independently.

- [ ] **Step 1: Add the iOS section to `scripts/gen-icons.mjs`** — insert after `genAndroid()` and before the self-check section

```javascript
// ── iOS app icon set ─────────────────────────────────────────────────────────
const IOS = join(ROOT, 'ios', 'Assets.xcassets', 'AppIcon.appiconset')
// filename -> pixel size. Matches the existing Contents.json exactly.
const IOS_ICONS = [
  ['Icon-App-20x20@1x.png', 20],
  ['Icon-App-20x20@2x.png', 40],
  ['Icon-App-20x20@2x-1.png', 40],
  ['Icon-App-20x20@3x.png', 60],
  ['Icon-App-29x29@1x.png', 29],
  ['Icon-App-29x29@2x.png', 58],
  ['Icon-App-29x29@2x-1.png', 58],
  ['Icon-App-29x29@3x.png', 87],
  ['Icon-App-40x40@1x.png', 40],
  ['Icon-App-40x40@2x.png', 80],
  ['Icon-App-40x40@2x-1.png', 80],
  ['Icon-App-40x40@3x.png', 120],
  ['Icon-App-60x60@2x.png', 120],
  ['Icon-App-60x60@3x.png', 180],
  ['Icon-App-76x76@1x.png', 76],
  ['Icon-App-76x76@2x.png', 152],
  ['Icon-App-83.5x83.5@2x.png', 167],
  ['ItunesArtwork@2x.png', 1024],
]

async function genIos() {
  for (const [name, px] of IOS_ICONS) {
    await writeOpaqueComposite(px, join(IOS, name))
  }
}
```

- [ ] **Step 2: Call `genIos()` in `main()`** — change `main` to:

```javascript
async function main() {
  await genAndroid()
  await genIos()
  await selfCheck()
  console.log('Done.')
}
```

- [ ] **Step 3: Run the generator**

Run:
```bash
node scripts/gen-icons.mjs
```
Expected: `OK: 32 PNG outputs verified.` (14 Android + 18 iOS) then `Done.`

- [ ] **Step 4: Verify opacity + size of the marketing icon**

Run:
```bash
node -e "import('sharp').then(async ({default:s})=>{const m=await s('ios/Assets.xcassets/AppIcon.appiconset/ItunesArtwork@2x.png').stats(); console.log('hasAlpha-opaque:', m.isOpaque)})"
```
Expected: `hasAlpha-opaque: true` (iOS requires opaque icons). Also open `Icon-App-60x60@3x.png` and confirm it shows the rounded-free square tile + K (iOS will round it itself).

- [ ] **Step 5: Commit**

```bash
git add scripts/gen-icons.mjs "ios/Assets.xcassets/AppIcon.appiconset"
git commit -m "feat(brand): generate iOS app icon set"
```

---

### Task 4: Windows .ico + macOS .icns

**Files:**
- Modify: `scripts/gen-icons.mjs` (add desktop section + call + extend self-check)
- Generates: `win/app_icon.ico`, `macx/app_icon.icns`

**Interfaces:**
- Consumes: `renderPng`, `OUT`, `ROOT`, `SVG`, `pngToIco`, `icnsConvert` (Task 2).
- Produces: a multi-resolution `.ico` (16/32/48/256) and a `.icns` (auto-laddered from a 1024 PNG) of the rounded composite. These are container formats, so they're verified by existence + non-empty, not by `sharp` square-dimension check.

- [ ] **Step 1: Add the desktop section to `scripts/gen-icons.mjs`** — insert after `genIos()`

```javascript
// ── Windows .ico + macOS .icns (rounded composite) ───────────────────────────
const WIN_ICO = join(ROOT, 'win', 'app_icon.ico')
const MAC_ICNS = join(ROOT, 'macx', 'app_icon.icns')
const CONTAINERS = []  // {path} — verified by existence, not dimensions

async function genDesktop() {
  // Windows .ico: pack the standard sizes.
  const icoSizes = [16, 32, 48, 256]
  const icoPngs = await Promise.all(icoSizes.map((px) => renderPng(SVG.icon, px)))
  const icoBuf = await pngToIco(icoPngs)
  await writeFile(WIN_ICO, icoBuf)
  CONTAINERS.push({ path: WIN_ICO })

  // macOS .icns: icns-convert auto-generates the full ladder from a 1024 PNG.
  const big = await renderPng(SVG.icon, 1024)
  const icnsBuf = await icnsConvert(big)
  await writeFile(MAC_ICNS, icnsBuf)
  CONTAINERS.push({ path: MAC_ICNS })
}
```

- [ ] **Step 2: Extend the self-check** — replace the `selfCheck` function body's end (after the PNG loop) so it also asserts the containers exist and are non-empty. New `selfCheck`:

```javascript
async function selfCheck() {
  for (const { path, px } of OUT) {
    const meta = await sharp(path).metadata()
    assert.equal(meta.width, px, `width mismatch: ${path} (${meta.width} != ${px})`)
    assert.equal(meta.height, px, `height mismatch: ${path} (${meta.height} != ${px})`)
  }
  const { stat } = await import('node:fs/promises')
  for (const { path } of CONTAINERS) {
    const s = await stat(path)
    assert.ok(s.size > 0, `empty container: ${path}`)
  }
  console.log(`OK: ${OUT.length} PNG outputs + ${CONTAINERS.length} containers verified.`)
}
```

- [ ] **Step 3: Call `genDesktop()` in `main()`**

```javascript
async function main() {
  await genAndroid()
  await genIos()
  await genDesktop()
  await selfCheck()
  console.log('Done.')
}
```

- [ ] **Step 4: Run the generator**

Run:
```bash
node scripts/gen-icons.mjs
```
Expected: `OK: 32 PNG outputs + 2 containers verified.` then `Done.`

- [ ] **Step 5: Verify the .ico opens** and shows the icon (Windows): `start win/app_icon.ico` or open in an image viewer; confirm the rounded K tile renders at multiple sizes. Confirm `macx/app_icon.icns` is non-empty (`ls -la macx/app_icon.icns`).

- [ ] **Step 6: Commit**

```bash
git add scripts/gen-icons.mjs win/app_icon.ico macx/app_icon.icns
git commit -m "feat(brand): generate Windows .ico and macOS .icns"
```

---

### Task 5: Rename display name to "Karobar"

**Files:**
- Modify: `android/res/values/strings.xml:3`
- Modify: `ios/Project-Info.plist:6`
- Modify: `qml/config.json:2`

**Interfaces:**
- Consumes: nothing.
- Produces: the user-visible name "Karobar" on all launchers and the window title. Bundle id / package / target names unchanged.

- [ ] **Step 1: Edit `android/res/values/strings.xml`** — change the `app_name` value

```xml
<?xml version="1.0" encoding="utf-8"?>
<resources>
  <string name="app_name">Karobar</string>
</resources>
```

- [ ] **Step 2: Edit `ios/Project-Info.plist`** — change `CFBundleDisplayName` (the value directly under that key, line ~6)

```xml
    <key>CFBundleDisplayName</key>
    <string>Karobar</string>
```

- [ ] **Step 3: Edit `qml/config.json`** — change `title`

```json
{
    "title": "Karobar",
    "identifier": "com.lkdigitalworks.business.management.app",
    "orientation": "auto",
    "versioncode": 1,
    "versionname": "1.0.0",
    "stage": "publish"
}
```

- [ ] **Step 4: Verify no unintended renames** — confirm the identifier and target names are untouched.

Run:
```bash
grep -rn "BusinessManagement" CMakeLists.txt qml/config.json ios/Project-Info.plist android/res/values/strings.xml
```
Expected: matches ONLY in `CMakeLists.txt` (project/target name — intentionally unchanged). `config.json`, the plist, and `strings.xml` show no `BusinessManagement`.

- [ ] **Step 5: Commit**

```bash
git add android/res/values/strings.xml ios/Project-Info.plist qml/config.json
git commit -m "feat(brand): rename display name to Karobar"
```

---

### Task 6: Wire the K mark into the login screen

Replaces the placeholder "BM" text mark with the real icon.

**Files:**
- Modify: `qml/pages/LoginPage.qml:150-168`

**Interfaces:**
- Consumes: `assets/brand/icon.svg` (Task 1). Uses the established in-app SVG pattern from `qml/components/Icon.qml` (an `Image` with `sourceSize`, `mipmap`, `PreserveAspectFit`).
- Produces: the login brand mark renders the K icon at the existing 72×72 footprint.

- [ ] **Step 1: Replace the brand-mark `Rectangle`** at `qml/pages/LoginPage.qml:150-168`. The current block is:

```qml
            // Brand mark
            Rectangle {
                Layout.alignment: Qt.AlignHCenter
                width: dp(72); height: dp(72); radius: dp(22)
                gradient: Gradient {
                    orientation: Gradient.Vertical
                    GradientStop { position: 0.0; color: Constants.brand1 }
                    GradientStop { position: 0.55; color: Constants.brand2 }
                    GradientStop { position: 1.0; color: Constants.brand3 }
                }
                Text {
                    anchors.centerIn: parent
                    text: "BM"
                    color: Constants.textOnBrand
                    font.bold: true
                    font.pixelSize: sp(22)
                    font.letterSpacing: 0.5
                }
            }
```

Replace it entirely with (the SVG already carries the tile + rounding, so no Rectangle/gradient is needed):

```qml
            // Brand mark — Karobar "K" (assets/brand/icon.svg carries tile + rounding)
            Image {
                Layout.alignment: Qt.AlignHCenter
                width: dp(72); height: dp(72)
                source: Qt.resolvedUrl("../../assets/brand/icon.svg")
                // Rasterize at physical pixels so the SVG stays crisp on HiDPI.
                sourceSize.width: dp(72) * Math.min(Screen.devicePixelRatio, 3)
                sourceSize.height: dp(72) * Math.min(Screen.devicePixelRatio, 3)
                fillMode: Image.PreserveAspectFit
                smooth: true
                mipmap: true
                cache: true
            }
```

- [ ] **Step 2: Ensure `Screen` is available** — confirm the import block at the top of `qml/pages/LoginPage.qml` includes `QtQuick.Window` (which provides the `Screen` attached type). Current imports are `QtQuick`, `QtQuick.Controls as QQC`, `QtQuick.Layouts`. Add after the `QtQuick` line:

```qml
import QtQuick.Window
```

- [ ] **Step 3: Lint the QML**

Run (the box needs the two QT_* env vars per AGENTS.md):
```bash
PATH="/c/Felgo/Felgo/mingw_64/bin:$PATH" "C:/Felgo/Felgo/mingw_64/bin/qmllint.exe" qml/pages/LoginPage.qml
```
Expected: no errors about `Image`, `Screen`, or the removed `Text`. (Pre-existing project-wide warnings unrelated to this file are acceptable.)

- [ ] **Step 4: Build and run, verify visually**

Run:
```bash
cmake --build build
```
Then launch the app (per the `run` skill / Felgo run target) and confirm the login screen shows the dark-indigo K tile where "BM" used to be, at the same size, horizontally centered.

- [ ] **Step 5: Commit**

```bash
git add qml/pages/LoginPage.qml
git commit -m "feat(brand): show Karobar K mark on the login screen"
```

---

### Task 7: iOS launch-screen wordmark (iOS-only polish)

**Optional / deferrable.** Per the spec this is iOS-only polish and may be split to a follow-up if it balloons. It does not block the icon + rename. Skip this task entirely on a non-iOS-priority pass; the launch screen stays its current blank white.

**Files:**
- Create: `assets/brand/wordmark.svg`
- Modify: `scripts/gen-icons.mjs` (emit launch PNGs)
- Create: `ios/Assets.xcassets/Wordmark.imageset/` (`Contents.json` + 3 PNGs)
- Modify: `ios/Launch Screen.storyboard`

**Interfaces:**
- Consumes: `renderPng`-style rasterization; the K geometry + gradient from Task 1.
- Produces: a centered wordmark image on the iOS launch screen.

- [ ] **Step 1: Create `assets/brand/wordmark.svg`** — K mark (left) + "Karobar" (right). Canvas 1024×320. Text uses a bold system sans (Helvetica is present on iOS/macOS; Qt also resolves it). The K reuses the master geometry scaled into a 320-tall tile.

```svg
<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="320" viewBox="0 0 1024 320">
  <defs>
    <radialGradient id="sheen" cx="35%" cy="30%" r="90%">
      <stop offset="0" stop-color="#312e81"/>
      <stop offset="1" stop-color="#1e1b4b"/>
    </radialGradient>
    <linearGradient id="k" x1="0" y1="0" x2="320" y2="320" gradientUnits="userSpaceOnUse">
      <stop offset="0" stop-color="#818cf8"/>
      <stop offset="0.5" stop-color="#a78bfa"/>
      <stop offset="1" stop-color="#f472b6"/>
    </linearGradient>
    <linearGradient id="word" x1="320" y1="0" x2="1024" y2="0" gradientUnits="userSpaceOnUse">
      <stop offset="0" stop-color="#6366f1"/>
      <stop offset="0.5" stop-color="#8b5cf6"/>
      <stop offset="1" stop-color="#ec4899"/>
    </linearGradient>
  </defs>
  <!-- K tile, 320x320 on the left -->
  <rect x="0" y="0" width="320" height="320" rx="72" fill="#1e1b4b"/>
  <rect x="0" y="0" width="320" height="320" rx="72" fill="url(#sheen)"/>
  <g fill="none" stroke="url(#k)" stroke-width="36" stroke-linecap="butt" stroke-linejoin="miter"
     transform="translate(0,0) scale(0.3125)">
    <line x1="360" y1="300" x2="360" y2="724"/>
    <polyline points="700,300 430,512 700,724"/>
  </g>
  <text x="372" y="208" font-family="Helvetica, Arial, sans-serif" font-weight="800"
        font-size="200" letter-spacing="-6" fill="url(#word)">Karobar</text>
</svg>
```

- [ ] **Step 2: Verify the wordmark** — open `assets/brand/wordmark.svg` in a browser. Confirm the K tile + "Karobar" read correctly and the text is fully inside the 1024 width. If the word overflows, reduce `font-size` to `184`. (Note the K group is the master geometry scaled by 0.3125 = 320/1024, with stroke 36 ≈ 116×0.3125.)

- [ ] **Step 3: Add launch-PNG generation to `scripts/gen-icons.mjs`** — add after `genDesktop()`. The launch image is non-square, so render at native aspect (1024×320 → @1/2/3x) and track in `CONTAINERS` (skip the square self-check).

```javascript
// ── iOS launch-screen wordmark (non-square) ──────────────────────────────────
const WORDMARK_SVG = join(BRAND, 'wordmark.svg')
const IOS_WORDMARK = join(ROOT, 'ios', 'Assets.xcassets', 'Wordmark.imageset')

async function genWordmark() {
  const scales = [['wordmark.png', 1], ['wordmark@2x.png', 2], ['wordmark@3x.png', 3]]
  for (const [name, scale] of scales) {
    await mkdir(IOS_WORDMARK, { recursive: true })
    const w = 512 * scale, h = 160 * scale  // display ~512x160 pt
    const buf = await sharp(WORDMARK_SVG).resize(w, h, { fit: 'fill' }).png().toBuffer()
    const out = join(IOS_WORDMARK, name)
    await writeFile(out, buf)
    CONTAINERS.push({ path: out })
  }
}
```

Call it in `main()` after `genDesktop()`:

```javascript
  await genDesktop()
  await genWordmark()
```

- [ ] **Step 4: Create `ios/Assets.xcassets/Wordmark.imageset/Contents.json`**

```json
{
  "images" : [
    { "idiom" : "universal", "filename" : "wordmark.png", "scale" : "1x" },
    { "idiom" : "universal", "filename" : "wordmark@2x.png", "scale" : "2x" },
    { "idiom" : "universal", "filename" : "wordmark@3x.png", "scale" : "3x" }
  ],
  "info" : { "version" : 1, "author" : "xcode" }
}
```

- [ ] **Step 5: Run the generator**

Run:
```bash
node scripts/gen-icons.mjs
```
Expected: `OK: 32 PNG outputs + 5 containers verified.` (2 desktop + 3 wordmark) then `Done.`

- [ ] **Step 6: Wire the wordmark into `ios/Launch Screen.storyboard`** — add an `imageView` referencing `Wordmark`, centered, inside the existing view. Replace the `<view>` element's empty body (it currently has only `rect`, `autoresizingMask`, `color`, `viewLayoutGuide`) by inserting a `subviews` block with a centered image view and two center constraints:

```xml
                    <view key="view" contentMode="scaleToFill" id="Ze5-6b-2t3">
                        <rect key="frame" x="0.0" y="0.0" width="414" height="896"/>
                        <autoresizingMask key="autoresizingMask" widthSizable="YES" heightSizable="YES"/>
                        <subviews>
                            <imageView clipsSubviews="YES" userInteractionEnabled="NO" contentMode="scaleAspectFit" image="Wordmark" translatesAutoresizingMaskIntoConstraints="NO" id="wm0-00-001">
                                <rect key="frame" x="71" y="418" width="272" height="60"/>
                            </imageView>
                        </subviews>
                        <color key="backgroundColor" red="1" green="1" blue="1" alpha="1" colorSpace="custom" customColorSpace="sRGB"/>
                        <constraints>
                            <constraint firstItem="wm0-00-001" firstAttribute="centerX" secondItem="Ze5-6b-2t3" secondAttribute="centerX" id="wm0-cx-001"/>
                            <constraint firstItem="wm0-00-001" firstAttribute="centerY" secondItem="Ze5-6b-2t3" secondAttribute="centerY" id="wm0-cy-001"/>
                        </constraints>
                        <viewLayoutGuide key="safeArea" id="Bcu-3y-fUS"/>
                    </view>
```

- [ ] **Step 7: Commit**

```bash
git add assets/brand/wordmark.svg scripts/gen-icons.mjs "ios/Assets.xcassets/Wordmark.imageset" "ios/Launch Screen.storyboard"
git commit -m "feat(brand): add Karobar wordmark to iOS launch screen"
```

---

## Self-Review

**Spec coverage:**
- Brand source SVGs (icon-background/foreground/icon/wordmark) → Tasks 1 & 7. ✓
- Generation pipeline (sharp + png-to-ico + icns) → Tasks 2–4 & 7. ✓
- Android adaptive + legacy fallback → Task 2 (corrected path `drawable-anydpi-v26`). ✓
- iOS 18-size set → Task 3. ✓
- Windows .ico → Task 4. ✓ · macOS .icns → Task 4. ✓
- Rename (strings.xml, plist, config.json) → Task 5. ✓
- In-app login mark → Task 6. ✓ · iOS launch wordmark → Task 7. ✓
- Script self-check → Tasks 2/4. ✓ · Identifier/target unchanged → Task 5 Step 4 guard. ✓

**Placeholder scan:** No TBD/TODO; every code/SVG/command step is complete and concrete.

**Type/name consistency:** `renderPng`, `writePng`, `writeOpaqueComposite`, `OUT`, `CONTAINERS`, `selfCheck`, `genAndroid`/`genIos`/`genDesktop`/`genWordmark`, `SVG.{bg,fg,icon}` are defined in Task 2 and used consistently in Tasks 3/4/7. iOS filenames match the existing `Contents.json`. `drawable-anydpi-v26` (not `mipmap-`) matches the manifest's `@drawable/ic_launcher` reference.

**Known correctness notes folded in:** iOS opacity via `.flatten()`; SVG always downscaled from 1024 (crisp); Android safe-zone math checked (Task 1 Step 4); `Screen` import added for LoginPage HiDPI sizing (Task 6 Step 2).
