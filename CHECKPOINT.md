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
- [ ] 2. Design doc + review (ponytail pass) before code.
- [ ] 3. `functions/lib/counterRegistry.js` (pure) + tests.
- [ ] 4. `operationLogic.js`: `mint` kind, substitution, guards, budget, replay, collision skip, seed fallback, `restock` opType + tests.
- [ ] 5. Handler tests, emulator e2e (CI only), source-guard parity test.
- [ ] 6. Docs: test plan, Skill, SKILLS-INDEX, AGENTS, README, KNOWN-ISSUES, atomic status.
- [ ] 7. Push, read CI, record observed counts.
