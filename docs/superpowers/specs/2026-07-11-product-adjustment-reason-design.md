# Design: Reason field for product adjustments

**Date:** 2026-07-11
**Status:** Approved (pending written-spec review)
**Scope:** one optional, free-text "Reason" field — Edit Product dialog (applies to whatever
changed in that save) and Restock dialog — surfaced in the per-product History tab and the
dashboard ActivityLog feed.

---

## 1. Problem statement

Today, every product edit and restock is recorded (`TransactionStore` per-product history,
`ActivityLog` dashboard feed), but there's no way to record *why* — was stock adjusted because of
a damaged-goods writeoff, a recount, a return-to-supplier? Was a price changed because of a
renegotiation or a data-entry fix? The History tab and Activity feed show the mechanical fact
("Stock adjusted: 40 → 35") with no context.

Two related existing patterns already solve a similar problem elsewhere: order returns and
price-adjustments already carry both a `reason` (short enum: `exchange`/`modify`/`other`) and a
`note` (free text). This feature introduces the free-text pattern for product edits/restocks,
literally labeled "Reason" per Taher's request, without adopting the enum pattern.

---

## 2. Decisions (locked with Taher, 2026-07-11)

| # | Decision |
|---|---|
| Scope | Applies to **any field edit** in the Edit Product dialog (not just stock), plus Restock. One reason per save action, applied uniformly to every field that changed in that save. |
| Field type | **Free text**, not a fixed dropdown, not the dropdown+note hybrid used by Returns. |
| Required? | **Optional**, always. |
| Branch | New branch off `main` (`feature/product-adjustment-reason`), not stacked on the still-unmerged `feature/product-size-and-tax-export`. |
| Photo changes | **Out of scope.** `InventoryStore.setPhoto()` fires immediately on pick, bypassing the batched Save/reason flow — a reason prompt there would need a different interaction pattern entirely. |
| Batches tab UI | **Not rendering reason/note there.** Data will be captured (threaded into `StockBatchStore.addBatch()`'s existing unused `note` param) but the Batches tab's compact per-row UI isn't being extended to show it in this pass. |
| `reason` storage model | **Not a persistent product field** (unlike `size`) — it's transaction metadata, passed as its own function argument alongside the existing `fields` object, not folded into it. |
| Dead signal paths (`Logic.restockProduct` / `DataModel.onRestockProduct`) | **Not touched.** Confirmed dead (never emitted, same pattern as the dead `addProduct` signal found in the previous feature). |

---

## 3. The actual data-flow (traced from code, not assumed)

Restock is a direct call: `RestockDialog.qml` → `InventoryStore.restock()`. No relay.

Edit Product is a **4-file relay**, discovered while planning this feature (not previously
documented anywhere in the codebase):

```
EditProductDialog.qml                  signal productUpdateRequested(productId, fields)
        │
        ▼
Main.qml            onProductUpdateRequested: logic.updateProduct(pid, fields)
        │                                      (emits a Logic.qml signal, not a function call)
        ▼
Logic.qml                              signal updateProduct(productId, fields)
        │
        ▼
DataModel.qml        onUpdateProduct(productId, fields):
                          - auth check (owner/admin only)
                          - InventoryStore.updateProduct(productId, fields)
                          - _reconcileBatchesForStockEdit(...)  ← FIFO ledger math, no history entry
                          - logic.productUpdated(productId)      ← no listener found; unaffected
```

`reason` must be threaded through every hop of this relay. `_reconcileBatchesForStockEdit` and
`logic.productUpdated` don't need it — confirmed by reading both; neither creates a
reason-bearing record.

---

## 4. Workstreams

### A. Threading `reason` through Edit Product's save path

**A1. `EditProductDialog.qml`**
- New field `reasonField` (`AuthTextField`), `visible: root.editMode` (not `readOnly`-toggled —
  there is no persistent value to show in view mode). Placed immediately after the edit-mode
  Supplier `ColumnLayout` closes, before `errorLabel`.
- Reset to `""` in three places: `openFor()` (dialog freshly opened), the Cancel/secondary-click
  path (`openFor(productId, false)` already re-runs `openFor`, so covered), and the View→Edit
  toggle in `onPrimaryClicked` (`if (!editMode) editMode = true` — this does **not** call
  `openFor()` again, so it needs its own explicit `reasonField.text = ""` or a stale reason from a
  previous edit session could leak into an unrelated later edit).
- `signal productUpdateRequested(string productId, var fields, string reason)` — reason added as
  its own signal argument, not inside `fields`.
- `_submit()` passes `reasonField.text.trim()` as the third argument. No validation added (reason
  is always optional — no `errs.push` case).

**A2. `Main.qml`**
- `onProductUpdateRequested: function(pid, fields, reason) { logic.updateProduct(pid, fields, reason) }`.

**A3. `Logic.qml`**
- `signal updateProduct(string productId, var fields, string reason)`.

**A4. `DataModel.qml`**
- `function onUpdateProduct(productId, fields, reason)` — forwards `reason` to
  `InventoryStore.updateProduct(productId, fields, reason)`. Auth check and
  `_reconcileBatchesForStockEdit` call are unchanged (confirmed: no reason needed in either).

**A5. `InventoryStore.qml`**
- `function updateProduct(productId, fields, reason)`. The existing `fieldChanges`/`stockChange`
  detection logic (`_maybe()`) is unchanged. After computing which fields actually changed:
  - `ActivityLog.record("product_updated", ..., subtitle + (reason ? " · " + reason : ""), ...)`
    — reason appended to the existing subtitle string (no `ActivityLog` schema change — `subtitle`
    is already one of the fields preserved by `markAllRead`/`dismiss`'s reconstruction).
  - Each `TransactionStore.recordFieldChange(productId, p.name, c.field, c.before, c.after, reason)`
    call gains the trailing `reason` argument.
  - `TransactionStore.recordStockAdjustment(productId, p.name, stockChange.before, stockChange.after, reason)`
    gains it too, when a stock change occurred.
- **Known, accepted edge case:** if a reason is typed but no field actually changed (all values
  identical to before), no `field_change`/`stock_adjustment` record is created (existing
  `_maybe()` behavior: `if (before === after) return`), so the reason is only visible in the
  generic `product_updated` ActivityLog entry, not in the per-product History tab. This is
  harmless and not being specially handled — there's nothing to explain if nothing changed.

### B. Restock's reason

**B1. `RestockDialog.qml`**
- New field `reasonField`, placed as the last field in the form, before the closing of the
  `ColumnLayout`. Reset to `""` in `openFor()`.
- `onPrimaryClicked` passes `reasonField.text.trim()` as a new argument to `InventoryStore.restock()`.

**B2. `InventoryStore.qml`**
- `function restock(productId, amount, party, unitCost, reason)`.
  - `ActivityLog.record("product_restocked", ..., subtitle + (reason ? " · " + reason : ""), ...)`.
  - `TransactionStore.recordPurchase(productId, addedQty, batchCost, changed.name, supplierId, reason)`.
  - `StockBatchStore.addBatch(productId, supplierId, addedQty, batchCost, reason)` — was previously
    always `""`; now carries the reason into the batch's existing (currently unrendered) `note`
    field.

### C. `TransactionStore.qml` — accept and store `reason`

- `recordFieldChange(productId, productName, field, before, after, reason)` — adds
  `reason: reason || ""` to the doc literal.
- `recordStockAdjustment(productId, productName, before, after, reason)` — same.
- `recordPurchase(productId, quantity, unitCost, productName, party, reason)` — same.
- No change needed to `_push()`/`forProduct()` — confirmed no field-whitelisting exists there
  (unlike `InventoryStore._clone()`, which was the load-bearing gotcha in the previous feature).

### D. Surfacing reason in the History tab (`EditProductDialog.qml` `_detailFor()`)

Currently `_detailFor()` has **no case at all** for `"stock_adjustment"` or `"field_change"` —
both fall through to a blank string. Adding:

```js
case "field_change":
    return d.reason || ""
case "stock_adjustment":
    return d.reason || ""
case "purchase":
    // existing @ cost · total logic, then append reason if present
```

The `"purchase"` case already returns `"@ %1 each · total %2"` or `""` — reason gets appended after
whatever that produces (matching the existing `" · "`-joining convention used by `"return"` and
`"price_adjust"`), not replacing it.

---

## 5. Files touched

| File | Workstream |
|---|---|
| `qml/pages/EditProductDialog.qml` | A1, D |
| `qml/Main.qml` | A2 |
| `qml/logic/Logic.qml` | A3 |
| `qml/model/DataModel.qml` | A4 |
| `qml/model/InventoryStore.qml` | A5, B2 |
| `qml/pages/RestockDialog.qml` | B1 |
| `qml/model/TransactionStore.qml` | C |

Not touched (confirmed out of scope): `InventoryStore.setPhoto()` / photo-change flow,
`StockBatchStore`'s Batches-tab rendering, the dead `Logic.restockProduct`/
`DataModel.onRestockProduct` signal path.

---

## 6. Testing

Same situation as the previous feature: no headless test coverage exists for page-level QML
(`EditProductDialog.qml`, `RestockDialog.qml`) or for `InventoryStore`/`DataModel`/`Logic` — no
`tst_*.qml` exists for any of them, and they can't run under `qmltestrunner` regardless (App
context). Unlike the previous feature, there's no pure-JS parsing logic here to extract into a
testable helper (`reason` is passed straight through as a string, no parsing/validation) — so
there's no `ImportMath.js`-style TDD opportunity this time. Verification is a manual on-device
test plan, covering:

- Edit a product's name only, with a reason. Save. Check History — the `field_change` row for
  "Name" shows the reason.
- Edit a product's stock only, with a reason. Save. Check History — the `stock_adjustment` row
  shows the reason. Check the dashboard Activity feed — the `product_updated` entry's subtitle
  includes the reason.
- Edit multiple fields (name + price + stock) in one save, with one reason. Confirm all resulting
  History rows show the same reason text (expected — not a bug).
- Edit a product with a reason typed but no actual field changes. Save. Confirm no History rows
  are created (existing `_maybe()` behavior) but the Activity feed's `product_updated` entry still
  shows the reason.
- View→Edit→type a reason→Cancel→Edit again. Confirm the reason field is blank the second time
  (not leaked from the cancelled attempt).
- Restock with a reason. Check History — the `purchase` row shows `@ cost · total · reason`.
  Check the Activity feed — the `product_restocked` subtitle includes the reason.
- Restock without a reason (leave blank). Confirm no stray " · " or empty-reason artifact appears
  anywhere.

---

## 7. Regression guardrails

- `reason` is threaded as an additional trailing argument at every hop — no existing parameter
  order changes, so no existing call site silently breaks from an argument shift.
- `ActivityLog`'s reason-bearing change is a string concatenation into an already-whitelisted
  field (`subtitle`) — no schema change, no whitelist-reconstruction risk (unlike the `_clone()`
  gotcha from the previous feature, which doesn't apply here since `TransactionStore` has no such
  whitelist).
- `_reconcileBatchesForStockEdit` and `logic.productUpdated` are explicitly confirmed unaffected —
  not modified.
