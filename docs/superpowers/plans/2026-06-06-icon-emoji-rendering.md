# Cross-Platform Icon & Emoji Rendering Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Eliminate the Android emoji crash and the missing-icon regression by replacing every Unicode-glyph `Text` icon/emoji with a single `Icon` component backed by Felgo's bundled FontAwesome.

**Architecture:** One reusable `Icon.qml` wraps Felgo `AppIcon` and resolves a semantic `name` through a map of names→`IconType` held in `Constants.qml`. All ~65 glyph sites across ~25 files are swept to use it. Emoji become monochrome FontAwesome glyphs — no bundled font asset, no `setTextRenderType` change, so the default distance-field renderer stays everywhere and the color-font crash becomes impossible.

**Tech Stack:** Felgo + Qt 6.8.3, QML. FontAwesome ships inside Felgo (593 `IconType` glyphs); the nav already uses it (`IconType.home`, etc.).

---

## Verification model (read first)

This project has **no QML unit-test harness**, and icon rendering is visual. So "tests" here are three concrete, runnable checks rather than xUnit assertions:

1. **`qmllint`** on every changed file — must report no new errors. Binary:
   `"/c/Felgo/Felgo/mingw_64/bin/qmllint.exe" -I qml <file>`
2. **Grep sweep** — after the sweep, a grep for icon/emoji glyphs in `text:`/`icon:`/`emoji:` literals must return **zero** results (final task).
3. **Android device build** — the only place the original crash reproduces. Launch + visit every former-emoji screen; confirm no crash and all icons render.

Desktop builds will NOT reproduce the crash; do not treat a passing desktop run as proof.

---

## File Structure

**Created:**
- `qml/components/Icon.qml` — the single icon-rendering element. Props: `name` (semantic string), `size` (px), `color`. Resolves `name` via `Constants.iconMap`.

**Modified (foundation):**
- `qml/helper/Constants.qml` — add `iconMap` (semantic name → `IconType` string) + an `icon(name)` resolver.

**Modified (shared components):**
- `qml/components/IconActionButton.qml` — add `iconName`; `contentItem` renders `Icon`.
- `qml/components/AppComboBox.qml`, `BottomSheet.qml`, `SearchField.qml`, `ConfirmDialog.qml`, `PhotoSourceSheet.qml`, `ActionTile.qml`
- `qml/helper/StatusBadge.qml`, `OrderRow.qml`

**Modified (pages):**
- `qml/pages/ActivityPage.qml`, `AddProductDialog.qml`, `AddStaffDialog.qml`, `DashboardPage.qml`, `EditProductDialog.qml`, `ExportSheet.qml`, `ImportPreviewDialog.qml`, `InventoryPage.qml`, `LoginPage.qml`, `ManageCategoriesDialog.qml`, `MemberManagementDialog.qml`, `NewOrderDialog.qml`, `NotificationsSheet.qml`, `OrderDetailDialog.qml`, `OrdersPage.qml`, `ProfilePage.qml`, `SalesPage.qml`, `StaffPage.qml`, `TenantSetupPage.qml`
- `qml/Main.qml` (quick-action data array at ~485)

**Modified (custom component finding):** `ProfilePage.qml` defines an inline `SettingsRow` with an `emoji` property; `DashboardPage.qml` uses `ActionTile`/quick-action arrays. These render emoji through data, not literal `Text` — handled in Task 6.

**Verified, NOT modified:**
- `main.cpp` — confirm it contains **no** `setTextRenderType` call (the earlier experiment must be reverted). Nav `IconType` usage stays as-is.

---

## Authoritative Glyph Inventory

Every site to change, grouped by task. `IconType` targets verified present in this Felgo install.

**Symbol glyphs (standalone `Text`):**

