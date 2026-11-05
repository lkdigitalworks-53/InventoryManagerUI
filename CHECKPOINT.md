# CHECKPOINT: 2026-11-04 picker v2 slice S2 (sheet component, dormant) - resume here

**Branch:** `feat/2026-11-04-picker-s2-sheet-component`, cut from `main` @ `415b11c` (PR #185 picker S1 and PR #183 R4 both merged).
**Commit identity:** author `Taher <lkdwtaher@gmail.com>`, the same address in every commit message. The PAT comes from the chat prompt only, passed per command with `git -c http.extraHeader=...`, never in a URL, `.git/config`, the repo or memory.
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
- [ ] 9. Docs (plan, test plan, KNOWN-ISSUES, README, AGENTS, Skill 156, index).
- [ ] 10. Commit, push, PR, read CI, fix only what CI shows.

## State
QML twins (`tst_PickerRowGeometry`, `tst_PickerSheetModel`), the Felgo layer and `BottomSheet` behaviour are CI-only or device-only and UNSEEN. Open items for S3/S4 are in KNOWN-ISSUES ("Product picker v2: carried requirements"). Next: S3 (New Order wired).
