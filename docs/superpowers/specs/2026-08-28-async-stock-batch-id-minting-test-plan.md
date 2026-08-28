# Test plan — feature/async-stock-batch-id-minting

**Covers:** `StockBatchStore._nextBatchId()` → `nextBatchId(callback)` (real, year-scoped Firestore
counter, `counters/stockBatches-<year>`), `addBatch()` converted to async, new `addBatchWithId()` for
the bulk-import path, and `InventoryStore.upsertMany`'s new third id-range reservation
(`neededBatchIds`, via the extracted `_scanUpsertManyNeeds` helper). Full design:
`docs/superpowers/specs/2026-08-27-async-stock-batch-id-minting-design.md`. Debugging notes from the
first CI round (2 failures, both root-caused and fixed): SKILLS Skill 48.

**Read this first:** `mintCounterValue`/`mintCounterBatch` themselves are proven — Products/Orders/
Staff/Suppliers have used them since `docs/superpowers/specs/2026-07-14-test-plan.md` (Section 3
there covers the same class of bug this branch closes for stock batches: id reuse after delete,
concurrent-mint collisions, fresh-tenant first mint). What's new and unverified against a real device
here is narrower: (1) batch ids specifically, with their **year-scoped** counter (nothing else in this
app resets a counter annually — untested territory), and (2) the four call sites that create a batch
now have a genuine network round-trip where they used to be instant, and **three of those four never
check whether the mint succeeded** (see Section 1.2 and N4 below — this is the one finding in this
plan worth prioritizing over the others).

---

## 1. Unit tests

### 1.1 Already covered (automated, in `tests/` and `test/e2e/`)

`tests/tst_StockBatchStore.qml` (18 tests) — pure logic and synchronous guard clauses: id-prefix/
seed-max helpers, `_buildBatchDoc`'s field defaults, `addBatchWithId`'s guard clauses and local-array
update, `addBatch`/`topUpOldest`'s guard clauses. All 18 passed in the first CI run.

`tests/tst_InventoryStore_upsertMany.qml` (16 tests) — the correctness-critical `_scanUpsertManyNeeds`
pre-scan: `neededProductIds`/`neededBatchIds` counted correctly across new/rename/skip/overwrite rows,
zero-stock vs. positive-stock gating, non-numeric stock treated as zero, new-supplier-name collection.
One test's own expected value was wrong on the first CI run (fixed, see Skill 48) — the other 15
passed first try.

`test/e2e/tst_StockBatchStoreE2E.qml` (4 tests, needs a real Firestore/Cloud Functions emulator —
**not run in either CI round so far**): `addBatch` creates a real doc via the async mint,
`addBatchWithId` creates a doc with a pre-reserved id (skips the mint round-trip), a duplicate create
for the same batch id produces a real CAS conflict, and — the actual point of this branch —
`nextBatchId` mints two sequential, non-colliding ids via the real counter. This is the only automated
coverage of the counter actually working against real Firestore; run it before trusting the design.

### 1.2 Gap — not covered by any committed test, recommend closing before/soon after this merges

- **A failed mint is silently swallowed at 3 of the 4 call sites.** `addBatch()` calls back with
  `null` and logs a `console.warn` if `nextBatchId` fails — but `InventoryStore.addProduct()`'s
  "Initial stock" call, `InventoryStore.restock()`'s call, and five of six `topUpOldest()` call sites
  in `DataModel.qml` pass no callback at all (fire-and-forget, same as before this branch — see the
  design doc). Before this branch, a failure here was essentially impossible (a local array scan
  can't fail); now it's a real network call that can. No automated test exercises "mint fails, what
  does the caller do" for any of these — because there's no mock layer for `FirebaseService`'s XHR
  calls anywhere in this codebase (established gap, not new to this branch). **This is what N4 below
  is for — it needs a human, on a device, in airplane mode.**
- No test (unit or E2E) exercises the year-boundary behavior of the new per-year counter
  (`counters/stockBatches-<year>`) — not practically automatable, flagged in the design doc as an
  accepted, extremely-low-probability limitation. Not in this plan's on-device scope either (see
  Section 5).

