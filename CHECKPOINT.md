# CHECKPOINT — 2026-10-13 Orders "Approve all pending" button: pressed colour + progress bar

**Branch:** `feat/2026-10-13-approve-all-progress` (base `main` 73c4cf6). Commit identity `tsadmin@gmail.com`. PAT only in the push command, never in files or the remote URL.
**Rules in force:** no build/run until Taher says so; no Qt tools in the sandbox (CI is the proof); branch + push without asking; honest trade-offs, grill before deciding; tests for every change (100% target) plus a test plan; keep scope short, remote branch always resumable by another account.
**Archived previous checkpoint:** `docs/superpowers/specs/2026-10-13-delete-roadmap-s4-cleanup-prev-CHECKPOINT.md`.
**Skills used:** brainstorming (path: BOUNDED, design gate open), qt-qml, qt-ui-design, ponytail.

## Request (Taher)
Pending orders show an Approve button in the teal banner. After a tap there is no visual sign it was pressed or is working. Want: pressed colour change + a simple progress bar for the completion. "Design in this session; if no design needed, implement."

## Facts established (read in code, nothing run)
- Button: `approveBtn` in `qml/pages/OrdersPage.qml` ~L196-214, `QQC.AbstractButton`, 80x32dp, background fixed `Qt.rgba(1,1,1,0.22)` -> no pressed/disabled look at all. `onClicked: _approveAllPending()`.
- `_approveAllPending()` (~L467): sequential loop over `pending` + `processing` orders: `LockManager.acquire` -> `dataModel.tryCompleteOrder` -> next. Outcome lists `failed` / `lockedOut`, one error dialog at the end. NO busy flag, NO progress state.
- BUG found while reading: double tap starts two concurrent loops. `DataModel._completingOrderIds` (L583/610) blocks the 2nd completion of the same order with `callback(false)`, so the 2nd loop lists those orders in `failed` and shows "Insufficient inventory" - WRONG message (data stays safe). A busy guard fixes it.
- Banner `visible: canApprovePending && _scopedPendingCount() > 0`; the count reads `OrdersStore.orders` (reactive via `revision`), so each completed order lowers it and the banner disappears when the LAST order completes -> a progress bar inside the banner would vanish at 100% with no end state unless the banner is held open.
- Minor, NOT in scope: the loop approves `pending`+`processing`, the banner counts only `pending`.
- No reduced-motion setting exists in the project (grep). `Constants` has `durFast 160`, `durMed 240`, `success`, `textOnBrand`, `fsSmall`, `radiusPill`.
- Page QML cannot be instantiated under qmltestrunner (Felgo import via Constants). Repo precedent: pure-JS helper + `tests/tst_*.qml` for logic, JS stand-in for page flow (`tst_NewOrderDialogSubmitGuard.qml`). So progress logic goes in a pure helper to be genuinely testable.
- `origin/feat/2026-10-13-completion-error-cause` (other session) touches DataModel, not OrdersPage -> no conflict expected. This work will not touch DataModel.

## Proposed design (BOUNDED path) - NOT yet approved
1. New pure helper `qml/helper/BulkApproveProgress.js`: state `{phase: idle|running|done, total, done, failed, lockedOut}` + `start/step/finish` reducers. No QML, fully unit-testable.
2. `OrdersPage.qml`: `_approving` + progress state; `if (_approving) return` first line of `_approveAllPending`; button `enabled: !_approving`.
3. Button looks: idle white 22%; pressed white 38% (instant); running white 12% + label `done / total`; Accessible name + description.
4. Progress bar: 3dp white-on-teal track along the banner bottom, inset by the corner radius (no `clip`), determinate, fill = done/total. Not `StockProgressBar` (its brand2/3 fill is invisible on a brand4/5 banner).
5. Banner held open while running and ~1.2s after finish ("All approved" state) even though pending count hits 0; error dialog flow unchanged.
6. No animation on the fill (no reduced-motion setting exists; steps are discrete).

## Open decision (asked Taher)
- D1 end state: (A) hold banner ~1.2s with success state [recommended], (B) banner vanishes at the end [zero extra code, 100% never seen, weak completion feedback].

## Steps
- [x] 1. Cloned repo, read 4 skills, AGENTS conventions, skills 61/66, OrdersPage + DataModel guard
- [x] 2. Branch created, checkpoint written, pushed
- [x] 3. Taher chose D1 = A (hold ~1.2s with success state). Defaults 1-6 not overridden.
- [x] 4. Implemented (code, tests, test plan + index row, Skill 117, `SKILLS-INDEX.md` 118, README/AGENTS lines). Helper + page change + tests (unit, functional model, monkey) + test plan + docs/skills + SKILLS-INDEX regen (`node .github/scripts/skills-index.js --write`) + script suite
- [~] 5. Push done; PR opened (see below). Push, open PR (REST: `gh api .../pulls`, GraphQL blocked), CI is the proof

## Progress log
- Built `qml/helper/BulkApproveProgress.js`, `OrdersPage.qml` wiring, `tests/tst_BulkApproveProgress.qml` (29 cases: unit, regression, functional stand-in, 2 monkey), `.github/scripts/__tests__/ordersPageApproveWiring.test.js` (18 cases, page source wiring guard).
- Proof in sandbox: QML test body run in node against the helper 29/29; 12 hand-made mutants of the helper all caught; script suite 94/94 (`node --test .github/scripts/__tests__/*.test.js`). qmltestrunner NOT run (CI is the proof).
- TODO next: test plan `docs/superpowers/test-plans/2026-10-13-approve-all-progress-test-plan.md` + index row; Skill 117 in SKILLS.md + `node .github/scripts/skills-index.js --write`; README/AGENTS one-liners; then PR via REST.
- Docs done: test plan + `test-plans/README.md` row, Skill 117, `SKILLS-INDEX.md` regenerated (118, `--check` current), README Orders row, AGENTS helper + Pages bullets. Script suite 94/94.

## NEXT (for the next session / account)
1. Read the PR checks. `tests/tst_BulkApproveProgress.qml` (29 cases) is CI-only: if it fails, fix the test or helper, do not weaken it.
2. Taher: on-device run of the plan's happy/negative/edge/monkey sections (build is his call).
3. Not done on purpose: watchdog for a callback that never fires; the `pending` vs `processing` count mismatch in the banner.
