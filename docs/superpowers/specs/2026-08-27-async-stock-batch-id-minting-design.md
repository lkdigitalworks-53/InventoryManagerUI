# Async stock batch ID minting — design

**Date:** 2026-08-27
**Branch:** `feature/async-stock-batch-id-minting`
**Status:** Implemented this session.

## Where this picks up

`docs/superpowers/E2E-TESTING-ROADMAP.md`'s "In progress" entry left this blocked on Taher's
decision between two options:

- **Option A** — full parity with Staff/Supplier: convert `_nextBatchId()` to a real
  Firestore-transaction-backed counter (`FirebaseService.mintCounterValue`), which cascades into
  `InventoryStore.upsertMany`'s bulk-import loop.
- **Option B** — retry-on-conflict inside `_onMutationConflicted`, zero changes to `addBatch()`'s
  contract or the import loop.

The roadmap entry leaned towards B for effort/risk reasons. **This session's instruction explicitly
named Option A** ("make batch id mint async") — that's Taher's call to make, and it's a legitimate
one: A closes the gap at the source (matches Staff/Supplier exactly) rather than papering over it
after the fact. Recorded here for the record, not as a disagreement: the actual blast radius turned
out smaller than the roadmap entry estimated, for a specific reason below, which changes the
risk/effort trade-off the original entry was made under.

## Why Option A is less risky than the roadmap entry estimated

The roadmap entry's concern was that converting `_nextBatchId()` to async forces a real restructure
of `InventoryStore.upsertMany`'s bulk-import loop, calling it "a real change to a working, sensitive
bulk-import feature, unrelated to anything else in this effort."

Reading `InventoryStore.qml` end to end shows that loop **already solves this exact problem twice**,
for `products` and `suppliers`: `upsertMany` pre-scans the incoming records for how many fresh
product ids and new supplier names it needs, reserves both ranges in one round-trip each via
`FirebaseService.mintCounterBatch`, then runs the original synchronous loop against the pre-reserved
pools (`pullProductId()`, `nameToSupplierId`). `SupplierStore` itself already has the sync/async
split this needs: `addSupplier()` (async, mints its own id, for one-at-a-time UI use) vs.
`addSupplierWithId()`/`addSupplierWithIdMany()` (sync, given a pre-reserved id, for the bulk path).

So this isn't novel restructuring — it's adding a **third** reservation of the same shape the file
already does twice, using a split (`addBatch` vs `addBatchWithId`) the codebase already has a working
precedent for in `SupplierStore`. That's a materially different risk profile than "unrelated
restructuring of a sensitive loop," which is worth flagging honestly rather than silently agreeing
with the more alarming framing in the roadmap doc.

## What's actually changing

### `StockBatchStore.qml`

- `_nextBatchId()` (sync, local-array scan) → `nextBatchId(callback)` (async), mirroring
  `SupplierStore.nextSupplierId()` exactly: seed a local scan (same purpose as
  `nextSupplierId`'s — floors the mint if the counter doc doesn't exist yet, e.g. first deploy, so
  existing local ids aren't reissued), then call `FirebaseService.mintCounterValue`.
- **Counter path is year-scoped**: `counters/stockBatches-<year>`, not a single global counter like
  `counters/suppliers`. `BAT-<year>-NNN` numbering resets every year by existing design (see the
  original `_nextBatchId` comment) — a single global counter would silently break that contract. A
  new counter doc is created per year the same way `counters/suppliers` bootstraps on first use;
  no `firestore.rules` change needed (`counters` isn't in `isLedgerCollection`/
  `isServerOnlyCollection`, so it already falls into the generic tenant-scoped read/write rule, same
  as the three counters already in use).
- `addBatch(productId, supplierId, qty, unitCost, note, deferWrite, callback)` becomes async
  (mints its own id via `nextBatchId`, then builds/pushes/records exactly as before). The three
  existing call sites that use it (`InventoryStore.addProduct` after `nextProductId`'s callback,
  `InventoryStore.restock` after `recordDelta`'s callback, `StockBatchStore.topUpOldest`'s
  synthetic-batch path) already discard `addBatch`'s return value and are already inside an async
  callback themselves — converting them costs nothing beyond passing `callback` through where one
  exists (`topUpOldest`).
- New `addBatchWithId(id, productId, supplierId, qty, unitCost, note, deferWrite)` — sync, given an
  already-minted id. Exact `addSupplierWithId` mirror. This is what the bulk-import path now calls
  instead of `addBatch(..., true)`.
- `addBatchMany(docs)` — unchanged; already takes fully-built docs.

### `InventoryStore.qml` — `upsertMany`

- Pre-scan gains `neededBatchIds`: for each record, exactly the same "will this row create a new
  product doc" condition `neededProductIds` already computes (new row, or existing row with
  `_conflictPolicy === "rename"`), additionally gated on `parseInt(row.stock) || 0 > 0` — because
  `_bookImportedProduct` only creates a companion batch when incoming stock is positive. Extracted
  into a small pure helper (`_scanUpsertManyNeeds`, no `FirebaseService` calls) specifically so this
  counting logic — the actual correctness-critical new code — is unit-testable without a live
  emulator, instead of being buried inline where only an E2E run could ever exercise it.
