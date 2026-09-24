# Test plan — P1 stock movements as server-side atomic ledger rows (slice S1: server)

**Branch (planned):** S1 `feature/2026-09-25-p1-s1-server-movements` (name may differ). S2-S4 get their own sections when planned.
**Spec:** `docs/superpowers/specs/2026-09-24-p1-server-side-stock-movements-design.md` · **Plan:** `docs/superpowers/plans/2026-09-24-p1-server-side-stock-movements-s1.md`

**What it does:** `recordDelta` and `recordOperation` accept optional `movements` next to a stock delta and write server-built
`stock_movements` rows (CGST 56(2)) in the same transaction. Rows carry server-stamped identity and time; quantities must sum to the
delta the server applied; `stock_movement` is no longer writable through any client endpoint. Backward compatible: no `movements`, no rows.

**Written before implementation.** Test bodies below were run in the design session's Node sandbox against a scratch copy of `main`
(status column says so). The implementation PR must replace "planned PR" with the CI result. QML is untouched in S1.

## 1. Unit test coverage

| Unit | Test file | Cases | Status |
|---|---|---|---|
| `functions/lib/movementLogic.js` | `functions/test/movementLogic.test.js` | 21: absent/null movements; normalization (trim, defaults `reason ""`, `valueAtCost 0`, `batchRef null`); every kind accepts its own direction; adjustment both signs and fractional qty; exactly 50 ok / 51 rejected; non-array, `[]`, null/number entries; unknown/missing/non-string kind incl. `__proto__` and `toString`; qty 0/NaN/±Infinity/string/null/undefined; wrong sign per kind (receipt, sales_return, 7 decrease kinds); bad `valueAtCost`; reason non-string / 501 chars / exactly 500; bad `batchRef`; client identity fields dropped; `totalsMatch` sums, float tolerance only; `buildRows` stamps identity, deterministic ids, operation context, never an `undefined` field, empty in gives empty out; monkey junk never throws | **Verified** (Node, sandbox): 21/21, 100% line/branch/function |

## 2. Functional / end-to-end test coverage (in-memory transaction fake, real logic)

| Unit | Test file | Cases | Status |
|---|---|---|---|
| `validateDeltaRequest`, `applyDelta` | `functions/test/movementWiring.test.js` | 14: movements returned normalized; no field = `[]` (backward compatible); needs `inventory` + `stock` delta; bad movement is 400; **all three validators reject entity `stock_movement`**; stock + audit + server-stamped row in one transaction (actor, role, time, productId from `entityId`); no movements = no rows; two FIFO-style movements sum to delta, ids `~m0`/`~m1`; sum mismatch writes nothing (409); clamp changing the applied delta mismatches and writes nothing; floor violation still wins; replay of same `requestId` writes no second row; missing product 404; receipt (+5) works | **Verified** (Node, sandbox) |
| `validateOperationRequest`, `applyOperation` | same file | 9: mutation op with movements rejected with `opIndex`; total cap 90 exactly ok / 91 rejected with `opIndex`; bad movement reports its op index; rows written with `operationId`/`opType`/`opIndex`; mismatch on ANY op rejects the WHOLE operation, zero writes; replay writes no second set; ops without movements unchanged; movement on a later op carries that op's index; **max-size operation (200 ops, 90 with movements) writes ≤ 500 docs** | **Verified** (Node, sandbox) |
| `recordDelta` handler | `functions/test/index.handlers.test.js` (5 appended) | forwards validated movements (client `id` dropped, reason trimmed); no movements = empty list; invalid movement 400 and `applyDelta` never called; `movement-qty-mismatch` forwarded as 409 with `field`/`current` (0 survives); closed entity 400 `unsupported-entity` | **Verified** (Node, sandbox) |

**Totals (sandbox, `main` @ `2c1e5f6` + S1 files):** full `functions/` suite 281/281 = 232 existing + 49 new. `movementLogic.js`, `gatewayLogic.js`,
`operationLogic.js`: 100% line coverage (`gatewayLogic.js` branch 92%: pre-existing branches, none in the new code). Planned PR: replace with the CI numbers.

