# Test plan — order completion as one atomic, replay-safe operation (C-3)

**Branches:** `feature/2026-09-21-record-operation-endpoint` (server, merged #78), `feature/2026-09-21-operation-helpers` (pure helpers, merged #79), `fix/2026-09-22-atomic-order-completion` (transport + wiring, open as #83 for Tasks 6-8; Tasks 9-11 not started).
**Spec:** `docs/superpowers/specs/2026-09-20-atomic-operation-outbox-design.md` · **Plan:** `docs/superpowers/plans/2026-09-20-atomic-operation-outbox.md`

**What it does:** completing an order sends one operation (batch deltas, stock deltas, order update, sale docs)
under a deterministic key; the server applies it in one transaction or not at all, and a re-run of the same
key returns the first result. Requests now time out, retry with jitter, fall back to the outbox, and count
toward the stuck-write indicator.

**Originally written before implementation** (2026-09-20); **updated 2026-09-25 for Phase 3 PR 1 (#83,
plan Tasks 6-8)** to replace "planned" rows with what actually shipped, since the approach changed from the
original draft in two ways worth calling out: (1) Gateway's timeout was NOT built as a shared `_xhrPost` helper
with an injectable `xhrFactory` -- the real `_send`/`_sendBatch`/`_sendDelta` had grown far more elaborate than
this plan assumed (a QTBUG-49896 workaround, CAS-conflict parsing, terminal-batch-error handling), so a full
reroute was rejected as too risky; each sender instead got a settled-flag `Timer` (the proven
`AuthService._postJson` pattern), later deduplicated into a shared `_armSendTimeout` helper. (2) No new test
files (`tst_Gateway_send.qml`, `tst_Gateway_operation.qml`) were created; the new cases were appended to the
existing `tst_Gateway.qml`, matching that file's own established pattern of driving `Gateway`'s internals
directly rather than mocking HTTP (there is no mock HTTP layer anywhere in this codebase). Tasks 9-11 (store
hooks, `DataModel`, UI) are still genuinely "planned" -- not started. QML coverage is not measured in this
repo, so for QML the claim is "CI passes plus documented unreachable branches", never a percentage.

## 1. Unit test coverage

| Unit | Test file | Cases | Status |
|---|---|---|---|
| `functions/lib/operationLogic.js` | `functions/test/operationLogic.test.js` | 20: validation (envelope, op type, empty, cap 200 exactly, per-op errors with `opIndex`); atomic apply (deltas + mutations, one transaction, 9 writes for 4 ops, audit shape); replay; two deltas on one doc compose and read once; floor violation writes nothing; landing exactly on the floor allowed, one below rejected; rejected key retried with a re-plan; clamp; 404; CAS conflict with `current`; create expects missing doc; create-then-delta; delete existing / missing; create-then-delete; null `after`; 200 ops = 401 writes | **Verified** (Node, sandbox): 20/20, 100% line, branch and function coverage. 14/14 deliberate mutations caught |
| `recordOperation` handler | `functions/test/index.handlers.recordOperation.test.js` | 13: success, replay flag, floor rejection forwards `opIndex`/`field`/`current` (0 survives), CAS conflict forwards `conflict`, status fallback 409, 404 with index, 401 missing/invalid token, 403 no tenant, 400 with `opIndex`, 400 empty envelope, 405, 500 write-failed | **Verified** (Node, sandbox): 13/13. Whole functions suite 228/228 with these applied |
| `qml/helper/CompletionPlan.js` | `tests/tst_CompletionPlan.qml` | 27: single line, lineage stamped, input never mutated, predicted state, op order, hooks called once, two-batch FIFO, empty/zero batches skipped, cost/supplier defaults, shared availability across lines, repair batch (fully consumed, deterministic id, per-line ids, no batches at all), stock validation (before hooks, summed per product, unknown product), `clampStock`, zero-qty line, empty order, cap 200 / exactly 200 / 201, stale consumption replaced, determinism, epoch changes key, 300-run seeded monkey (consumed = sold, no batch overdrawn, cap respected) | **Logic verified** in Node through a shim (27/27, 21/21 mutations caught across the helpers). **Not run under `qmltestrunner`**: QML syntax of the file is unproven until CI |
| `qml/helper/OperationKeys.js` | `tests/tst_OperationKeys.qml` | 7: epoch from null/`{}`/0/stored/non-numeric, key format and determinism, key differs per order and epoch, sale id prefix and uniqueness, repair id | Logic verified in Node (7/7); CI pending |
| `qml/helper/SendPolicy.js` | `tests/tst_SendPolicy.qml` | 7: timeout selection, pinned values (10s < 30s), jitter bounds and midpoint, monotonic, invalid `rand` falls back, zero delay, seeded monkey over the whole backoff schedule | Logic verified in Node (7/7); CI pending |
| `qml/helper/StuckWrites.js` (D5) | `tests/tst_StuckWrites.qml` (+6) | timeout counts only when `online === true`; unknown/`"yes"` connectivity does not; numeric statuses ignore the flag; 5 online timeouts tip; offline never; timeouts and 5xx share one counter; an offline timeout does not reset earlier online failures | Logic verified in Node (27/27 incl. #75's 21 existing); CI pending |
| `OutboxStore` op items | `tests/tst_OutboxStore.qml` (+7) | append durable item; same key returns existing; keys for all entities (deduped); never a coalescing target; in-flight op blocks its keys; `dueItems` never returns two items sharing a key; jitter band | **Verified in CI** (real `qmltestrunner`, PR #83): 7/7. Hand-traced against the real implementation before pushing (no Qt toolchain in the sandbox) |
| `Gateway` send timeout (`_armSendTimeout`) | `tests/tst_Gateway.qml` (+6, appended to the existing file) | timeouts count toward the stuck indicator only while online (D5); numeric statuses ignore the online flag; 5 online timeouts tip it; offline never; timeouts and 5xx share one counter; an offline timeout doesn't erase earlier online failures | **Verified in CI**: 6/6. The actual Timer/XHR/`abort()` interaction genuinely cannot be tested here (no mock HTTP layer anywhere in this codebase, documented in this file's own scope note) -- proven only by CI's `qmltestrunner` run and, for real timing, the on-device plan below |
| `Gateway.recordOperation` | `tests/tst_Gateway.qml` (+15, appended) | validation (empty/no-key/201-ops/non-array, all before touching the outbox), exactly-200-ops accepted, gateway-mode required, queued immediately when not awaiting, offline never waits, same key twice both told "queued", awaiting registers a waiter without answering, **a real await timer actually let to fire** delivers `{pending:true}` once and the later real answer doesn't re-invoke the callback, `_finishOperation` delivers to a waiter / to every waiter / with none registered (relaunch case) and fires `operationApplied`/`operationRejected`, `clear()` drops pending callbacks | **Verified in CI**: 15/15. Same scope split as above: validation/enqueue/`_finishOperation` decision logic and the await-timer's real firing are genuinely exercised (no XHR involved); the server round trip itself is not |
| Store hooks | `tests/tst_{Inventory,StockBatch,Orders,Transaction}Store_*.qml` (new) | unknown id, returns previous value, idempotent adds, `revision` bumps, `buildOrderUpdate` pure (no Gateway call, no local change), `buildSaleDocs` deterministic and shape-identical to the old function | Planned |

## 2. Functional / end-to-end test coverage

| Scenario | Where | Status |
|---|---|---|
| Online completion applied by the server; caches equal the response | `tests/tst_DataModel_completeOrderAtomic.qml` case 1 (fake XHR through the real Gateway) | Planned |
| Local stock validation fails: no request, `out of stock`, message | case 2 | Planned |
| Server rejects the stock op: "stock ran out…", no local change | case 3 | Planned |
| Another device drained a batch: reconcile from `current`, re-plan, same key, succeeds | case 4 | Planned |
| Re-plan bounded (4 requests max) | case 5 | Planned |
| Await window ends, then the server answers: predicted state overwritten, guard released | case 6 | Planned |
| Offline: optimistic apply, no wait | case 7 | Planned |
| Queued then rejected at sync: revert, re-plan with clamp, repair batch, stock clamped at 0 (D3) | case 8 | Planned |
| Replay with different local state: caches equal the response, not the plan | case 9 | Planned |
| Reopen then re-complete gets epoch 2 | case 11 | Planned |
| `too-many-ops` message, status not changed | case 12 | Planned |
| Already completed / in-flight guard unchanged | case 13 | Planned |
| Seeded monkey (200 runs): guard never stuck after a terminal outcome, stock never negative, one key per order and epoch | case 15 | Planned |
| Server transaction end to end against the Firestore emulator | not available in the sandbox; covered by the on-device plan against dev | On-device |

## 3. Regression test coverage

| Bug it pins | Test | Status |
|---|---|---|
| **C-3:** hang, sign-out, sign-in, re-run sent NEW request ids and consumed FIFO twice | `tst_DataModel_completeOrderAtomic.qml` case 10: the re-run's `requestId` equals the first; answered as a replay, stock and batches change once | Planned |
| Re-run also double-booked revenue (random `txId`) | case 14: sale doc ids are deterministic and not duplicated by a replay | Planned |
| A rejection must leave no trace so the same key can be retried | `operationLogic.test.js` "a rejected requestId can be retried later with a re-planned payload" | **Verified** |
| A timeout must be a retryable failure, not a dropped write and not "offline" | `tst_Gateway_send.qml` | Planned |
| Two due outbox items on one key no longer race in one drain | `tst_OutboxStore.qml` `dueItems` case | Planned |
| Existing completion behaviour: guard, out-of-stock message, drift repair end state | `tst_DataModel_completeOrderReentrancy.qml` (must stay green) plus the planner's repair-batch cases | Planned |

## 4. Firestore rules test coverage

No rules change. `audit_log` and the ledger collections are already client write-locked
(`test/firestore.rules.test.js`, "the wildcard match's ledger guard denies a member write to audit_log even
in isolation"), and the per-op and marker entries live in that same collection. The Rules job must stay
green; no new rules test is needed.

## On-Device Test Plan

Prerequisites: the `recordOperation` function deployed to dev (Taher), two devices signed into the same
tenant (same user id on one, a different user id on the other), a product with two batches and known
quantities. Build only when Taher asks.

### Happy Path

- [ ] Online, complete a 1-line order: it completes after a short wait, stock and the oldest batch each drop by the quantity, one sale row appears in Transaction History, no error toast.
- [ ] Online, complete a 3-line order spanning two batches on one line: batch quantities, stock and consumption lineage (per-supplier margin view) all correct.
- [ ] Offline (airplane mode), complete an order: it shows as completed immediately with a quiet "Saved. Syncing…" hint; turn the network on: hint disappears, server values match.
- [ ] Two orders completed back to back for the same product: both apply, totals correct.

### Negative Cases

- [ ] Complete an order for more than the stock: "need N, only M in stock", status `out of stock`, no stock change, no sale row.
- [ ] Device B drains a batch while device A (offline) completes an order that needs it; reconnect A: the sale still books (repair batch labelled "Adjustment (drift repair)"), product stock clamps at 0, order stays completed.
- [ ] Complete an order whose product was deleted: clear message, nothing changes.
- [ ] Stop the function (or use a wrong URL in dev): the write retries, and after 5 failures the "not syncing" line appears.

### Edge Cases

- [ ] Hang: throttle the network hard so the request stalls. After about 10s the UI shows "Saved. Syncing…"; after about 30s the request is aborted and retried; the order ends up applied exactly once. Note the real timings for tuning `SendPolicy`.
- [ ] Kill the app mid-completion, relaunch: the operation resends and lands once; no duplicate sale rows.
- [ ] Sign out while a completion is queued, sign in again, complete the same order again: stock and batches change once (the C-3 repro).
- [ ] Reopen a completed order, complete it again: applies again (epoch 2), sale rows for both completions present.
- [ ] Order with a repair batch on one line, then reopen: reversal behaves as before.
- [ ] An order with an unusually large number of lines (find the limit) shows the "too large" message instead of hanging.
- [ ] Double-tap Complete quickly: one completion.

### Affected Areas

| File | Automated coverage | Where to look on-device |
|---|---|---|
| `functions/lib/operationLogic.js`, `functions/index.js` | Node, 100% for the new module | Firebase console: `audit_log` has a marker (`action: "operation"`) plus one entry per op; a replay adds nothing |
| `qml/helper/CompletionPlan.js`, `OperationKeys.js`, `SendPolicy.js`, `StuckWrites.js` | headless QML tests (logic verified in Node) | indirectly, via every scenario above |
| `qml/model/OutboxStore.qml` | planned QML tests | queued completions survive relaunch; nothing sends out of order on the same order |
| `qml/model/Gateway.qml` | planned, via fake XHR | timeouts, "not syncing" line, await behaviour: on-device only for real network timing |
| `qml/model/DataModel.qml` (`_tryCompleteOrder`) | planned QML tests | all scenarios above |
| Inventory/StockBatch/Orders/Transaction stores | planned QML tests | stock, batches, order list, history stay consistent after each scenario |
| `_completeImportedOrder`, `_reverseCompletedOrder`, `_tryAdjustOrder` | unchanged, existing tests | smoke test import, reopen and a return after completion: they must behave as before |

### Regression Tests (manual counterpart)

How you would notice each bug returning:

- [ ] **C-3:** after a hang plus sign-out/in plus re-complete, compare batch quantities before and after: only the ordered quantity is gone, and only one sale row exists for the order.
- [ ] **Partial completion:** kill the app at random moments during completion, repeat 5 times: never a state where stock dropped but the order is not completed, or the order completed but stock did not drop.
- [ ] **Silent hang:** with a stalled network the UI must not sit on a spinner forever.
- [ ] **Monkey:** for two minutes, toggle airplane mode, kill/relaunch and complete orders at random on both devices against the same product; afterwards `product.stock` equals the sum of batch `qtyRemaining` (plus clamped repairs), and every completed order has exactly one set of sale rows.