- A third, nested `FirebaseService.mintCounterBatch("counters/stockBatches-" + year, seedBatchMax,
  neededBatchIds, ...)` call, chained after the existing product/supplier reservations (same
  give-up-on-failure-and-callback-early pattern as the other two).
- `pullBatchId()` closure, same shape as `pullProductId()`.
- `_bookImportedProduct` and `_upsertManySync` both gain a `pullBatchId` parameter; the one call
  site that creates a companion batch now calls `StockBatchStore.addBatchWithId(pullBatchId(), ...)`
  instead of `StockBatchStore.addBatch(..., true)`.

### Known, accepted limitation (not fixed, same class as the account-switch-mid-sync trade-off)

`upsertMany` captures `currentYear` once at the top, before any network round-trips. An import that
is somehow still running across an actual Dec 31 → Jan 1 boundary would reserve batch ids under the
old year's counter for rows processed after midnight. This is an existing-shape edge case (the old
synchronous `_nextBatchId()` had the same property — it computed `new Date().getFullYear()` fresh
per call, so a batch created after real midnight would already get next year's prefix while an
import spanning midnight was mid-flight) and not something this change makes worse. Not worth solving
for an import that would have to run for hours across literal midnight; flagged rather than silently
ignored.

## Testing

This codebase's own established convention for functions that reach `FirebaseService`'s network mint
calls (see `tests/tst_OrdersStore_mutations.qml`'s `test_addOrder_dispatches_without_throwing`) is:
unit tests confirm the synchronous portion before the network call doesn't throw; the actual mint
round-trip, retry behavior, and collision handling are covered by the E2E slice against the Firestore
emulator. No mocking layer for `FirebaseService`'s XHR calls exists in this codebase, and building one
from scratch is out of scope for this change. Coverage plan follows that existing split rather than
inventing a new one:

- **Unit** (`tests/tst_StockBatchStore.qml`, new): pure logic — `_buildBatchDoc`'s field defaults,
  `addBatchWithId`'s guard clauses and local-array update, `addBatch`'s guard clauses and
  dispatches-without-throwing smoke test.
- **Unit** (`tests/tst_InventoryStore_upsertMany.qml`, new): the extracted `_scanUpsertManyNeeds`
  helper — this is the one genuinely new piece of correctness-critical logic (does the reservation
  count match what the loop will actually consume?) and it's fully testable without touching the
  network, so it gets real assertions, not just a doesn't-throw smoke test.
- **E2E** (`test/e2e/tst_StockBatchStoreE2E.qml`, updated): the two existing tests
  (`test_addBatch_creates_real_emulator_doc`, `test_duplicate_create_for_the_same_batch_id_produces_a_real_conflict`)
  call `addBatch` for its synchronous return value — that stops compiling correctly the moment
  `addBatch` is async (it wouldn't fail loudly; `doc` would just be `undefined` and the tests would
  pass or fail for the wrong reason). Both are rewritten to the same
  callback-plus-`tryVerify(() => done)` pattern `tst_SupplierStoreE2E.qml`'s `_createSupplier` helper
  already establishes. Two new tests added: `test_addBatchWithId_creates_real_emulator_doc` (the
  bulk-import path still works and skips the mint round-trip) and
  `test_nextBatchId_mints_sequential_ids_via_a_real_counter` (proves this is now backed by a real
  Firestore counter, not just "still happens to work" — the actual point of doing Option A at all).
