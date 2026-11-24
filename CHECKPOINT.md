# CHECKPOINT: 2026-11-23 picker S5e-3b (name the text-child buttons and the four order fields) - resume here

**Branch:** `feat/2026-11-23-picker-s5e3b-names-for-text-buttons-and-fields` (cut from `main` @ `13e08e8`, PR #215 S5e-3a merged).
**Commit rule (this session):** every commit message carries `lkdwtaher@gmail.com` (project-instruction address); git user `Taher (via Claude session)`. The commit-email question is still open (KNOWN-ISSUES 125).
**Rules in force:** no build or run; no Qt in the sandbox (CI is the oracle); always a branch; push without asking (PAT per command, remote URL kept clean); tests + test plan for every change; out-of-scope findings go to `docs/superpowers/KNOWN-ISSUES.md`; short scope so another account can take over from the remote branch; no parallel agents.
**Previous checkpoint archived:** `docs/superpowers/specs/2026-11-23-pr215-merged-prev-CHECKPOINT.md`.
**Skills used:** superpowers:brainstorming (design in the plan, decisions with defaults, veto in the PR), qt-qml, qt-ui-design, ponytail. **Plan:** `docs/superpowers/plans/2026-11-23-product-picker-v2-s5e3b-names-for-text-buttons-and-fields.md`. **Test plan:** `docs/superpowers/test-plans/2026-11-03-product-picker-v2-test-plan.md` (S5e-3b rows, checks 180 to 192).

## Steps
- [x] 0. Cloned fresh, skills read, roadmap read from the repo: S1 to S5e-3a merged (#215 merged). Left: S5e-3b, S5e-3c (split out), S5e-4.
- [x] 1. Recon: the 13 text-child buttons read one by one; 9 text fields counted (7 unnamed); main had not moved.
- [x] 2. Plan doc (decisions S5e3b-D1 to D9, what is NOT done, advice, questions).
- [x] 3. QML (14 files): 11 text-child buttons named, 3 member buttons say the member, 4 order fields named, 3 tab labels `qsTr`.
- [x] 4. Tests: `pickerS5e3bNames.test.js` (27), `pickerS5e3Names.test.js` re-pinned (S5E3-07, 15, 16, 22), `scanFields` in the support module, one loose guard tightened (`completionsSyncingWiring.test.js`, KI 126). 33 hand mutants, 33 killed (one lived on the first run: `TextArea`, fixed by `S5E3B-27`).
- [x] 5. Docs: test plan (slice row, unit table, checks 180 to 192, affected areas, verification row), KNOWN-ISSUES (97, 120, 124 updated; 126 to 130 new), Skill 187 + index (188 skills), AGENTS, README, this file.
- [x] 6. Committed `58881af`, pushed, PR #216 opened. CI on the head: QML 3382, Functions 2327, Rules 129, E2E 124 = 5962/5962, green.
- [x] 6b. PR #216 final sweep (account B, 2026-11-24): review done, F-1 fixed (empty item name), tests 29, KI 131 to 134, CI green on `842ea90`. Details: `docs/superpowers/specs/2026-11-23-pr216-final-sweep-CHECKPOINT.md`.
- [ ] 7. Owner: veto or accept D1 to D9, answer Q1 to Q3 of the plan, write the device results down.

## Measured (this session, by running it)
functions suite 2327/2327 (clean main measured 2300, +27); scripts 1199/1199; `skills-index.js --check` current. Not run: CI, any device check, the repo's QML lint (not in the tree).

## If this session is cut off
Resume at the first unticked step above. Re-measure counts before claiming any: `cd functions && npm ci && node --test`, `node --test .github/scripts/__tests__/*.test.js`, `node .github/scripts/skills-index.js --check`. NEXT SLICE: S5e-3c (font-scale and two-theme source audit), then S5e-4.
