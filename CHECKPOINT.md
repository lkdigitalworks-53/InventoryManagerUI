# CHECKPOINT — 2026-10-28 R1+R2 server `mint` op (atomic-ops arc, resume here)

**Branch:** `feat/2026-10-28-r2-mint-engine`, cut from `main` @ `fbd7dec` (PR #170 merged). Server only: no QML touched.
**Commit identity:** `dextran52@gmail.com` (Taher, this session). PAT comes from the chat prompt only, never in a remote URL, repo, config or memory. After a push `grep -c ghp_ .git/config` must print 0.
**Rules in force:** no build/run; no Qt in sandbox (CI is the QML oracle; this slice has no QML); push without asking; tests + test plan for every change; caveman FULL in chat only.
**Skills used:** brainstorming (design approved as v2 in #147; slice design = `specs/2026-10-28-r2-mint-engine-design.md`, defaults vetoable), ponytail, qt-qml + qt-ui-design (N/A: no QML/UI in this slice).
**Previous checkpoint archived:** `docs/superpowers/specs/2026-10-28-pr170-merged-prev-CHECKPOINT.md`.

## Why this slice
Other open work: S2f-3 = PR #171 (in flight); S2d-2 (kind hint) and S2e (pickers) wait for Taher / the CA. The atomic-ops design (#147) is merged and approved; its only remaining gate was the implementation plan. S0 (sign-out guard, #167) and pending-mint scoping (#168) are merged. R1+R2 is the next critical-path item, and S2f-6 (server-side counters) folds into it (design 7b item 1).

## Steps
- [x] 1. Read memory, repo, P1/atomic designs, `operationLogic.js`, client mint code (R1 evidence in the design doc section 1).
- [x] 2. Design doc + review pass before code (`specs/2026-10-28-r2-mint-engine-design.md`, M1-M11 defaulted, vetoable).
- [x] 3. `counterRegistry.js` + 9 tests (100%).
- [x] 4. `operationLogic.js` mint kind etc.; 35 tests; 100% line; 27/30 mutants killed (3 equivalent).
- [x] 5. +3 handler tests, +3 emulator e2e (CI only, NOT run), QML source drift guard (3, mutation-tested). Functions suite 927/927 local.
- [x] 6. Docs: test plan, Skill 142 (#171 holds 141; renumber on rebase conflict), SKILLS-INDEX, AGENTS, README, KNOWN-ISSUES, atomic status, design v2 note.
- [ ] 7. Push, read CI, record observed counts.

## Open for a human / next account
- Read CI on the PR; e2e (3 new) and counts are PREDICTED (Functions 927, E2E 106). Fix what is red, record observed counts in the test plan.
- Taher: veto M1-M11 (esp. M3 IST year, M5 collision skip, M6 lenient `after`); `firebase deploy --only functions`; run the on-device regression in the test plan.
- NEXT SLICE: R3 (`OperationKeys.restockKey`, pure `RestockPlan.build`, apply-from-results hooks), QML, CI is the oracle.

