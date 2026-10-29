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
- [x] 7. Pushed; CI read on 353050f: QML 2442 ok, Functions 927 ok, Rules 106 ok, E2E 99 with 1 red (test hygiene, see session 2).

## Session 2 — 2026-10-29 review sweep of this PR (branch `review/2026-10-29-pr172-sweep`, pushed INTO `feat/2026-10-28-r2-mint-engine`)
Skills run: requesting-code-review, ponytail-audit, qt-qml-review (N/A: no QML in the diff; reported, not skipped silently). Findings F1-F7 are in design section 7; every one was reproduced with `strictDb` first.
- [x] S2-1. Read memory, cloned, read design, `counterRegistry.js`, the whole `operationLogic.js` diff, handler, drift guard, e2e, CI comment.
- [x] S2-2. F1 spurious rewrite of probed docs (`dirty` flag), F2 counter stuck for gaps > 20 (M12 heal), F3 unused/mint-only mint (M13 `unused-mint`), F4 `__proto__` key, F5 cross-entity whole id (M14).
- [x] S2-3. Tests: 4 old tests rewritten, +4 new, handler +2 rows; mutation-checked 7/7 killed; coverage 100% line+branch on both lib files; functions suite 931/931.
- [x] S2-4. E2E: per-test cleanup of minted docs (the CI red), +2 new cases (heal with 25 occupied ids, unused-mint 400). NOT RUN (no emulator in the sandbox): CI is the oracle.
- [x] S2-5. Docs: design section 7 + M5 row, test plan (counts, new cases), README, AGENTS, Skill 143 + regenerated SKILLS-INDEX.
- [x] S2-6. CI on 0f114ad: QML 2442, Functions 931, Rules 106, E2E 101 (1 red: my heal e2e assumed id v0+26; the seeded tenant holds BAT-2026-900 so the correct id is 901; the heal worked as designed).
- [x] S2-7. CI on 0e4fe4f: ALL GREEN (QML 2442, Functions 931, Rules 106, E2E 101).

## Open for a human / next account
- CI is green on 0e4fe4f (observed above). Nothing to read; review the diff, veto decisions, deploy.
- Taher: veto M1-M14 (new: M12 heal, M13 `unused-mint`, M14 entity match); `firebase deploy --only functions`; run the on-device regression in the test plan.
- NEXT SLICE: R3 (`OperationKeys.restockKey`, pure `RestockPlan.build`, apply-from-results hooks), QML, CI is the oracle. The client must send a `receipt` movement on the restock stock delta and must use every bind it mints.
- Not done on purpose (decisions for Taher): role gate on `restock`; restricting `mint` by opType; a per-tenant cap on counter jumps.
