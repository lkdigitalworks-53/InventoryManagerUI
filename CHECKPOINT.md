# CHECKPOINT: 2026-11-12 P1 S4b-1 stock register CLIENT ENGINE (pure model + service, dormant) - resume here

**Branch:** `feat/2026-11-12-p1-s4b1-register-client-engine`, cut from `main` @ `66d3f8d` (#195 merged). Design: `docs/superpowers/specs/2026-11-12-p1-s4b-register-client-design.md`. Test plan: `docs/superpowers/test-plans/2026-11-12-p1-s4b1-register-client-engine-test-plan.md`.
**Commit identity:** `taher.lkdw@gmail.com` as git user AND last line of every commit message (this session's prompt). PAT comes from the chat prompt only: pass per command, never in a URL kept in `.git/config`, the repo, or memory.
**Rules in force:** no build or run; no Qt in sandbox (CI is the oracle); always a branch; push without asking; tests + test plan for every change; out-of-scope findings go to `docs/superpowers/KNOWN-ISSUES.md`.
**Skills used:** `brainstorming` (design doc, decisions defaulted + vetoable, no interactive gate: one-turn rule), `qt-qml` (service + helper rules, Skills 156/161), `qt-ui-design` (N/A this slice: zero UI; page is S4b-2), `ponytail` (one model file, one service file, no abstraction).
**Previous checkpoint archived:** `docs/superpowers/specs/2026-11-12-p1-s4a-followups-merged-prev-CHECKPOINT.md` (its step 7 was never ticked; #195 IS merged on main).
**Skill number:** 167 (main is at 165; open PR #196 took 166). If #196 does not merge first, renumber (rule: follow main's highest).

## Where P1 stands (read from main @ 66d3f8d)
Done: S1a/S1b server rows, S2a-c cleanup + inventory lock, S2d-1 typed kinds, S2f authz, S4a server read model `computeStockRegister` + its 4 follow-ups (#193, #195). Open: S2d-2, S2e (waits for CA), S3, **S4b (client page: this slice + next)**, S4c (CA layout export).

## Steps
- [x] 0. Read memory, AGENTS rules, CHECKPOINT, S4a design, skills 153/156/161/163, AnalysisService/LockManager XHR pattern; repo cloned, branch cut, identity set.
- [ ] 1. Design doc + decisions (D1..D10).
- [x] 2. `qml/helper/StockRegisterModel.js` (pure): IST presets, custom range, classify, validateAnswer, buildView, detailLines. `.github/scripts/__tests__/stockRegisterModel.test.js` SRM-01..07 green in Node (battery, TZ independence, 3000+1500 monkey, real-server contract, guards, hand mutants).
- [x] 2b. `qml/model/StockRegisterService.qml` written + qmldir entry (tests: step 4).
- [ ] 3. Node tests + QML test for the model.
- [ ] 4. `qml/model/StockRegisterService.qml` + qmldir + Node behaviour/wiring/guard tests.
- [ ] 5. Docs: test plan, KNOWN-ISSUES, Skill 167 + index, README, AGENTS.
- [ ] 6. Push, read CI, done / pending / next.

## NEXT (if this session stops)
Continue at the first unchecked step. Slice is dormant: nothing calls the service until S4b-2, so a red step can be reverted alone.
