# Completed-order edits must keep surviving units' tax at the booked rate

**Date:** 2026-06-26
**Status:** Approved
**Author:** debugging session (audit → brainstorming)

## Problem

Flow: add product (tax 0%) → complete order → edit product to add 10% tax →
edit the completed order, remove the line and re-add it from the product picker
→ the order **total now shows tax included** → complete. But the **reports**
(hero + exports) show **no tax**.

### Root cause (confirmed, reproduced headlessly)

Tax is not a tracked dimension on a *surviving* order line, so two things
diverge:

1. **`OrderAdjust.diffLines` ignores tax** (`qml/helper/OrderAdjust.js:36`):
   `changed = (oldQty !== newQty) || (oldPrice !== newPrice)`. Remove + re-add
   the same product at the same qty/price → diff is EMPTY → `_tryAdjustOrder`
   books no return and no added-units sale event. The immutable sale event keeps
   its originally-booked `tax: 0`. Reports read the stamped event → tax 0.
   (Per-line discount has the same blind spot, compensated by a separate scan
   `_lineDiscAmt`; tax has no such path.)

2. **The order total re-taxes surviving units**
   (`qml/model/OrdersStore.computeOrderTotals:237`): tax is computed from each
   line's STORED `taxable`/`taxPercent`. The product picker re-add seeds those
   from the product's CURRENT rate (`OrderDetailDialog.qml:462-464`, catalog
   built from InventoryStore at `:126-127`). So `o.total`/`o.tax` include tax the
   ledger never booked.

### Accounting norm (decides the fix direction)

Tax is fixed at the **time of supply** (GAAP/IFRS revenue recognition; GST/VAT
tax-point). A later product tax-rate change is **prospective**: it applies only
to NEW supply (units added after the change, or a new order), never retroactively
to units already supplied on a completed order.

Therefore: **the ledger is correct (tax 0); the on-screen/persisted total is the
bug** for retroactively taxing already-supplied units. The codebase already
encodes this rule for ADDED units (`DataModel._tryAdjustOrder:592-604` — added
units get current tax on their own sale event; originals stay immutable). The
defect is only that the live total doesn't follow the same rule for surviving
units.

## Solution (Approach A — seed surviving completed-line tax from the booked value)

For a **completed** order, a surviving line's `taxable`/`taxPercent` must reflect
what was BOOKED, not the product's current rate. Pending orders keep refreshing
from the catalog (not yet supplied — correct).

### Changes (all in `qml/pages/OrderDetailDialog.qml`)

1. **Capture booked tax in the original-line snapshot.** `_originalLines`
   (`:171-177`) currently drops tax. Add `taxable`/`taxPercent` (from the
   persisted line) to each snapshot entry so the booked rate is available for
   re-seeding.

2. **Picker re-add (`:462-464`).** When `_orderStatus === "completed"` and the
   product matches an original booked line (`_findOriginalLine`), append with the
   booked line's `taxable`/`taxPercent` instead of the catalog's current rate.
   Non-completed orders, and products with NO original line (genuinely new units
   on a completed order), keep the catalog/current rate — those are new supply
   and correctly taxed at today's rate.

3. **Order-load seed (`:202-219`).** Already prefers the persisted line's stored
   tax when present (`lp.taxable !== undefined`), falling back to inventory. Verify
   this holds — if a previously-saved line already had its tax corrupted to the
   current rate, re-loading shows the persisted (wrong) value. Acceptable: the
   fix prevents NEW corruption at the picker; existing rows reflect what was
   saved. (Fresh-data MVP → no legacy corrupted rows.)

### Net effect

Re-adding a product on a completed order keeps the line at its booked rate →
`computeOrderTotals` yields the booked tax → total matches the ledger and the
report. Genuinely added units still get current tax via the existing
`_tryAdjustOrder` path. No change to the (correct) ledger code.

## Testing

Headless test (extends the OrderAdjust / OrderMath suites):
- Completed order, line booked at tax 0%; product later set to 10%; re-add the
  line at same qty/price → `OrdersStore.computeOrderTotals` over the
  booked-seeded line yields `tax == 0` (total matches ledger).
- A genuinely ADDED unit (qty up by 1) on the same order → that unit's sale event
  books current 10% tax (unchanged `_tryAdjustOrder` behavior), originals stay 0.
- Confirm `diffLines` still reports "no change" for the pure re-add — i.e. the fix
  works WITHOUT making diffLines tax-aware (the total is now ledger-consistent so
  there is nothing to adjust).

## Flagged follow-up (NOT in this change) — Approach B

`OrderAdjust.diffLines` silently drops EVERY surviving-line attribute change
except qty and price. Discount got a band-aid (`_lineDiscAmt` scan); tax is the
second casualty this exposed. A cleaner long-term fix is to compare a full line
fingerprint and route each changed dimension through the adjust/ledger path. This
is a larger refactor with its own correctness surface (it would also re-open the
"should a surviving-unit tax change ever book a ledger event?" question — and per
the time-of-supply norm, it should NOT). Deferred deliberately; flagged so the
gap is documented, not forgotten.

## Out of scope

- No retroactive re-taxing of booked units (rejected on accounting grounds).
- No change to `_tryAdjustOrder` added-units tax (already correct).
- No `diffLines` signature change (Approach B, flagged above).
