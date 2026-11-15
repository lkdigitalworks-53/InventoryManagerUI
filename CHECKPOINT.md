# CHECKPOINT: picker v2 slice S5a (2026-11-15, resume here)

Branch `feat/2026-11-15-picker-s5a-no-price-and-e2e` (from main @ `e35c758`, #196 merged). Commit email: dextran52@gmail.com. Skills used: brainstorming (design already approved, defaults taken), ponytail, qt-qml, qt-ui-design. Plan: `docs/superpowers/plans/2026-11-15-product-picker-v2-s5a-no-price-and-e2e.md` (S5 cut into S5a..S5e, decisions S5a-D1..D7, questions Q1..Q3).

## Done
- [x] Read roadmap: S1 to S4 merged; S5 split into S5a (this), S5b stock formula, S5c touch targets/Back key, S5d measure then tune, S5e a11y/themes/font scale/final device pass.
- [x] `hasPrice` hook in `ProductPickability` (no-price reason, only for rows not on the order), `PickerSheetModel` words and pill, both dialogs wired.
- [x] Tests: PICK-35..42, SHEET-41..43, NOW-17, EOW-20, E2EW-01..05; NOW-03, EOW-03, PICK-33, SHEET-05b, DORM-01 repinned on purpose; QML twins regenerated. 6 hand mutants killed.
- [x] E2E `test/e2e/pickerOrder.e2e.test.js` (PK-E1..E3) wired into `checks.yml`; dry-run 3/3 offline against in-memory Firestore + real `applyOperation`.
- [x] Node: functions 1791/1791, scripts 1049/1049. Code pushed as `ee99413`.
- [x] Docs: plan, test plan (S5a rows, device checks 97 to 101), KNOWN-ISSUES 23 fixed / 34 partly / 40 to 42, Skill 169 + SKILLS-INDEX, AGENTS, README, E2E roadmap. Old checkpoint archived to `docs/superpowers/specs/2026-11-13-pr196-second-sweep-CHECKPOINT.md`.

## Not done / next
- [ ] Open the PR (no tool for it here besides the API; Taher opens or asks) and read CI. First real run of `pickerOrder.e2e` and the two regenerated QML twins: if red, read `results-pickerOrder.xml` first (KNOWN-ISSUES 41).
- [ ] Device checks 97 to 101 (no build until Taher says).
- [ ] Taher decides Q1 (S5b stock formula), Q2 (legacy seed delete), Q3 (KI 29 cap).
- [ ] S5b next (money path before cosmetics), then S5c to S5e.