| File:line | Glyph | name | IconType |
|---|---|---|---|
| components/AppComboBox.qml:52 | ▾ | dropdown | caretdown |
| components/BottomSheet.qml:118 | ✕ | close | times |
| components/ConfirmDialog.qml:84 | ⚠ | warn | exclamationtriangle |
| components/SearchField.qml:30 | 🔍 | search | search |
| components/SearchField.qml:51 | ✕ | close | times |
| helper/StatusBadge.qml:42 | ▾ | dropdown | caretdown |
| helper/OrderRow.qml:56 | ✓ | check | check |
| helper/OrderRow.qml:65 | ✎ | edit | pencil |
| pages/ActivityPage.qml:70 | ← | back | arrowleft |
| pages/AddProductDialog.qml:214 | ▾ | dropdown | caretdown |
| pages/ExportSheet.qml:36 | › | chevron | angleright |
| pages/InventoryPage.qml:52 | ⤓ | import | download |
| pages/InventoryPage.qml:57 | ⤴ | export | share |
| pages/MemberManagementDialog.qml:204 | ✕ | close | times |
| pages/NewOrderDialog.qml:190 | ＋ | add | plus |
| pages/NewOrderDialog.qml:222 | − | remove | minus |
| pages/NewOrderDialog.qml:245 | + | add | plus |
| pages/OrderDetailDialog.qml:335 | ＋ | add | plus |
| pages/OrderDetailDialog.qml:396 | − | remove | minus |
| pages/OrderDetailDialog.qml:422 | + | add | plus |
| pages/OrderDetailDialog.qml:438 | ✕ | close | times |
| pages/OrdersPage.qml:45 | ⤓ | import | download |
| pages/OrdersPage.qml:50 | ⤴ | export | share |
| pages/OrdersPage.qml:55 | ⚙ | settings | cog |
| pages/OrdersPage.qml:104 | ⚡ | quick | bolt |
| pages/OrdersPage.qml:178 | ✓ | check | check |
| pages/ProfilePage.qml:38 | ← | back | arrowleft |
| pages/ProfilePage.qml:313 | › | chevron | angleright |
| pages/SalesPage.qml:113 | ⚙ | settings | cog |
| pages/SalesPage.qml:148 | ⤴ | export | share |
| pages/SalesPage.qml:320 | × | close | times |
| pages/StaffPage.qml:50 | ← | back | arrowleft |
| pages/StaffPage.qml:68 | ⤴ | export | share |

**Emoji (standalone `Text`):**

| File:line | Emoji | name | IconType |
|---|---|---|---|
| pages/AddProductDialog.qml:102 | 📷 | camera | camera |
| pages/AddStaffDialog.qml:103 | 📅 | calendar | calendar |
| pages/DashboardPage.qml:230 | 🔔 | bell | bell |
| pages/DashboardPage.qml:456 | 📋 | clipboard | clipboard |
| pages/EditProductDialog.qml:208 | 📦 | box | archive |
| pages/EditProductDialog.qml:441 | 🏷️ | tag | tag |
| pages/EditProductDialog.qml:644 | 📜 | history | filetext |
| pages/ActivityPage.qml:149 | 📭 | empty-inbox | inbox |
| pages/InventoryPage.qml:173 | 📦 | box | archive |
| pages/NotificationsSheet.qml:274 | 🎉 | celebrate | trophy |
| pages/OrdersPage.qml:276 | 📭 | empty-inbox | inbox |
| pages/SalesPage.qml:193 | 📊 | analytics | barchart |
| pages/StaffPage.qml:63 | 👥 | staff | users |
| pages/StaffPage.qml:180 | 👥 | staff | users |
| pages/TenantSetupPage.qml:49 | 🏢 | workspace | building |
| components/PhotoSourceSheet.qml:71 | 📷 | camera | camera |
| components/PhotoSourceSheet.qml:107 | 🖼️ | gallery | image |
| components/PhotoSourceSheet.qml:151 | 🌐 | web | globe |
| components/PhotoSourceSheet.qml:197 | 🗑️ | delete | trash |

**Icon + text compounds (decompose into `Icon` + `Text` in a `Row`):**

