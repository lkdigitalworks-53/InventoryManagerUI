# Icon Migration Map — Emoji/Glyph → Monochrome `Icon`

**Date:** 2026-06-08
**Branch:** `feat/icon-emoji-rendering`
**Related:** `2026-06-06-icon-emoji-rendering-design.md` (design), `../plans/2026-06-06-icon-emoji-rendering.md` (plan)

## Purpose

Every former Unicode glyph / color emoji is now rendered through a single `Icon` component
(`qml/components/Icon.qml`) backed by Felgo FontAwesome, resolved via a semantic name → `IconType`
map in `qml/helper/Constants.qml` (`iconMap` + `icon(name)`).

This document is the **complete inventory** of what was replaced and where, to plan the **next phase:
swapping the monochrome FontAwesome icons for raster/vector images exported from the prototype.**

### How the indirection helps the image swap

Because every icon goes through `Icon { name: "<semantic>" }` and one central map, the image swap is
**localized**: change `Icon.qml` (or the map) to resolve a semantic `name` to a prototype image
asset instead of a FontAwesome glyph, and every call site updates at once. No call site hardcodes a
glyph anymore. The semantic-name table below is the contract to design the prototype asset set
against — one image per semantic name.

> **Note on accuracy:** line numbers are as of branch HEAD and will drift. The semantic `name` and
> file are the stable references. Re-grep `name:`/`iconName:` to refresh line numbers.

---

## 1. Semantic name → current FontAwesome glyph (the asset contract)

One image asset is needed per row. Group/priority is a suggestion for the prototype export.

| Semantic name | Current `IconType` (FontAwesome) | Origin glyph(s) | Notes |
|---|---|---|---|
| `dropdown` | caretdown | ▾ | combo/expander caret |
| `add` | plus | ＋ / + | steppers, FABs, "new" |
| `remove` | minus | − | stepper decrement |
| `close` | times | ✕ / × | close / clear / remove-row |
| `check` | check | ✓ | confirm / complete |
| `edit` | pencil | ✎ | edit / rename |
| `settings` | cog | ⚙ | page settings |
| `quick` | bolt | ⚡ | quick-approve |
| `import` | download | ⤓ | import action |
| `export` | share | ⤴ | export/share action |
| `back` | arrowleft | ← | page back |
| `chevron` | angleright | › | row drill-in |
| `star` | star | ★ | "Default" marker, revenue badge |
| `warn` | exclamationtriangle | ⚠ | error/warning rows |
| `search` | search | 🔍 | search field |
| `camera` | camera | 📷 | photo capture |
| `calendar` | calendar | 📅 | date picker |
| `bell` | bell | 🔔 | notifications |
| `box` | archive | 📦 | product / inventory empty-state |
| `empty-inbox` | inbox | 📭 | orders/activity empty-state |
| `celebrate` | trophy | 🎉 | notifications all-clear |
| `staff` | users | 👥 | staff page/empty-state |
| `workspace` | building | 🏢 | tenant setup, profile row |
| `analytics` | barchart | 📊 | sales empty-state, export |
| `secure` | lock | 🔒 | login security note |
| `delete` | trash | 🗑️ | delete photo |
| `gallery` | image | 🖼️ | pick from gallery |
| `web` | globe | 🌐 | web/URL source |
| `clipboard` | clipboard | 📋 | dashboard recent-activity |
| `history` | filetext | 📜 | product history section |
| `tag` | tag | 🏷️ | product pricing |
| `orders` | shoppingcart | 🧾 | nav tab, quick-action |
| `products` | archive | 📦 | nav tab, quick-action |
| `analysis` | linechart | 📈 | nav tab |
| `report` | linechart | 📈 | quick-action |
| `profile` | user | 👤 | settings row |
| `team` | users | 👥 / 🧑‍🤝‍🧑 | quick-action, settings row |
| `security` | lock | 🔐 | settings row |
| `appearance` | paintbrush | 🎨 | settings row |
| `language` | globe | 🌐 | settings row |
| `currency` | exchange | 💱 | settings row |
| `home` | home | ⌂ | nav tab |
| `pause` | pause | — | (reserved) |
| `reveal` | eye | 👁 | password show |
| `hide` | eyeslash | 🙈 | password hide |
| `file` | file | 📄 | import file row |
| **History feed (EditProductDialog)** | | | |
| `created` | pluscircle | 🆕 | product created |
| `purchase` | download | 📥 | restock/purchase |
| `sale` | upload | 📤 | sale |
| `stock_adjustment` | calculator | 🧮 | manual stock edit |
| `field_change` | pencil | ✏️ | field edit (also legacy/default) |
| `photo_change` | image | 🖼 | photo changed |
| **Activity feed (Activity/Dashboard/Notifications)** | | | |
| `product-added` | plus | ＋ | activity badge |
| `product-updated` | pencil | ✎ | activity badge |
| `restocked` | refresh | ↻ | activity badge |
| `staff-added` | user | 👤 | activity badge |
| `staff-updated` | pencil | ✎ | activity badge |
| `pause-status` | pause | ⏸ | suspend/activate toggle |
| `activity` | questioncircle | • | generic activity fallback |