---

## 2. Regression tests

Nothing in this list should have changed behavior — these are either untouched code paths, or call
sites that pass straight through the same guard clauses/parameters as before.

- [ ] Restock or return against a product whose FIFO batches are intact (the overwhelming majority
      case) still goes through `StockBatchStore.restoreFifo`'s **existing**-batch branch
      (`Gateway.recordDelta`) — untouched by this branch, no network dependency added, should feel
      exactly as fast as before.
- [ ] A normal sale's FIFO consumption (`consumeFifo`) — not touched by this branch at all.
- [ ] Add Product / Restock / Add Staff / Add Supplier / New Order's own id-minting (`PRD-`/`STF-`/
      `SUP-`/`ORD-` prefixes) — untouched, still going through the same `mintCounterValue` path as
      before this branch.
- [ ] Bulk product import: existing-row overwrite, rename-on-conflict, and the duplicate-row
      collapsing behavior from `docs/superpowers/specs/2026-07-14-test-plan.md` — all untouched;
      this branch only added a third reservation call *alongside* the existing product/supplier ones,
      same chained-callback shape.
- [ ] Analysis → **Value** view (`Σ open batch qty × unit cost`) and **Current** stock view — read
      `StockBatchStore.batches`, so confirm they still total correctly once a newly-minted batch
      lands (see H5/H6 below for the timing angle specifically).
- [ ] Product/Order list and detail views, dashboard KPIs, exports — this branch touched creation
      paths only, not display.
- [ ] RBAC gates on the affected dialogs (Add Product, Restock, Import) — unchanged.

---

## 3. On-device tests

### 3.1 Happy path

