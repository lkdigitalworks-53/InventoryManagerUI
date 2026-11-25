# CHECKPOINT: 2026-11-25 picker S5g (dead Auth buttons out, S5e-4 final device pass prepared) - resume here

**Branch:** `feat/2026-11-25-picker-s5g-auth-button-cleanup-and-final-pass` (cut from `main` @ `4ce6a48`, PR #220 S5f merged).
**Commit rule:** every commit message carries `dextran52@gmail.com` (owner instruction 2026-11-25, this session; ignore the addresses in older checkpoints, KI 125).
**Rules in force:** no build or run; no Qt in the sandbox (CI is the oracle); always a branch; push without asking (PAT per command via http.extraheader, remote URL kept clean); tests + test plan for every change; out-of-scope findings go to `docs/superpowers/KNOWN-ISSUES.md`; short scope so another account can take over from the remote branch; no parallel agents.
**Previous checkpoint archived:** `docs/superpowers/specs/2026-11-25-pr220-merged-prev-CHECKPOINT.md`.
**Skills used:** superpowers:brainstorming (design in the plan, questions answered by defaults), qt-qml, qt-ui-design, ponytail, caveman.

## Steps
- [x] 0. Cloned fresh, memory + repo docs read. Roadmap read: picker v2 S1 to S5f merged (#220 = S5f, main @ `4ce6a48`). Open PRs: #219 (NO3b, atomic-ops roadmap, not picker), #211, #178, #39, #29. Only roadmap row left: S5e-4 (curated device pass, KI 29 with a number): a PHONE job, no code. Left over from S5f: KI 146 (dead Auth buttons, Q3 default yes), KI 143 (colour literals), KI 29.
- [x] 1. Baseline measured on main: functions 2408/2408, scripts 1199/1199, skills-index current.
- [x] 2. Commit A `d7fe130`: deleted `AuthPrimaryButton` + `AuthSecondaryButton` (KI 146); fixed `S5E3-29`, `S5F-03`, `S5E3C-12`; new `pickerS5gAuthButtons.test.js` (S5G-01..06). 11 hand mutants, all killed (first loop polluted by an untracked file and mutant 11 edited the test: both redone, Skill 191).
- [x] 3. Commit B (docs only): `test-plans/2026-11-25-picker-v2-s5e4-final-device-pass.md` (20 checks F1..F20, KI 29 table F8 + partial-state probe F9, decision rule written first), plan `plans/2026-11-25-product-picker-v2-s5g-auth-buttons-and-final-pass.md` (D1..D6, Q-S5G-1..4), test plan rows + checks 213/214, KNOWN-ISSUES (146 closed, 143 to 49, 150 new), README, AGENTS, Skill 191 + index (192 skills), atomic-ops note.
- [x] 4a. Measured by running: functions 2414/2414 (main 2408), scripts 1199/1199, skills-index current.
- [ ] 4b. Push, open PR, read CI verdicts AND counts (fill in below).
- [ ] 5. Owner: run the 20 checks on a phone, write the result lines in the S5e-4 file, answer the questions in the plan, merge.

## Next
(1) Owner: run F1..F20 on a phone (F8, F9 first if short of time), write a result line each. (2) Owner: Q-S5G-1..4 in the plan. (3) After the pass: fix FAILs, decide KI 29 by the written rule, close KI 143/144 if no theme is planned. (4) Atomic-ops arc: `_tryAdjustOrder` (Q-NO3-1), PR #219 NO3b is open and not mine.

## If this session is cut off
Resume at the first unticked step. Re-measure counts before claiming any: `cd functions && npm ci && node --test`, `node --test .github/scripts/__tests__/*.test.js`, `node .github/scripts/skills-index.js --check`. Push with `git -c http.extraheader="Authorization: Basic $(printf 'x-access-token:%s' $PAT | base64 -w0)" push origin HEAD`.
