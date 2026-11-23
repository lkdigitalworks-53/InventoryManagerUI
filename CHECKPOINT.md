# CHECKPOINT: 2026-11-23 NO3a create-order wire - resume here

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
- [x] 8. Docs: test plan (+ index row), KNOWN-ISSUES 126-131 (110 and 115 closed), Skill 187 + index, AGENTS, README, STATUS 20.
- [x] 9. Functions 2332/2332 RUN, scripts 1199/1199 RUN, skills index current. Committed; push + PR below.
- [ ] 10. CI read on the pushed head (QML twins, the three rewired e2e suites are the unproven part: KNOWN-ISSUES 128); owner review, merge, Q-NO3-1..3.

## Next slice (NO3b, not started)
`NewOrderDialog._setLinePrice` cap at `RestockFlow.MAX_UNIT_COST` with a visible message (KNOWN-ISSUES 114); then NO4 (Taher's device pass, test plan steps 1-19); then design `_tryAdjustOrder` first (Q-NO3-1). If CI is red on the e2e suites, read the first `addOrder callback never fired` (KNOWN-ISSUES 128).
