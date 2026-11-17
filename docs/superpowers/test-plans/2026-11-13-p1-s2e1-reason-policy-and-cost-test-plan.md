# Test plan: P1 S2e-1, reason policy + server-stamped cost value

Branch `feat/2026-11-13-p1-s2e1-reason-policy-and-cost-snapshot` (stacked on #198). Design: `specs/2026-11-13-p1-s2e1-reason-policy-and-cost-design.md` (E1..E8). Standard format (Skill 49). Nothing sends the new kinds from the app yet (S2e-2), so **nothing is visible on a device**. Node tests were RUN in the sandbox; QML tests run in CI only.

## 1. Unit tests

| File | Cases | Run? | Covers |
|---|---|---|---|
| `functions/test/reasonPolicy.test.js` | RP-01..05: one battery (512 checks per run), 3000-list parity monkey, 37 hand mutants (10 for the invisible-character rule), real-module branch checks (RP-05) | RUN | Required kinds refused for undefined/null/empty/blank/1-2 chars/padded 2 chars; accepted for 3 chars, padded 3, 500 chars, Hindi, Gujarati, emoji, "...", text with zero-width characters that still has 3 visible ones; refused for 18 invisible-only shapes (zero-width space/joiner, soft hyphen, word joiner, direction marks, BOM, Hangul filler, braille blank, variation selectors, Mongolian/Khmer fillers, combining grapheme joiner, Arabic letter mark, bidi isolates, NBSP/ideographic space mixes); optional kinds accept anything; the TRIMMED reason is stored; check order (kind, direction, value, type/length, required); whole list fails if one movement fails; `unitCostOf` for 17 doc shapes (0, negative, NaN, Infinity, string, null, selling price only); `valueFor` for all six kinds (forged value ignored, `|qty|`, paise rounding both ways, fractions, overflow gives 0, big value survives), untouched kinds, no product doc leaves the value; `buildRows` end to end; client helper equals server for every kind x reason |
| `functions/test/movementWiring.test.js` (+10) | S2e-1 tests | RUN | `applyDelta`: loss valued 60 from price 20 with a forged value ignored; all six kinds use cost not selling price; no or invalid cost gives 0 and the loss is recorded; sale keeps its value; derived adjustment stays 0; a replay does not re-value after the cost changed; `applyOperation`: each op uses its own product's cost; sale and no-movement ops unchanged; refusal names the op index; single-delta refusal |
| `functions/test/index.handlers.test.js` (+1) | recordDelta | RUN | Theft with a blank reason: HTTP 400 `movement-reason-required`, `applyDelta` never called |
| `tests/tst_StockMovements.qml` (+6) | reason constants, `reasonRequired`, `reasonProblem`, validate refusal, invisible-character cases (18 hidden, 7 shown) | CI only | Same contract in the Qt JS engine; the invisible-character twin is the proof that the phone reads the same pattern as Node |
| `tests/tst_FailureCause.qml` | terminal code list | CI only | `movement-reason-required` is an app problem |

Suites after the review sweep (rebased on `main` @ `db64115`): `functions` 1898/1898, script suite 1061/1061; `movementLogic.js` 100% line / branch / function (measured with `--experimental-test-coverage`, lcov branch list empty).

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
7. POST `recordDelta` with `{"entity":"inventory","entityId":"<id>","requestId":"x1","deltas":{"stock":-1},"movements":[{"kind":"theft","qty":-1}]}` expects HTTP 400 `movement-reason-required`; the same with `"reason":"counter theft"` expects 200 and, in Firestore, a `stock_movements` row with `valueAtCost` = the product's `price` (use a dev product). Also try `"reason":"\u200b\u200b\u200b"` (three zero-width spaces, send the JSON escape as is): expects HTTP 400 `movement-reason-required`.
