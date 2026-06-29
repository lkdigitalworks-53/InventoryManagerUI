# Supplier filter must include stamped price/discount adjustments

**Date:** 2026-06-25
**Status:** Approved
**Author:** debugging session (systematic-debugging → brainstorming)

## Problem

On the Analysis page, filtering a money report (Revenue / Profit) by **supplier**
drops every `price_adjust` event (a price modify or a discount edit) from the
calculation — so a supplier's discounts and price changes vanish from the hero,
the chart, the by-supplier / by-category cards, and the Totals block, for every
period (Day / Week / Month / Year).

### Root cause (confirmed against live Firestore + headless repro)

Both realised-money aggregation paths in `qml/helper/RealisedMath.js` skip
`price_adjust` entirely when a supplier filter is active:

- `byDimension` (line 62-70): `if (!(scope && scope.supplierId)) _accumulatePriceAdjust(...); continue`
- `bucketWalk` (line 296-299): `if (!supplierId) bins[idx] += e.total; continue`

The guard predates supplier stamping. It assumed a price_adjust had no reliable
per-supplier lineage (attribution was re-derived from the live order, which a
later return could empty → dumped into "Unknown"). That was fixed by stamping
`supplierSlices` on the event AT WRITE TIME (see `tst_PriceAdjustSupplierStamp`),
but the skip-guard was never updated to USE them.

Live data proves the lineage exists:

```
tx-pa-…238  discount 0->5 on Rida  total:-5  supplierSlices:[{key:"SUP-001", amount:-5}]
tx-pa-…705  price 20->18           total:-2  supplierSlices:[{key:"SUP-001", amount:-2}]
```

Headless repro under `scope.supplierId="SUP-001"`:

| Scope | net | discount |
|-------|-----|----------|
| Filter SUP-001 | **0** | **0** ← bug |
| No filter | -7 | 5 ← correct |

`byDimension("supplierId")` returns `[]` under the filter — the stamped slices
are never read.

## Solution

Under a supplier filter, attribute a `price_adjust` by the sum of its **stamped
`supplierSlices` whose `key === scope.supplierId`**. Skip only when no slice
matches (contributes 0 — no "Unknown" leakage). Without a filter, behaviour is
byte-identical to today.

### Why stamped slices ONLY (no live-order re-derivation)

`bucketWalk` receives only `categoryOf` in its `lookups` (InventoryStore.realisedBucketWalk),
not `orderLookup`, while `byDimension` has both. To keep the reconciliation
invariant `totals == Σ bucketWalk` EXACT under a supplier filter, both paths must
compute the same amount. Restricting to stamped slices needs no `orderLookup`, so
both stay identical. This also matches the stamping design's intent: stop
depending on the mutable live order. Fresh-data MVP → no un-stamped legacy
adjusts to worry about.

### Shared helper (one place, used by both paths)

```js
// Supplier-attributable portion of a price_adjust, from its STAMPED slices.
// "" / no match → 0. Stamped-only so byDimension and bucketWalk agree exactly.
function _priceAdjustSupplierAmount(e, supplierId) {
    var slices = (e && Array.isArray(e.supplierSlices)) ? e.supplierSlices : null
    if (!slices || slices.length === 0) return 0
    var amt = 0
    for (var i = 0; i < slices.length; ++i)
        if (slices[i].key === supplierId) amt += (slices[i].amount || 0)
    return amt
}
```

### byDimension change (line 62-70)

```js
if (e.kind === "price_adjust") {
    if (scope && scope.supplierId) {
        var amt = _priceAdjustSupplierAmount(e, scope.supplierId)
        if (amt !== 0) {
            // Bucket the supplier-matched delta into this field's key. For
            // supplierId that's the filtered supplier; category uses the line's
            // product category (line adjusts carry productId).
            var key = (field === "supplierId") ? scope.supplierId
                    : (field === "category")   ? (categoryOf(e.productId) || "(uncategorised)")
                    : (field === "channel")    ? (e.orderChannel || "")
                    : (field === "staffId")    ? (e.staffId || "")
                    :                            (e.productId || "")
            if (!out[key]) out[key] = _emptyRow()
            out[key].revenue += amt
            out[key].profit  += amt
            if (e.reason === "discount") out[key].discount += -amt
        }
    } else {
        _accumulatePriceAdjust(out, e, field, scope, categoryOf, orderLookup)
    }
    continue
}
```

`totals()` correctness: it sums all keys of `byDimension("category")`; under the
filter each price_adjust adds its supplier-matched `amt` to some category key, so
the total = Σ amt = the supplier's true delta, regardless of key.

### bucketWalk change (line 296-299)

```js
if (e.kind === "price_adjust") {
    bins[idx] += supplierId ? _priceAdjustSupplierAmount(e, supplierId)
                            : (e.total || 0)
    continue
}
```

## Scope

- `qml/helper/RealisedMath.js`: add `_priceAdjustSupplierAmount`; edit the two
  price_adjust branches above. No other files. (`InventoryStore` adapters,
  SalesPage, exports all flow through these two functions.)

## Testing

Extend `tst_PriceAdjustSupplierStamp` (or a sibling) with the live-data case:
two SUP-001 price_adjusts (-5 discount, -2 modify) under `scope.supplierId="SUP-001"`:
- `totals` → net -7, discount 5
- `byDimension("supplierId")` → `{ "SUP-001": {revenue:-7, discount:5} }`
- `bucketWalk("net", Month)` sum → -7
- a filter for a DIFFERENT supplier → 0 (no leakage)
- reconciliation: `totals.net == Σ bucketWalk` under the filter

## Out of scope

- Order-wide price_adjusts (no `productId`) under a *by-category* card with a
  supplier filter land their matched amount in "(uncategorised)" — totals stay
  correct (sum is key-independent); the rare card-key imperfection is left as a
  noted limitation, not built now.
- No change to write-time stamping or to the no-filter behaviour.
