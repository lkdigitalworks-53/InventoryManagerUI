# Design: Search in the product picker (Add Order / Edit Order)

**Date:** 2026-07-15
**Status:** Approved (pending written-spec review)
**Scope:** replace the plain `AppComboBox` product picker in `NewOrderDialog.qml` (Add Order) and
`OrderDetailDialog.qml` (Edit Order) with a searchable "select product" sheet. Search matches on
product name, SKU, and product ID.

---

## 1. Problem statement

Both order dialogs let you add a product via a `ComboBox`-style dropdown populated with every
product in the catalog. As the catalog grows, scrolling a flat dropdown to find one product
becomes slow. Taher asked for search by product ID, SKU, and name.

While tracing the existing picker to add search, a more serious problem surfaced: **both dialogs
select a product via `productCombo.currentIndex`, using it as a raw array position** —

- **Add Order** (`NewOrderDialog.qml`): `_rebuildPickerNames()` builds the dropdown's display
  strings by looping `InventoryStore.products` and skipping any product with `stock <= 0`.
  `addSelectedProduct()` then takes `productCombo.currentIndex` and indexes directly into the
  *unfiltered* `InventoryStore.products`. Whenever any product in the catalog is out of stock,
  these two arrays are no longer positionally aligned — `addSelectedProduct()` can silently add
  the wrong product. This is a live bug today, independent of this feature.
- **Edit Order** (`OrderDetailDialog.qml`): `_rebuildCatalog()` builds `catalog` (objects) and
  `catalogNames` (display strings) together in one unfiltered loop, so the indices happen to
  agree today — but only because nothing filters the list.

Any search feature filters the visible list, which breaks position-based indexing in both dialogs
regardless of the bug above. Fixing selection to be ID-based is therefore part of this feature,
not a separate follow-up.

---

## 2. Decisions (locked with Taher, 2026-07-15)

| # | Decision |
|---|---|
| UI shape | A nested **"Select product" sheet**, opened by tapping a compact trigger field where the `ComboBox` used to be. Reuses the existing `BottomSheet` pattern and the existing `SearchField` component — not an editable `ComboBox`, not an inline embedded list. |
| Out-of-stock products | Shown normally and selectable in the sheet, for **both** dialogs (standardizes on Edit Order's existing, more permissive rule; Add Order's hard-reject of 0-stock products is removed). |
| Tapping a 0-stock row | Stays tappable — does **not** silently no-op. Shows `Toast.show(qsTr("Out of stock"))`, does not add anything, sheet stays open. |
| Tapping an in-stock row | Adds the product immediately (no separate "+" confirmation step) and closes the sheet. Matches how "+" already adds without any confirmation step today — nothing is lost by collapsing select+add into one tap, since qty/price/discount remain editable in the cart list afterward either way. |
| Search fields | Substring match against `name`, `sku`, and `productId` — case-insensitive, live as you type. Extends the exact convention already used by `InventoryPage._filteredProducts()` (which matches `name + sku + category`), adding `productId`. |
| Default (empty query) view | Shows the full catalog, same as today's dropdown — search narrows the list, it doesn't gate access to it. |
| Blast radius | Only `NewOrderDialog.qml` and `OrderDetailDialog.qml`'s product pickers change. The other 11 `AppComboBox` usages app-wide (staff role, discount type, channel, etc.) are untouched. `RestockDialog.qml` has no product-picking dropdown of its own (`openFor(productId)` is called with a product already chosen elsewhere) — out of scope, not touched. |
| Backend | None. This is 100% client-side filtering over `InventoryStore.products`, which is already synced. No Firestore query or Cloud Function changes. |

---

## 3. New: `qml/helper/ProductSearch.js`

Pure helper, `.pragma library`, same convention as `BreakdownMath.js` / `OrderMath.js` — headless
unit-testable, no QML dependency.