| File:line | Source | Decomposition |
|---|---|---|
| pages/LoginPage.qml:296 | `"⚠  " + root._displayedError` | `Icon{name:"warn"}` + `Text{text: root._displayedError}` |
| pages/LoginPage.qml:349 | `"🔒 Your sign-in is secure and encrypted"` | `Icon{name:"secure"}` + `Text{qsTr("Your sign-in is secure and encrypted")}` |
| pages/TenantSetupPage.qml:157 | `"⚠  "` (+ sibling text) | `Icon{name:"warn"}` + existing text |
| pages/ManageCategoriesDialog.qml:97 | `"★ Default"` | `Icon{name:"star"}` + `Text{qsTr("Default")}` |

**Emoji-in-data (through custom components / arrays):**

| File:line | Source | Action |
|---|---|---|
| Main.qml:485 | `{ icon: "📦", label: "Stock" }` | change data to `iconName: "box"`; delegate uses `Icon` |
| pages/DashboardPage.qml:330,335 | `ActionTile { emoji: "📦" / "👥" }` | `ActionTile` gains `iconName`; pass `"box"`/`"staff"` |
| pages/ExportSheet.qml:21 | `{ icon: "📊", ... }` | data → `iconName: "analytics"`; delegate uses `Icon` |
| pages/ProfilePage.qml:165,168,202 | `SettingsRow { emoji: "🏢"/"🔔"/"🌐" }` | `SettingsRow` gains `iconName`; pass `"workspace"/"bell"/"web"` |
| pages/EditProductDialog.qml:709 | `case "photo_change": return "🖼"` | return `"gallery"`; caller renders via `Icon` |
| pages/InventoryPage.qml:228 | `... : "📦"` avatar fallback | replace fallback branch with `Icon{name:"box"}` |

**NOT icons — leave as plain text:** currency/qty prefixes `"− " + …`, `"→ " + …` (ImportPreviewDialog:194, NewOrderDialog:331, OrderDetailDialog:531), and the em-dash inside sentences (Main.qml:266, ImportPreviewDialog:273, LoginPage:391). Do not touch these.

---

### Task 1: Icon map in Constants + `Icon` component (foundation)

**Files:**
- Modify: `qml/helper/Constants.qml`
- Create: `qml/components/Icon.qml`

- [ ] **Step 1: Add the icon map + resolver to Constants**

Open `qml/helper/Constants.qml`. Immediately before the final closing `}` of the root `Item`, add:

```qml
    // ── Icon system ──────────────────────────────────────────────────────────
    // Semantic icon name → Felgo FontAwesome IconType string. The single
    // source of truth for every icon in the app. Add new icons here, never
    // inline a raw glyph in a Text element (breaks on Android — see
    // docs/superpowers/specs/2026-06-06-icon-emoji-rendering-design.md).
    readonly property var iconMap: ({
        "dropdown":  IconType.caretdown,
        "add":       IconType.plus,
        "remove":    IconType.minus,
        "close":     IconType.times,
        "check":     IconType.check,
        "edit":      IconType.pencil,
        "settings":  IconType.cog,
        "quick":     IconType.bolt,
        "import":    IconType.download,
        "export":    IconType.share,
        "back":      IconType.arrowleft,
        "chevron":   IconType.angleright,
        "star":      IconType.star,
        "warn":      IconType.exclamationtriangle,
        "search":    IconType.search,
        // Former emoji → monochrome
        "camera":    IconType.camera,
        "calendar":  IconType.calendar,
        "bell":      IconType.bell,
        "box":       IconType.archive,
        "empty-inbox": IconType.inbox,
        "celebrate": IconType.trophy,
        "staff":     IconType.users,
        "workspace": IconType.building,
        "analytics": IconType.barchart,
        "secure":    IconType.lock,
        "delete":    IconType.trash,
        "gallery":   IconType.image,
        "web":       IconType.globe,
        "clipboard": IconType.clipboard,
        "history":   IconType.filetext,
        "tag":       IconType.tag
    })

    // Resolve a semantic name to an IconType. Falls back to a visible
    // question-circle so a typo is obvious on-screen rather than blank.
    function icon(name) {
        return iconMap[name] !== undefined ? iconMap[name] : IconType.questioncircle
    }
```

`IconType` is available in `Constants.qml` because Felgo registers it globally (same as it is in `Main.qml`). If qmllint flags `IconType` as unqualified, add `import Felgo` to the top of `Constants.qml`.

