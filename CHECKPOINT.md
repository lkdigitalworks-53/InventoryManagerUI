# CHECKPOINT: 2026-11-26 NO3c (order price and discount fields) - resume here

**Branch:** `feat/2026-11-26-no3c-edit-order-money-fields`, cut from `main` @ `5c41b8f` (#219).
**Ask (2026-11-26):** take the next atomic-ops roadmap task, design and implement in one session, document out-of-scope findings, quality and robustness first, show done/next at the end. Caveman chat mode.
**Commit rule:** every commit message carries the account email (`lkdwtaher@gmail.com`).
**Rules in force:** no build or run; no Qt in the sandbox (CI is the oracle); always a branch; push without asking; PAT per command, never in `.git/config`.
**Previous checkpoint archived:** `docs/superpowers/specs/2026-11-26-pr219-merged-prev-CHECKPOINT.md`.

## Steps
- [x] 1. State read: #219 merged and device tested; CI on `main` green; baseline functions 2437/2437.
- [x] 2. Design `specs/2026-11-26-no3c-edit-order-money-fields-design.md` (D-NO3c-1..8, Q-NO3c-1..2, defaults taken).
- [x] 3. Code: `OrderFlow.js` helpers, `NewOrderDialog.qml`, `OrderDetailDialog.qml`.
- [x] 4. Tests RUN: functions 2475/2475, scripts 1199/1199, 48/48 hand mutants. QML twins (+6) are CI only.
- [x] 5. Docs: test plan (19 device checks), test-plan index, README, KNOWN-ISSUES 162-170 (151, 154, 158 fixed), Skill 192, SKILLS-INDEX, AGENTS, STATUS section 22.
- [ ] 6. Push, open PR, read CI (QML, Functions, Rules, E2E).
- [ ] 7. Owner: review the PR (veto D-NO3c-4 / D-NO3c-6 if wanted), device checks 1 to 19. Rotate the PAT.

## Next slice
Design `_tryAdjustOrder` as one operation (Q-NO3-1; needs owner rulings), then `_reverseCompletedOrder`, `completeImportedOrder`, step 4 (import chunking, with KNOWN-ISSUES 164). Optional small: planner/server discount limits (163). AP4 device pass is the owner's.
