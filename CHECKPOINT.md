# CHECKPOINT — 2026-11-12 PR #191 review pass 4 (Android launch crash) — resume here

**Branch:** work branch `fix/2026-11-12-pr191-review-sweep-4`, pushed to the PR's own branch `feat/2026-11-10-r5a-restock-dialog-supplier-in-op` (PR #191), so the fix is in the PR. Base of this pass: `afa2808`.
**Commit identity:** `Taher (via Claude session) <lkdigitalworks@gmail.com>`. Push: the PAT goes in the push URL only, nothing written to `.git/config`.
**Rules in force:** no build or run, no Qt in the sandbox (CI is the QML oracle), push to the PR branch without asking, tests and test plan for every change, honest trade-offs, no parallel agents in this chat, caveman FULL in chat only (documents in normal prose), short scope per turn.
**Skills used:** `superpowers:requesting-code-review`, `qt-development-skills:qt-qml-review` (linter run, deep passes by hand, no agents), `ponytail:ponytail-audit` (lens only).
**Previous checkpoint archived:** `docs/superpowers/specs/2026-11-12-pr191-pass3-prev-CHECKPOINT.md` (it holds the pass 3 steps and the "Device crash on launch" section this pass worked from).

## Task
Taher: the Felgo Cloud build of this branch crashes at launch on Android after a clean install. Review PR #191 in full, check QML errors and missing imports that can crash, fix in the same PR. Logcat to follow.

## Steps
- [x] 1. Cloned, fetched PR #191 head (`afa2808`), made the work branch.
- [x] 2. Re-checked what pass 3 had ruled out, by script, not by memory: 235 `import "..."` paths resolve with EXACT letter case; no JS `.import` cycle; no `.pragma library` file importing a non-library file; no JS API newer than the engine (`normalize`, `Intl` guarded); all types, singletons and `BottomSheet` properties used by `RestockDialog.qml` exist.
- [x] 3. New angle: names that must exist in Qt, not only in the repo. Listed every `property alias` (24). **23 are real Qt properties. One is not: `AuthTextField.qml:16  property alias maxLength: input.maxLength`.** `input` is a `QQC.TextField`; QML has `maximumLength`, not `maxLength` (that is QLineEdit). An alias to a missing property is a compile error: `AuthTextField.qml` fails, so does `LoginPage.qml` (uses it) and `Main.qml` (instantiates `LoginPage` at the root). Qt exits at once = "crash at launch". Added by this PR (R5a). Nothing in CI could see it: Felgo components cannot be loaded by `qmltestrunner`, and `restockR5a.test.js` G-5 pinned the wrong name.
- [x] 4. Also scanned every instantiation of a local component for properties it does not declare: 33 hits, all real `QQC.ComboBox` properties (`model`, `currentIndex`, `displayText`). Nothing else.
- [x] 5. Fix: alias renamed `maximumLength: input.maximumLength`; two users in `RestockDialog.qml` renamed; comment in `RestockFlow.js`; test G-5 pinned to the real name and to the absence of `maxLength`.
- [x] 6. Guard: `functions/test/qmlAliasTargets.guard.test.js` (11 tests: AS-1..AS-6 scanner, AL-0..AL-3 tree, IM-1 exact-case imports). Proven: with the QML fix stashed AL-1, AL-2, AL-3 and G-5 fail (4); with the fix 11 of 11 pass.
- [x] 7. Suites run here: `node --test test/*.test.js` in `functions/` = 1182 tests, 1173 pass, 9 files fail on `Cannot find module 'node-mocks-http'` (not installed in this sandbox, same on the clean tree; CI has it). Brace balance of the three touched files checked.
- [x] 8. Docs: test plan section 9 + device steps 36 and 37, design and status doc wording, AGENTS (pass 4 entry), SKILLS Skill 164 rule 20.
- [ ] 9. Commit, push to the PR branch (this step is the one being done when this file is read: check `git log` and the PR for the pass 4 commit).
- [ ] 10. CI of the new head: QML Tests, Functions, Rules, E2E.
- [ ] 11. Taher: new Felgo Cloud build, step 36 of the test plan FIRST (clean install opens to Login). If it still exits, send the logcat: the first `qt.qml` / `FATAL` / `AndroidRuntime` line decides.

## Honest status of the fix
High confidence, not proof. A static read found a definite compile error on the startup path, introduced by this PR. It is the strongest candidate for the exit at launch, but no log has been seen. If the build still exits, the cause is elsewhere.

## Not checked, still open (in order of how much they matter)
1. `qml/components/ProductPickerSheet.qml` and `ProductPickerRow.qml`: first loaded by a device through PR #194 (the picker was dormant before). Read by hand this pass for names (properties, signals, `Constants.*`, `SearchField`, `ChipScroller`, `ConfirmDialog.ask`): all exist. Not provable without a load. Test plan step 37.
2. No test loads any Felgo component. A real load needs Felgo in CI; the guards only read text.
3. Environment suspects from pass 3 (still unconfirmed): `Qt5Compat.GraphicalEffects` (LoginPage) and `QtQuick.Effects` (RoundedThumb) packaged by Felgo Cloud; Qt version of the Felgo SDK vs CI Qt 6.8; Firebase init.
4. `NewOrderDialog.qml` changes of #194 (152 lines) and `RefreshAction.qml` (#186) were not read line by line this pass.
Everything in the pass 3 "Not fixed on purpose" list still stands (O1 two offline devices, parked restock keeps holding its new supplier name, `{{sup}}` text does not name the field, Qt cuts a long paste silently, Devanagari numerals refused).

## Next session (pick up here)
1. Read CI of the PR head after the pass 4 push.
2. Taher's build and logcat decide what is next (step 11 above).
3. Then R5b on a NEW branch off `main` after #191 merges (design section 5), then R6.