| # | Flow | Steps | Expect |
|---|---|---|---|
| H1 | Add product with initial stock | Add Product → fill required fields, Stock > 0 → Save | Product appears immediately with its usual `PRD-0xx` id; **within a few seconds**, a matching FIFO batch (`BAT-<year>-0xx`) appears in Inventory → that product's batch/lineage view |
| H2 | Add product with zero stock | Add Product → Stock = 0 → Save | Product appears; **no** batch is created for it (confirm via the batch/lineage view — empty, not an error) |
| H3 | Restock an existing product | Product detail → Restock → qty, optional supplier/reason → Confirm | Stock increases immediately; a new `BAT-<year>-0xx` batch appears shortly after, cost/qty correct |
| H4 | Sell the just-restocked stock | Complete a sale consuming the batch from H1 or H3 | FIFO consumption pulls correctly from the newly-minted batch — confirms the batch's shape (`qtyRemaining`, `unitCost`) is right, not just that a doc exists |
| H5 | Return against an intact batch | Complete an order, then return part of it (product's batches untouched since the sale) | Return succeeds, stock/ledger update — this is the **normal** path (existing-batch `recordDelta`), should feel identical to before this branch |
| H6 | Fresh tenant, first-ever batch mint | A tenant/account with zero existing products or batches — Add Product with stock > 0 | Gets `BAT-<year>-001`, not a crash, not a collision — exercises "counter doc doesn't exist yet" for `counters/stockBatches-<year>` specifically (analogous to E3 in `2026-07-14-test-plan.md`, but for the new per-year counter, which has never been exercised this way before) |
| H7 | Bulk import — new rows, mixed stock | Import 8-10 new product rows, some with stock > 0, some with 0 | Every row gets a product id as usual; **only** the positive-stock rows get a companion batch, all with sequential `BAT-<year>-0xx` ids and no gaps |
| H8 | Bulk import — new rows, all zero stock | Import 5 new rows, all Stock = 0 | Import completes normally; confirm (via network inspection if available, or just via the batch/lineage view showing nothing new) that this does **not** reserve any batch ids at all — `neededBatchIds` should be 0, not a wasted reservation |
| H9 | Bulk import spanning two batches of work | Import once, then import again shortly after (second file, more new stock rows) | Second import's batch ids continue from where the first left off (`BAT-<year>-0xx` sequential across both imports, not restarting or colliding) |

### 3.2 Negative tests

| # | Scenario | Expect |
|---|---|---|
| N1 | Airplane mode ON, then Add Product with stock > 0 | Product creation itself fails gracefully as before (unrelated to this branch) — not applicable if product creation already requires network regardless; if it doesn't, confirm the product still saves and note whether the batch silently never appears (expected per the gap in 1.2 — see N4) |
| N2 | Airplane mode ON, then Restock an existing product | Stock number and any local UI feedback update as usual; **check specifically** whether the app tells you the batch/ledger write failed, or stays silent — record which (this is the exact gap in Section 1.2) |
| N3 | Toggle airplane mode ON right *after* tapping Save/Confirm on H1 or H3 (mid-request, not before) | Same as N1/N2 — covers "request in flight when connectivity drops," not just "no connectivity at all" |
| N4 | **The important one.** Airplane mode ON, Add Product with stock > 0, wait, then turn connectivity back ON. | Does the batch eventually appear once connectivity returns, or is it permanently lost? `addBatch`'s mint failure is a one-shot attempt with no retry — if the answer is "permanently lost," that's a real gap worth its own follow-up (product's `stock` field would show correctly but the FIFO batch ledger backing it would be silently short, a data-integrity drift with no user-facing signal) |
| N5 | Restock/return against a product whose original sale batch has since been fully consumed *and* the batch itself somehow no longer exists locally (hard to engineer deliberately — see E5) combined with airplane mode | The `topUpOldest` drift-repair fallback (itself now async) fails silently, same shape as N4 but for the rarer repair path — lower priority than N4, note if you can trigger it |
| N6 | Double-tap Save rapidly on Add Product / Restock with stock > 0 | Only one product/restock and one batch created, not two — confirms the existing busy-guard still holds even though the batch side of the write now has a longer async tail than before |

### 3.3 Edge cases — map directly to what this branch actually changed, don't skip these

| # | Scenario | Expect |
|---|---|---|
| E1 | **Batch id reuse after delete/adjustment**, mirroring `2026-07-14-test-plan.md`'s E1 but for batches specifically. Note the current highest `BAT-<year>-NNN`. Fully consume/write off a batch (or otherwise remove its influence), then create a new one via Restock. | New batch gets the next sequential number — **never** reuses a number from a batch that's since been fully consumed or written off. This is the entire reason `_nextBatchId()`'s local-scan approach was replaced. |
| E2 | **Concurrent restock**, two devices/sessions restocking the *same or different* products within the same second. | Both succeed, each batch gets a **different** id, neither silently overwrites the other's counter advance. Hard to test without two devices — schedule accordingly, same caveat as the Products/Orders/Staff/Suppliers version of this test. |
| E3 | **Large bulk import**, 50+ new rows, most with positive stock, a handful at zero. | Import completes in reasonable time (one `mintCounterBatch` round-trip for the whole batch-id range, not one network call per row); exactly as many batches created as positive-stock rows; all `BAT-<year>-NNN` sequential, no gaps or duplicates. |
| E4 | **The rare fallback path.** Deliberately engineer a return/restore against a product where the *specific* batch id the sale recorded no longer exists in the local store (e.g. via a stock reconcile/edit that clears batch history, if the app exposes one — otherwise may need a direct Firestore edit in a test tenant). Then return part of that sale. | `restoreFifo` falls through to `topUpOldest`'s synthetic-batch creation (the path this branch made async) — confirm the return still completes and a new drift-repair batch eventually appears, not just that the order return itself reports success. This is the exact path SKILLS Skill 48 traced through during CI debugging; it has real E2E coverage (`tst_StockBatchStoreE2E.qml`) but zero on-device verification so far. |
| E5 | **Order completion hitting the FIFO drift guard.** `DataModel.qml`'s order-completion flow has its own drift-repair (`topUpOldest` → retry `consumeFifo`) for when recorded batches can't cover a sale despite `product.stock` saying they should. Genuinely hard to trigger deliberately (requires the ledger and stock count to already disagree) — if you happen to hit it naturally during other testing, confirm the order still completes (just a beat slower, one real network round-trip mid-completion) rather than hanging or erroring. | Order completes normally; note if you observe any perceptible pause on this specific path. |
| E6 | **Year boundary** — not practically testable except very close to real Dec 31 → Jan 1 midnight, and even then only for whichever operation happens to straddle it. Skip unless the test window genuinely includes that date; the design doc documents this as an accepted limitation, not something to chase down. | N/A — informational only, see Section 5. |

### 3.4 Monkey testing

- Rapid multi-tap (3-5 taps in under a second) on Save/Confirm for Add Product and Restock, both with
  stock > 0 — confirm no duplicate batches, matching N6.
- Toggle airplane mode ON/OFF repeatedly (every 1-2 seconds) during a large bulk import (E3) — confirm
  it either completes cleanly with a consistent batch count, or fails cleanly with no partial/
  duplicated batch ids, not a silent undercount.
- Force-close and relaunch immediately after tapping Save on Add Product with stock > 0 (before the
  batch's own network round-trip could plausibly have finished) — check on relaunch whether the batch
  appears, is missing, or duplicated.
- Rapidly restock the same product several times in a row (a few seconds apart) — confirm each gets
  its own sequential batch id, none collide, none silently skipped.
- During a large bulk import (E3), background the app or switch away and back — confirm the import
  either continues correctly or fails cleanly, no corrupted partial batch-id range.

---

## 4. Suggested order of attack

Given limited testing time, prioritize in this order:

1. **N4** — does a failed batch mint ever get recovered, or is it silently permanent? This is the one
   finding in this plan that could be a real, shippable gap rather than just "confirm the new thing
   works."
2. **E1** (batch id reuse after delete) — the core reason this branch exists, mirrors the highest-
   priority test from the Products/Orders/Staff/Suppliers precedent.
3. **H1–H9** happy paths — confirms nothing is outright broken, including the two genuinely new
   behaviors (year-scoped counter, bulk-import batch reservation).
4. **N1–N3, N6** — the other new failure modes and the busy-guard check.
5. **E3** large bulk import — the main practical stress case.
6. **E4** — the rare fallback path this branch's own CI debugging surfaced; worth confirming on-device
   at least once even though it's already E2E-covered.
7. **E2** concurrent restock — schedule around two-device availability.
8. Regression checklist (Section 2) — spot-check rather than exhaustive if time is short; nothing here
   was touched directly.
9. **E5, E6** — low priority, opportunistic only.
10. Monkey testing last, time-permitting.

## 5. Explicitly out of scope for this test plan

- Deploying/validating against a live production Firestore project — same as every prior test plan in
  this repo, this assumes your usual dev/test tenant.
- Deliberately waiting for a real Dec 31 → Jan 1 midnight to test the year-boundary behavior (E6) —
  informational only; the design doc already documents this as an accepted limitation, not a defect
  to chase down before merge.
- Building a mock/stub layer for `FirebaseService` to make the mint-failure gap (Section 1.2, N4)
  automatable — a real fix here, if N4 finds one is needed, is a follow-up scoped separately from this
  branch, not something to improvise on-device.

## 6. Sign-off checklist

- [ ] Section 1.1 unit tests passing in the actual build, **and** `test/e2e/tst_StockBatchStoreE2E.qml`
      run at least once against a real emulator — this is the only automated proof the counter itself
      works, and it has never been run in either CI round so far
- [ ] Section 2 regressions spot-checked, nothing broken
- [ ] Section 3.1 all happy paths pass, including H6 (fresh-tenant first mint) and H8 (zero-stock
      rows correctly reserve no batch id)
- [ ] N4 explicitly confirmed one way or the other — a failed mint's fate must be a known, recorded
      answer before this ships, not an open question
- [ ] E1 (batch id reuse after delete) explicitly confirmed fixed
- [ ] E3 (large bulk import) confirmed — count matches, no gaps/duplicates
- [ ] E4 (the rare fallback path) confirmed at least once on-device, even opportunistically
- [ ] E2 (concurrent restock) confirmed if two devices were available; noted as skipped if not
- [ ] Monkey testing found nothing alarming