- [ ] **Step 2: qmllint Constants**

Run: `"/c/Felgo/Felgo/mingw_64/bin/qmllint.exe" -I qml qml/helper/Constants.qml`
Expected: no new errors (a pre-existing `Settings`/`missing-property`-style note, if any, is unrelated). If `IconType` shows as `unqualified`, add `import Felgo` and re-run.

- [ ] **Step 3: Create the `Icon` component**

Create `qml/components/Icon.qml`:

```qml
import QtQuick
import Felgo

import "../helper"

// The single icon-rendering element for the whole app. Wraps Felgo's
// FontAwesome-backed AppIcon and resolves a semantic name through
// Constants.iconMap. Use this instead of putting a raw Unicode glyph in a
// Text element — raw glyphs depend on the device font and crash / vanish on
// Android (see the icon-emoji-rendering design spec).
//
//   Icon { name: "dropdown"; size: sp(14); color: Constants.textSecondary }
AppIcon {
    id: root
    property string name: ""
    iconType: Constants.icon(name)
    size: sp(16)
    color: Constants.textPrimary
}
```

- [ ] **Step 4: qmllint the new component**

Run: `"/c/Felgo/Felgo/mingw_64/bin/qmllint.exe" -I qml qml/components/Icon.qml`
Expected: no errors. **If qmllint reports a type-name collision** with Felgo's `AppIcon`/`Icon`, rename the file to `UiIcon.qml` (type `UiIcon`) and use `UiIcon` everywhere below. Record the chosen name before proceeding.

- [ ] **Step 5: Commit**

```bash
git add qml/helper/Constants.qml qml/components/Icon.qml
git commit -m "feat(icons): add Icon component + semantic IconType map"
```

---

### Task 2: Migrate IconActionButton (shared, highest fan-out)

**Files:**
- Modify: `qml/components/IconActionButton.qml`

- [ ] **Step 1: Replace the content Text with Icon + an iconName prop**

In `qml/components/IconActionButton.qml`: add `import "../helper"` is already present? It imports `"../helper"` (yes). Add `property string iconName: ""` next to the existing `property string variant`. Replace the `contentItem`'s inner `Text { … text: root.text … }` block (lines ~33–38) with:

```qml
        Icon {
            anchors.centerIn: parent
            name: root.iconName
            size: sp(18)
            color: Constants.textPrimary
        }
```

Leave the badge `Rectangle` sub-element unchanged. Keep `root.text` available for accessibility but it is no longer rendered.

- [ ] **Step 2: Update every IconActionButton call site to pass iconName**

Search call sites: `grep -rn "IconActionButton" qml --include=*.qml`. For each, replace the `text: "<glyph>"` assignment with `iconName: "<name>"` using the Symbol-glyph table above. Files: `SalesPage`, `OrderDetailDialog`, `NewOrderDialog`, `InventoryPage`, `OrdersPage`, `DashboardPage`, `ProfilePage`, `AddStaffDialog`, `StaffPage`. (Sites whose glyph is in the table map directly; e.g. `text: "⚙"` → `iconName: "settings"`.)

- [ ] **Step 3: qmllint**

Run: `"/c/Felgo/Felgo/mingw_64/bin/qmllint.exe" -I qml qml/components/IconActionButton.qml`
Expected: no errors.

- [ ] **Step 4: Commit**

```bash
git add qml/components/IconActionButton.qml
git commit -m "feat(icons): IconActionButton renders Icon via iconName"
```

---

### Task 3: Migrate remaining shared components

**Files:**
- Modify: `qml/components/AppComboBox.qml`, `qml/components/BottomSheet.qml`, `qml/components/SearchField.qml`, `qml/components/ConfirmDialog.qml`, `qml/components/PhotoSourceSheet.qml`
- Modify: `qml/helper/StatusBadge.qml`, `qml/helper/OrderRow.qml`

Each is the same transform: replace a `Text { … text: "<glyph>" … }` icon with `Icon { … name: "<name>" … }`, preserving `anchors`, `size`/`font.pixelSize`→`size`, and `color`.

