# CHECKPOINT: 2026-11-12 picker v2 slice S4 (Edit Order wired) - resume here

**Branch:** `feat/2026-11-12-picker-s4-edit-order`, cut from `main` @ `3c03306` (PR #194 picker S3 and PR #193 P1 S4a merged).
**Commit identity:** git user `taher.lkdw@gmail.com`, and the last line of every commit message carries `taher.lkdw@gmail.com` (Taher's standing instruction). The PAT comes from the chat prompt only; the clone URL was reset right after cloning and pushes pass it with `git -c http.extraHeader=...` (never in a URL, `.git/config`, the repo or memory).
**Rules in force:** no build or run until Taher says so; no Qt in the sandbox (CI is the QML oracle); always a branch; push without asking; short scope per chat turn; honest trade-offs with a veto window in the PR; tests and a test plan for every change; out-of-scope findings go to `docs/superpowers/KNOWN-ISSUES.md`.
**Skills used:** `brainstorming` (design: the approved picker design plus S4-D1..D8, vetoable in the PR), `ponytail` (smallest change: one optional hook instead of a copy, one new pure helper), `qt-qml` and `qt-ui-design` (consulted: the only UI change is one existing `GhostButton` and the existing sheet).
**Previous checkpoint archived:** `docs/superpowers/specs/2026-11-12-p1-s4a-merged-prev-CHECKPOINT.md` (P1 S4a register, #193 merged; its follow-up PR plan `docs/superpowers/plans/2026-11-11-p1-s4a-followups-one-pr-plan.md` is STILL the next server task).

## Scope (design brief section 9, slice S4)
Wire `OrderDetailDialog` to `ProductPickerSheet`; delete the combo and its helpers. Carried requirements closed here: item 2 (completed-order edit has no `CompletionPlan`: decided, dry run only for pending and processing, S4-D2), item 4 (the order's own guards stay in the dialog: lock, busy, `TransactionStore.hasMore`, booked tax, valid price). NOT in S4: S5 polish, the emulator E2E, any server or rules change.

## Steps
- [x] 1. Clone, memory and skills read, branch cut, previous checkpoint archived.
- [x] 2. Read design, audit brief, S3 plan and checkpoint, KNOWN-ISSUES carried list, `NewOrderPicker.js`, the S3 wiring, `OrderDetailDialog` (catalog, stock formula, add handler, save path, stepper), `DataModel._tryAdjustOrder`.
- [x] 3. Plan `plans/2026-11-12-product-picker-v2-s4-edit-order.md` with S4-D1..D8 (trade-offs inside).
- [x] 4. `NewOrderPicker.applyPlan` optional `lookup.availableOf` hook (`_capOf`), `NOP-28..30`.
- [x] 5. `qml/helper/EditOrderPicker.js` + `EOP-01..26`, QML twin derived and registered (`pickerTwin.js`).
- [x] 6. `OrderDetailDialog.qml` wired; `EOW-01..16` (runs the dialog's real functions against a fake `ListModel`).
- [x] 7. S3 pins changed on purpose: `NOW-09`, `WIRE-15`, `W-20`, `DORM-01` allow-list.
- [x] 8. Node: functions 1616/1616 (after merging main @ `4c0f360`), `.github/scripts` 1049/1049, picker files 299/299. 27 hand mutants: 3 survivors on the first run (2 real gaps fixed with tests, 1 equivalent), final run all killed except the equivalent one.
- [x] 9. Docs: plan, test plan (rows, device checks 67 to 91, verification row), KNOWN-ISSUES 28 to 35, README, AGENTS, Skill 165, `SKILLS-INDEX.md` regenerated.
- [x] 10. Committed `b7b3824`, pushed, PR #196 opened (REST). It was `dirty` against main @ `4c0f360` (#191 restock R5a): merged main into the branch (CHECKPOINT = branch, my skill renumbered 164 -> 165, index regenerated), suites re-run green. Next: read CI.
- [ ] 11. For Taher: veto window on S4-D1..D8, answer the questions below, device checks 67 to 91, merge.

## Findings (read from code, not changed unless listed in the plan)
- The booked-tax rule lived only in the dialog's add handler; `tst_CompletedOrderTaxTimeOfSupply.qml` re-implements it, so the real code had no test. It is now `EditOrderPicker.seedOf` (EOP-07, EOP-12, EOW-15).
- Completed-order edit has no operation cap (KNOWN-ISSUES 29), orders with no lines are seeded from the first two products of the shop (30), the lock does not gate adding (31).

## State
Not built, not run on a device. The QML twin `tst_EditOrderPicker` (25 cases) and the regenerated `tst_NewOrderPicker` have NOT run (no Qt here): CI is their oracle. The Felgo layer (the button, the sheet over the order sheet, `_applyPicked` on a real `ListModel`) is device-only and UNSEEN.

## NEXT (in this order, my recommendation)
1. Read CI on this PR; fix whatever is red.
2. Taher: veto/answer, device checks 67 to 91, merge.
3. The P1 S4a follow-up PR (`plans/2026-11-11-p1-s4a-followups-one-pr-plan.md`: `productName` in ledger rows, ledger read rule, droppable `count()`, wrap `deriveContext`), decided on 2026-11-11 to be taken right after #193.
4. Picker S5: the emulator E2E (KNOWN-ISSUES 34), accessibility, themes, font scale, big-catalog performance, the full device pass, the 28 dp cart steppers (28a, 24a), the "no price" row reason (23).
5. P1 S4b client page (needs a design pass first); S2d-2.
