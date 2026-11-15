# Test plan: AP2, the add-product client plan (pure helpers, dormant)

Branch `feat/2026-11-15-ap2-add-product-client-plan`. Design: `specs/2026-11-15-ap2-add-product-client-plan-design.md` (D-AP2-1..11) on top of `specs/2026-11-13-add-product-atomic-operation-design.md` section 9. Standard format (Skill 49).
Honesty note: no QML component, no rules, no server file changed. Node tests were RUN in the sandbox against the real server code. QML twins (`tests/tst_*.qml`) were run only in a throwaway Node harness (no Qt in the sandbox, by rule); the real qmltestrunner result is CI's (section 5).

## 1. Unit tests
| File | Cases | Run? | Covers |
|---|---|---|---|
| `functions/test/addProductPlan.test.js` (new) | 43 | RUN 43/43 | K-1..K-6 keys (nonce, key, `isAddProductKey`, restock key unchanged, server accepts the key and refuses a restock key, history ids); B-1..B-10 plan shape (new/known/no supplier, stock 0, no SKU, fractional stock, rounding, trim and input untouched, key-list drift vs `_newProductDoc`, `_buildBatchDoc`, `recordCreated`, 5000-char text cut with surrogate pairs); R-1..R-6 every refusal reason with 60 inputs (12 added in the PR #201 sweep: a timestamp or day with the right shape that is not a real instant), boundaries, real times that must stay accepted (R-6: leap days, year ends, every fraction length, `date` != UTC day), non-object input, 1 MiB doc, nothing built when refused; N-1..N-4 neutralise (pairs, triples, singles, unicode) and through the real server; S-1..S-8 the real server (apply, reflect, replay, K-2 closed, two adds, every supplier x stock combination, ledger rows); F-1..F-3 reflect refuses 38 damaged answers; M-1, M-2 seeded monkeys (M-1 also reaches time-shaped junk and asserts every accepted plan holds a real instant and a real day); C-1, C-2 `forAddProduct`; D-1 label; G-1 dormancy |
| `functions/test/failureCauseCodes.test.js` | 3 (C-2 widened) | RUN 3/3 | every server error code is a person-facing text or an app bug for completion, restock AND add product |
| `functions/test/operationLogic.addProduct.test.js` | G-1 narrowed | RUN 34/34 | the AP1 pin now skips `qml/helper/` only |
| `tests/tst_AddProductPlan.qml` (new, CI) | 23 functions, 68 rows | harness: 191 rows green over the four QML files (68 in this file) | the same cases for the QML engine (regex lookahead, number formatting, `Array.join`) |
| `tests/tst_OperationKeys.qml`, `tst_FailureCause.qml`, `tst_DescribeItem.qml` | +5, +3, +2 | harness green | keys, `forAddProduct`, label |

Hand mutants (35, each applied to the source, the two Node files run, source restored): neutralise lookahead and the `}` half, trim, batch at stock 0, supplier mint always, ids without the nonce (both), tax bound, price bound, overflow check, money rounding, party always, too-large check, mint twice, batch qty, nonce equality, feed required, feed kind, ISO check, supplier brace guard, surrogate guard, title clip, dropped taxPercent, dropped supplier on the product, batch note, `reflect` batch rule and batch supplier, nonce length, key prefix, `isAddProductKey` offset, created id, mint kind, add `not-found`, label, label detail. **35 of 35 killed** (one mutant first did not match its source line and was fixed: a mutant that does not apply proves nothing). PR #201 sweep, 4 more on the new time guard: no round trip, `now` unchecked and `date` unchecked are killed; comparing 10 instead of 19 characters survives and is EQUIVALENT (brute force over 259203 parseable hour/minute/second values on three days: 0 inputs differ), so it is not a gap. **38 of 39 killed, 1 proven equivalent.** Also a throwaway chain probe (4000 adversarial inputs: 100-character nonce, 5000-character text, emoji, lone surrogate, brace pairs, `$` and backslash text) through build, the real validator, the real apply, reflect and a stored-doc round trip: 3452 round-tripped, 548 refused by the planner, 0 failures.

## 2. Regression tests
- Full functions suite: 1882/1882 green on the branch rebased onto #200 (RUN; 43 of them are the new `addProductPlan.test.js`).
- Restock keys and planner untouched in behaviour: K-4 and the whole `restockPlan.test.js`.
- AP1 server suite untouched except the narrowed G-1.
- `qmlReservedWords.guard.test.js` passes over the new QML (no reserved word as a variable).

## 3. E2E
No emulator case: nothing sends the operation yet. The plan-through-real-server cases (S-1..S-8) are the substitute and run against the same engine the emulator cases of AP1 use.

## 4. Rules
Unchanged.

## On-device test plan (Taher; AP2 changes nothing visible, so this is a smoke of the build that contains the helpers)
Prerequisite: a build of this branch (CI builds it; I did not build or run the app).
### Happy path
1. Launch, sign in as owner on the dev tenant. Expect: no new toast, no console warning mentioning `AddProductPlan`.
2. Add a product with stock 5 and a NEW supplier through the dialog (the OLD path). Expect: product, supplier, batch, a History row, an Activity row, as before.
3. Restock it by 2: stock 7, "Restocked" row. Complete an order of 1: stock 6.
### Negative
- Add a product with an empty name: the dialog's own message, nothing saved.
- Stuck-writes sheet (Settings): open it; existing items still show their labels (a restock reads "Restock", an order "Order completion").
### Edge cases
- A name containing `{{prd}}` typed through the OLD path is stored EXACTLY as typed: plain writes do no `{{...}}` substitution (corrected in the PR #201 sweep; the earlier text of this step claimed the opposite). Expect the list, the History row and the Activity row to show `{{prd}}` literally. It changes by one space (`{ {prd} }`) only once AP3 sends the add as an operation.
- Stock 0 and a fractional stock on the old path: same behaviour as before this PR.
### Affected areas
None by design: the helpers are not imported by any component.
### Regression
Import a CSV with 3 products; restock; edit a product; delete a product: unchanged.
### Monkey
Two minutes of rapid add / restock / order from the dialog and the list: no crash, no new warning in the console.
### Not testable on device until AP3
The plan itself, the id from the answer, the photo, the offline refusal.

## 5. CI result
PR #201 head `1a99696` (before the rebase and the sweep): QML Tests, Functions Tests, Firestore + Storage Rules Tests and E2E Tests all success; Deploy Check skipped (nothing to deploy).
After the rebase onto #200 (`b211dcf`) and the PR #201 sweep (code `49abb69`, then the docs commit): the checks run on the PR; the result is recorded here when read (see the checkpoint). The new twin rows (10 refusals, one boundary test) are checked by CI's real qmltestrunner only.