- [ ] **Step 1: AppComboBox indicator (`▾` → dropdown)**

In `qml/components/AppComboBox.qml`, replace the `indicator` `Text` (lines 50–55) with:

```qml
        Icon {
            anchors.centerIn: parent
            name: "dropdown"
            color: Constants.textSecondary
            size: sp(14)
        }
```

Import note (verified): `components/` files reference each other by **bare type name** with **no import** (QML resolves same-directory `.qml` files implicitly; `components/qmldir` only registers the `Toast` singleton, nothing else). So `Icon` resolves inside `AppComboBox.qml` with no new import line. Do not add `import "."` or `import "../components"` to files already in `components/`.

- [ ] **Step 2: BottomSheet close (`✕` → close), SearchField (`🔍`→search, `✕`→close)**

`BottomSheet.qml:118` `Text{text:"✕"}` → `Icon{name:"close"; size: <same>; color:<same>}`.
`SearchField.qml:30` `Text{text:"🔍"}` → `Icon{name:"search"; …}`. `SearchField.qml:51` `Text{text:"✕"}` → `Icon{name:"close"; …}`.

- [ ] **Step 3: ConfirmDialog (`⚠`→warn), PhotoSourceSheet (📷/🖼️/🌐/🗑️)**

`ConfirmDialog.qml:84` → `Icon{name:"warn"; …}`.
`PhotoSourceSheet.qml`: 71 `📷`→`camera`, 107 `🖼️`→`gallery`, 151 `🌐`→`web`, 197 `🗑️`→`delete`. Preserve each Text's `font.pixelSize` as `size:` and `anchors`.

- [ ] **Step 4: StatusBadge (`▾`→dropdown), OrderRow (`✓`→check, `✎`→edit)**

`StatusBadge.qml:42` `text: "▾"` → `Icon{name:"dropdown"; size:<same>; color:<same>}`.
`OrderRow.qml:56` inline `contentItem: Text { text: "✓"; color:"#22c55e"; … }` → `contentItem: Icon { name:"check"; color:"#22c55e"; size: 14 }`. `OrderRow.qml:65` `"✎"` → `Icon{name:"edit"; color:"#6b7280"; size:14}`.

These two helper files are in `qml/helper/`; add `import "../components"` at the top so `Icon` resolves.

- [ ] **Step 5: qmllint all touched files**

Run for each:
`"/c/Felgo/Felgo/mingw_64/bin/qmllint.exe" -I qml qml/components/AppComboBox.qml qml/components/BottomSheet.qml qml/components/SearchField.qml qml/components/ConfirmDialog.qml qml/components/PhotoSourceSheet.qml qml/helper/StatusBadge.qml qml/helper/OrderRow.qml`
Expected: no new errors. `components/` files need no import for `Icon` (same-dir resolution). `helper/` files (`StatusBadge.qml`, `OrderRow.qml`) DO need `import "../components"` added at the top — without it `Icon` is unresolved.

- [ ] **Step 6: Commit**

```bash
git add qml/components/AppComboBox.qml qml/components/BottomSheet.qml qml/components/SearchField.qml qml/components/ConfirmDialog.qml qml/components/PhotoSourceSheet.qml qml/helper/StatusBadge.qml qml/helper/OrderRow.qml
git commit -m "feat(icons): migrate shared components to Icon"
```

---

### Task 4: Migrate standalone-Text symbol glyphs in pages

**Files:** `qml/pages/ActivityPage.qml`, `AddProductDialog.qml`, `ExportSheet.qml`, `InventoryPage.qml`, `OrdersPage.qml`, `OrderDetailDialog.qml`, `NewOrderDialog.qml`, `MemberManagementDialog.qml`, `ProfilePage.qml`, `SalesPage.qml`, `StaffPage.qml`

For each row in the **Symbol-glyph table** that is a standalone `Text` (not an IconActionButton site already done in Task 2), replace the `Text` with `Icon`, preserving `anchors`, `color`, and mapping `font.pixelSize: X` → `size: X`. Ensure each page imports the components dir (pages already `import "../components"` — verify; if not, add it).

**Worked example** (`ActivityPage.qml:70`, back arrow):

