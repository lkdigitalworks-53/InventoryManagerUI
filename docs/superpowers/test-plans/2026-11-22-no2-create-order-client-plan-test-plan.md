# Test plan: NO2, the create-order client plan (pure helpers, dormant)

Branch `feat/2026-11-22-no2-create-order-client-plan`. Design: `specs/2026-11-22-no2-create-order-client-plan-design.md` (D-NO2-1..9) on top of `specs/2026-11-21-create-order-atomic-operation-design.md` (D-NO-5b is the server rule). Standard format (Skill 49).
Honesty note: no QML component, no rules, no server file changed. Node tests were RUN in the sandbox against the real server code and the real `OrdersStore` normaliser. QML twins (`tests/tst_*.qml`) were run only in a throwaway Node harness (no Qt in the sandbox, by rule); the real qmltestrunner result is CI's (section 5). Data-driven (`_data`) QML functions cannot run in that harness; the ones touched here are not data-driven.

## 1. Unit tests
| File | Cases | Run? | Covers |
|---|---|---|---|
| `functions/test/createOrderPlan.test.js` (new) | 34 | RUN 34/34 | K-1..K-5 keys (nonce, key, `isCreateOrderKey` against every other op's key, other keys unchanged, server accepts the key for `createOrder` and refuses a restock key); T-1 the shared time checks; B-1..B-6 plan shape (mint + one create, bare token, trim, input untouched, key-list DRIFT GUARD vs the real `_normalizeOrder`, extra keys dropped, several lines with mixed tax and both discount types, free item); R-1..R-5 every refusal (55 inputs, 7 reasons, totals kept consistent where only the field bound can refuse), bad-line index, boundaries that ARE allowed, non-objects, 1 MiB; N-1..N-3 braces in every string, through the real server, single braces byte-identical; S-1..S-4 real server (one order doc, counter moves, NO ledger row, NO feed row, replay writes nothing, number not reused after a delete); F-1..F-3 `reflect` refusals; **P-1 chain probe: 2500 random carts through the REAL store normaliser -> planner -> real validator -> real apply -> reflect, stored doc equals the store's doc, 0 failures**; M-1 monkey (3000 inputs, both sides reached, accepted plans always pass the real validator); M-2 monkey (3000 damaged answers); C-1/C-2 `forCreateOrder`; D-1 label; G-1 dormancy |
| `functions/test/failureCauseCodes.test.js` | C-2 widened | RUN | every server code has a text for completion, restock, add product AND create order, and create order has the add's kind for each code |
| `functions/test/operationLogic.createOrder.test.js` | G-1 widened | RUN 37/37 | NO1's "no QML names createOrder" guard now allows the three helpers that must |
| `functions/test/addProductPlan.test.js` | G-1 narrowed | RUN 43/43 | the AP guard skips `OrderPlan.js` (it imports `AddProductPlan.js`) |
| `tests/tst_OrderPlan.qml` (new, CI) | 13 functions | harness 13/13 | the same cases for the QML engine (regex, number formatting, `Array.join`, rounding) |
| `tests/tst_OperationKeys.qml`, `tst_DescribeItem.qml`, `tst_FailureCause.qml`, `tst_AddProductPlan.qml` (CI) | +3, +1, +3, +1 | harness green | keys, label, `forCreateOrder`, `isIsoInstant`/`isIsoDate` |

Totals: functions 2206/2206 RUN (2172 on `main` + 34), scripts 1199/1199 (after the rebase and the review fix), `skills-index.js --check` current.
**Hand mutants of `OrderPlan.js`:** 60 first (48 killed, 12 survived). The 12 led to 9 new test rows (tax below 0, discount below 0 and above the subtotal and tax below 0 each with a CONSISTENT total, tax-row rate and amount below 0, defaults of adjustments and consumption, the id regex anchors) and 3 deletions: `typeof name !== "string"` (the trimmed-empty check already refuses a non-string), `results.length !== 2` (the mint/create counts already force it), and the nested double rounding of the total (equal to one rounding for whole cents, proven by a 2-million-case search that found no difference). Final sweep 56 of 56 killed, plus the "total check removed" mutant (2 tests fail). The review sweep added one line (unit price limit); its three mutants (`>=`, line removed, limit x10) are killed by R-1 and R-3.

## 2. Regression tests
`addProductPlan.test.js` (43), `operationLogic.createOrder.test.js` (37), `failureCauseCodes.test.js` and the whole functions suite pass unchanged: `AddProductPlan.build` now calls the two exported time checks, so its R-1/R-6 time cases are the regression for that refactor.

## 3. E2E
None. Nothing sends the operation; NO1's three emulator cases already cover the server. NO3 adds the device-path e2e.

## 4. Rules
None changed.

## On-device test plan (Taher; NO2 changes nothing visible, so this is a smoke of the build that contains the helpers)
Prerequisite: a build of this branch (CI builds it; I did not build or run the app).
### Happy path
1. Launch, sign in as owner on the dev tenant. Expect: no new toast, no console warning mentioning `OrderPlan`.
2. New order: customer "Asha", 2 products, Save. Expect: the order appears as `ORD-nnn` with the next number, as before (the OLD path still runs).
3. Complete it. Expect: stock down, a sale History row, as before.
### Negative
- New order with a customer of 1 character or no product: the dialog's own message, nothing saved.
- Stuck-writes sheet (Settings): existing items still show their labels (a restock reads "Restock", an add "Add product", an order completion "Order completion").
### Edge cases
- A customer typed `{{ord}}` through the OLD path is stored EXACTLY as typed (plain writes do no substitution); it changes by one space only once NO3 sends the order as an operation.
- Auto-approve ON then a new order: created, then completed, as before.
- A 20-digit unit price typed in New Order still saves through the OLD path (the cap arrives with NO3, KNOWN-ISSUES 101); nothing to check here beyond "no crash".
### Affected areas
None by design: the helpers are imported by no component.
### Regression
Add a product, restock it, edit a product, import a CSV: unchanged.
### Monkey
Two minutes of rapid New Order / complete / delete: no crash, no new warning in the console.
### Not testable on device until NO3
The plan itself, the id from the answer, the offline refusal.

## 5. CI result
PR #212, READ 2026-11-22 on head `3ddef0c` (after the rebase onto #210; functions 2206/2206 and scripts 1199/1199 re-run locally on the rebased tree): QML Tests success (the new `tst_OrderPlan.qml` and the four widened twins passed on the REAL qmltestrunner), Functions Tests success, Firestore + Storage Rules Tests success, E2E Tests success; Deploy Check, Deploy to Firebase and Record Deployed Commit skipped (nothing to deploy). The first push (`4ed491d`) had a merge conflict with #209/#210 (docs only: KNOWN-ISSUES, Skills, status, checkpoint), so CI did not start; resolved by rebase, my entries renumbered to KNOWN-ISSUES 94-99 and Skill 183.

## 6. Review sweep (2026-11-22, same branch, commits by `allibaas1998@gmail.com`)
- Method: `requesting-code-review` + `qt-qml-review` (Phase 1 lint; the six agent domains are empty: no QML component changed) + `ponytail-audit`, one agent, sequentially.
- Fix: `OrderPlan._line` refuses a unit price above `RestockFlow.MAX_UNIT_COST` (1e9), `bad-line`. R-1 +3 rows (1e9 + 0.01, a 20-digit price, 1e308), R-3 allows exactly 1e9 and pins `AddProductFlow.MAX_MONEY` equal to the limit; the Infinity-overflow row now uses a huge quantity. `tst_OrderPlan.qml` has the same rows.
- RUN after the fix: functions 2206/2206, scripts 1199/1199 (the full suites, with `npm ci`). QML twin: CI only.
- CI on the review commits: READ 2026-11-22 on head `c6ac2bc`: QML Tests 3351/3351 (the real qmltestrunner, with the new `tst_OrderPlan.qml` rows), Functions Tests 2206/2206, Firestore + Storage Rules Tests success, E2E Tests success; the bot comment says 5810/5810. Deploy jobs skipped. This note's own commit is docs only; its CI run is not read here.
- Docs corrected: see CHECKPOINT R4 and KNOWN-ISSUES 100-105.