```js
.pragma library

function filterProducts(products, query) {
    var q = (query || "").toLowerCase().trim()
    if (q.length === 0) return products.slice()
    return products.filter(function(p) {
        var hay = ((p.name || "") + " " + (p.sku || "") + " " + (p.productId || "")).toLowerCase()
        return hay.indexOf(q) >= 0
    })
}
```

Kept as a standalone function (not folded into the sheet component) so the matching rule has one
home, can be unit-tested the same way `BreakdownMath.js` is, and is trivially reusable if another
searchable product list is ever needed.

---

## 4. New: `qml/components/ProductSearchSheet.qml`

A `BottomSheet`-based component, shared by both dialogs.

**Properties / API:**
- `availableStockFor: function(product) { return product.stock }` — default falls back to raw
  stock; each dialog overrides this to its own cart-aware `_availableStock()`, so the sheet never
  needs to know about cart state, order status, or completed-order semantics.
- `signal productChosen(var product)` — emitted only when the tapped row's `availableStockFor()`
  result is `> 0`. The sheet closes itself immediately after emitting.

**Behavior:**
- `SearchField` at the top, auto-focused (keyboard shown) when the sheet opens — the primary
  action here is typing, so this removes one tap versus tapping into the field first.
- List built via `ProductSearch.filterProducts(InventoryStore.products, searchText)`, bound
  declaratively (`model: ProductSearch.filterProducts(...)`, not an imperative `.model =`
  reassignment — matches the existing documented convention for picker dropdowns in `SKILLS.md`).
