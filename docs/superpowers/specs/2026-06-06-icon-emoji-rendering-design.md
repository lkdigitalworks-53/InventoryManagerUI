# Cross-Platform Icon & Emoji Rendering — Design

**Date:** 2026-06-06
**Status:** Approved (design); pending implementation plan
**Platforms:** Android (crashing), iOS, desktop
**Stack:** Felgo + Qt 6.8.3, QML

---

## 1. Problem & Root Cause

The Android build crashes on screens that render color emoji, and the attempted fix
(`QQuickWindow::setTextRenderType(QQuickWindow::NativeTextRendering)` in `main.cpp`) stopped the
crash but made many icons (dropdown `▾`, `＋` in IconActionButton, etc.) disappear.

**Root cause:** the app has **no icon abstraction**. Every icon and emoji is a literal Unicode
character rendered through a plain `Text` element, relying on the platform font to contain that
glyph. Two failure modes stem from this single design gap:

- **Crash:** Qt Quick's default *distance-field* text renderer (`QtRendering`) does not safely
  handle color-emoji fonts (CBDT/COLR) on Android in Qt 6.8 → crash.
- **Missing icons:** switching globally to `NativeTextRendering` makes all text use the Android
  system font, which lacks glyphs like `＋` (U+FF0B), `▾` (U+25BE), `⤓`, `⤴` → they render as
  nothing/tofu. Distance-field had been sourcing them from a fallback font that happened to
  include them.

Both are symptoms of *"assume the device font contains whatever glyph I type."* That assumption is
unreliable across Android/iOS versions and is the thing this design removes.

**Asset already present:** Felgo bundles **FontAwesome (593 `IconType` glyphs)**, already used in
the app's navigation (`IconType.home`, `IconType.shoppingcart`, `IconType.archive`,
`IconType.linechart` in `Main.qml`). It is compiled into Felgo — guaranteed present on every
platform, cannot fail to load. The icons simply bypassed it.

---

## 2. Decisions (locked)

| Decision | Value |
|---|---|
| Symbol-glyph icons | Render via Felgo **`AppIcon`/`IconType`** (bundled FontAwesome). |
| Emoji | **Replace with monochrome FontAwesome icons** — no bundled emoji font, no color-font crash surface. |
| Scope | **Full sweep now** — all glyph sites migrated in one pass. |
| `main.cpp` render type | **Leave at default (distance field).** No global `setTextRenderType` call. Crash is eliminated by removing emoji glyphs from text rendering entirely, not by special-casing the renderer. |

Tradeoff accepted: decorative emoji empty-states (`📭`, `📊`, `🎉`) become monochrome glyphs —
sized generously and tinted with `Constants` accent colors so they still read as friendly
empty-states rather than cold error marks.

---

## 3. Components

1. **`qml/components/AppIcon.qml`** (new) — the single place icon rendering is defined. Wraps
   Felgo's `AppIcon`/`IconType`. Properties: `name` (semantic string), `size` (px), `color`.
   Resolves `name` through the icon map. This is the only element that touches `IconType`.
2. **Icon map in `Constants.qml`** — a semantic-name → `IconType` map so call sites express intent
   (`"dropdown"`, `"add"`) rather than glyph trivia. Full mapping in §5.
3. **`IconActionButton.qml`** — `contentItem` switches from `Text { text }` to `AppIcon`, driven
   by a new `iconName` property. Callers set `iconName` instead of `text`. The notification badge
   sub-element is unchanged.
4. **No new font assets, no `FontLoader`, no `EmojiText`.** Removed from scope by the
   monochrome-emoji decision.

`AppIcon` is the only unit with behavior; everything else is a data map or a call-site swap. It can
be understood and eyeballed in isolation (an icon-gallery debug check, §6).

---

## 4. The Sweep (rollout)

A single uniform replacement across ~25 files / ~65 sites: every icon/emoji `Text` glyph becomes an
`AppIcon { name: …; size: …; color: … }`.

**Three call-site shapes, handled distinctly:**

- **Standalone icon** — `Text { text: "▾"; font.pixelSize: sp(18); color: … }` →
  `AppIcon { name: "dropdown"; size: sp(18); color: … }`.
