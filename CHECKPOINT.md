# CHECKPOINT: 2026-11-11 picker v2 slice S3 (New Order wired) - resume here

**Branch:** `feat/2026-11-11-picker-s3-new-order`, cut from `main` @ `977cde0` (PR #187, picker S2, merged).
**Commit identity:** every commit message text contains `tsadmin@gmail.com` (Taher's instruction of 2026-11-11; older commits carry other addresses). The PAT comes from the chat prompt only and is passed per command with `git -c http.extraHeader=...`. It is never stored in `.git/config`, the repo, a document or memory. (This session's first clone put it in the remote URL; the URL was cleaned straight after.)
**Rules in force:** no build or run until Taher says so; no Qt in the sandbox (CI is the QML oracle); always a branch; push without asking; short scope per chat turn; honest trade-offs and a veto window in the PR; tests and a test plan for every change; out-of-scope findings go to `docs/superpowers/KNOWN-ISSUES.md`, not into code.
**Skills used:** `brainstorming` (design approved as a whole on 2026-11-03; S3 sub-decisions S3-D1..D8 are vetoable in the PR, same as S2), `qt-qml`, `qt-ui-design`, `ponytail`.
**Previous checkpoint archived:** `docs/superpowers/specs/2026-11-11-pr187-merged-prev-CHECKPOINT.md`.

## Scope (design brief section 9, slice S3)
Wire `NewOrderDialog` to `ProductPickerSheet`; delete `productNames`, `_pickerProducts`, `_rebuildPickerNames`, the combo and the add button. Carried requirements closed here (KNOWN-ISSUES "Product picker v2: carried requirements"): item 1 (dry run of `CompletionPlan` before "Add to order"), item 3 (parity gap, verified by reading), item 4 (valid selling price), item 5 (id matching), item 7 (pending-mint revision counter). NOT in S3: `OrderDetailDialog` (S4), accessibility and big-catalog polish (S5), any server or rules change.

## Steps
- [x] 1. Clone, skills read, branch cut, old checkpoint archived, this file.
- [x] 2. Read design, audit, S2 plan, KNOWN-ISSUES carried list, sheet, helpers, stores, `NewOrderDialog`.
- [x] 3. Plan doc `plans/2026-11-11-product-picker-v2-s3-new-order.md` with S3-D1..D8 (trade-offs inside).
- [x] 4. `NewOrderPicker.js` + `NOP-01..24` (24/24), QML twin derived.
- [x] 5. `PickerSheetModel.build` optional `commitCheck` + `SHEET-32..40` (42/42).
- [x] 6. `StockBatchStore.mintRevision`, `NewOrderDialog` wired, `NOW-01..16` (16/16), dormancy allow-lists and `W-20` updated on purpose.
- [x] 7. Node: functions 1409/1409, `.github/scripts` 1049/1049. 43 hand mutants: 1 real survivor (shortfall hid oversize), test added, all killed.
- [x] 8. Docs: plan, test plan (rows, checks 54 to 66, verification row), KNOWN-ISSUES 22 to 25, README, AGENTS, Skill 162, SKILLS-INDEX regenerated.
- [x] 9. Pushed `705349e`, PR #194 opened (REST API). CI ALL GREEN on `705349e`: QML Tests (twins included), Functions, Rules, E2E; PR Test Summary Comment also green.
- [ ] 10. For Taher: veto window on S3-D1..D8, device checks 54 to 66, merge; next S4 (Edit Order).

## Findings so far (read from code)
- Parity gap (carried item 3): a HELD row (`dependsOn`) is never sent, so it never fails, so `StuckWrites.isParkedItem` (needs `terminal` + `stuck` or failures) cannot become true for it. `hasParkedForEntity` and `unsyncedByEntity` therefore only differ for a damaged saved row; the failure direction is safe (completion refuses with a message). No code change.
- `StockBatchStore._pendingMints` has no revision (confirmed). `OutboxStore.revision` ticks on every item change, so a queued restock or edit ticks it. `InventoryStore.revision` ticks on `products`.
- Dry run is feasible: `CompletionPlan.build` is pure; the sale docs are one per line with a quantity; so a stub `saleDocs` gives the same operation count as the real one.

## Taher's answers on PR #194 (2026-11-11) - resume here
- [x] A1. No selling price refused, 0 allowed: already the behaviour, plan and KNOWN-ISSUES 23 note it. A2. Dry run per rebuild kept (device check 64 measures). A4. Size-only check confirmed.
- [x] A3. Toast instead of the red label: `_applyPicked` clears the label and calls `Toast.show(note)`; NOW-06 and NOW-15 updated (fake `Toast` in the sandbox); docs updated.
- [x] A5. Pushed `9bd72d0`; CI ALL GREEN (QML, Functions, Rules, E2E). Told Taher. Then he runs device checks 54 to 66 and merges #194; next S4 (Edit Order).

## State
Not built, not run on a device. The QML twins (`tst_NewOrderPicker`, regenerated `tst_PickerSheetModel`) ran GREEN in CI on `705349e`. The Felgo layer (`NewOrderDialog` wiring, the sheet over the order sheet, the button) is device-only and UNSEEN. Open items: KNOWN-ISSUES 22 to 25 (no-price row reason, cart stepper 28 dp, error label may be off screen, dry-run cost unmeasured). Next: Taher answers the four questions in PR #194, runs device checks 54 to 66, merges; then S4 (Edit Order).

## REVIEW SWEEP R1 of PR #194 (2026-11-11, new session, other account) - resume here
**Rules this session:** commit message text contains `allibaas52@gmail.com` (Taher's current instruction; earlier commits on this branch carry `tsadmin@gmail.com`). Skills run inline, no sub-agents: `requesting-code-review`, `qt-qml-review` (lint script run on PR-added lines; qmllint not available, Qt not installed on purpose), `ponytail-audit` (scoped to the picker v2 surface plus this PR; whole-repo audit is NOT done). PAT is passed per command, never written to a file.
**Steps**
- [x] R1-1. Read skills, memory, cloned, branch checked out, PR read (23 files, +1667/-162, CI green on 9bd72d0).
- [x] R1-2. Read `NewOrderPicker.js`, `PickerSheetModel.js` diff, `StockBatchStore.mintRevision`, `NewOrderDialog.qml` diff, sheet contract, `CompletionPlan`, `ToastHost`; lint on added lines; Node probes of edge cases; baseline Node tests 133/133.
- [ ] R1-3. Fix F1 (toast note too long for the single-line pill), F2 (negative cart qty frees stock), F3 (bump of a line with a bad qty gives NaN), F4 (stale comments), F5 (`var` in new function).
- [ ] R1-4. Tests: NOP-17 rewritten, NOP-25..28 added, NOW-06/15 updated, twin regenerated (`node functions/test/testSupport/pickerTwin.js --write`), full Node suites run.
- [ ] R1-5. Docs: plan S3-D8, KNOWN-ISSUES 26 (ToastHost cannot wrap) and 27, test plan rows + device checks, Skill 162, AGENTS, README as needed.
- [ ] R1-6. Commit (message has allibaas52@gmail.com), push, wait for CI, comment on PR with the report.
**Findings so far**
- F1 IMPORTANT: `ToastHost` pill is one line, 40 dp, no wrap or elide, at most about 44 characters on a 360 dp phone. The skipped note ("Not added as picked. A: ...; B: ...") is up to about 190 characters, so on a phone it is clipped on both sides and unreadable. Fix here: a short note (one name, "(+N more)"). Root cause (ToastHost cannot wrap, every long toast in the app has it) is logged, not changed: shared component, layout cannot be seen without a build.
- F2 IMPORTANT: `cartQty` adds negative quantities, so a stray negative cart line frees stock for another (CompletionPlan itself counts only positive quantities).
- F3 MINOR: `applyPlan` bump on a line whose qty is not a number gives NaN.
- F4 MINOR: `NewOrderPicker.js` header and `skippedNote` comment still say "error label".
- F5 MINOR: `var` in the new `_applyPicked` (lint JS-1). Other lint hits on added lines: `errorLabel.text =` BND-2 is a false positive (label is driven imperatively everywhere), ORD-1 on the GhostButton is the repo-wide Layout-first order.
