# Colorful SVG Icons — Design Spec

**Date:** 2026-06-08
**Branch:** `feat/icon-emoji-rendering` (continues the prior FontAwesome migration)
**Related:**
- `docs/superpowers/plans/2026-06-06-icon-emoji-rendering.md` (prior plan — FontAwesome migration, already implemented)
- `docs/icon-replacement-doc.md` (authoritative semantic-name catalog; §1 is the icon contract)

---

## 1. Problem & Goal

**Problem.** The app crashed on Android because color-emoji glyphs (📦 👥 🔔) were rendered
through `Text` elements. Qt routes `Text` through its distance-field glyph renderer, which
cannot handle multicolor (COLR/CBDT) glyphs and crashes on some Android GPU drivers.

The prior migration (`2026-06-06-icon-emoji-rendering.md`, already on this branch) fixed the
crash by replacing every glyph/emoji `Text` with a single `Icon` component backed by Felgo
**FontAwesome**, resolved through `Constants.iconMap`. That stopped the crash — but every icon
is now **monochrome**, which is not the colorful look of the prototype.

**Goal.** Restore colorful icons that work identically on **Android, iOS, and desktop**, without
reintroducing the crash. Render icons as **images** (texture path), never as font glyphs (atlas
path), so the crashing code path is never touched.

**Non-goals.**
- No changes to the HTML prototype (`prototypes/mobile-redesign/`). It uses the OS's own color
  emoji and has no exportable icon set; the doc's §1 semantic-name list is the authoritative
  catalog. (Decision: app-only.)
- No re-introduction of a color-emoji font with native text rendering (that is the crash path).
- No call-site changes in pages/components — every site already routes through `Icon`.

---

## 2. Key Principle

> **Colorful + cross-platform + crash-safe = render icons as images, not font text.**

Images go through Qt's texture path on every platform, identically. Font glyphs go through the
glyph atlas / distance-field renderer, which is where color emoji crash on Android. The entire
design follows from this: the *illustrative* icons become bundled **color SVG** images; the
*functional chrome* icons stay on the already-working, crash-proven FontAwesome backend (which is
monochrome and therefore safe).

---

## 3. Architecture — one component, two backends

`Icon.qml` remains the **single swap point**. Every call site in the app already uses
`Icon { name: "..." }`, so changing `Icon.qml` updates every screen at once. We teach it to pick
a backend from the name:

```
Icon { name }
   │
   ├─ name is a color icon?  ──►  Image { source: assets/icons/<name>.svg }   (full-color Twemoji)
   │
   └─ otherwise              ──►  AppIcon { iconType: Constants.icon(name) }  (FontAwesome, tinted)
```

Two maps in `Constants.qml`:

- **`iconMap`** (already exists) — `name → IconType`, for tintable chrome. **Unchanged.**
- **`colorIconMap`** (new) — `name → svg filename` for the color set. A name present here renders
  as `assets/icons/<file>`; any name absent falls through to FontAwesome via `iconMap`.

Two resolver functions in `Constants.qml`:

- `isColorIcon(name)` → `bool` — is this name in `colorIconMap`?
- `colorIconSource(name)` → URL string for the SVG asset.

**Why this shape:**
- **Zero call-site churn** — every screen already uses `Icon`.
- **Chrome path is unchanged** — it is the exact code already shipping and crash-proven.
- **One-line edits** — adding/removing a color icon is a single map entry.
- **No breakage** — the `color` property still exists on every `Icon`; it simply has no effect on
  color-SVG icons (documented), so no call site fails to compile or behaves unexpectedly.

---

## 4. Name → backend split

### 4a. Color (Twemoji SVG) — illustrative "things"

These render as full-color SVG. Several semantic names intentionally share one emoji file.