---

## 2. Call sites by file (line numbers as of branch HEAD)

### Shared components (`qml/components/`)
| File:line | Semantic name | Was |
|---|---|---|
| AppComboBox.qml:52 | dropdown | ▾ |
| BottomSheet.qml:118 | close | ✕ |
| ConfirmDialog.qml:84 | warn | ⚠ |
| SearchField.qml:30 | search | 🔍 |
| SearchField.qml:51 | close | ✕ |
| PhotoSourceSheet.qml:71 | camera | 📷 |
| PhotoSourceSheet.qml:107 | gallery | 🖼️ |
| PhotoSourceSheet.qml:151 | web | 🌐 |
| PhotoSourceSheet.qml:197 | delete | 🗑️ |
| AuthPasswordField.qml:~92 | reveal / hide | 👁 / 🙈 (dynamic toggle) |
| IconActionButton.qml | *(renders `iconName` passed by callers)* | — |
| FloatingActionButton.qml:12 | add | ＋ (default `iconName: "add"`) |
| FloatingTabbar.qml | *(renders `modelData.iconName`)* | — |
| ActionTile.qml | *(renders `iconName`)* | — |
| AvatarBadge.qml | *(optional `iconName` icon mode)* | — |

### Helpers (`qml/helper/`)
| File:line | Semantic name | Was |
|---|---|---|
| StatusBadge.qml:44 | dropdown | ▾ |
| OrderRow.qml:57 | check | ✓ |
| OrderRow.qml:65 | edit | ✎ |

### App root
| File:line | Semantic name | Was |
|---|---|---|
| Main.qml:483 | home | ⌂ (nav tab data) |
| Main.qml:484 | orders | 🧾 (nav tab data) |
| Main.qml:485 | products | 📦 (nav tab data) |
| Main.qml:486 | analysis | 📈 (nav tab data) |

