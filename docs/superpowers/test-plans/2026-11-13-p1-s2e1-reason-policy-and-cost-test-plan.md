# Test plan: P1 S2e-1, reason policy + server-stamped cost value

Branch `feat/2026-11-13-p1-s2e1-reason-policy-and-cost-snapshot` (stacked on #198). Design: `specs/2026-11-13-p1-s2e1-reason-policy-and-cost-design.md` (E1..E8). Standard format (Skill 49). Nothing sends the new kinds from the app yet (S2e-2), so **nothing is visible on a device**. Node tests were RUN in the sandbox; QML tests run in CI only.

## 1. Unit tests

| File | Cases | Run? | Covers |
|---|---|---|---|
| `functions/test/reasonPolicy.test.js` | RP-01..04: one battery (about 245 checks), 3000-list parity monkey, 27 hand mutants | RUN | Required kinds refused for undefined/null/empty/blank/1-2 chars/padded 2 chars; accepted for 3 chars, padded 3, 500 chars, Hindi, emoji; optional kinds accept anything; the TRIMMED reason is stored; check order (kind, direction, value, type/length, required); whole list fails if one movement fails; `unitCostOf` for 17 doc shapes (0, negative, NaN, Infinity, string, null, selling price only); `valueFor` for all six kinds (forged value ignored, `|qty|`, paise rounding both ways, fractions, overflow gives 0, big value survives), untouched kinds, no product doc leaves the value; `buildRows` end to end; client helper equals server for every kind x reason |
| `functions/test/movementWiring.test.js` (+10) | S2e-1 tests | RUN | `applyDelta`: loss valued 60 from price 20 with a forged value ignored; all six kinds use cost not selling price; no or invalid cost gives 0 and the loss is recorded; sale keeps its value; derived adjustment stays 0; a replay does not re-value after the cost changed; `applyOperation`: each op uses its own product's cost; sale and no-movement ops unchanged; refusal names the op index; single-delta refusal |
| `functions/test/index.handlers.test.js` (+1) | recordDelta | RUN | Theft with a blank reason: HTTP 400 `movement-reason-required`, `applyDelta` never called |
| `tests/tst_StockMovements.qml` (+4) | reason constants, `reasonRequired`, `reasonProblem`, validate refusal | CI only | Same contract in the Qt JS engine (shim-run in Node 4/4) |
| `tests/tst_FailureCause.qml` | terminal code list | CI only | `movement-reason-required` is an app problem |

Suites after the change: `functions` 1686/1686 (was 1671), script suite 1061/1061.

## 2. Functional / rules / e2e
- Functional: the wiring tests above run the real `applyDelta` and `applyOperation` against a fake transaction.
- Rules: unchanged (ledger stays server-write only). E2E (emulator): none; first QML-to-server case arrives with S2e-2.
- Guards: `failureCauseCodes.test.js` (server codes vs the client's lists) stays green with the new code listed; `stockMovementsParity.test.js` (client vs server validation) stays green.

## 3. Regression
- Order completion, restock, delete and edit flows write only derived kinds or sale/receipt: unchanged (wiring tests for them still pass untouched).
- 17 existing tests failed on fixtures that lacked a reason; 7 fixture lines in 6 files got one; no assertion weakened.

## On-device test plan (Taher; build needed; dev tenant)
Honest scope: **no feature to test yet**; this is a no-regression pass.

### Happy path
1. Install, sign in, complete a normal order and restock: both succeed as before.
2. Edit a product's stock in the form: the change saves (derived adjustment, no reason asked).

### Negative
3. Try an order that exceeds stock: still refused with the usual message.

### Edge cases
4. Go offline, complete an order, go online: it syncs (the queued write is not rejected).

### Affected areas
5. Stock history / activity for a product shows the usual rows with no new errors in the log (look for `movement-reason-required`: it must NOT appear).

### Regression
6. Refresh row, New Order, Edit Order, Restock still behave (one pass each).

### Optional server check (curl, owner token)
7. POST `recordDelta` with `{"entity":"inventory","entityId":"<id>","requestId":"x1","deltas":{"stock":-1},"movements":[{"kind":"theft","qty":-1}]}` expects HTTP 400 `movement-reason-required`; the same with `"reason":"counter theft"` expects 200 and, in Firestore, a `stock_movements` row with `valueAtCost` = the product's `price` (use a dev product).
