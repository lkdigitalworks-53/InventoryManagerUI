# Test plan — P1 stock movements as server-side atomic ledger rows (slices S1a and S1b: server)

**Branches (planned):** S1a `feature/2026-09-25-p1-s1a-server-movements`, S1b `feature/2026-09-26-p1-s1b-derived-mutations` (names may differ). S2-S4 get their own sections when planned.
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
| `stockOf`, `deriveForMutation` (S1b) | `functions/test/movementDerive.test.js` (part 1) | 4: `stockOf` number-or-0; create receipt / zero / no stock; update difference / unchanged; delete whole stock, `opening_balance`, delete ignoring `after` | **Verified** (Node, sandbox) |

## 2. Functional / end-to-end coverage (in-memory transaction fake, real logic)

| Unit | Test file | Cases | Status |
|---|---|---|---|
| `validateDeltaRequest`, `applyDelta`, closed path (S1a) | `functions/test/movementWiring.test.js` part 1 (17) | movements returned normalized; none = `[]`; needs inventory + stock delta; bad movement 400; all three validators reject entity `stock_movement`; stock + audit + server-stamped row in one transaction; no movements derives ONE `adjustment` from the applied delta; derived row after a clamp records the applied delta; zero change / non-inventory / non-stock field derive nothing; FIFO-style multi-movement sums; sum mismatch writes nothing (409); explicit movements + clamp mismatch; floor violation still wins; replay writes no second row; missing product 404; receipt +5 | **Verified** (Node, sandbox) |
| `validateOperationRequest`, `applyOperation` (S1a) | same file part 2 (13) | mutation op / `recordMutation` reject movements; write budget 166 ok / 167 rejected; explicit rows count; 200 `stock_batch` ops ok; bad movement reports `opIndex`; rows carry operation context; derived `sale` row for `completeOrder`; increase falls back to `adjustment`; non-inventory delta and mutation ops write no rows; whole-operation rollback on any mismatch; replay; largest operations write 499 / 401; later op index in id and row | **Verified** (Node, sandbox) |
| `recordDelta` handler (S1a) | `functions/test/index.handlers.test.js` (5 appended) | forwards normalized movements (client `id` dropped); none = empty list; invalid movement 400 and `applyDelta` never called; `movement-qty-mismatch` forwarded as 409; closed entity 400 | **Verified** (Node, sandbox) |
| S1a re-expected existing tests | `functions/test/operationLogic.test.js` (3) | +1 derived row in the 9-write test; the two 200-op tests use `stock_batch` ops | **Verified** (Node, sandbox) |
| `applyMutation` (S1b) | `movementDerive.test.js` part 2 (8) | update writes doc + audit + derived adjustment; create is `receipt` (stock 0 writes none); delete writes -stock; edit without stock change writes none; other entities never derive; stale `before` 409 writes nothing; replay writes no second row; non-numeric stock counts as 0 | **Verified** (Node, sandbox) |
| `recordMutationsBatch` (S1b) | part 3 (6) | movements rejected, cap 150 ok / 151 rejected; one row per stock-changing inventory item with correct ids/`productId`/`clientTimestamp`; any conflict = zero writes; replay; non-inventory derives none; 150-item inventory batch = 450 writes | **Verified** (Node, sandbox) |
| operation mutation ops (S1b) | part 4 (4) | derived adjustment with operation context; no stock change derives none; stale `before` rejects whole operation; 166 inventory mutation ops = 499 writes | **Verified** (Node, sandbox) |
| batch cap pin (S1b) | `batchMutationLogic.test.js` (1 changed) | pin moves 200 -> 150 | **Verified** (Node, sandbox) |

**Totals (sandbox):** S1a: full suite 291/291 = 232 existing + 59 new. S1a + S1b: 313/313 = 232 existing + 81 new. 100% line coverage on `movementLogic.js`, `gatewayLogic.js`,
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
- [ ] Bulk import 200 rows with stock: imports complete in chunks of at most 150; one `receipt` row per row with stock > 0.
- [ ] Delete a product that has stock 4: one `adjustment` of -4.

### S1b — Negative / Edge
- [ ] Stale edit (edit the same product on two devices): the conflict UI works as before, no row for the rejected write.
- [ ] Import file with 0-stock rows: those create products and no rows.
- [ ] Order completion containing 166+ inventory lines is rejected with `operation-too-large` (unrealistic; verify the message path only).

### Affected Areas
- [ ] Restock, manual stock edit, order approve/complete, return, bulk import, product create/delete, offline-then-online sync: behavior identical to before, plus the extra rows.
- [ ] Bulk import progress/"chunked" notice still correct (cap is now 150).

### Regression Tests (manual counterpart)
- [ ] Two devices completing orders on the same product at nearly the same time: both apply, stock correct, two rows.
- [ ] Offline complete, reconnect: order completes once, one set of rows.
- [ ] Stuck-write indicator still appears after 5 server-side failures (spot check).