- Each row shows two lines: `[SKU] Name` (primary), and `₹price · N left` (secondary, reusing the
  exact "N left" wording already used in today's picker labels). Rows where `availableStockFor()`
  is `0` get a muted/secondary visual treatment (existing `Constants.textMuted` token) so it's
  visually clear before tapping — but the row stays enabled and tappable per the decision above.
- On row tap: compute `avail = availableStockFor(product)`. If `avail <= 0`,
  `Toast.show(qsTr("Out of stock"))` and stop — no signal emitted, sheet stays open. Otherwise
  emit `productChosen(product)` and close.
- Empty-results state: `qsTr("No matches")`, same convention as `InventoryPage`.

---

## 5. Changes to `NewOrderDialog.qml`

- Remove the `RowLayout { AppComboBox { id: productCombo ... }; IconActionButton { ... } }` block.
  Replace with a single tappable trigger styled to match `AppComboBox`'s closed-state visuals
  (44dp height, 14dp radius, `Constants.cardBg`/`borderColor`) showing placeholder text
  (`qsTr("Search products to add…")`) plus a search glyph — a `QQC.AbstractButton` with a custom
  `background`/`contentItem`, the same pattern already used for the "Manage channels" link in this
  same file — that calls `productSearchSheet.open()`.
- Add `ProductSearchSheet { id: productSearchSheet }` to the dialog, wired:
  - `availableStockFor: function(p) { return dlg._availableStock(p) }` (existing function,
    unchanged signature — already takes a full product object).
  - `onProductChosen: function(p) { dlg.addSelectedProduct(p) }`.
- `addSelectedProduct()` changes signature to `addSelectedProduct(p)` — takes the chosen product
  object directly instead of resolving `productCombo.currentIndex` into
  `InventoryStore.products[idx]`. This is the fix for the positional-index bug in §1: there is no
  longer any index to misalign.
- The existing `if (p.stock <= 0) return` guard inside `addSelectedProduct()` is removed — that
  check is now `ProductSearchSheet`'s job (via `availableStockFor`), done consistently with the
  row's own displayed badge instead of a second, separately-computed raw-stock check.
- **Deleted entirely** (nothing else in the file references them, confirmed by inspection):
  `productNames` property, `_rebuildPickerNames()` function, and every call site that only existed
  to keep it fresh (the qty-change call sites in `addSelectedProduct`/`updateQty`/`removeProduct`,
  and the `onOpened` call). The sheet rebuilds its list fresh from live state every time it opens,
  so there's nothing to keep pre-computed.

---

## 6. Changes to `OrderDetailDialog.qml`

- Same trigger-button replacement as §5, replacing the
  `RowLayout { AppComboBox { id: productCombo ... }; IconActionButton { iconName: "add" ... } }`
  block.
- Add `ProductSearchSheet { id: productSearchSheet }`, wired:
  - `availableStockFor: function(p) { return dlg._availableStock(p.name) }` — thin wrapper; the
    existing `_availableStock(productName)` (with its completed-order-aware math) is unchanged and
    reused as-is.
  - `onProductChosen: function(p) { /* existing add-to-cart body from the old "+" handler,
    parameterized on p instead of dlg.catalog[idx] */ }`.
- **`catalog` is kept** — confirmed by inspection it's used outside the picker, to seed
  `products` for legacy orders that have no stored `products` array (`_seedLegacyOrder`-style
  logic around lines 256-268, referencing `catalog[0]`/`catalog[1]`). Only the picker-facing half
  of `_rebuildCatalog()` is removed: the `names.push(...)` line and the `catalogNames` property
  (confirmed to have no other consumer).
- The existing `if (avail <= 0) return` guard in the old "+" handler is removed for the same
  reason as §5 — `ProductSearchSheet` already enforces this before `productChosen` ever fires.

---

## 7. Files touched

| File | Change |
|---|---|
| `qml/helper/ProductSearch.js` | **New** — pure filter predicate |
| `qml/components/ProductSearchSheet.qml` | **New** — shared search-and-pick sheet |
| `qml/pages/NewOrderDialog.qml` | Picker replaced; `addSelectedProduct` takes a product object; `productNames`/`_rebuildPickerNames()` deleted |
| `qml/pages/OrderDetailDialog.qml` | Picker replaced; add-handler takes a product object; `catalogNames` deleted, `catalog` kept |

Not touched (confirmed out of scope): the other 11 `AppComboBox` usages, `RestockDialog.qml`,
Cloud Functions, Firestore rules/indexes.

---

## 8. Testing

- **`ProductSearch.js`**: new `tests/tst_ProductSearch.qml` covering — match by full name, partial
  name, SKU, product ID; case-insensitivity; empty query returns everything unfiltered; no-match
  returns an empty array; a query matching multiple fields across different products. Verified in
  this session the same way `BreakdownMath.js` was verified previously — executing the real
  source through Node's `vm` module (stripping only the `.pragma`/directive line), not
  hand-traced.
- **`ProductSearchSheet.qml` / dialog wiring**: no headless test coverage exists for page-level
  QML today (same situation noted in the previous `product-adjustment-reason` spec — no
  `qmltestrunner` toolchain in this session regardless). Verification is a manual on-device test
  plan, covering:
  - Search by exact SKU, partial name, and product ID; confirm the right single product surfaces
    for each.
  - Tap an in-stock result — confirm it's added to the cart, sheet closes, no "+" tap needed.
  - Tap the same product a second time — confirm it increments the existing cart line's qty
    (not a duplicate line), capped at raw stock, matching today's existing behavior.
  - Tap a 0-stock result — confirm the toast appears, nothing is added, sheet stays open.
  - Open the sheet with an empty query — confirm the full catalog shows, matching today's
    dropdown contents (minus the ordering-by-position quirk).
  - Type a query with no matches — confirm "No matches" renders.
  - Edit Order: reopen an existing order, confirm editing/removing already-added lines is
    unaffected (search only touches how NEW lines get added).
  - Edit Order: open a legacy order with no stored `products` array — confirm the
    `catalog[0]`/`catalog[1]` seeding path still works (regression check for §6's "catalog is
    kept" decision).

---

## 9. Out of scope (explicit)

- `RestockDialog.qml` — no picker of its own; not touched.
- The other 11 `AppComboBox` usages app-wide — untouched, no shared-component changes that could
  affect them (this feature introduces a new, separate component rather than modifying
  `AppComboBox`).
- Any backend/Firestore change — search is client-side only.
- A "recently used" or "most sold" quick-access shortcut in the sheet — not requested, not added.
