# Test plan: P1 S2e-1, reason policy + server-stamped cost value

Branch `feat/2026-11-13-p1-s2e1-reason-policy-and-cost-snapshot` (PR #204, on `main` since #198 merged). Design: `specs/2026-11-13-p1-s2e1-reason-policy-and-cost-design.md` (E1..E8). Standard format (Skill 49). Nothing sends the new kinds from the app yet (S2e-2), so **nothing is visible on a device**. Node tests were RUN in the sandbox; QML tests run in CI only.

## 1. Unit tests

| File | Cases | Run? | Covers |
|---|---|---|---|
| `functions/test/reasonPolicy.test.js` | RP-01..06: one battery (715 checks per run, counted), 3000-list parity monkey, 49 hand mutants (22 for the invisible-character rule), real-module branch checks (RP-05), RP-06 every one of the 65,536 code units and the whole tag block, server and client, against an independently written table | RUN | Required kinds refused for undefined/null/empty/blank/1-2 chars/padded 2 chars; accepted for 3 chars, padded 3, 500 chars, Hindi, Gujarati, emoji, "...", astral math letters, the code point just past the tag block, lone high surrogates next to letters, text with zero-width or control characters that still has 3 visible ones; refused for 33 shapes whose visible part is under 3 characters (counted; zero-width space/joiner, soft hyphen, word joiner, direction marks, BOM, Hangul filler, braille blank, variation selectors, Mongolian/Khmer fillers, combining grapheme joiner, Arabic letter mark, bidi isolates, NBSP/ideographic space mixes; D-1b: NUL, C0 controls, DEL, NEL and C1 controls, tag characters, variation-selector supplement, both edges of the tag block, mixes); optional kinds accept anything; the TRIMMED reason is stored; check order (kind, direction, value, type/length, required); whole list fails if one movement fails; `unitCostOf` for 17 doc shapes (0, negative, NaN, Infinity, string, null, selling price only); `valueFor` for all six kinds (forged value ignored, `|qty|`, paise rounding both ways, fractions, overflow gives 0, big value survives), untouched kinds, no product doc leaves the value; `buildRows` end to end; client helper equals server for every kind x reason |
| `functions/test/movementWiring.test.js` (+10) | S2e-1 tests | RUN | `applyDelta`: loss valued 60 from price 20 with a forged value ignored; all six kinds use cost not selling price; no or invalid cost gives 0 and the loss is recorded; sale keeps its value; derived adjustment stays 0; a replay does not re-value after the cost changed; `applyOperation`: each op uses its own product's cost; sale and no-movement ops unchanged; refusal names the op index; single-delta refusal |
| `functions/test/index.handlers.test.js` (+1) | recordDelta | RUN | Theft with a blank reason: HTTP 400 `movement-reason-required`, `applyDelta` never called |
| `tests/tst_StockMovements.qml` (+8) | reason constants, `reasonRequired`, `reasonProblem`, validate refusal, invisible-character cases (18 hidden, 7 shown); second sweep: control and tag characters (11 hidden, 6 shown, incl. the surrogate-pair branch) and a NUL test of its own | CI only | Same contract in the Qt JS engine; the invisible-character twins are the proof that the phone reads the same pattern as Node. **If the tag-character twin is red in CI, Qt's engine reads the surrogate-pair branch differently from Node: that is a real on-device difference, not a flaky test** |
| `tests/tst_InventoryStore_movementKinds.qml` (+1) | `_movementsFor` with a required kind and no real reason | CI only | Pins today's silent degrade to a derived adjustment (KNOWN-ISSUES S2e-1 item 17) so S2e-2 changes it on purpose |
| `tests/tst_FailureCause.qml` | terminal code list | CI only | `movement-reason-required` is an app problem |

Suites after the second review sweep (on `main` @ `db64115`, measured 2026-11-17 after `npm ci` in `functions/`): `functions` 1899/1899; `movementLogic.js` 100% line / branch / function (`--experimental-test-coverage`). QML tests: CI only.

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
7. POST `recordDelta` with `{"entity":"inventory","entityId":"<id>","requestId":"x1","deltas":{"stock":-1},"movements":[{"kind":"theft","qty":-1}]}` expects HTTP 400 `movement-reason-required`; the same with `"reason":"counter theft"` expects 200 and, in Firestore, a `stock_movements` row with `valueAtCost` = the product's `price` (use a dev product). Also try `"reason":"\u200b\u200b\u200b"` (three zero-width spaces, send the JSON escape as is): expects HTTP 400 `movement-reason-required`. Same expectation for `"reason":"\u0000\u0000\u0000"` (three NULs) and `"reason":"\udb40\udc20\udb40\udc21\udb40\udc22"` (three Unicode tag characters, one surrogate pair each). `"reason":"\u0000abc"` passes the validator (three visible letters), but whether Firestore stores a string with an embedded NUL was NOT verified: treat a 5xx on that one as a finding (KNOWN-ISSUES S2e-1 item 18), not as a test error.
