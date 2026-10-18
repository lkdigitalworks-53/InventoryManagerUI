# Test plan — P1 stock movements as server-side atomic ledger rows (slices S1a and S1b: server)

**Branches:** S1a `feature/2026-10-16-p1-s1a-server-movements` (implemented), S1b (implemented 2026-10-18) `feature/2026-10-18-p1-s1b-derived-mutations`. S2-S4 get their own sections when planned.
**Spec:** `docs/superpowers/specs/2026-09-24-p1-server-side-stock-movements-design.md` (rev 2) · **Plans:** `plans/2026-09-24-p1-server-side-stock-movements-s1a.md`, `...-s1b.md`

**What it does:** every stock change on `inventory` writes a server-built `stock_movements` row in the same transaction: the client's `movements` on `recordDelta` (validated, must sum to the applied
delta) or a server-derived default (`adjustment`; `sale` inside `completeOrder`; `receipt` on create; `adjustment` on whole-record edit/delete/import). Identity and time are server-stamped, replays never
double-write, operations respect the 500-write ceiling, and `stock_movement` is no longer writable through any client endpoint. DEV only: no old-client or backfill concerns.

**Written before implementation.** The test bodies below were run in the design session's Node sandbox against a scratch copy of `main` @ `6da373d` (status column says so). The implementation PRs replace
"planned" with the CI result. QML is touched only in S1b Task 5 (constants and pins) and verified by CI only.

## 1. Unit test coverage

| Unit | Test file | Cases | Status |
|---|---|---|---|
| `movementLogic.js` (S1a) | `functions/test/movementLogic.test.js` | 24: absent movements; normalization (trim, defaults, `derived:false`); every kind accepts its direction; adjustment both signs, fractional qty; exactly 50 ok / 51 rejected; non-array/empty/junk entries; unknown/missing/non-string kind incl. `__proto__`, `toString`; qty 0/NaN/±Infinity/string/null; wrong sign per kind; bad `valueAtCost`; reason bounds (500); client identity fields dropped; `totalsMatch` sum and float tolerance; `deriveMovement` (applied delta, zero/noise/non-finite derive nothing, direction fallback to `adjustment`); `buildRows` (server stamps, deterministic ids, operation context, no `undefined` field); constants; monkey junk | **Verified** (Node, sandbox) 24/24, 100% line/branch |
| `stockOf`, `deriveForMutation` (S1b) | `functions/test/movementDerive.test.js` (part 1) | 8: `stockOf` number-or-0 (incl. `-Infinity`, `[]`); create receipt / zero / no stock / null after; create with negative stock falls back to `adjustment`; update difference / unchanged; float noise derives nothing; delete whole stock even if `after` carries stock; `opening_balance` = adjustment; absent / string stock counts as 0 on either side | **Verified** (Node, 2026-10-18) |
| requestId guard D-2 (S1b) | `functions/test/requestIdGuard.test.js` (13) | `isClientRequestId`: real ids pass (`req-<ms>-<rand>`, colons, 200 chars), `~` `/` empty 201 chars and non-strings refused; batch validator: bad requestId and bad `entityId` (whole batch rejected); `recordOperation` validator unchanged (still takes its own ids, still refuses `~` in the requestId); shared validators stay permissive; handlers `recordMutation` / `recordDelta` / `recordMutationsBatch`: `~` id and 201-char id = `400 invalid-request-id`, normal id still 200 | **Verified** (Node, 2026-10-18) |

## 2. Functional / end-to-end coverage (in-memory transaction fake, real logic)

