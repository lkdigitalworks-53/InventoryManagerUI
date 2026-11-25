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
- [ ] 2. Baseline: install `functions` deps (`npm ci`), run the Node suites on the merged tree (this is Node only, not the app).
- [ ] 3. Review phase 1: qt-qml-review linter (`qt_qml_lint.py`) on the QML files touched by #219/#221 and the picker files.
- [ ] 4. Review phase 2: six qt-qml-review domains by hand, ponytail audit of the diff, requesting-code-review of #221 against its plan.
- [ ] 5. Fixes in this PR (list filled in as found).
- [ ] 6. Tests for each fix, test plan rows, docs (KNOWN-ISSUES, README, SKILLS/AGENTS only if needed).
- [ ] 7. Push, read CI (QML, Functions, Rules, E2E) on the pushed head.
- [ ] 8. Report: done / next / important test cases.

## If this session is cut off
Resume at the first unticked step. Re-measure counts before claiming any: `cd functions && npm ci && node --test`, `node --test .github/scripts/__tests__/*.test.js`, `node .github/scripts/skills-index.js --check`. The branch on the remote always holds the latest finished step.
