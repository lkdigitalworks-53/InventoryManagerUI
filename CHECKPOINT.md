# CHECKPOINT: picker v2 slice S5a (2026-11-15, resume here)

Branch `feat/2026-11-15-picker-s5a-no-price-and-e2e` (from main @ `e35c758`, #196 merged). Commit email of the S5a commits: dextran52@gmail.com (project rule: lkdwtaher@gmail.com; the sweep commit uses it). Skills used: brainstorming (design already approved, defaults taken), ponytail, qt-qml, qt-ui-design. Plan: `docs/superpowers/plans/2026-11-15-product-picker-v2-s5a-no-price-and-e2e.md` (S5 cut into S5a..S5e, decisions S5a-D1..D7, questions Q1..Q3).

## PR #200 deep sweep (2026-11-15, same branch, resume here)
Scope read: the whole PR diff (25 files) plus the code it connects to (`NewOrderPicker`, `EditOrderPicker`, `ProductPickerRow`, `StatusPill`, `OrderDetailDialog`/`NewOrderDialog` hook literals, the workflow, the E2E against the server's id formats). Not a repo-wide audit.
- [x] Baseline re-run by hand: functions 1791/1791 at the PR head, CI 5110/5110 green on `c68b40c`; CI log shows PK-E1..E3 ran on the real emulator and passed.
- [x] FIXED: sheet display price ignored the legacy `price` when `sellingPrice` was `null` (row 0, total 0, order line priced 3). `PickerSheetModel.priceOf`; SHEET-44 fails on the old code (mutant run).
- [x] FIXED: vacuous assertion in PICK-39 removed; hidden-reason precedence added. NOP-32 (Node only): row never looser than `applyPlan` on price, 9 shapes x 6 carts; a loosening mutant fails it.
- [x] QML twins regenerated (`tst_PickerSheetModel`, `tst_ProductPickability`). Functions 1793/1793, scripts 1049/1049 (`SKILLS-INDEX.md` regenerated: the first run was 1047, caught here, would have been red in CI).
- [x] Docs: KNOWN-ISSUES 41 closed, 43 added; test plan count corrected (was 1786, not measured), checks 102 and 103 added; plan section; Skill 170 + index; AGENTS.
- [ ] Wait for CI on the sweep commit (the two regenerated QML twins are the only unproven part). If red, read `results.xml` of the QML job first.
- [ ] Process finding for Taher: both S5a commits and the PR body say `dextran52@gmail.com`, the project rule is `lkdwtaher@gmail.com`. Not rewritten (force push on a PR under review). Sweep commit has the right one.
- Open, not changed (KNOWN-ISSUES 43): "0.00 / pcs" on a no-price row; same `null` pattern in the legacy `_rebuildCatalog`; row stricter than commit for a line with no usable quantity.

## Done (S5a, original session)
- [x] Read roadmap: S1 to S4 merged; S5 split into S5a (this), S5b stock formula, S5c touch targets/Back key, S5d measure then tune, S5e a11y/themes/font scale/final device pass.
- [x] `hasPrice` hook in `ProductPickability` (no-price reason, only for rows not on the order), `PickerSheetModel` words and pill, both dialogs wired.
- [x] Tests: PICK-35..42, SHEET-41..43, NOW-17, EOW-20, E2EW-01..05; NOW-03, EOW-03, PICK-33, SHEET-05b, DORM-01 repinned on purpose; QML twins regenerated. 6 hand mutants killed.
- [x] E2E `test/e2e/pickerOrder.e2e.test.js` (PK-E1..E3) wired into `checks.yml`; dry-run 3/3 offline against in-memory Firestore + real `applyOperation`.
- [x] Node: functions 1791/1791, scripts 1049/1049. Code pushed as `ee99413`.
- [x] Docs: plan, test plan (S5a rows, device checks 97 to 101), KNOWN-ISSUES 23 fixed / 34 partly / 40 to 42, Skill 169 + SKILLS-INDEX, AGENTS, README, E2E roadmap. Old checkpoint archived to `docs/superpowers/specs/2026-11-13-pr196-second-sweep-CHECKPOINT.md`.

## Not done / next
- [x] PR #200 is open; CI green on `c68b40c` incl. `pickerOrder.e2e` 3/3 (KNOWN-ISSUES 41 closed).
- [ ] Device checks 97 to 101 (no build until Taher says).
- [ ] Taher decides Q1 (S5b stock formula), Q2 (legacy seed delete), Q3 (KI 29 cap).
- [ ] S5b next (money path before cosmetics), then S5c to S5e.