- **IconActionButton content** — callers pass `iconName: "settings"` instead of `text: "⚙"`.
- **Icon + text compounds** (must be decomposed, NOT blind-swapped):
  - `"⚠  " + root._displayedError` (LoginPage:296) → a `Row`/inline `AppIcon` + `Text`.
  - `"🔒 Your sign-in is secure and encrypted"` (LoginPage:349) → `AppIcon` (lock) + `Text`.
  - `"★ Default"` (ManageCategoriesDialog:97) → `AppIcon` (star) + `Text`.
  - Currency/qty prefixes `"− " + …`, `"→ " + …` are **plain text, not icons** — leave as-is.

Also covered: `\u`-escaped glyphs (`StatusBadge` `▾`, `OrderRow` `✓`/`✎`) and inline
`contentItem: Text { text: "−" }` steppers in `OrderDetailDialog` / `NewOrderDialog`.

After the sweep, grep verifies zero raw icon/emoji glyphs remain in any `text:` literal.

---

## 5. Icon Map (semantic name → IconType)

All targets verified present in Felgo 6.8.3's `IconType.qml` (593 names).

**Symbols:**

| Glyph | Semantic name | IconType |
|---|---|---|
| `▾` / `▾` | dropdown | `caretdown` |
| `＋` / `+` | add | `plus` |
| `−` / `−` | remove | `minus` |
| `✕` / `×` | close | `times` |
| `✓` / `✓` | check | `check` |
| `✎` | edit | `pencil` |
| `⚙` | settings | `cog` |
| `⚡` | bolt / quick | `bolt` |
| `⤓` | download / import | `download` |
| `⤴` | share / export | `share` (or `upload`) |
| `←` | back | `arrowleft` |
| `›` | chevron | `angleright` |
| `★` | star / default | `star` |
| `⚠` | warn | `exclamationtriangle` |
| `🔍` | search | `search` |

**Emoji → monochrome:**

| Emoji | Semantic name | IconType |
|---|---|---|
| `📷` | camera | `camera` |
| `📅` | calendar | `calendar` |
| `🔔` | bell | `bell` |
| `📦` | box / product | `archive` |
| `📭` | empty-inbox | `inbox` |
| `🎉` | celebrate | `star` (or `trophy`) |
| `👥` | staff | `users` |
| `🏢` | workspace | `building` |
| `📊` | analytics | `barchart` |
| `🔒` | secure | `lock` |
| `🗑️` | delete | `trash` |
| `🖼️` | gallery | `image` |
| `🌐` | web | `globe` |
| `📋` | clipboard | `clipboard` |
| `📜` | history | `filetext` |
| `🏷️` | tag / price | `tag` |

Any name not confirmed at implementation time falls back to the closest verified glyph; the map is
the single point of adjustment.

---

## 6. Error Handling & Testing

- **No font-load failure path** — FontAwesome is compiled into Felgo; `AppIcon` cannot fail to
  load. No bundled emoji font means no color-font crash is possible.
- **No global render-type change** — fast distance-field text everywhere; no all-text regression.
- **Testing (Android device is the real target — desktop won't reproduce the original crash):**
  1. App launches past every former-emoji screen (Dashboard, empty Orders/Inventory/Sales/Staff,
     Notifications, TenantSetup, Login) without crashing.
  2. All steppers (`+`/`−`), dropdowns (`▾`), close (`✕`), settings (`⚙`), back (`←`),
     import/export (`⤓`/`⤴`) icons render correctly.
  3. Spot-check iOS + desktop unchanged.
  4. Optional: a temporary icon-gallery view rendering every mapped `AppIcon` to eyeball the full
     set at once.

---

## 7. Files Touched (indicative)

`main.cpp` (confirm no `setTextRenderType`), `qml/helper/Constants.qml` (icon map),
`qml/components/AppIcon.qml` (new), `qml/components/IconActionButton.qml`,
`qml/components/{AppComboBox,BottomSheet,SearchField,PhotoSourceSheet,ConfirmDialog}.qml`,
`qml/helper/{StatusBadge,OrderRow}.qml`, and pages
`{Activity,AddProduct,AddStaff,Dashboard,EditProduct,Export,ImportPreview,Inventory,Invite
Member,Login,ManageCategories,MemberManagement,NewOrder,Notifications,OrderDetail,Orders,Profile,
Sales,Staff,TenantSetup}.qml`.

---

## 8. Out of Scope

- No change to Felgo nav icons (already `IconType`).
- No new emoji/icon-font assets.
- No global text-rendering configuration.