**Deliberate mutations, all caught (10):** drop the sign check; `totalsMatch` always true; raise the 50 cap; skip the row-write loop in `applyDelta`;
change `baseId`; drop the operation cap; allow `movements` on mutation ops; hard-code `opIndex: 0` (survived once, killed by the "later op" test);
re-add `stock_movement` to `ENTITY_COLLECTIONS`; drop `movements` pass-through in `index.js`.

## 3. Regression test coverage

- Existing `gatewayLogic`, `operationLogic`, `lockLogic`, `batchMutationLogic`, `cutoverLogic`, handler suites: all 232 pass unchanged (no edits to their files).
- Monkey: `movementLogic` junk-input test (unit); 300-run randomized sum/cap fuzz is **not** written; the exhaustive kind x sign matrix stands in for it. Add if S2/S3 find a gap.
- Not covered by design: concurrent writers on the same product (Firestore transaction semantics, not our code; the existing delta tests own that).

## 4. Firestore rules test coverage

No change. `test/firestore.rules.test.js` already asserts client writes to `stock_movements` are denied (`LEDGER_COLLECTIONS`). S1 adds no rule.
CI runs it in the `firestore-rules-tests` job as before.

## 5. E2E (emulator)

None new in S1. The `recordOperation` emulator e2e from C-3 stays as is. A `recordDelta`-with-movements emulator case is worth adding in S2
when the client first sends real movements (Q: cost of emulator time vs value; the unit + fake-transaction coverage above is the authority for S1).

## On-Device Test Plan

S1 changes no client code, so nothing new is visible in the app. This section proves the deploy did not break anything and that the endpoint
behaves on real Firestore. Run after Taher deploys functions to dev. Do not start S2 before it passes.

### Happy Path
- [ ] Unauthenticated `POST` to `recordDelta` returns `401 missing-token` (confirms the new function is deployed and reachable).
- [ ] With a real ID token: `POST recordDelta` `{entity:"inventory", entityId:<real product>, requestId:"req-manual-1", deltas:{stock:-1}, movements:[{kind:"loss", qty:-1, reason:"manual test", valueAtCost:10}]}` returns 200; the product's `stock` dropped by 1; Firestore has `audit_log/req-manual-1` and `stock_movements/req-manual-1~m0` with `actorUid`, `actorRole`, `serverTimestamp` filled by the server.
- [ ] Same call with `deltas:{stock:+2}` and `movements:[{kind:"receipt", qty:2}]` returns 200 and a `+2` row.

### Negative Cases
- [ ] `movements:[{kind:"theft", qty:+1}]` returns `400 invalid-movement-qty`; stock unchanged, no row.
- [ ] `movements:[{kind:"loss", qty:-5}]` with `deltas:{stock:-1}` returns `409 movement-qty-mismatch`; stock unchanged, no row, no audit entry.
- [ ] `POST recordMutation` with `entity:"stock_movement"` returns `400 unsupported-entity`.
- [ ] Client SDK write to `stock_movements` is denied (rules), as before.

### Edge Cases
- [ ] Repeat the first happy-path call with the SAME `requestId`: returns 200 replay, stock does NOT drop again, still exactly one row.
- [ ] `deltas:{stock:-1}` on a product with stock 0 and `floors:{stock:0}`: `409 insufficient-quantity`, no row.
- [ ] Decimal quantity (`-0.5`) on a product that uses decimals, if any exist.
- [ ] `movements: []` returns `400 invalid-movements`; omitting `movements` entirely behaves exactly as before.

### Affected Areas
- [ ] Every existing stock path in the app still works with the redeployed functions: restock, manual stock edit, order approve/complete, return, bulk import. Behavior identical to before; **no** `stock_movements` rows appear (old client sends none).
- [ ] `recordOperation` `completeOrder` still completes an order (S1 touched its transaction code).

### Regression Tests (manual counterpart)
- [ ] Two devices completing orders on the same product at nearly the same time: both apply, stock correct (delta path untouched, re-verify after deploy).
- [ ] Offline complete, reconnect: order completes once (replay-safe path untouched, re-verify after deploy).
- [ ] Stuck-write indicator still appears after 5 server-side failures (unchanged, spot check).
