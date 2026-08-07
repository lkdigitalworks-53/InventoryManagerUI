# Checkpoint — Fix `OrdersStore._normalizeOrder` consumption-source bug (C1)

**Session:** Claude (via LKDigitalWorks session), 2026-08-08
**Trigger:** Taher reported `qmltestrunner` failures on `tests/tst_OrdersStore_normalization.qml`
(all 4 tests in the suite), invoked via `/superpowers:systematic-debugging`.
**Source branch checked out:** `review/async-write-sequencing-audit` (docs-only review branch,
tip `59d3a4c`).
**Working branch:** `fix/ordersstore-normalize-consumption-source`, branched off
`review/async-write-sequencing-audit` — kept separate so the review branch stays docs-only, per
the standing "always create a new branch before implementing" rule. Flagged to Taher as a
deliberate deviation from "checkout branch X" being read as "commit on X" (see chat response).

---

## Phase 1 — Root cause investigation (complete)

**Reported error (all 4 tests, identical):**
```
Uncaught exception: Cannot read property 'consumption' of null
```

**Reproduced by static trace (no qmltestrunner in this sandbox — see Verification section):**
`tests/tst_OrdersStore_normalization.qml`'s `_rawNewOrder()` fixture builds a product line with
`productId: "SKU-1"` and never seeds `InventoryStore` with a matching product. Every one of the
4 tests calls `OrdersStore._normalizeOrder(_rawNewOrder())` (directly or via a second pass).

**Traced to source (`qml/model/OrdersStore.qml:302-343`, `_normalizeOrder`):**
```js
var inv = lp.productId ? InventoryStore.getById(lp.productId) : null;   // line 308
...
if (Array.isArray(inv.consumption)) {                                    // line 320 — BUG
    for (var ci = 0; ci < inv.consumption.length; ++ci) {                // line 321 — BUG
        var c = inv.consumption[ci];                                     // line 322 — BUG
        ...
```
- `inv` = `InventoryStore.getById(lp.productId)`, i.e. the **product/inventory record** — resolved
  two lines above purely for tax fallback (`taxable`/`taxPercent`).
- `InventoryStore.qml` has **zero** occurrences of `consumption` anywhere in the file (confirmed by
  grep) — no product record has ever carried that field.
- `consumption` is instead stamped directly onto an **order line** (`line.consumption = ...`) by
  `DataModel.qml` (`_tryCompleteOrder`/its return-sibling, lines ~477-545) after FIFO batch
  consumption runs. That order line is exactly `lp` in `_normalizeOrder`, not `inv`.
- In the test fixture, `InventoryStore.getById("SKU-1")` returns `null` (no seeded product) →
  `inv` is `null` → `inv.consumption` throws `TypeError`, exactly matching the reported message,
  before any test reaches its own assertions.
- Independent of the crash: even when `inv` *is* a real product, `Array.isArray(inv.consumption)`
  is always `false` (product records never have this field), so `consClone` silently ends up `[]`
  on every single order normalization — meaning FIFO lineage (`batchId`, `supplierId`,
  `qtyConsumed`, `unitCost`) needed for COGS/revenue-by-supplier reporting is wiped on every clone,
  not just when a product happens to be missing.

**Recent-changes check:** this is a pre-existing, already-diagnosed finding. It matches
**C1** in `docs/superpowers/specs/2026-08-06-async-write-sequencing-code-review.md` verbatim
(same file, same two failure modes, same fix). That review doc traces it to commit `b38c392`
("feat(orders): enhance order normalization…"), which consolidated two near-duplicate
`_normalizeOrder` functions and swapped the variable during the merge. Cross-checked directly
against current file content on this branch — finding still applies unchanged.

**Single hypothesis:** the three `inv.consumption` reads at lines 320-322 should be `lp.consumption`
(the raw order line being normalized, not the resolved product record). No other change needed —
confirmed by reading `_normalizeOrder` end-to-end and comparing against how `lp` fields are used
identically elsewhere in the same function (e.g. `lp.productId`, `lp.taxable`).

## Phase 2 — Pattern analysis (complete)

- Working reference: every other field in the same loop (`productId`, `name`, `price`, `quantity`,
  `taxable`, `taxPercent`, discount fields) reads off `lp` (the raw line being normalized), never
  off `inv`, except where `inv` is an explicit, intentional fallback (`taxable`/`taxPercent` when
  `lp` doesn't carry them). `consumption` has no such fallback semantics documented anywhere —
  it's purely a pass-through/deep-copy of what's already on the line.
- No other caller or test in the repo relies on `inv.consumption` — grepped `qml/` and `tests/` for
  `.consumption` usage; every other site (`DataModel.qml`, `StockBatchStore.qml`) treats it as an
  order-line field.

## Phase 3 — Hypothesis test

Fix: change all three `inv.consumption` occurrences (lines 320-322) to `lp.consumption`. Minimal,
single-variable change — no other lines touched.

## Phase 4 — Implementation status

- [x] Root cause confirmed via direct code read (not just trusting the prior review doc)
- [x] Fix applied: `inv.consumption` → `lp.consumption` (3 occurrences, `OrdersStore.qml:320-322`)
- [x] Diff reviewed: exactly 3 lines changed, no other `inv.consumption` references remain anywhere
      in `qml/` or `tests/` (grepped). Checked all 7 call sites of `_normalizeOrder` — none rely on
      the old (buggy) always-empty-`consumption` behavior. Checked the 11 other test files that
      reference `consumption` (`tst_RealisedProfitRepro.qml`, `tst_OrderMath.qml`, etc.) — none call
      `_normalizeOrder` directly, so none are affected by this change.
- [ ] **On-device `qmltestrunner` run — NOT done.** No Qt/QML toolchain in this sandbox (checked:
      no `qmltestrunner`/`qmlscene` binary; only incidental Qt5 libs present, project needs Qt6).
      This matches the test file's own header comment and every prior session's caveat. Static
      trace of all 4 test bodies against the fixed code (below) is the best verification available
      here — **Taher should run `qmltestrunner tests/tst_OrdersStore_normalization.qml` locally
      before merge.**

### Static trace of each test against the fix

1. `test_normalizeOrder_adds_adjustments_even_when_the_raw_object_lacks_it` — no longer throws
   (loop body only runs if `lp.consumption` is an array; `_rawNewOrder()`'s line has no
   `consumption` field, so `Array.isArray(undefined)` is `false`, loop skipped, `consClone: []`).
   Function proceeds to build `adjustments: []` as before. **Expected: pass.**
2. `test_normalizeOrder_preserves_updatedAt_sent_at_creation` — same path, `updatedAt` untouched by
   this fix. **Expected: pass.**
3. `test_normalizeOrder_is_idempotent_key_shape` — second pass normalizes `once` (which now has
   `consumption: []` per product line from pass 1). `Array.isArray([])` is `true`, loop runs zero
   iterations, `consClone: []` again — key set unchanged across passes. **Expected: pass.**
4. `test_normalizeOrder_on_a_raw_object_missing_adjustments_matches_shape_of_one_that_has_it` —
   both fixtures share the same product-line shape (no `consumption` field); both take the
   `Array.isArray(undefined) === false` branch identically. **Expected: pass.**

## Next action

Commit fix + this checkpoint on `fix/ordersstore-normalize-consumption-source`, push once Taher
confirms, open PR against `review/async-write-sequencing-audit` (not `main`) since that's the
branch this bug was found on and the branch containing the rest of the async-write-sequencing work.