| Semantic name(s) | Emoji | Twemoji file |
|---|---|---|
| `camera` | 📷 | `1f4f7.svg` |
| `calendar` | 📅 | `1f4c5.svg` |
| `bell` | 🔔 | `1f514.svg` |
| `box`, `products` | 📦 | `1f4e6.svg` |
| `empty-inbox` | 📭 | `1f4ed.svg` |
| `celebrate` | 🎉 | `1f389.svg` |
| `staff`, `team` | 👥 | `1f465.svg` |
| `workspace` | 🏢 | `1f3e2.svg` |
| `analytics` | 📊 | `1f4ca.svg` |
| `analysis`, `report` | 📈 | `1f4c8.svg` |
| `gallery`, `photo_change` | 🖼️ | `1f5bc.svg` |
| `web`, `language` | 🌐 | `1f310.svg` |
| `clipboard` | 📋 | `1f4cb.svg` |
| `history` | 📜 | `1f4dc.svg` |
| `tag` | 🏷️ | `1f3f7.svg` |
| `orders` | 🧾 | `1f9fe.svg` |
| `profile` | 👤 | `1f464.svg` |
| `security`, `secure` | 🔒 | `1f512.svg` |
| `appearance` | 🎨 | `1f3a8.svg` |
| `currency` | 💱 | `1f4b1.svg` |
| `file` | 📄 | `1f4c4.svg` |
| `delete` | 🗑️ | `1f5d1.svg` |
| `home` | 🏠 | `1f3e0.svg` |
| `created` | 🆕 | `1f195.svg` |
| `purchase` | 📥 | `1f4e5.svg` |
| `sale` | 📤 | `1f4e4.svg` |
| `stock_adjustment` | 🧮 | `1f9ee.svg` |
| `product-added` | ➕ | `2795.svg` |
| `restocked` | 🔄 | `1f504.svg` |
| `staff-added` | 👤 | `1f464.svg` |
| `activity` | 🔵 | `1f535.svg` |

> **Codepoint table is reviewable, not guessed.** The Origin-glyph column in
> `docs/icon-replacement-doc.md` §1 is the guide for each mapping. This table is the
> authoritative source for the fetch step; any ambiguity is resolved here before download.

**Shared-file names** (point two names at one file): `staff`/`team` → `1f465`,
`box`/`products` → `1f4e6`, `analysis`/`report` → `1f4c8`, `web`/`language` → `1f310`,
`security`/`secure` → `1f512`, `gallery`/`photo_change` → `1f5bc`, `profile`/`staff-added` → `1f464`.

**Activity-feed badges that reuse chrome semantics** (`product-updated`, `staff-updated`,
`field_change` are all "edit/pencil" actions; `pause-status` is a control): these stay on
**FontAwesome** (4b) — they are status affordances, not illustrative objects, and look correct
monochrome/tinted in a small feed badge.

### 4b. Chrome (FontAwesome, tinted) — functional controls

These stay on the existing FontAwesome backend, monochrome, tinted by the `color` property
(white on a colored button, gray in a row). No new assets.

`dropdown, add, remove, close, check, edit, settings, quick, import, export, back, chevron,
star, warn, search, reveal, hide, pause, pause-status, product-updated, staff-updated,
field_change`

### 4c. Nav tabs (decision)

Nav tabs (`home, orders, products, analysis`) render as **color SVG**. Because color SVG cannot
be tinted, the **active-tab state is shown via label color + pill background** (the way the
prototype does it), **not** via icon tint. `FloatingTabbar.qml` already renders
`modelData.iconName` through `Icon`; the active-state styling moves to the label/background if it
is not already there. (Confirmed decision.)

---

## 5. Asset pipeline

**Location.** `assets/icons/*.svg`. The `assets/` tree is already globbed into the build
(`CMakeLists.txt:34`, `AssetsFiles`) and deployed via `deploy_resources` (`:57`). **No CMake
change required** — new SVGs are picked up automatically.

**Sourcing.** Twemoji publishes one SVG per emoji, named by Unicode codepoint. For each row in
§4a: resolve name → codepoint → fetch `https://.../twemoji/.../svg/<codepoint>.svg` → save as
`assets/icons/<name>.svg`. Shared names copy the same file under each name so the runtime map
stays a dumb 1:1 lookup (no aliasing logic in QML).

**License.** Twemoji is **CC-BY 4.0**. Add `assets/icons/ATTRIBUTION.md` crediting Twemoji /
Twitter to satisfy the license. (This is a hard requirement, not optional.)