| Unit | Test file | Cases | Status |
|---|---|---|---|
| `validateDeltaRequest`, `applyDelta`, closed path (S1a) | `functions/test/movementWiring.test.js` part 1 (17) | movements returned normalized; none = `[]`; needs inventory + stock delta; bad movement 400; all three validators reject entity `stock_movement`; stock + audit + server-stamped row in one transaction; no movements derives ONE `adjustment` from the applied delta; derived row after a clamp records the applied delta; zero change / non-inventory / non-stock field derive nothing; FIFO-style multi-movement sums; sum mismatch writes nothing (409); explicit movements + clamp mismatch; floor violation still wins; replay writes no second row; missing product 404; receipt +5 | **Verified** (Node, sandbox) |
| `validateOperationRequest`, `applyOperation` (S1a) | same file part 2 (13) | mutation op / `recordMutation` reject movements; write budget 166 ok / 167 rejected; explicit rows count; 200 `stock_batch` ops ok; bad movement reports `opIndex`; rows carry operation context; derived `sale` row for `completeOrder`; increase falls back to `adjustment`; non-inventory delta and mutation ops write no rows; whole-operation rollback on any mismatch; replay; largest operations write 499 / 401; later op index in id and row | **Verified** (Node, sandbox) |
| `recordDelta` handler (S1a) | `functions/test/index.handlers.test.js` (5 appended) | forwards normalized movements (client `id` dropped); none = empty list; invalid movement 400 and `applyDelta` never called; `movement-qty-mismatch` forwarded as 409; closed entity 400 | **Verified** (Node, sandbox) |
| S1a re-expected existing tests | `functions/test/operationLogic.test.js` (3) | +1 derived row in the 9-write test; the two 200-op tests use `stock_batch` ops | **Verified** (Node, sandbox) |
| `applyMutation` (S1b) | `movementDerive.test.js` part 2 (9) | update writes doc + audit + derived adjustment (3 writes); create is `receipt`, stock 0 writes none; delete of a product with stock writes -stock beside the PH3 marker, with 0 stock writes none; edit without stock change writes none; other entities never derive; stale `before` 409 writes nothing; replay writes no second row; string stock counts as 0 | **Verified** (Node, strict fake, 2026-10-18) |
| `recordMutationsBatch` (S1b) | part 3 (8) | `movements` rejected, cap 150 ok / 151 rejected; one row per stock-changing inventory item with ids `{requestId}:{entityId}~m0`, `productId`, `clientTimestamp`, `requestId`; batch delete derives -stock; any conflict = zero writes; replay and partly-overlapping batch write only new rows; non-inventory derives none; 150-item inventory batch = 450 writes, pessimistic count 750 pinned as the D-1 exposure | **Verified** (Node, strict fake, 2026-10-18) |
| operation mutation ops (S1b) | part 4 (8) | derived adjustment with operation context (`operationId`, `opType`, `opIndex`); no stock change derives none; inventory delete op derives -stock; non-inventory op derives none; stale `before` rejects whole operation, zero writes; two ops on the same product derive each step; 166 inventory mutation ops = 499 writes; 167 refused by the budget | **Verified** (Node, strict fake, 2026-10-18) |
| batch cap pin (S1b) | `batchMutationLogic.test.js` (3 changed) | pin 200 -> 150; F36b now a 150-item max batch; RES-B1 case-sensitivity probe `Cascade-x` (a `~` id is now invalid anyway) | **Verified** (Node, 2026-10-18) |
| budget vs client planner bound (S1b review) | `movementWiring.test.js` (1 added) | MAX_OPS 200 and at most 99 inventory ops = 500 writes accepted; 100 inventory ops = 501 refused; 201 ops refused. Pins why an order never reaches the server's `operation-too-large`: if `MAX_OPS` or the budget moves, this fails first | **Verified** (Node, 2026-10-18) |
| client cap mirror (S1b) | `tests/tst_Gateway.qml` (pin 150; 250 items split 150 + 100), `tests/tst_InventoryStore_upsertMany.qml` and `test/e2e/tst_BulkImportChunkingE2E.qml` (boundary indices 149/150), `test/e2e/tst_OrdersStoreE2E.qml` (message) | QML / E2E are CI-only, not run in the sandbox | **CI green** (PR #149, commit `5ae38da`, 5/5 checks) |

**Verification status (S1b implementation, 2026-10-18):** `cd functions && node --test` = 740/740 (S1b adds `movementDerive.test.js` 32 + `requestIdGuard.test.js` 13 and re-expects 3 tests in `batchMutationLogic.test.js`; the review round adds 1 in `movementWiring.test.js`, mutation-checked: `MAX_OPS` 210 and `MAX_TXN_WRITES` 480 both fail it). Line coverage 100% on `movementLogic.js`, `gatewayLogic.js`, `batchMutationLogic.js`, `operationLogic.js`. 11 deliberate mutations, all caught: recordMutation / batch / operation derive off; cap back to 200; delete not zeroing stock; create typed as adjustment; batch requestId guard off; batch entityId guard off; `~` allowed by the predicate; batch `movements` reject off; handler guard off. Files restored (`cmp` against backups). QML/E2E edits: CI only.
**Verification status (S1a implementation, 2026-10-16):** `cd functions && node --test` = 685/685 = 626 existing on `main` @ `0f081f2` + 59 new (24 + 17 + 13 + 5); `movementLogic.js` 100% line and branch, `gatewayLogic.js` and `operationLogic.js` 100% line; 7 deliberate mutations all caught. CI result and the on-device checklist below: pending.
**Review sweep addition (2026-10-17, PR #146 stacked review):** `functions/test/movementStrict.test.js`, 8 tests, suite = 693/693. Runs the S1a write paths against a STRICT Firestore fake (throws on an `undefined` field, an odd document path, a read after a write), the same product twice in one operation, and a pessimistic write count (each `serverTimestamp()` = +1). Mutation check: an injected `undefined` row field turns 6 of 8 red. The pessimistic test documents that the pinned 166-op maximum (499 writes) would exceed 500 IF transforms count; that Firestore behaviour is still unverified (see the review note).
**Design-session numbers (older base):** S1a: full suite 291/291 = 232 existing + 59 new. S1a + S1b: 313/313 = 232 existing + 81 new. 100% line coverage on `movementLogic.js`, `gatewayLogic.js`,
`operationLogic.js`, `batchMutationLogic.js` (branch: `movementLogic.js` 100%, the others carry pre-existing untested branches, none in new code). Implementation PRs: replace with the CI numbers.

**Deliberate mutations, all caught (12, S1a + S1b):** derive skipped in `applyMutation`, batch and operation mutation ops; batch cap 151; delete ignoring the `delete` rule in `deriveForMutation`; create typed as `adjustment`;
direction fallback removed; `applyDelta` derive removed; `completeOrder` default kind removed; write budget row term zeroed; `movements` no longer rejected on mutations and on batch. From the first draft: opIndex hard-coded to 0,
`stock_movement` re-added to `ENTITY_COLLECTIONS`, handler pass-through dropped. The design session also caught one real bug this way (batch derive read the doc after writing it).

## 3. Regression coverage

- All 232 existing server tests pass unchanged except the 4 on-purpose re-expectations listed above.
- Monkey: `validateMovements` junk-input test; the exhaustive kind x sign matrix stands in for a randomized fuzz. Add a fuzz if S2/S3 find a gap.
- Not covered by design: concurrent writers on the same product (Firestore transaction semantics; existing delta tests own it).

## 4. Firestore rules tests

No change in S1a/S1b (ledger writes already denied). S2 adds a rules test that a member cannot write `inventory` directly.

## 5. E2E (emulator)

S1b Task 5 keeps `tst_BulkImportChunkingE2E` valid at the new cap (chunks 150 + 100) and, as a side effect, runs product creation through the derived-row path on the real emulator. A dedicated
"stock_movements row exists" e2e assertion is planned for S2, when the client first sends real kinds.

## On-Device Test Plan

Run after Taher deploys functions to dev, once per slice. New tenant + user + products are enough (dev only). Use Firestore console to inspect `tenants/{id}/stock_movements`.

### S1a — Happy Path
- [ ] Unauthenticated `POST recordDelta` returns `401 missing-token` (function deployed).
- [ ] Any existing in-app stock change made through `recordDelta` (restock) adds one row `derived: true`, kind `adjustment`, signed `qty`, `actorUid`/`actorRole`/`serverTimestamp` filled by the server.
- [ ] Approve/complete an order of 2 lines: each product's stock drops as before and each gets one `sale` row, `derived: true`, with `operationId`.
- [ ] Manual `POST recordDelta` with a real ID token and `movements:[{kind:"loss", qty:-1, reason:"manual test", valueAtCost:10}]` and `deltas:{stock:-1}`: 200, one non-derived row.

### S1a — Negative Cases
- [ ] `movements:[{kind:"theft", qty:+1}]` returns `400 invalid-movement-qty`; nothing written.
- [ ] `movements:[{kind:"loss", qty:-5}]` with `deltas:{stock:-1}` returns `409 movement-qty-mismatch`; stock unchanged, no row, no audit entry.
- [ ] `POST recordMutation` with `entity:"stock_movement"` returns `400 unsupported-entity`; with a `movements` field on any entity returns `400 movements-not-supported`.
- [ ] Client SDK write to `stock_movements` is denied (rules).

### S1a — Edge Cases
- [ ] Repeat a request with the same `requestId`: replay, stock does not drop twice, still exactly one row.
- [ ] Complete an order for more units than in stock (offline oversell): the order still completes, the row records only what actually left stock.
- [ ] Product with stock 0 and a floor: `409 insufficient-quantity`, no row.

### S1b — Happy Path
- [ ] Create a product with stock 10: one `receipt` row of +10 (derived).
- [ ] Edit the product name only: no row. Edit stock 10 -> 7 in the product form: one `adjustment` of -3.
- [ ] Bulk import 250 rows with stock: imports complete in chunks of at most 150 (150 + 100); one `receipt` row per row with stock > 0.
- [ ] Delete a product that has stock 4: one `adjustment` of -4.

### S1b — Negative / Edge
- [ ] `POST recordMutation` / `recordDelta` / `recordMutationsBatch` with a requestId containing `~` (for example `completeOrder:x:1~0`): `400 invalid-request-id`, nothing written. Normal in-app saves are unaffected (ids are `req-<ms>-<rand>`).
- [ ] Bulk import of exactly 150 rows (one chunk) and 151 rows (two chunks): all rows land, one `receipt` row each. Watch the function log for a write-limit error on the 150-row chunk (D-1: the pessimistic count is 750, unverified on real Firestore). **Status 2026-10-18: NOT YET RUN (Taher).** This is the gate before production, not before merge. If it fails, say so: the cap must drop (about 100 is safe under both readings): `MAX_BATCH_SIZE`, `Gateway.maxBatchSize` and their pins move together.
- [ ] Stale edit (edit the same product on two devices): the conflict UI works as before, no row for the rejected write.
- [ ] Import file with 0-stock rows: those create products and no rows.
- [ ] **D-1 for orders.** Complete one real order of about 60 lines (each line one product with one stock batch, about 181 ops). It must complete, with one `sale` row per line. Same unverified-ceiling question as the import: if the function log shows a write-limit error, the order is retried and then parked (Retry / Discard), and `MAX_OPS` has to drop.
- [ ] **Too-big order message (device).** Import 80 products with stock 5 (CSV import, one stock batch each). Create ONE order with 70 lines (the product picker's search helps), quantity 1 each. Each line costs 3 changes (batch, stock, sale), so 70 lines plus the order = 211 changes, above the 200 limit. Tap Complete. Expect, with the phone online or offline: no spinner hang, the order stays `pending` (NOT `out of stock`), no stock changes, and the error reads "This order has too many items to complete in one step. Move some lines, or part of a line's quantity, to a second order, then complete both (70 lines, 211 changes, limit 200)". The function log shows NO `recordOperation` call for it.
- [ ] **Way out works (device).** Same order: delete 30 lines so 40 remain, add the 30 as a second order. Complete the first, then the second. Both complete, one `sale` row per line (70 in all), and each product's stock is 4.
- [ ] **Edge: exactly at the limit.** 66 lines of quantity 1 (one batch each) is 199 changes: completes. A 67th line makes 202: refused with the message above. (If it completes, the limit changed: tell Claude.)
- [ ] **Automated only, not a device step.** One line spread over many small batches (a product bought often) hits the same limit on its own: 199 batches of quantity 1 sold as one line of 199 = 202 changes. On a device this needs about 200 restocks of one product, so it is covered by `tests/tst_CompletionPlan.qml` only (the message then says "part of a line's quantity"; selling it as 99 + 100 in two orders fits). If a real shop shows this, see KNOWN-ISSUES.

### Affected Areas
- [ ] Restock, manual stock edit, order approve/complete, return, bulk import, product create/delete, offline-then-online sync: behavior identical to before, plus the extra rows.
- [ ] Bulk import progress/"chunked" notice still correct (cap is now 150).

### Regression Tests (manual counterpart)
- [ ] Two devices completing orders on the same product at nearly the same time: both apply, stock correct, two rows.
- [ ] Offline complete, reconnect: order completes once, one set of rows.
- [ ] Stuck-write indicator still appears after 5 server-side failures (spot check).
