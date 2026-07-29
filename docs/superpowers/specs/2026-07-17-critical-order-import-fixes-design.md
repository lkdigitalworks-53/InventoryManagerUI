# Design: 3 Critical fixes on `fix/order-import-stock-and-holistic-bugs`

**Date:** 2026-07-17
**Branch:** `fix/order-import-stock-and-holistic-bugs` (continuing on this branch, not a new one —
these are corrections to work already in flight, not a new feature)
**Scope:** Deliberately limited to the 3 Critical findings from this session's rescue review.
The 8 Important/Minor findings from that same review, and the 8 items still open from the
2026-07-12 review, are explicitly out of scope here — Taher's call, tracked in `CHECKPOINT.md`
for a later pass.
**Status:** Design approved by Taher in chat. Not yet implemented.

## Context

This branch went through a 2026-07-12 review → fix → 2026-07-14 rebuild-on-Gateway → this
session's rescue review. The rescue review found 3 new, concrete, verified bugs sitting in the
functionality this branch exists to deliver. All three are described below with the evidence that
grounds them — this isn't a re-statement of suspicion, each was either executed (Node repro) or
read directly against current code this session.

## Fix 1 — Cross-order stock oversell within one import batch

**Problem.** `ImportPreviewDialog._validateOrderRows` (line ~507) builds `idToProduct` once as a
static snapshot of `InventoryStore.products` and never updates it while looping over every
order/row in the import file. `ImportMath.checkOrderLineStock` — itself correct — gets called
once per row against that same static `inv.stock` value. Proven via a standalone Node
re-implementation this session: three independent
`checkOrderLineStock(null, /*stock*/10, /*qty*/5, /*isCompleting*/true)` calls (simulating three
different completed orders each wanting 5 units of a 10-unit-stock product) all return
`reject:false` — 15 accepted against 10 in stock. `completeImportedOrder` (DataModel.qml:440)
then really does deduct the full requested quantity unconditionally
(`InventoryStore.deductStock(invP.productId, qqty)`), driving that product's stock negative —
confirmed by reading that function directly, not assumed. Taher's call: fix the preview's
accuracy (keep `completeImportedOrder`'s existing "complete + report shortfall" apply-time
behavior as-is — not touching that), and make the oversell **visible** to the user rather than
silently resolved.

**Design.** New pure function in `qml/helper/ImportMath.js`:

```
checkOrderLineStockAcrossBatch(existingLineQty, fullStock, remainingStock, importedQty, isCompleting)
  → { qty, reject, issue, crossOrder, netNew }
```

- Delegates the actual accept/reject/clamp decision to the existing, already-verified
  `checkOrderLineStock(existingLineQty, remainingStock, importedQty, isCompleting)` — that
  function itself is untouched.