Before:
```qml
Text { anchors.centerIn: parent; text: "←"; color: Constants.textPrimary; font.pixelSize: sp(22); font.bold: true }
```
After:
```qml
Icon { anchors.centerIn: parent; name: "back"; color: Constants.textPrimary; size: sp(22) }
```
(`font.bold` drops — FontAwesome glyphs have fixed weight.)

Apply the same transform to: AddProductDialog:214 (`▾`→dropdown), ExportSheet:36 (`›`→chevron), InventoryPage:52/57 (`⤓`→import, `⤴`→export), OrdersPage:178 (`✓`→check; the IconActionButton ones at 45/50/55/104 are Task 2), OrderDetailDialog:396/422/438 inline steppers (`−`→remove, `+`→add, `✕`→close), NewOrderDialog:222/245 (`−`→remove, `+`→add; 190 if standalone), MemberManagementDialog:204 (`✕`→close), ProfilePage:313 (`›`→chevron; 38 is Task 2 back if it's an IconActionButton — otherwise convert here), SalesPage:320 (`×`→close).

- [ ] **Step 1: Convert each standalone symbol Text to Icon** (per list above)

- [ ] **Step 2: qmllint each touched page**

Run `qmllint -I qml <file>` for every file in this task. Expected: no new errors.

- [ ] **Step 3: Commit**

```bash
git add qml/pages/ActivityPage.qml qml/pages/AddProductDialog.qml qml/pages/ExportSheet.qml qml/pages/InventoryPage.qml qml/pages/OrdersPage.qml qml/pages/OrderDetailDialog.qml qml/pages/NewOrderDialog.qml qml/pages/MemberManagementDialog.qml qml/pages/ProfilePage.qml qml/pages/SalesPage.qml qml/pages/StaffPage.qml
git commit -m "feat(icons): migrate page symbol glyphs to Icon"
```

---

### Task 5: Migrate standalone emoji in pages

**Files:** `qml/pages/AddProductDialog.qml`, `AddStaffDialog.qml`, `DashboardPage.qml`, `EditProductDialog.qml`, `ActivityPage.qml`, `InventoryPage.qml`, `NotificationsSheet.qml`, `OrdersPage.qml`, `SalesPage.qml`, `StaffPage.qml`, `TenantSetupPage.qml`

For each row in the **Emoji (standalone `Text`)** table, replace the emoji `Text` with `Icon`, mapping `font.pixelSize`→`size` and adding a sensible `color`.

**Worked example** (`OrdersPage.qml:276`, empty-state):

Before:
```qml
Text { text: "📭"; font.pixelSize: sp(32); Layout.alignment: Qt.AlignHCenter }
```
After:
```qml
Icon { name: "empty-inbox"; size: sp(32); color: Constants.textMuted; Layout.alignment: Qt.AlignHCenter }
```

Empty-state hero glyphs (ActivityPage:149 `empty-inbox`, InventoryPage:173 `box`, OrdersPage:276 `empty-inbox`, SalesPage:193 `analytics` size sp(56), StaffPage:180 `staff`, NotificationsSheet:274 `celebrate`) use `color: Constants.textMuted` (friendly, not alarming). Inline header emoji (DashboardPage:230 `bell`, 456 `clipboard`; EditProductDialog:208 `box`, 441 `tag`, 644 `history`; AddProductDialog:102 `camera`; AddStaffDialog:103 `calendar`; StaffPage:63 `staff`; TenantSetupPage:49 `workspace`) keep their existing color or `Constants.textSecondary`.

- [ ] **Step 1: Convert each standalone emoji Text to Icon** (per list)

- [ ] **Step 2: qmllint each touched page**

Run `qmllint -I qml <file>` for every file in this task. Expected: no new errors.

- [ ] **Step 3: Commit**

```bash
git add qml/pages/AddProductDialog.qml qml/pages/AddStaffDialog.qml qml/pages/DashboardPage.qml qml/pages/EditProductDialog.qml qml/pages/ActivityPage.qml qml/pages/InventoryPage.qml qml/pages/NotificationsSheet.qml qml/pages/OrdersPage.qml qml/pages/SalesPage.qml qml/pages/StaffPage.qml qml/pages/TenantSetupPage.qml
git commit -m "feat(icons): migrate page emoji to monochrome Icon"
```

---

### Task 6: Compounds + emoji-in-data + custom components

**Files:** `qml/pages/LoginPage.qml`, `TenantSetupPage.qml`, `ManageCategoriesDialog.qml`, `DashboardPage.qml`, `ProfilePage.qml`, `ExportSheet.qml`, `EditProductDialog.qml`, `InventoryPage.qml`, `Main.qml`, `qml/components/ActionTile.qml`

- [ ] **Step 1: Decompose icon+text compounds**

`LoginPage.qml:296` — replace the single `Text { text: "⚠  " + root._displayedError }` with a `Row` (spacing dp(6)): `Icon { name:"warn"; size: sp(13); color: Constants.danger }` + `Text { text: root._displayedError; … }` (keep existing color/size/wrap). 
`LoginPage.qml:349` — `Text { text: "🔒 Your sign-in is secure and encrypted" }` → `Row`: `Icon{name:"secure"; size: sp(12); color:<existing>}` + `Text{ text: qsTr("Your sign-in is secure and encrypted"); …}`.
`TenantSetupPage.qml:157` — `"⚠  "` prefix → `Row`: `Icon{name:"warn"}` + the existing message `Text`.
`ManageCategoriesDialog.qml:97` — `"★ Default"` → `Row`: `Icon{name:"star"; size:<same>; color:<same>}` + `Text{ text: qsTr("Default") }`.

- [ ] **Step 2: ActionTile gains iconName; Dashboard quick-actions use it**

In `qml/components/ActionTile.qml`: add `property string iconName: ""`. Replace the inner emoji `Text` (lines 33–37) with:
```qml
                Icon {
                    anchors.centerIn: parent
                    name: root.iconName
                    size: sp(22)
                    color: Constants.textPrimary
                }
```
Keep the `emoji` property declaration for back-compat but stop using it. No import needed — `ActionTile` is in `components/`, so `Icon` resolves as a same-dir sibling.
In `qml/pages/DashboardPage.qml:330,335`: change `ActionTile { emoji: "📦" … }` → `ActionTile { iconName: "box" … }` and `"👥"` → `iconName: "staff"`.

- [ ] **Step 3: SettingsRow gains iconName (ProfilePage)**

Find the inline `SettingsRow` component definition in `ProfilePage.qml` (it has an `emoji` property and renders it in a `Text`). Add `property string iconName: ""` and replace its emoji `Text` with `Icon { name: root.iconName; size: sp(18); color: Constants.textSecondary; … }` (preserve layout anchors). Update the three usages: `:165` `emoji:"🏢"`→`iconName:"workspace"`, `:168` `emoji:"🔔"`→`iconName:"bell"`, `:202` `emoji:"🌐"`→`iconName:"web"`.

- [ ] **Step 4: Data-array icons (Main.qml, ExportSheet, EditProductDialog, InventoryPage)**

`Main.qml:485` — in the data array change `{ icon: "📦", label: "Stock" }` to `{ iconName: "box", label: "Stock" }`; find the delegate that renders `modelData.icon` as `Text` and change it to `Icon { name: modelData.iconName; … }`.
`ExportSheet.qml:21` — `{ fmt:"xlsx", icon:"📊", … }` → `iconName:"analytics"`; delegate `Text` rendering `modelData.icon` → `Icon { name: modelData.iconName }`.
`EditProductDialog.qml:709` — the `case "photo_change": return "🖼"` (and any sibling emoji returns in that function) returns a glyph used in a `Text`. Change the function to return semantic names (`"gallery"`, etc.) and the consuming `Text` to `Icon { name: <returnedName> }`. Inspect the whole `switch` and convert all emoji branches consistently.
`InventoryPage.qml:228` — avatar fallback `... ? name.charAt(0) : "📦"`. Replace the conditional so the non-letter branch renders `Icon { name: "box" }` instead of a `Text` glyph (may require splitting the ternary into a `Loader`/`if` in the delegate — keep the letter branch as `Text`).

- [ ] **Step 5: qmllint all touched files**

Run `qmllint -I qml <file>` for every file in this task. Expected: no new errors.

- [ ] **Step 6: Commit**

```bash
git add qml/pages/LoginPage.qml qml/pages/TenantSetupPage.qml qml/pages/ManageCategoriesDialog.qml qml/pages/DashboardPage.qml qml/pages/ProfilePage.qml qml/pages/ExportSheet.qml qml/pages/EditProductDialog.qml qml/pages/InventoryPage.qml qml/Main.qml qml/components/ActionTile.qml
git commit -m "feat(icons): migrate compounds, data-array icons, and custom components"
```

---

### Task 7: main.cpp verification + final sweep + device test

**Files:** `main.cpp` (verify only)

- [ ] **Step 1: Confirm no global render-type override**

Run: `grep -n "setTextRenderType" main.cpp`
Expected: **no output**. If the line exists (leftover experiment), remove it so the default distance-field renderer is used. Commit the removal if changed:
```bash
git add main.cpp && git commit -m "fix(icons): remove global setTextRenderType (emoji handled by Icon)"
```

- [ ] **Step 2: Final glyph sweep — must be empty**

Run (Grep tool or ripgrep):
- Emoji in literals: search `qml/` for any of `📦📭🎉👥🏢📊🔒🗑🖼🌐📋📜🏷📷📅🔔` in `text:`/`icon:`/`emoji:`/`iconName:` lines → must be **0** (the `iconName:` values are semantic strings, not glyphs).
- Symbol glyphs as icons: confirm the only remaining non-ASCII in `text:` literals are real sentence text (em-dash `—`, ellipsis `…`) and currency prefixes — NOT `▾ ＋ − ✕ ✓ ⚙ ⚡ ⤓ ⤴ ← › ★ ⚠ × 🔍`.

If any icon glyph remains, convert it (it belongs to one of Tasks 2–6) and re-run.

- [ ] **Step 3: Build for Android and deploy to device**

Build the Android target (Felgo/Qt Creator or CLI) and deploy to a connected device. Expected: build succeeds.

- [ ] **Step 4: Device smoke test (the real verification)**

On the Android device, confirm — **no crash** and **icons render** — on:
- Login (lock + warn row), TenantSetup (workspace, warn)
- Dashboard (bell, clipboard, quick-action box/staff tiles)
- Orders (import/export/settings/quick/check, empty `📭`→inbox)
- Inventory (import/export, empty box, avatar fallback box)
- Sales (settings/export/close, empty analytics)
- Staff (back/export, staff hero), Activity (back, empty inbox)
- Add/Edit Product (camera, dropdown, box/tag/history), Add Staff (calendar)
- Combo boxes (dropdown caret), search field, bottom sheets (close), photo source sheet (camera/gallery/web/delete), confirm dialog (warn)
- Notifications (celebrate), Profile (back, chevron, settings rows)

Expected: every screen loads; every icon visible; no missing glyphs; no crash.

- [ ] **Step 5: Final commit (if any device-test fixes were needed)**

```bash
git add -A && git commit -m "test(icons): device verification fixes"
```

---

## Self-Review Notes

- **Spec coverage:** §3 components → Tasks 1–2; §4 sweep (3 call-site shapes + data-array shape discovered during planning) → Tasks 3–6; §6 testing → Task 7; §2 "no setTextRenderType" → Task 7 Step 1. All covered.
- **Type consistency:** the component is `Icon` with props `name`/`size`/`color` throughout; `IconActionButton.iconName`, `ActionTile.iconName`, `SettingsRow.iconName`, and data-array `iconName` all feed `Icon.name`. `Constants.icon(name)`/`Constants.iconMap` names match the per-file tables exactly.
- **Naming-collision guard:** Task 1 Step 4 explicitly verifies `Icon` doesn't collide with Felgo's `AppIcon`/`Icon`; fallback name `UiIcon` documented.
- **No placeholders:** every glyph site is enumerated with file:line, source glyph, and target name; worked examples show exact before/after.
