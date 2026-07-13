# Design — Enlarge product photo + order-line product quick-view

**Branch:** `feature/enlarge-product-photo-and-order-details`
**Status:** Approved by Taher, 2026-07-13. Not yet implemented.

## 1. Goals

1. Tapping a product's photo, anywhere it appears, opens an enlarged view of that photo.
2. Tapping a product line inside an order (New Order / Edit Order) opens a read-only
   quick-view of that product's details.

## 2. Non-goals (explicitly out of scope for v1)

- Pinch-to-zoom / pan on the enlarged photo (static fit-to-screen only).
- A true "grow from the tapped thumbnail's screen position" shared-element transition
  (using a simple scale+fade-from-center animation instead — see §6).
- Editing anything from the quick-view popup (it's read-only; "View full product" hands off
  to the existing `EditProductDialog` for any edits).
- Showing product photos in the small order-line avatars for lines with no matched product
  (no `productId`) — those rows are not interactive at all in this feature.

## 3. Trigger points (5 for the photo viewer, 2 for the quick-view)

| # | Location | Element | Opens |
|---|----------|---------|-------|
| 1 | `InventoryPage.qml` product list row | `AvatarBadge` (already shows real photo) | Photo viewer |
| 2 | `AddProductDialog.qml` | pending-photo preview `Image` | Photo viewer |
| 3 | `EditProductDialog.qml` | saved-photo `Image` | Photo viewer |
| 4 | `NewOrderDialog.qml` cart line | `AvatarBadge` (upgraded to show real photo) | Photo viewer |
| 5 | `OrderDetailDialog.qml` line item | `AvatarBadge` (upgraded to show real photo) | Photo viewer |
| 6 | `NewOrderDialog.qml` cart line | rest of the row (name/price area) | Product quick-view |
| 7 | `OrderDetailDialog.qml` line item | rest of the row (via `ListCard.onClicked`) | Product quick-view |

Rule, consistent across #4/#5 vs #6/#7: tap the avatar/photo → photo viewer; tap elsewhere on
the row → quick-view. A row with no photo isn't tappable for the photo viewer; a row with no
`productId` isn't tappable at all (no quick-view, no photo viewer, no visual affordance).

## 4. New components

### 4.1 `qml/components/PhotoViewerPopup.qml`

A centered `QQC.Popup`, hoisted once in `Main.qml` (shared across all 5 trigger points, same
pattern as the existing `photoSourceSheet`).

- `modal: true`, `parent: QQC.Overlay.overlay`, `QQC.Overlay.modal: Rectangle { color: Constants.overlay }`
- Sizing: `width: parent.width - dp(Constants.space5 * 2)` (side padding both edges),
  `height: parent.height / 3`, centered via standard `x`/`y` centering bindings.
