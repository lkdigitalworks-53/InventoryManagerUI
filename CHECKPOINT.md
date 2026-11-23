# CHECKPOINT: 2026-11-23 NO3a create-order wire - resume here

**Branch:** `feat/2026-11-23-no3a-create-order-wire` (cut from `main` @ `5948767`, #212 merged; #213 and #214 also merged).
**Commit rule:** every commit carries `dextran52@gmail.com` (author and message), per the task prompt of 2026-11-23. History is not rewritten; KNOWN-ISSUES 111/118 (which address is right) still waits for the owner.
**Rules in force:** no build or run; no Qt in the sandbox (CI is the oracle); always a branch; push without asking; tests + test plan for every change; out-of-scope findings go to `docs/superpowers/KNOWN-ISSUES.md`; PAT per command via `git -c http.extraHeader`, never in `.git/config`; keep scope short so another account can take over.
**Previous checkpoint archived:** `docs/superpowers/specs/2026-11-23-pr212-merged-prev-CHECKPOINT.md`.
**Skills used:** caveman (chat), brainstorming (design + decisions defaulted, vetoable in the PR, as ordered), qt-qml (store/dialog glue), qt-ui-design (dialog wording only), ponytail (dead params and the no-lines branch deleted).

## Scope split (decided this session)
NO3 (wire) = NO3a (this branch: store + DataModel + dialog callback + helper texts + e2e helpers + tests) and NO3b (next: `NewOrderDialog._setLinePrice` cap with a visible message, KNOWN-ISSUES 114; device pass NO4).

## Steps
- [x] 0. Clone, memory read, roadmap read (STATUS 14-19, NO2 design, AP3a design), code read (OrdersStore.addOrder/_normalizeOrder, DataModel route, NewOrderDialog.trySubmit, InventoryStore AP3a wire, e2e `_addOrder` helpers).
- [ ] 1. Design doc `specs/2026-11-23-no3a-create-order-wire-design.md`.
- [ ] 2. `OrderFlow.js` (texts, key, classify, refusal text per planner reason).
- [ ] 3. `OrdersStore.addOrder` rewrite + `onCreateOrderApplied/Rejected`.
- [ ] 4. `DataModel` route + auto-approve after the answer; `Logic.addOrder` signal; `Main.qml`; dialog callback.
- [ ] 5. e2e helpers (4 files) + guard test.
- [ ] 6. Node tests, QML twins, guards replaced by wiring pins.
- [ ] 7. Hand mutants.
- [ ] 8. Docs (test plan, KNOWN-ISSUES, Skill, AGENTS, README, STATUS).
- [ ] 9. Commit, push, PR, CI read.
