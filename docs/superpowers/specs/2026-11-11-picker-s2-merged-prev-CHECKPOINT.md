# CHECKPOINT: 2026-11-04 picker v2 slice S2 (sheet component, dormant) - resume here

**Branch:** `feat/2026-11-04-picker-s2-sheet-component`, cut from `main` @ `415b11c` (PR #185 picker S1 and PR #183 R4 both merged).
**Commit identity:** every commit message ends with `allibaas52@gmail.com` (Taher's instruction of 2026-11-09; earlier commits carry `lkdwtaher@gmail.com`). The PAT comes from the chat prompt only, passed per command with `git -c http.extraHeader=...`, never in a URL, `.git/config`, the repo or memory.
**Rules in force:** no build or run until Taher says so; no Qt in the sandbox (CI is the QML oracle); always a branch; push without asking; short scope per chat turn; honest trade-offs; tests and a test plan for every change; documents in normal prose; out-of-scope findings go to `docs/superpowers/KNOWN-ISSUES.md`, not into code.
**Skills used:** `brainstorming` (S2-D1..D6 in the plan), `qt-qml`, `qt-ui-design` (row layout, touch targets, empty and disabled states), `ponytail`.
**Previous checkpoint archived:** `docs/superpowers/specs/2026-11-04-pr185-merged-prev-CHECKPOINT.md`.

## Scope
Design brief section 9, slice S2: `BottomSheet.scrollBody` (+ `guardClose`), `PickerRowGeometry.js`, `ProductPickerSheet.qml`, `ProductPickerRow.qml`, plus one added pure helper `PickerSheetModel.js` (S2-D1). Dormant: nothing instantiates the sheet. NOT in S2: any dialog wiring (S3, S4), the `CompletionPlan` dry run, sweep (S5).

## Steps
- [x] 1. Read memory, design brief, audit, S1 helpers, `BottomSheet`, `InventoryPage` row, `ChipScroller`, `SearchField`, `ConfirmDialog`, stores' revision signals.
- [x] 2. Branch, checkpoint archived, this file.
- [x] 3. `PickerRowGeometry.js` + `GEOM-01..12` (13 cases with 08b).
- [x] 4. `PickerSheetModel.js` + `SHEET-01..26` (28 cases with 02b, 05b).
- [x] 5. `BottomSheet` opt-ins, `ProductPickerRow.qml`, `ProductPickerSheet.qml`.
- [x] 6. `WIRE-01..16`, dormancy allow-list, two derived QML twins.
- [x] 7. Hand mutants: 80 listed, first run 18 survivors; 5 test gaps fixed with new cases, redundant guards deleted, 6 stale patterns corrected; final run all present mutants killed.
- [x] 8. Node: picker files 189/189, functions 1237/1237, scripts 905/905.
- [x] 9. Docs (plan, test plan, KNOWN-ISSUES, README, AGENTS, Skill 161, index).
- [x] 10. Pushed `c135dbc`, PR #187 opened (REST API: `gh pr create` needs GraphQL, blocked here). CI first run red on one twin case (`SHEET-26` wrote `draft["__proto__"]`, V4 throws), test-only fix `c12465d`, CI ALL GREEN: QML 2927/2927, Functions, Rules, E2E.
- [ ] 11. For Taher: veto window on S2-D1..D6, then merge #187; next slice S3 (New Order).

## State
The two QML twins ran green in CI. The Felgo layer, `BottomSheet` with the new properties and the Back key are device-only and UNSEEN. Open items for S3/S4 are in KNOWN-ISSUES ("Product picker v2: carried requirements"). Next: S3 (New Order wired).

## Review sweep of PR #187 (2026-11-09, second chat session) - resume here
Skills run: `requesting-code-review`, `qt-qml-review` (lint script + the six passes done inline: no subagent tool in this chat), `ponytail-audit`.
- [x] R1. Rebased onto `main` @ `515ab19` (#188 and #190 merged). Conflicts only in docs: CHECKPOINT kept ours, AGENTS, SKILLS, SKILLS-INDEX, test-plans README merged. `main` already used Skills 156 to 158, so this PR's skill is now **Skill 159**. Force-pushed with lease, PR mergeable.
- [x] R2. `qt_qml_lint.py` on the 5 QML files: 63 hits (ORD-1 30, JS-1 13, BND-1 8, BND-2 3, STY-1 2, PRF-3 2, PRF-1 2, STY-3 1, LAY-2 1, BND-3 1). Triage: ORD-1, JS-1 (`var`, 1916 uses in `qml/`), BND-1 (`property var`, 171 uses) are the repo's own style, not changed; BND-2 intended (the field is re-synced on purpose); PRF-1 `color: "transparent"` is the repo's idiom (11 uses). Nothing in the lint output is a defect.
- [x] R3. Deep review, found and FIXED in this PR (all four are device-only code, pinned by WIRE tests + Node helper tests):
  - F1 (critical): a double tap on Add handed the plan over twice (the sheet fades out and the button stays live); the dialog's order then held the first adds, so the second plan turned every line into a bump by the same quantity again. Now a `_committed` latch (button disabled, handler and `onCloseRequested` return), reset by `_reset()` on closed or on a reopen during the fade. WIRE-11, 12, 19.
  - F2: every stepper tap or key typed assigned a NEW chips array, so the chip Repeater rebuilt every chip (flicker, scroll reset). Now `Model.sameList` guards the assignment. SHEET-27, WIRE-17.
  - F3: every refresh called `ListModel.set` for every row of the catalog (thousands on a big shop, per tap). Now `Model.changedRows` and only those rows are set. SHEET-28 to 30, WIRE-17.
  - F4: the "In stock only" row had a role and a name but no accessibility action, so TalkBack could not toggle it. Now `Accessible.onPressAction` and `onToggleAction` call `_toggleStock()`, the one place that changes the filter. WIRE-18.
- [x] R4. Node: `functions` 1354/1354 (after `npm ci`); 22 hand mutants on the new code, 21 killed first run, the survivor (`_sameFlat` key presence) got a test, final all killed. Twins regenerated (`pickerTwin.js --write`). QML twins UNSEEN until CI.
- [x] R5. Pushed `5144722`; CI: QML, Functions, Rules green, E2E was still running when read.
- [x] R6. Docs: KNOWN-ISSUES items 11 to 17, test plan checks 45 to 50, README, AGENTS, Skill 161 rules 10 to 13, SKILLS-INDEX.
- [x] R7. `ponytail-audit` written as KNOWN-ISSUES item 17 (nothing deleted: row shape is S3's contract).
- [x] R8. Taher answered yes x3 (2026-11-09): unit shown (item 12), dead roles and geometry outputs deleted (item 17), search debounced 150 ms (item 14). Done in the third commit; Node 17 more mutants all killed, QML twins regenerated.
- [x] R9a. CI on `b198ee7`: QML Tests FAILED (4): `pillsOf` helper in `pickerRowGeometry.test.js` was outside the QML-PRELUDE, so the twin had no such function. Fixed (moved into the prelude), and `pickerTwin.js` now refuses a case that uses a helper outside the prelude. Skill 159 rule 16.
- [x] R9. CI on `4461cb9` read in sweep 3: Functions, Rules, QML, E2E all success. `PR Test Summary Comment` exited 1 (log not read, KNOWN-ISSUES 20).

## Sweep 3 of PR #187 (2026-11-10, third chat session) - resume here
Skills run: `requesting-code-review`, `qt-qml-review` (lint plus the six passes inline, no subagent tool), `ponytail-audit`. Branch already on `main` @ `515ab19` (0 behind). Lint: no new hit (BottomSheet hits are older code).
- [x] S1. Found and FIXED F5: the sheet built its list on `onOpened`, but `Popup.opened` is true only after the slide-in, so it slid up empty and `_later` and the debounce dropped every refresh meanwhile. Now `Connections` on `aboutToShow` (reset, `_live`, build) and `aboutToHide`; `rebuild` no-ops unless live and not committed; a reopen mid-fade of a discarded sheet starts clean. Closes KNOWN-ISSUES 13. WIRE-19, 22, 23; 9 hand mutants all killed.
- [x] S2. Found and FIXED F6: the in-stock row had a second unnamed accessibility stop (inner `Switch`, also focusable). `focusPolicy: Qt.NoFocus`, `Accessible.ignored: true`. WIRE-24; 2 mutants killed.
- [x] S3. Node: functions 1360/1360, scripts 905/905, picker wiring 24/24. No helper changed, so no QML twin changed. `SKILLS-INDEX.md` regenerated (the committed 159 line had drifted from the heading in SKILLS.md).
- [x] S4. Docs: KNOWN-ISSUES 13 fixed, 18 to 21 added; Skill 161 rules 17, 18 (and rule 14 now says `_live`); test plan checks 45, 51 to 53.
- [ ] S5. Push, read CI (QML twins unchanged, so only Node pins moved). Then for Taher: device checks 45, 49, 51 to 53; veto window on S2-D1..D6; merge #187. Next slice S3 (New Order).

## Rebase onto main @ `77332d3` (2026-11-10, #186 merged) - resume here
- [x] RB1. Squashed the 8 branch commits into one (replaying them one by one would have hit the same doc conflicts 8 times), then rebased onto `main` @ `77332d3`. Backup of the old history: local branch `backup-pre-rebase-187` only (not pushed). Force-pushed with lease.
- [x] RB2. Conflicts only in docs. CHECKPOINT: ours. AGENTS, README, SKILLS, KNOWN-ISSUES: both sides kept (main's first). `main` now holds Skill 159 (L4b refresh row) and Skill 160 (order CAS), so the picker skill is **Skill 161**; its references were renumbered in SKILLS, AGENTS, README, KNOWN-ISSUES and this file. `SKILLS-INDEX.md` regenerated (162 skills).
- [ ] RB3. Read CI on the rebased head. Then for Taher: device checks 45, 49, 51 to 53; veto window on S2-D1..D6; merge #187. Next slice S3 (New Order).