- Content: rounded-rectangle card (`radius: Constants.radiusXl`, `color: Constants.cardBg`)
  containing an `Image` with `fillMode: Image.PreserveAspectFit`, plus a close `✕`
  (`QQC.AbstractButton`, top-right, same visual treatment as `BottomSheet`'s close button).
- Public contract: `property string photoUrl`; `function openFor(url)`.
- Closes on: close button, tap on the dimmed backdrop, Android/hardware Back.

### 4.2 `qml/pages/ProductQuickViewDialog.qml`

A read-only `BottomSheet` (reuses the existing component — title bar, close ✕, Back-button
compatible via the same `.opened`/`.close()` contract every other `BottomSheet`-based dialog
already has).

- `sheetTitle: "Product details"`, `secondaryAction: "Close"`,
  `primaryAction: "View full product"`.
- Body: photo (tappable → opens `PhotoViewerPopup`, only shown if a photo exists), name,
  "ID: <productId>  ·  SKU: <sku>" (mirrors `EditProductDialog`'s header pattern), cost price,
  selling price, tax info (`"Taxable · X%"` or `"Not taxable"`), size (only shown if non-empty).
- Public contract: `property string productId`; `function openFor(id)` (looks up
  `InventoryStore.getById(id)` and populates fields — same lookup `EditProductDialog.openFor`
  already does).
- `onPrimaryClicked`: `root.close()`, then (via `Qt.callLater`, to let this sheet finish
  closing first — avoids two `BottomSheet`s stacked) open `editProductDlg.openFor(productId, false)`.
  Rationale: keeps the Back-button chain at most 2 deep at a time in this flow, and matches
  how `InventoryPage` already opens the same dialog in view mode.

## 5. `AvatarBadge` extension (additive only)

`AvatarBadge` is used in 13+ places app-wide (staff lists, notifications, dashboard, sales
reports, etc.), many nested inside a clickable `ListCard` with its own unrelated `onClicked`.
To avoid any regression there, the change is a single new property, default off:

```qml
property bool enlargeOnTap: false
signal photoTapped()
```

When `enlargeOnTap` is `true` **and** `imageSource.length > 0`, an internal `MouseArea` (sized
to the badge) appears and emits `photoTapped()` on click, consuming the event so it doesn't
reach a parent's click handler — the same pattern already proven by the qty-stepper buttons
inside `OrderDetailDialog`'s `ListCard` not triggering that row's own click. When
`enlargeOnTap` is `false` (the default — all 13 existing call sites), no `MouseArea` is added
and behavior is byte-for-byte unchanged.

Only 3 call sites set `enlargeOnTap: true`: `InventoryPage`'s product row, `NewOrderDialog`'s
cart line, `OrderDetailDialog`'s line item.

## 6. Animation

Scale + fade from center: both new popups enter at `scale: 0.6, opacity: 0` and animate to
`scale: 1.0, opacity: 1` (`NumberAnimation`, `Constants.durMed`, `Easing.OutCubic` — matching
`BottomSheet`'s existing `enter`/`exit` `Transition` conventions), and reverse on close.

Not doing a true origin-anchored "grow from the tapped thumbnail" transition: it would require
tracking each tapped item's live screen coordinates (`mapToItem(Overlay.overlay, 0, 0)`) across
5 structurally different contexts (a plain list row, two dialog-internal photo boxes, and two
different cart-line implementations, one of which is itself already inside a `BottomSheet`),
with no existing precedent in this codebase for either technique. Taher agreed the simpler
version is the right v1 trade-off.

## 7. Back-button routing (`Main.qml`)

`_handleBack()`'s `dialogs` array must gain both new popups, positioned so Back closes the
top-most layer first:

```
[photoViewerPopup, productQuickView, photoSourceSheet, addProductDlg, editProductDlg,
 newOrderDlg, orderDetail, restockDlg, ...]
```

- `photoViewerPopup` first overall — it can appear on top of any of the other dialogs
  (including on top of `productQuickView`, e.g. tapping the photo inside the quick-view).
- `productQuickView` next — it can appear on top of `newOrderDlg` or `orderDetail`, but must
  itself close before either of those (or before `photoViewerPopup` is opened on top of it).

This mirrors the existing precedent set by `photoSourceSheet` being listed first because it
can appear on top of `addProductDlg`/`editProductDlg`. This routing convention isn't documented
in `AGENTS.md` today; Task list below includes adding a short note there once implemented.

## 8. Data / wiring notes

- `NewOrderDialog`/`OrderDetailDialog` cart-line `AvatarBadge`s currently only bind `label`
  (initials). They'll additionally bind `imageSource` via
  `InventoryStore.getById(modelData.productId).photoUrl` (guarding for a missing/removed
  product the same way existing code already does, e.g.
  `InventoryStore.findByName(model.name)` fallbacks already present in `OrderDetailDialog`).
- Quick-view and photo-viewer are both opened via signals from the dialog underneath them
  (`quickViewRequested(productId)`, `photoEnlargeRequested(photoUrl)`), routed and hoisted in
  `Main.qml` — same shape as the existing `photoPickRequested` → `photoSourceSheet.openFor(...)`
  chain.

## 9. Edge cases

| Case | Behavior |
|---|---|
| Product has no photo | Avatar/photo box shows the existing placeholder (initials/icon); not tappable for the photo viewer. |
| Order line has no `productId` (ad-hoc/unmatched line) | Row is fully non-tappable — no quick-view, no photo viewer, no visual change from today. |
| Product referenced by a completed order's line was later deleted | `InventoryStore.getById()` returns nothing; quick-view falls back to the line's own captured `name`/`price` (same graceful-degradation approach `OrderDetailDialog` already uses elsewhere) and hides fields it can't resolve (photo, SKU, tax, size) rather than showing blanks. |
| Tax-exempt product | Quick-view shows "Not taxable" instead of a 0%. |

## 10. Files touched

- New: `qml/components/PhotoViewerPopup.qml`, `qml/pages/ProductQuickViewDialog.qml`
- Modified: `qml/components/AvatarBadge.qml`, `qml/pages/InventoryPage.qml`,
  `qml/pages/AddProductDialog.qml`, `qml/pages/EditProductDialog.qml`,
  `qml/pages/NewOrderDialog.qml`, `qml/pages/OrderDetailDialog.qml`, `qml/Main.qml`
- Docs: this spec; an on-device test-plan doc in `docs/superpowers/test-plans/` (written
  during implementation, per the plan); a short `AGENTS.md` note on the Back-button routing
  convention (§7).

## 11. Testing approach

This is almost entirely view-layer (layout, animation, tap-target geometry, Back-button
routing) — not meaningfully provable by `qmltestrunner`. Verification will be an on-device
test-plan doc for Taher to walk through on a real build (per his standing instruction, no
build/run happens automatically in this session). No claim of "tested" will be made without
either a real `qmltestrunner` run (for anything that is unit-testable, e.g. `AvatarBadge`'s
new opt-in property not affecting existing usages) or Taher's own on-device pass.
