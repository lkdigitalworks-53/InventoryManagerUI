# CHECKPOINT: 2026-11-26 PR #221 (S5g) deep review sweep - resume here

**Branch:** `feat/2026-11-25-picker-s5g-auth-button-cleanup-and-final-pass`, PR #221 (base `main` @ `5c41b8f`, #219 NO3b merged).
**Ask (2026-11-26):** full deep review of PR #221, fixes in the SAME PR, no parallel agents, quality and robustness first, show done/next at the end, caveman chat mode. Skills used: requesting-code-review, qt-qml-review, ponytail-audit (all run inline, no subagents).
**New owner facts (2026-11-26):** (1) all picker slices were tested on a device by the owner; (2) NO dark theme or any other theme is planned in the near future, focus is finishing pending features (recorded in KNOWN-ISSUES 143/144 and README).
**Commit rule (owner, 2026-11-26):** every commit message carries `tsadmin@gmail.com`. Older addresses in older checkpoints are history (KI 125).
**Rules in force:** no build or run; no Qt in the sandbox (CI is the oracle); always a branch; push without asking (PAT per command via http.extraheader, never stored in `.git/config`); tests + test plan for every change; keep scope small enough for one chat turn so another account can resume from the remote branch.
**Previous checkpoint archived:** `docs/superpowers/specs/2026-11-26-pr221-s5g-prev-CHECKPOINT.md` (the S5g session's own checkpoint).

## Steps
- [x] 0. Cloned repo, read skills, fetched PR #221 (`0dd5b02`). State was `dirty`: conflicts with main (#219 NO3b merged after the PR was cut).
- [x] 1. Merged `origin/main` into the branch. 6 doc conflicts (CHECKPOINT, README, SKILLS, SKILLS-INDEX, ATOMIC status, KNOWN-ISSUES), NO code file conflicted. Kept main's entries, appended ours. RENUMBERED ours: KNOWN-ISSUES 150 -> 162 (main owns 150-161), Skill 191 -> 192 (main owns 191); skills count 193; skills-index `--check` current.
- [x] 2. Baseline on the merged tree: `npm ci`, functions 2443/2443 (Node only, no app).
- [x] 3. Linter on 8 picker, dialog, login files: 500 findings (156 ORD-1, 176 JS-1, 63 BND-2, 41 JS-2, 31 BND-1, 18 DEL-1). All pre-existing style/robustness, NOT mass-fixed (plan section 8).
- [x] 4. Six domains by hand, ponytail audit of the diff, PR claims checked against git (83 lines, 7 literals true; renumbering). 4 real findings, all in the S5g test matcher (JS, qmldir, folders, temp leak).
- [x] 5. Fixes: `pickerS5gAuthButtons.test.js` matcher widened, cleanup added, S5G-07..09, 6 hand mutants killed (commit `step 2`). KNOWN-ISSUES 163 fixed, 164 open (owner input).
- [x] 6. Docs: plan section 8, test plan rows, device pass (status + ranked important checks), KNOWN-ISSUES 142/143/144/163/164, README, AGENTS, Skill 192 rule 7. Measured: functions 2446/2446, scripts 1199/1199, skills-index current.
- [ ] 7. Push, read CI (QML, Functions, Rules, E2E) on the pushed head.
- [ ] 8. Report: done / next / important test cases.

## If this session is cut off
Resume at the first unticked step. Re-measure counts before claiming any: `cd functions && npm ci && node --test`, `node --test .github/scripts/__tests__/*.test.js`, `node .github/scripts/skills-index.js --check`. The branch on the remote always holds the latest finished step.
