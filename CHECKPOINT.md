# CHECKPOINT — async stock batch id minting

**Session date:** 2026-08-27
**Branch:** `feature/async-stock-batch-id-minting`
**Previous arc archived to:**
`docs/superpowers/specs/2026-08-26-post-merge-backlog-and-roadmap-decision-CHECKPOINT.md`

## What this session is

`docs/superpowers/E2E-TESTING-ROADMAP.md`'s "In progress" item left `StockBatchStore._nextBatchId()`'s
async conversion blocked on Taher's decision between Option A (full async parity with Staff/Supplier,
cascades into `InventoryStore.upsertMany`'s bulk-import loop) and Option B (retry-on-conflict, smaller,
contained). The doc leaned toward B. This session's instruction named Option A explicitly — that
decision is now made and acted on.

## Status: implementation complete, not yet committed/pushed as of this checkpoint

### Done
- [x] Fresh clone, branch created, previous CHECKPOINT.md archived
- [x] Read `InventoryStore.upsertMany`/`SupplierStore` end to end before designing — found the actual
      blast radius is smaller than the roadmap doc estimated (see design doc, SKILLS Skill 47)
- [x] Design doc written: `docs/superpowers/specs/2026-08-27-async-stock-batch-id-minting-design.md`
- [x] `StockBatchStore.qml`: `_nextBatchId()` → `nextBatchId(callback)` (real, year-scoped Firestore
      counter `counters/stockBatches-<year>`), `addBatch()` converted to async, new
      `addBatchWithId()` for the bulk-import path, `_buildBatchDoc()` extracted, `topUpOldest()`'s
      synthetic-batch call site updated to chain its callback correctly
- [x] `InventoryStore.qml`: `upsertMany` reserves a third id range (batch ids) via a new, pure,
      unit-testable `_scanUpsertManyNeeds` helper; `_bookImportedProduct`/`_upsertManySync` threaded
      with `pullBatchId`; the two other `addBatch` call sites (`addProduct`, `restock`) updated with
      comments only (no behavior change — they already discarded the return value)
- [x] `test/e2e/tst_StockBatchStoreE2E.qml`: rewrote the 2 existing tests that relied on `addBatch`'s
      old synchronous return (would have silently broken), added 2 new tests
      (`addBatchWithId`, `nextBatchId` real-counter sequencing), updated the `init()` comment
- [x] `tests/tst_StockBatchStore.qml` (new) — unit tests for pure logic + guard clauses
- [x] `tests/tst_InventoryStore_upsertMany.qml` (new) — unit tests for `_scanUpsertManyNeeds`
      (the correctness-critical new logic) + smoke tests for `upsertMany` itself
- [x] `qt_qml_lint.py` run on all 5 touched/new files — no new findings beyond this codebase's
      pre-existing, consistent conventions (`var`, loose equality in older code, no `id: root` on
      TestCase files — confirmed 0/56 existing test files use it)
- [x] Brace/paren/bracket balance check on all 5 files — all balanced
- [x] `SKILLS.md` — Skill 47 added
- [x] `AGENTS.md` — new "ID minting" bullet under Store & Firebase Agent documenting the
      `addX`/`addXWithId`/`addXWithIdMany` split as the established pattern for future domains
- [x] `README.md` — dated update note under Concurrency & Conflict Resolution
- [x] `docs/superpowers/E2E-TESTING-ROADMAP.md` — item moved from "In progress" to "Resolved this
      arc", with an honest note on how the risk estimate compared to what reading the code found

### Remaining before this session ends
- [x] First real CI run: 2 failures, both root-caused and fixed (see below) — Skill 48 added
- [ ] Final `git diff` read-through of the CI-fix round
- [ ] `git add -A`, commit, push using PAT injected into the URL, verify clean, redact in output

## CI round 1 — 2 failures, both root-caused via full call-stack trace (not patched blind)

1. **`InventoryStore_upsertMany::test_scan_sums_batch_ids_across_multiple_qualifying_rows`**
   (Actual 3, Expected 2) — my own test's expected `neededProductIds` was wrong: a zero-stock new row
   still needs a product id (only the *batch* id is stock-gated). Implementation was correct; fixed
   the test's expected value (3, not 2) and its comment.
2. **`DataModel_adjustOrderSyncGuard::test_proceeds_normally_once_transaction_history_is_synced`**
   (Actual 3, Expected 4, missing the `stock_batch` mutation) — traced the full call stack: this
   test's `init()` never seeded `StockBatchStore.batches`, so `StockBatchStore.restoreFifo("B1", ...)`
   has *always* fallen through to `topUpOldest`'s synthetic-batch fallback rather than the normal
   existing-batch `recordDelta` path the test's own header comment describes and intends. Invisible
   before this session's change only because that fallback used to be fully synchronous; now it mints
   an id over a real network round-trip, so its mutation isn't enqueued yet when the test's synchronous
   assertion runs. Fixed by seeding a matching `B1` batch in `init()` — makes the test exercise the
   path it always claimed to, which is fully synchronous regardless (`recordDelta` on a known id never
   mints anything). See SKILLS Skill 48 for the full trace and why this wasn't just "add a `tryVerify`."

**Not touched, flagged only**: `tst_OrderMetadataEditPreservesConsumption.qml` also seeds
`StockBatchStore.batches = []` with a `consumption` referencing `batchId: "B1"`, so it hits the same
`topUpOldest` fallback — but none of its assertions depend on that mutation landing synchronously, so
it wasn't failing and wasn't touched (out of scope for this fix-forward round; per systematic-debugging
convention, no bundled changes beyond what CI actually flagged).

## On-device test plan

Written: `docs/superpowers/specs/2026-08-28-async-stock-batch-id-minting-test-plan.md`. Follows the
happy/negative/edge/monkey/regression structure from `docs/superpowers/specs/2026-07-14-test-plan.md`
(the closest precedent — same class of change, id minting, for a different entity). Headline finding
surfaced while writing it, not yet verified either way: **3 of the 4 call sites that create a batch
pass no callback to `addBatch`/`topUpOldest` at all**, so a failed mint (new failure mode — a network
call where there used to be an instant local scan) is silently swallowed with no user-facing signal.
Flagged as the top-priority on-device scenario (N4 in the plan) rather than guessed at or fixed
speculatively — don't know yet whether it's a real gap worth a follow-up until someone runs it.

## Known, accepted limitations (not fixed, flagged instead)

- **Midnight year-rollover during upsertMany**: `currentYear` is captured once at the top of
  `upsertMany`, before any network round-trips. An import somehow still running across a real Dec 31
  → Jan 1 boundary reserves batch ids under the old year's counter for rows processed after midnight.
  Pre-existing-shape edge case (the old synchronous version had the same property), not made worse by
  this change, not worth solving for an import that would need to run for hours across literal
  midnight.
- **Two more `deferWrite`-into-`addBatchMany` callers do not currently exist** for `addBatch` (only
  `addBatchWithId` is used that way, by the bulk-import path) — `addBatch`'s `deferWrite`/no-callback
  combination is preserved for interface parity with `addBatchWithId` but has no current caller; not
  removed since it's a legitimate, cheap-to-keep option, not dead weight that obscures anything.

## Next action if resumed

If interrupted before the remaining steps above: re-run `git status` and `git diff --stat` on this
branch first — all source/test/doc edits described as "Done" above should already be present in the
working tree (nothing has been committed yet as of this checkpoint's writing). Finish the "Remaining"
checklist in order.
