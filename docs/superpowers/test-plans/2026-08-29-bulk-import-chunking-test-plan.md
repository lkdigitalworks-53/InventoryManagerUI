# Test plan — `fix/bulk-import-chunking-durable-status`

**Branch:** `fix/bulk-import-chunking-durable-status`, rebased onto `main` @ `61f85e0`
(`feature/async-stock-batch-id-minting`, #53) — linear history, two commits specific to this fix
(`07d01eb` implementation, `7b5a3ad` coverage-gap closure).
**Date:** 2026-08-29. CI green on this branch (QML, Functions, Firestore Rules, E2E jobs all passed).
**Covers:** the reported bug — bulk product/order/supplier import silently failed past 200 rows
(server's `MAX_BATCH_SIZE`), retried the same doomed request forever in total silence, and the UI
reported success regardless with no rollback. Full root cause + design trade-offs: `CHECKPOINT.md`
and `SKILLS.md` Skill 52.

Every count below comes from `grep -c "function test_"` / `grep -c "^test("` on each file, diffed
against its `main`-branch baseline, not carried forward from memory.

---

## 1. Unit test coverage

Pure logic and store-level guard clauses — would exist even framed as "does the new code behave
correctly," independent of the specific bug narrative. 27 cases.

| Area | File | Cases |
|---|---|---|
| `Gateway._chunkItems` | `tests/tst_Gateway.qml` | Single chunk under the limit; splits evenly at exactly 2× the limit (no trailing empty chunk); splits with a remainder; empty/null input; `size<=0` falls back to one chunk of everything rather than zero-length chunks (dead in production — `recordMutations` always passes `maxBatchSize` — but it's in the code, so it's tested). 5 cases. |
| `Gateway.maxBatchSize` | `tests/tst_Gateway.qml` | Literal pin at 200, mirroring the pin on the Functions side (below). 1 case. |
| `Gateway.recordMutations` (new correctness property) | `tests/tst_Gateway.qml` | Each chunk gets a distinct-but-related `requestId` (`<parent>-c0`, `-c1`, …) — this is what keeps a retry of one chunk idempotent against the server's `requestId:entityId` audit-log dedup. 1 case. |
| `Gateway._classifyBatchMutationFailure` | `tests/tst_Gateway.qml` | Malformed body, empty string, valid-JSON `null` (distinct from the parse-exception path), body without `ok:false`, `ok:false` with a missing/non-string `error`, all 4 remaining definitive-error strings via `recognizes_every_definitive_validation_error`, 401/403 (auth/tenant-context) deliberately NOT terminal, a well-formed 5xx not terminal regardless of its error string, 2xx ignored, an unrecognized 4xx error string not terminal (conservative default). 10 cases (the 11th — `batch-too-large` specifically — is the regression case in §2, not counted twice here). |
| `counts.chunked` flag | `tests/tst_InventoryStore_upsertMany.qml` (sync), `test/e2e/tst_OrdersStoreE2E.qml` (async — see §6 for why Orders needs the E2E tier here) | False for a small import, true for 201 rows (Inventory, synchronous); true for 201 new orders (Orders, E2E — `upsertMany`'s counts object is only populated inside the async `mintCounterBatch` callback, which no unit test can reach). 3 cases. |
| `_onBatchMutationFailedPermanently` guard clauses (wrong-entity, empty-items) | `tests/tst_InventoryStore_upsertMany.qml`, `tests/tst_OrdersStore_mutations.qml`, `tests/tst_SupplierStore_batchMutationFailedPermanently.qml` (new) | Both halves of each store's compound guard clause, tested separately per store. 6 cases (2 × 3 stores). |
| `MAX_BATCH_SIZE` literal pin | `functions/test/batchMutationLogic.test.js` | Twin of the Gateway-side pin above — both sides hardcode 200 so a drift between them fails a test on both, not silently in production. 1 case. |

## 2. Regression test coverage

Tests that exist *specifically because* this bug was found — each one pins down the exact reported
defect so it can't come back silently. 15 cases.

| Test | Regression for | What it locks down |
|---|---|---|
| `test_recordMutations_splits_an_oversized_batch_into_multiple_outbox_entries` (`tst_Gateway.qml`) | The reported bug itself | 250 items produces 2 outbox entries (200+50), not 1 — before this fix, this was always 1 entry the server unconditionally rejects. |
| `test_recordMutations_over_the_cap_lands_every_row_via_chunked_batches` (E2E) | Same, end-to-end | 250 rows against the **real** emulator — both chunk boundaries (row 199, row 200) and the first/last rows all actually land in Firestore. The strongest proof available: before the fix, none of these 250 rows would ever have reached the server. |
| `test_classifyBatchMutationFailure_recognizes_batch_too_large_as_terminal` (`tst_Gateway.qml`) | The "retries forever, silently" half of the bug | The server's exact `batch-too-large` response is classified as never-retry — this classifier didn't exist before, so any failure (including this one) retried every 10 minutes forever with only a `console.warn`. |
| `test_permanently_rejected_item_rolls_back_and_is_not_reported_as_success` (E2E) | The "UI didn't inform about error or revert the import" half of the bug | A real server rejection (`unsupported-action`, chosen so this doesn't depend on the size cap specifically) rolls the optimistically-added row back out of `InventoryStore.products`, confirms the row never reached Firestore either, and confirms a durable `ActivityLog` entry exists — none of which happened before this fix; the import just "finished" regardless. |
| `test_onBatchMutationFailedPermanently_removes_only_the_failed_rows` / `_removes_only_the_failed_orders` / `_removes_only_the_failed_suppliers`, plus each store's `test_gateway_signal_reaches_*_and_rolls_back` (6 cases, `tst_InventoryStore_upsertMany.qml` / `tst_OrdersStore_mutations.qml` / `tst_SupplierStore_batchMutationFailedPermanently.qml`) | Same "didn't revert" half, at the store level for all 3 affected stores | Local state actually gets rolled back to match remote reality, through the real signal wiring (`Component.onCompleted`'s connection), not just when the handler is called directly. |
| `test_onBatchMutationFailedPermanently_is_a_no_op_for_an_unknown_entityId` / `_orderId` / `_supplierId` (3 cases) | Defensive regression — a rollback must never touch an unrelated row | Guards against a future change to the entityId-matching loop silently over-deleting. |
| `test_recordMutations_under_the_limit_is_unaffected_by_chunking`, `test_recordMutations_direct_mode_is_unaffected_by_chunking` (`tst_Gateway.qml`) | Regression **introduced by this fix**, not the original bug — confirms the fix itself doesn't break the common case | A normal ≤200-row import keeps its plain `requestId` (no `-c0` suffix); `direct` mode (the non-production fallback) is completely untouched by the new chunking logic. |

## 3. E2E test coverage

`test/e2e/tst_BulkImportChunkingE2E.qml` (new) and one addition to the existing
`test/e2e/tst_OrdersStoreE2E.qml`, run via `firebase emulators:exec` against a real Firestore +
Cloud Functions emulator — the only tier that exercises the real, deployed `recordMutationsBatch`
validation logic, not a client-side simulation of it.

| Test | What it proves | CI status |
|---|---|---|
| `test_recordMutations_over_the_cap_lands_every_row_via_chunked_batches` | The reported bug, fixed, end-to-end (see §2) | Passed |
| `test_permanently_rejected_item_rolls_back_and_is_not_reported_as_success` | The rollback/notify half of the fix, against a real server rejection (see §2) | Passed |
| `test_upsertMany_sets_chunked_true_for_more_than_maxBatchSize_new_orders` (`tst_OrdersStoreE2E.qml`) | `OrdersStore.upsertMany`'s `counts.chunked` flag — the one new branch that can't be unit-tested (see §6) | Passed |

## 4. Firestore Rules coverage

**Not applicable — `firestore.rules` is untouched by this fix**, and the existing 10-case
`test/firestore.rules.test.js` suite is orthogonal to it. `Gateway.mode` defaults to `"gateway"` in
production: the actual write happens server-side in `recordMutationsBatch` via the Admin SDK, which
bypasses client rules entirely. The rules file's generic working-tier fallback (`allow create,
update, delete: if isMember(tenantId) && !isLedgerCollection && !isServerOnlyCollection`) only
governs the `direct`-mode fallback path, which this fix deliberately leaves untouched
(`test_recordMutations_direct_mode_is_unaffected_by_chunking` confirms it). CI's Rules job passing
on this branch is expected and uninformative for this change specifically — it would pass on any
branch that doesn't touch `firestore.rules`.

## 5. On-device test plan

### 5.1 Happy path

| # | Flow | Steps | Expect |
|---|---|---|---|
| H1 | Bulk-import exactly 250 new products | Import a CSV with 250 brand-new rows | Import dialog closes with a message ending "· still syncing to your workspace in the background"; within a short time, all 250 products appear in Inventory (confirm both the 200th and 201st specifically — the chunk boundary) |
| H2 | Bulk-import exactly 200 new products | Import a CSV with exactly 200 new rows | Import completes with **no** "still syncing" note (200 is not `>` the cap, so `counts.chunked` is `false` and this fits in one chunk) — confirms the boundary is `>`, not `>=` |
| H3 | Bulk-import 50 new products (well under the cap) | Import a CSV with 50 new rows | Completes exactly as before this fix — no "still syncing" note, no perceptible behavior change |
| H4 | Bulk-import 250 rows that also introduce 3 brand-new supplier names | Import a CSV with 250 new product rows, 3 of which reference suppliers that don't exist yet | Both the product batch (2 chunks) and the supplier batch (1 chunk, well under 200) sync correctly; all 3 new suppliers appear, all 250 products correctly reference them |
| H5 | Bulk-import 400 new orders | Import/create 400 new order rows in one operation | Same shape as H1 but for `OrdersStore` — 2 chunks (200+200), all 400 orders eventually present |

### 5.2 Negative tests

| # | Scenario | Expect |
|---|---|---|
| N1 | Force a real permanent rejection: bulk-import a CSV where one row is deliberately malformed in a way `validateBatchMutationRequest` rejects (e.g. a supplier name resolving to an invalid character set, if the app's own row validation doesn't already catch it first — may need to bypass client-side validation via a direct test payload if the UI's own CSV validation is stricter than the server's) | The offending row's chunk is rolled back locally (row disappears from the list if it was optimistically shown), a toast appears, and the notification bell/activity log records an "import failed" entry naming the row count and reason — **not** silent success |
| N2 | Airplane mode ON immediately after tapping "Import" on a 250-row CSV, before the sync could plausibly complete, then airplane mode OFF ~15s later | The two chunks are still queued (durable — this is `OutboxStore`'s existing persistence, exercised here for the first time at this scale) and both sync automatically once connectivity returns; no data loss, no duplicate rows (idempotent per-chunk `requestId`) |
| N3 | Force-close the app immediately after tapping "Import" on a 300-row CSV (before either chunk's HTTP round-trip could complete), then relaunch | On relaunch, both chunks are still in the outbox and resume sending automatically; eventually all 300 rows land exactly once each (no duplicates — same idempotency guarantee as N2, but via a real process kill rather than just a network drop) |
| N4 | Bulk-import 0 rows / an empty CSV | No crash, no outbox activity, completion message has no "still syncing" note (pre-existing behavior, confirm unaffected) |

### 5.3 Edge cases

| # | Scenario | Expect |
|---|---|---|
| E1 | Exactly 201 rows (one row over the cap) | 2 chunks (200 + 1), both sync — confirms the boundary condition on the other side from H2 |
| E2 | A very large import — 1000+ rows, if a realistic test CSV of that size is available | 5 chunks; confirm no perceptible UI freeze while all 5 are enqueued (enqueueing is synchronous but should still be fast — this is new territory, no prior import ever chunked) |
| E3 | Two large imports back to back — start a 300-row product import, then immediately start a second 300-row import before the first has finished syncing in the background | Each import's chunks carry distinct `requestId`s (parent id includes a timestamp/counter) — confirm rows from both imports land correctly, without one import's chunks being mistaken for the other's |
| E4 | A permanently-failed supplier row where some of the *same* import's product rows already reference that supplier locally | **Known, documented gap** — those products are left pointing at a now-locally-removed supplier until the next full re-sync (see `SupplierStore.qml`'s handler comment). Confirm this is what actually happens, not something worse (e.g. a crash) — this on-device check is about verifying the documented limitation, not finding a new one |
| E5 | Bulk-import 250 rows, then immediately edit/delete one of the rows from chunk 2 (the still-pending one) before it's finished syncing | Confirms the optimistic-local-then-reconcile model holds up under a second, unrelated mutation racing the still-in-flight import — not a scenario this fix changed, but the increased chunk count and background-sync window make the race window larger than before |

### 5.4 Monkey testing

- Rapidly tap "Import" multiple times on the same large CSV before the dialog has a chance to close — confirm no duplicate chunks/rows, matching the existing busy-guard behavior this fix didn't touch.
- Toggle airplane mode ON/OFF repeatedly (every 1-2s) during a 250+ row import — confirm it either completes cleanly with the correct final row count, or fails cleanly with no partial/duplicated rows, never a silent undercount.
- Background the app and switch back repeatedly during a large import's background sync — confirm chunks keep draining correctly across foreground/background transitions.
- Import a very large CSV, then immediately navigate away from the Inventory/Orders page before syncing finishes — confirm returning to the page later shows the fully-synced, correct state (not stuck showing only the pre-sync optimistic rows).
- Rapidly create/delete unrelated products or orders while a large import's chunks are still draining in the background — confirm no cross-contamination between the unrelated mutations and the in-flight import chunks.

### 5.5 Affected areas

| File | Automated coverage | Notes |
|---|---|---|
| `qml/model/Gateway.qml` | Unit + regression, extensive (§1, §2) | The actual fix — chunking, failure classification, new signal |
| `qml/model/InventoryStore.qml` | Unit + regression (§1, §2) | Rollback handler, `counts.chunked` |
| `qml/model/OrdersStore.qml` | Unit + regression (§1, §2) + E2E (§3, `counts.chunked` specifically) | Rollback handler |
| `qml/model/SupplierStore.qml` | Unit + regression (§1, §2) | Rollback handler; new unit test file (none existed before this fix) |
| `qml/pages/ImportPreviewDialog.qml` | **None** — see §6 | H1/H2/H3 on-device steps are this line's only coverage |
| `functions/lib/batchMutationLogic.js` | Unchanged logic, comment only; existing 110-case Functions suite covers it, +1 new pin | No behavior change — confirmed by Phase 1 root-cause investigation that the 200 cap itself is correct |

---

## 6. Coverage completeness

Every new branch in `Gateway.qml`, `InventoryStore.qml`, `OrdersStore.qml`, and
`SupplierStore.qml` has at least one test exercising each direction — verified by diffing this
fix's changes against the existing suite branch-by-branch, not assumed from "the file has tests."
One exception, **not silently skipped**:

**`ImportPreviewDialog._finishApply`'s `if (counts.chunked)` line has no automated test at any
tier.** Checked before deciding this: no `.qml` page or dialog anywhere in this repository has a
unit test file — `tests/` covers stores and pure-logic helpers exclusively. Building a
first-of-its-kind `BottomSheet` instantiation harness to cover one conditional string-concatenation
line would be a disproportionate, precedent-setting investment for this fix specifically. Covered
instead by on-device steps H1/H2/H3 above, which is the same tier every other page-level behavior
in this codebase is verified at (see `2026-08-22-pr_taher_bug_fixes-test-plan.md`'s own "Affected
areas" table for the identical judgment call on other pages). If dialog-level unit testing becomes
a project-wide priority, this line would be trivial to add coverage for at that point.

## 7. Sign-off checklist

- [x] Section 1 unit tests + Section 2 regression tests — all passing, confirmed via real
      `qmltestrunner`/`node --test` CI run on this branch (2026-08-29)
- [x] Section 3 E2E tests — confirmed via the same CI run's E2E job (real Firestore/Functions
      emulator), not a local approximation
- [x] Section 4 — confirmed not applicable; `firestore.rules` untouched
- [ ] H1-H5 happy paths — not yet run on a physical device
- [ ] N1-N4 negative tests — not yet run; **N1 is the highest-priority item in this whole plan**,
      it's the only on-device check of the "real permanent rejection" path outside of the E2E
      test's synthetic `unsupported-action` trigger
- [ ] E1-E5 edge cases — not yet run; E4 is a known, accepted, already-documented limitation, not
      a suspected defect — confirm it behaves as documented, not as a bug hunt
- [ ] Monkey testing — not yet run

## How this was verified

- QML: every touched/new test file re-verified with a string/comment-stripped brace-balance AND
  per-function nesting-depth check before each commit (a naive brace count alone produced false
  positives from this codebase's own malformed-JSON string test fixtures, e.g. `"not json{{{"`) —
  see `SKILLS.md` for why the naive check isn't trusted on its own in this repo.
- Functions: `cd functions && npm test` — 110 tests, 0 failed, re-run after every change in this
  branch.
- CI: real GitHub Actions run on this branch — QML, Functions, Firestore Rules, and E2E jobs all
  green (confirmed by Taher; this sandbox's GitHub API access hit an unauthenticated rate limit
  when attempting to double-check independently).
- Exact new-test counts in §1-§3 come from `grep -c "function test_"` / `grep -c "^test("` on each
  file, diffed against its `main`-branch (`61f85e0`) baseline — 42 new test cases total across this
  fix. Categorized as 27 unit-tier + 15 regression-tier (summing to the full 42 — every test counted
  exactly once); §3's E2E table is a cross-cutting *tier* view, not a third additive bucket — its 3
  tests are already inside the 27+15 (2 regression, 1 unit), just called out separately because
  they're the only 3 that run against a real emulator instead of an in-memory fixture.
