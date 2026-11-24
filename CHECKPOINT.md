# CHECKPOINT: 2026-11-23 NO3a create-order wire - resume here

## REVIEW SWEEP 2026-11-24 (owner session `lkdigitalworks@gmail.com`; PR #217 head branch, fixes added to the SAME PR) - resume here
**Ask:** full deep review of PR #217 (requesting-code-review, qt-qml-review, ponytail-audit), fixes in the same PR, no parallel agents, quality and robustness first, show done/next at the end. Commit rule for THIS sweep: `lkdigitalworks@gmail.com` in the message (the nine earlier commits carry `dextran52@gmail.com`; history is not rewritten). No build, no Qt in the sandbox, CI is the oracle, never write the PAT to `.git/config`.
- [x] R0 Clone, PR #217 metadata (head `feat/2026-11-23-no3a-create-order-wire`, base `main`, clean, CI green on `093dd05`), CHECKPOINT, design, test plan read.
- [x] R1 Code review of the diff against the design: store, DataModel, dialog, Logic, Main, e2e helpers; read Gateway (`recordOperation`, `_finishOperation`: waiter first, signal always; `discardParked`), `OrderPlan`, `FailureCause`, key nonce (62 bits), `_commit` vs `_addLocalOrder`, server role gate (staff can still create orders), all `addOrder` callers.
- [x] R2 `qt_qml_lint.py` filtered to changed lines: no real finding (project `var` style, existing end-of-file `Connections`, 2 `JS-2` false positives). Six QML domains checked one at a time: nothing in layout, loaders, delegates, states or images (none touched).
- [x] R3 Ponytail audit. Findings: **F1 should-fix** a live replayed answer was reported as `applied`, so `DataModel` auto-approved it whenever a sync had already listed the order (a race), against D-NO3-5 and KNOWN-ISSUES 135; **F2 should-fix** the dialog's new `onOrderCreationDeferred` and its busy/emit rules had no test (KNOWN-ISSUES 139). No must-fix found. Small items judged and left: KNOWN-ISSUES 141.
- [x] R4 Fixes: `OrdersStore.addOrder` returns status `replayed`; `DataModel.onAddOrder` skips auto-approve for it; `orderWire` W-4 and W-14 updated, QML twin updated + new DataModel replay test; `functions/test/newOrderDialog.guard.test.js` (6 cases); replica test +2. Functions 2338/2338 RUN locally; 3 hand mutants killed.
- [x] R5 Docs: design (D-NO3-4, D-NO3-5, section 6), test plan (+rows, device steps 20-21, counts), KNOWN-ISSUES 135, 139, 141, AGENTS, Skill 188 (rules 10-11), STATUS. README unchanged on purpose (no person-visible change).
- [x] R6 Scripts 1199/1199, skills index current, brace balance ok, committed (author and message carry `lkdigitalworks@gmail.com`), `.git/config` has no token. The first push (`2e97553`, `7632f82`) was rewritten by the rebase below, so those SHAs no longer exist: use `git log`.
- [x] R6b REBASE onto `main` `a40e8c0` (#216 merged; 11 branch commits replayed, then 2 sweep commits, then 1 renumber commit). Conflicts: `CHECKPOINT.md` took the BRANCH version at every step (as asked); `SKILLS.md`, `KNOWN-ISSUES.md`, `SKILLS-INDEX.md` were merged by keeping main's entries and appending ours. Main now owns Skill 187 and KNOWN-ISSUES 126-134, so OUR entries moved: Skill 187 -> **188**, NO3a KNOWN-ISSUES 126-132 -> **135-141** (every reference on lines this branch added was moved with them: AGENTS, design, test plan, STATUS, code comments, the dialog guard test). Intermediate commits still show the old numbers; only the tip is consistent. After the rebase: functions 2367/2367 RUN (main's 2332 base moved, ours +38 incl. the sweep), scripts 1199/1199, skills index current, no conflict markers. QML and e2e: CI only.
- [ ] R7 Owner: review in PR #217; answer Q-NO3-1..3; confirm the commit email (KNOWN-ISSUES 111, 118, 125, 141f). If CI is red on the new QML tests (`tst_OrdersStore_addOrder.qml` replay test, `tst_NewOrderDialogSubmitGuard.qml`), they are CI-only: read the first failure, the node twins (`orderWire` W-4/W-14, `newOrderDialog.guard`) already pass.
**Next after the owner review:** unchanged from below (NO3b price cap, NO4 device pass steps 1-21, then `_tryAdjustOrder` design).

---

**Branch:** `feat/2026-11-23-no3a-create-order-wire` (cut from `main` @ `5948767`, #212 merged; #213 and #214 also merged).
**Commit rule:** every commit carries `dextran52@gmail.com` (author and message), per the task prompt of 2026-11-23. History is not rewritten; KNOWN-ISSUES 111/118 (which address is right) still waits for the owner.
**Rules in force:** no build or run; no Qt in the sandbox (CI is the oracle); always a branch; push without asking; tests + test plan for every change; out-of-scope findings go to `docs/superpowers/KNOWN-ISSUES.md`; PAT per command via `git -c http.extraHeader`, never in `.git/config`; keep scope short so another account can take over.
**Previous checkpoint archived:** `docs/superpowers/specs/2026-11-23-pr212-merged-prev-CHECKPOINT.md`.
**Skills used:** caveman (chat), brainstorming (design + decisions defaulted, vetoable in the PR, as ordered), qt-qml (store/dialog glue), qt-ui-design (dialog wording only), ponytail (dead params and the no-lines branch deleted).

## Scope split (decided this session)
NO3 (wire) = NO3a (this branch: store + DataModel + dialog callback + helper texts + e2e helpers + tests) and NO3b (next: `NewOrderDialog._setLinePrice` cap with a visible message, KNOWN-ISSUES 114; device pass NO4).

## Steps
- [x] 0. Clone, memory read, roadmap read (STATUS 14-19, NO2 design, AP3a design), code read.
- [x] 1. Design `specs/2026-11-23-no3a-create-order-wire-design.md` (D-NO3-1..11, Q-NO3-1..3).
- [x] 2. `OrderFlow.js` (texts, key, classify, one refusal text per planner reason). A mutant-style test found `Line NaN` for a NaN index; fixed.
- [x] 3. `OrdersStore.addOrder` rewrite (one operation, loop and no-lines branch deleted) + `onCreateOrderApplied/Rejected`.
- [x] 4. `DataModel` route + `_autoApproveNewOrder`; `Logic.addOrder` signal + `orderCreationDeferred`; `Main.qml`; dialog payload and Connections.
- [x] 5. e2e: `_withOnline` in OrdersE2E, ReturnAfterMetadataEditE2E, OrdersStoreE2E (+ operation URL); guard `orderE2eHelpers.guard.test.js`.
- [x] 6. Tests: `orderWire` 15, `orderFlow` 7, e2e guard 10, QML twins `tst_OrderFlow`, `tst_OrdersStore_addOrder`, smoke test updated; both dormancy guards became wiring guards.
- [x] 7. Hand mutants: 28 -> 3 survivors (DataModel guards, online type) -> W-6 odd values, W-14, W-15 -> 28/28 killed.
- [x] 8. Docs: test plan (+ index row), KNOWN-ISSUES 135-140 (110 and 115 closed), Skill 188 + index, AGENTS, README, STATUS 20.
- [x] 9. Functions 2332/2332 RUN, scripts 1199/1199 RUN, skills index current. Committed; push + PR below.
- [x] 10. PR #217 opened; CI on head ba8d732 all green 5990/5990 (QML 3405, Functions 2332, Rules 129, E2E 124; the rewired e2e suites passed first run).
- [ ] 11. Owner review in PR #217; merge; answers to Q-NO3-1..3 (and still Q-NO2-2/3, commit-email KNOWN-ISSUES 111/118).

## Next slice (NO3b, not started)
`NewOrderDialog._setLinePrice` cap at `RestockFlow.MAX_UNIT_COST` with a visible message (KNOWN-ISSUES 114); then NO4 (Taher's device pass, test plan steps 1-21); then design `_tryAdjustOrder` first (Q-NO3-1). If CI is red on the e2e suites, read the first `addOrder callback never fired` (KNOWN-ISSUES 137).