- Only when that call rejects or clamps, makes a second call to the same function against
  `fullStock` (the product's real, un-decremented stock) purely to classify *why* it failed:
  - `crossOrder: true` — would have fit against the product's actual stock; failed only because
    earlier rows in this same import already claimed it.
  - `crossOrder: false` — would have failed regardless; today's plain "insufficient stock" case.
- `netNew` — the actual new draw on the shared pool for this row, used by the caller to decrement
  the running tally:
  - Non-completing row → `0` (matches the existing rule that stock isn't reserved until
    completion — this is why non-completing rows can't wrongly deplete the tally for a later
    completing row in the same batch).
  - New line, accepted → `qty`.
  - New line, rejected → `0`.
  - Existing line, increase accepted → `qty - existingLineQty` (the delta only — the original
    quantity was already deducted when that order first completed, so it isn't new demand).
  - Existing line, increase clamped back → `0` (no net change applied).
  - Existing line, decrease or unchanged → the (non-positive) delta, so a decrease actually
    *frees up* pool for later rows in the same batch, which is correct — it does.

**Caller change** (`_validateOrderRows`): add `var remainingStock = {}`, lazily seeded from
`idToProduct[pid].stock` on first touch per product. Rows are processed in the same order they
already are today (file/row order, matching what `_apply()` will later replay), so the running
tally's resolution order matches what `completeImportedOrder` will actually do when applied — no
new tie-break rule is being invented, this just makes the preview stop lying about the existing
one. After the call, `remainingStock[pid] -= result.netNew`. Warning message
(`warns.push(...)`) gets the extra clause only when `result.crossOrder` is true:

> `"ProductX: insufficient stock — N left after earlier rows in this import — line skipped"`

vs. today's unchanged plain message for a genuine total-stock shortfall.

**Alternatives considered, not taken:**
- *No auto-resolve on batch contention* (flag every competing row, force manual resolution) —
  rejected as a bigger behavioral change than "make the preview accurate"; also just moves the
  same file-order tie-break question one level down instead of answering it.
- *Batch-level disclaimer only* (leave every row's individual result untouched, bolt on one
  summary note) — rejected as not actually fixing the per-row inaccuracy, just annotating it.

**Testing.** New cases in `tests/tst_ImportMath.qml` (Node-verified the same way the existing
suite was this session) for `checkOrderLineStockAcrossBatch`: fits-alone-but-not-remaining
(reject and clamp variants), doesn't-fit-even-at-full-stock, decrease-frees-up-pool,
non-completing-never-decrements. Plus one `_validateOrderRows`-level scenario test (3 completed
orders, same product, cumulative oversell) if the existing test scaffolding for that function
supports it without disproportionate setup — to be confirmed during implementation, not blocking
this design.

## Fix 2 — `AddStaffDialog.qml` missing double-submit guard

**Problem.** `onPrimaryClicked: trySubmit()` (line 38) and `trySubmit()` itself (line 231) have
no re-entry guard, unlike `AddProductDialog` (`if (!busy) trySubmit()`) and `RestockDialog`
(`if (busy) return`) — both edited by this same branch. Staff-add's id-mint used to be
synchronous/instant; it's now a real network round trip, so the double-tap window that used to be
effectively zero is now real. Read directly this session, not inferred.

**Design.** Mirror `AddProductDialog`'s exact pattern:
`onPrimaryClicked: { if (!busy) trySubmit() }`. One-line change, no new state, no design
alternatives worth comparing — this is restoring parity with an established, working pattern
already proven elsewhere in the same file set.

## Fix 3 — Dropped truthy-guard from the productId-only refactor

**Problem.** `DataModel._findLine(lines, productId)` (line 748) and
`OrderDetailDialog._findOriginalLine(productId)` (line 97) both lost the `productId &&` guard
their two-argument (id-or-name) predecessors had, when the productId-only cleanup collapsed them
to one argument. If `productId` is falsy — a legacy, pre-productId order line — and another line
in the same array is *also* missing productId, `undefined === undefined` spuriously matches the
wrong line, misattributing FIFO/tax data during an order adjustment or reversal. Same shape
(harmless in practice today) also present in `NewOrderDialog._inCartQty` and
`ImportMath.findOrderLineByProductId`.

**Design.** Restore the guard in all four:
```js
function _findLine(lines, productId) {
    if (!lines || !productId) return null
    for (var i = 0; i < lines.length; ++i) {
        if (lines[i].productId === productId) return lines[i]
    }
    return null
}
```
(early-return form, not the inline `productId &&` form the old two-arg version used — cleaner
now that there's no second condition to combine it with). Same shape for `_findOriginalLine`,
`_inCartQty`, `findOrderLineByProductId`. No behavior change for any currently-reachable call
site except the two real ones; the other two are hardening against future callers, not live bug
fixes — worth doing for consistency since it's the same one-line change in the same pattern, not
worth a separate discussion.

## Files touched
`qml/helper/ImportMath.js`, `qml/pages/ImportPreviewDialog.qml`, `qml/pages/AddStaffDialog.qml`,
`qml/model/DataModel.qml`, `qml/pages/OrderDetailDialog.qml`, `qml/pages/NewOrderDialog.qml`,
`tests/tst_ImportMath.qml`.

## Explicitly out of scope (tracked elsewhere, not forgotten)
Everything in `CHECKPOINT.md`'s "Important"/"Minor" sections from this session's review, and the
8 items still open from the 2026-07-12 review. None of this spec touches them.

## Commit sequencing
Three separate commits, not one — these are 3 unrelated bugs sharing one spec because Taher
scoped the *spec* that way, not because they're one task:
1. `fix(import): track cumulative stock across orders in the same import batch`
2. `fix(staff): guard AddStaffDialog against double-submit`
3. `fix(orders): restore productId falsy-guard dropped by the productId-only refactor`

Each gets shown for review before its own commit, per the established one-commit-per-task rule —
not batched into a single confirmation.

## Residual risk
`qmltestrunner` verification of any of this still has to happen on Taher's machine — this session
can only Node-verify the pure-function layer (`ImportMath.js`), not the QML wiring
(`_validateOrderRows`'s actual integration, the two dialogs' busy-guard behavior on a real
device). Flagging this rather than implying the design is proven correct end-to-end.