### Pages (`qml/pages/`)
| File:line | Semantic name | Was |
|---|---|---|
| ActivityPage.qml:70 | back | ← |
| ActivityPage.qml:154 | empty-inbox | 📭 |
| ActivityPage.qml:~107 | product-added / product-updated / restocked / staff-added / staff-updated / activity | ＋/✎/↻/👤/✎/• (kind block) |
| AddProductDialog.qml:102 | camera | 📷 |
| AddProductDialog.qml:215 | dropdown | ▾ |
| AddProductDialog.qml:367 | close / add | ✕/＋ (dynamic toggle) |
| AddStaffDialog.qml:103 | calendar | 📅 |
| DashboardPage.qml:230 | bell | 🔔 |
| DashboardPage.qml:325 | orders | 🧾 (quick-action) |
| DashboardPage.qml:330 | products | 📦 (quick-action) |
| DashboardPage.qml:335 | team | 👥 (quick-action) |
| DashboardPage.qml:340 | report | 📈 (quick-action) |
| DashboardPage.qml:461 | clipboard | 📋 |
| DashboardPage.qml:~403 | product-added / … / activity | (activity kind block); title `👋` stripped (plain text) |
| EditProductDialog.qml:208 | box | 📦 |
| EditProductDialog.qml:442 | tag | 🏷️ |
| EditProductDialog.qml:572 | close / edit | ✕/✎ (rename toggle) |
| EditProductDialog.qml:643 | history | 📜 |
| EditProductDialog.qml:~705 | created/purchase/sale/stock_adjustment/field_change/photo_change | 🆕/📥/📤/🧮/✏️/🖼 (`_icon` switch) |
| ExportSheet.qml:21 | analytics | 📊 (data); export-label 📥/🆕/📤 stripped to plain text |
| ExportSheet.qml:36 | chevron | › |
| ImportPreviewDialog.qml:73 | file | 📄; "✓ Imported" → "Imported" (glyph stripped) |
| InventoryPage.qml:52 | import | ⤓ |
| InventoryPage.qml:57 | export | ⤴ |
| InventoryPage.qml:173 | box | 📦 |
| InventoryPage.qml:196 | add | ＋ (FAB default); "＋ Restock" → "Restock"; avatar fallback 📦 → "?" |
| LoginPage.qml:298 | warn | ⚠ (compound row) |
| LoginPage.qml:364 | secure | 🔒 (compound row) |
| ManageCategoriesDialog.qml:99 | star | ★ (compound "★ Default") |
| ManageOrderChannelsDialog.qml:105 | star | ★ (compound "★ Default") |
| MemberManagementDialog.qml:180 | check / pause-status | ✓/⏸ (status toggle) |
| MemberManagementDialog.qml:203 | close | ✕ |
| NewOrderDialog.qml:190 | add | ＋ |
| NewOrderDialog.qml:222 | remove | − |
| NewOrderDialog.qml:244 | add | + |
| NotificationsSheet.qml:257 | star | ★ (revenue badge) |
| NotificationsSheet.qml:275 | celebrate | 🎉 |
| NotificationsSheet.qml:~169 | product-added / … / activity | (activity kind block) |
| OrderDetailDialog.qml:335 | add | ＋ |
| OrderDetailDialog.qml:396 | remove | − |
| OrderDetailDialog.qml:422 | add | + |
| OrderDetailDialog.qml:438 | close | ✕ |
| OrdersPage.qml:45 | import | ⤓ |
| OrdersPage.qml:50 | export | ⤴ |
| OrdersPage.qml:55 | settings | ⚙ |
| OrdersPage.qml:104 | quick | ⚡ |
| OrdersPage.qml:178 | check | ✓ |
| OrdersPage.qml:275 | empty-inbox | 📭 |
| OrdersPage.qml:299 | add | ＋ (FAB default) |
| ProfilePage.qml:38 | back | ← |
| ProfilePage.qml:163 | profile | 👤 (settings row) |
| ProfilePage.qml:164 | workspace | 🏢 (settings row) |
| ProfilePage.qml:165 | team | 🧑‍🤝‍🧑 (settings row) |
| ProfilePage.qml:166 | security | 🔐 (settings row) |
| ProfilePage.qml:167 | bell | 🔔 (settings row) |
| ProfilePage.qml:200 | appearance | 🎨 (settings row) |
| ProfilePage.qml:201 | language | 🌐 (settings row) |
| ProfilePage.qml:202 | currency | 💱 (settings row) |
| ProfilePage.qml:314 | chevron | › |
| RestockDialog.qml:212 | close / add | ✕/＋ (dynamic toggle) |
| SalesPage.qml:113 | settings | ⚙ |
| SalesPage.qml:148 | export | ⤴ |
| SalesPage.qml:193 | analytics | 📊 |
| SalesPage.qml:320 | close | × |
| StaffPage.qml:50 | back | ← |
| StaffPage.qml:62 | staff | 👥 |
| StaffPage.qml:67 | export | ⤴ |
| StaffPage.qml:179 | staff | 👥 |
| StaffPage.qml:202 | add | ＋ (FAB default) |
| TenantSetupPage.qml:49 | workspace | 🏢 |
| TenantSetupPage.qml:159 | warn | ⚠ (compound row) |

---

## 3. Decorative glyphs removed from strings (no icon — context for the image swap)

These were emoji prefixes inside sentence/toast strings; they were **stripped to plain text**, not
replaced with an icon. If the prototype wants an icon here, it must be added new (there is no `Icon`
at these sites today):

| File | Was | Now |
|---|---|---|
| Main.qml (×4 export toasts) | "✓ … exported." | "… exported." |
| ImportPreviewDialog.qml | "✓ Imported …" | "Imported …" |
| DashboardPage.qml | greeting + " 👋" | greeting only |
| SalesPage.qml | tx-label "📥/🆕/📤 …" | label only |
| InventoryPage.qml | avatar fallback "📦" | "?" (letter, not icon) |

---

## 4. Recommendations for the prototype-image phase

1. **Design assets against the §1 semantic-name list** (one image per name) — not against the raw
   emoji. That list is the de-facto icon catalog.
2. **Single swap point:** extend `Icon.qml` to map `name` → a prototype image (e.g. an `Image`
   `source` from a `name → asset-path` map) with FontAwesome as fallback for any unmapped name.
   No call site changes.
3. **Empty-state heroes** (`empty-inbox`, `box`, `analytics`, `staff`, `celebrate`) are large
   (sp28–sp56) and may warrant richer/illustrative artwork vs. small UI icons — consider a
   separate `size`/variant convention.
4. **Color:** UI icons currently inherit `Constants` colors (textPrimary/secondary/muted, danger,
   textOnBrand). Prototype images should ship in a tintable form (monochrome SVG/alpha) if the
   color-by-context behavior is to be preserved; otherwise per-context variants are needed.
5. Keep `Icon` as the only icon primitive — do not reintroduce raw glyphs (Android color-emoji in
   distance-field text crashes; see the design doc).
