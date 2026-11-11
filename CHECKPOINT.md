# CHECKPOINT — 2026-11-11 PR #191 review pass 3 (QML CI red) + option A — resume here

**Branch:** work branch `fix/2026-11-11-pr191-review-sweep-3`, pushed to the PR's own branch `feat/2026-11-10-r5a-restock-dialog-supplier-in-op` (PR #191, base `main` @ `977cde0`), so the fixes are in the PR. Reviewed head before this pass: `4925f0f`.
**Commit identity:** `Taher (via Claude session) <lkdigitalworks@gmail.com>` (the Project rule). Earlier passes used other addresses; this account uses this one. Push goes through the session's attached repo access (`add_repo` with push), no token in any command, nothing written to `.git/config`.
**Rules in force:** no build or run, no Qt in the sandbox (CI is the QML oracle), push to the PR branch without asking, tests and test plan for every change, honest trade-offs, no parallel agents in this chat, caveman FULL in chat only (documents in normal prose), short scope per turn.
**Skills used:** `superpowers:requesting-code-review`, `qt-development-skills:qt-qml-review` (linter run, deep passes by hand), `ponytail:ponytail-audit` (lens only).
**Previous checkpoint archived:** `docs/superpowers/specs/2026-11-11-pr191-sweep2-prev-CHECKPOINT.md`.

## Task
Review PR #191 in full, fix what CI shows and what the review finds, in the same PR.

## Steps
- [x] 1. Clone (depth 1) and fetch the PR branch; REST only (GraphQL is blocked in these sessions).
- [x] 2. CI of head `4925f0f`: Functions, Firestore + Storage Rules and E2E green; QML Tests red with `Totals: 2942 passed, 2 failed`.
- [x] 3. Root causes, both in tests. (a) `tests/tst_RestockFlow.qml:239` declared `var long`: `long` is reserved in QML's JavaScript, the whole file failed to compile (`Expected token identifier`), so none of its tests ran. (b) `tests/tst_InventoryStore_movementKinds.qml` `test_restock_with_a_very_long_reason_still_queues_a_valid_row` still expected a 900-character reason to be cut to 500 and queued; since R5a `restock` refuses it (`reason-too-long`), so `_restockDelta` was null.
- [x] 4. Fixes: `var long` renamed; the stale test replaced by four (refused over 500 with nothing queued and no mint, exactly 500 whole, 500 plus padding, 501 refused); `-0` assertions use `verify` instead of QtTest's fuzzy `compare` on Infinity; the `String.normalize` dependent assertion is guarded and has its own availability test.
- [x] 5. Regression guard: `functions/test/qmlReservedWords.guard.test.js` (Q-1..Q-3) reads every QML and helper file. Proven first on the broken tree: it failed on exactly that line and nowhere else.
- [x] 6. Review findings. F-J (fixed, D-R5-13): `_cleanName` stripped U+200C and U+200D, which Hindi, Malayalam and Persian names need; now only U+200B, U+2060, U+FEFF are stripped, joiners are left out of the match key only (`_matchKey`), and `unusedPartyText` uses the same key. The invisible characters in the regex were literals; now escapes. Tests J-1..J-5 and N-7 updated; QML twin +3 functions. 4 of 4 hand mutants killed.
- [x] 7. Read by hand and found sound: `onActivated` exists (`AppComboBox` is a `QQC.ComboBox`), `applyRestockResults` adds the new supplier locally so the Activity text can name it, the plan trims the reason (so the 500 check is consistent), the typed-quantity label re-evaluates on text, the "+" toggle clears the field so a hidden field never blocks Confirm, other `restock` caller (`DataModel`) passes no party. Linter on the changed QML: no category that main does not already have.
- [x] 8. Docs: KNOWN-ISSUES (open decision), design D-R5-13, test plan (F-J..F-L, steps 29 to 31, counts), status doc section 11, AGENTS, README, Skill 162 rules 15 to 18.
- [x] 9. Suites here: functions 1421/1421 (1413 after the rebase, +8).
- [x] 10. Pushed `4925f0f..46630b9` to the PR branch. CI of `46630b9`: QML Tests 2975 passed, 0 failed (was 2942 passed, 2 failed; `tst_RestockFlow` compiled and ran for the first time, engine has `String.normalize`), Functions, Rules and E2E green, deploy jobs skipped (not a merge).
- [x] 11. Taher answered the open decision: option A. Built: `RestockFlow.queuedNewSupplierClash(newName, items)` + `supplierPendingText`, called in `InventoryStore.restock` after the same-product hold (reads `OutboxStore.items`). Tests: `restockR5a.test.js` K-1..K-7 (7 of 7 hand mutants killed), `restockWire.test.js` rig got an `OutboxStore` fed by the fake Gateway (it broke W-1, W-4, W-14, M-1 first) + W-15..W-20, QML twins (6 functions, CI only). Docs: KNOWN-ISSUES, D-R5-14, test plan F-M and steps 32 to 35, status doc, AGENTS, README, Skill 162 rule 19. Suites here: functions 1434/1434, scripts 1049/1049.
- [ ] 12. Push and read CI of the new head (QML twins run only in CI).


## Not fixed on purpose
Two phones offline adding the same new supplier (O1) still create two; needs a server rule. A parked restock keeps holding its new supplier name until retried or discarded (accepted cost of option A).
Everything in the previous checkpoint's list still stands (`{{sup}}` text does not name the field; Qt cuts a long paste silently; O1 two offline devices; `AddProductDialog` inline add-supplier row). A cost typed with non-ASCII digits (Devanagari numerals) is refused as not a valid amount, never booked wrong.

## Next session (pick up here)
1. Read CI of the PR head after the option A push; fix anything the QML twins show (they have never run).
2. Taher: device steps 1 to 35 of the test plan.
3. Then R5b on a NEW branch off `main` after #191 merges (design section 5), then R6.