**SVG profile.** Qt renders the **Tiny SVG 1.2** profile. Twemoji SVGs are flat `<path fill>`
with no filters/scripts/CSS — squarely inside that profile, low risk. The plan includes a
desktop render-grid step (§7.3) to catch any asset that fails to parse.

---

## 6. `Icon.qml` implementation

The component becomes a small backend selector. Final form lands in the implementation plan;
this is the intended shape:

```qml
import QtQuick
import Felgo
import "../helper"

Item {
    id: root
    property string name: ""
    property real size: sp(16)
    property color color: Constants.textPrimary   // affects chrome (FontAwesome) only — ignored for color SVG
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
            source: Constants.colorIconSource(root.name)
            sourceSize.width: root.size      // pin rasterization to render size — crisp vector
            sourceSize.height: root.size
            width: root.size
            height: root.size
            fillMode: Image.PreserveAspectFit
            smooth: true
            asynchronous: true
        }
    }
}
```

Key points:
- **`sourceSize`** pins SVG rasterization to the render size — sharp at every density, no blur.
  Critical for empty-state heroes (`empty-inbox, box, analytics, staff, celebrate` at sp28–sp56).
- **`color` is ignored for color icons by design** — stated in the component header comment so no
  one files a "tint doesn't work" bug.
- **Type-name guard.** The component is type `Icon` today and works (despite Felgo's own
  `AppIcon`/`Icon`). We keep `Icon`. If the `Item`/`Loader` rewrite trips a collision in qmllint,
  fall back to type `UiIcon` and update call sites — recorded in the plan as a contingency.
- **Backward compatible.** Public surface (`name`, `size`, `color`) is unchanged, so all ~70 call
  sites keep working untouched.

---

## 7. Verification

No QML unit-test harness exists and icon rendering is visual, so verification is four concrete
runnable checks (same model as the prior migration):

1. **`qmllint`** on `qml/components/Icon.qml` and `qml/helper/Constants.qml` — no new errors.
   Binary: `"/c/Felgo/Felgo/mingw_64/bin/qmllint.exe" -I qml <file>`.

2. **Asset-completeness check** — every name in `colorIconMap` has a matching
   `assets/icons/<file>.svg`, and every SVG maps back to at least one name (no orphans). This is
   the closest thing to a unit test for this work; it runs as a scripted grep/ls assertion.

3. **Desktop visual grid** — a throwaway QML screen rendering all color icons + chrome icons in a
   grid. Confirms every SVG parses and looks right at small and hero sizes. Desktop build does NOT
   reproduce the crash — this step only validates rendering, not the crash fix.

4. **Android device build (the real proof)** — the only place the original crash reproduced and
   the only proof the SVG image plugin is packaged. Visit every former-emoji screen; confirm color
   icons render (not blank) and no crash.
   - **Blank color icons on Android = the `qsvg` image plugin was not packaged.** The plan
     includes the Felgo/Qt deployment knob (`QT_ANDROID_EXTRA_PLUGINS` / `androiddeployqt`
     plugin inclusion) to force-include `qsvg` if the default packaging drops it. `qsvg.dll` is
     confirmed present in the Felgo install, so this is a packaging concern, not a missing
     dependency.

---

## 8. Out of scope / explicitly deferred

- HTML prototype updates (app-only decision).
- Dark-mode-specific icon variants — Twemoji color icons are theme-agnostic by nature; revisit
  only if a specific icon reads poorly on the dark surface.
- Animated icons / Lottie — not required for the crash fix or the colorful look.

---

## 9. Build sequence (preview — full plan via writing-plans)

1. Resolve the §4a codepoint table; fetch Twemoji SVGs into `assets/icons/`; add `ATTRIBUTION.md`.
2. Add `colorIconMap` + `isColorIcon()` + `colorIconSource()` to `Constants.qml`; qmllint.
3. Rewrite `Icon.qml` as the two-backend selector; qmllint.
4. Asset-completeness check (§7.2).
5. Desktop visual grid (§7.3); fix any non-parsing assets.
6. Confirm nav-tab active state is label/background-based (§4c) in `FloatingTabbar.qml`.
7. Android build + device smoke test (§7.4); add `qsvg` plugin knob if icons render blank.
