# CHECKPOINT: 2026-11-22 picker S5e-2 (the toast pill wraps, KNOWN-ISSUES 26) - resume here

**Branch:** `feat/2026-11-22-picker-s5e2-toasthost-wrap` (cut from `main` @ `4217032`, PR #213 S5e-1 merged).
**Commit rule (this session, owner instruction 2026-11-22):** every commit message carries `taher.lkdw@gmail.com`; git user `Claude <taher.lkdw@gmail.com>`. Earlier commits on `main` carry other addresses; not rewritten, not considered.
**Rules in force:** no build or run; no Qt in the sandbox (CI is the oracle); always a branch; push without asking; tests + test plan for every change; out-of-scope findings go to `docs/superpowers/KNOWN-ISSUES.md`; no parallel agents; PAT per command, never in `.git/config`.
**Previous checkpoint archived:** `docs/superpowers/specs/2026-11-22-pr213-merged-prev-CHECKPOINT.md`.
**Skills used:** superpowers:brainstorming (design in the plan, decisions with defaults, veto in the PR), qt-qml, qt-ui-design, ponytail (smallest complete change; nothing extra built). **Plan:** `docs/superpowers/plans/2026-11-22-product-picker-v2-s5e2-toasthost-wrap.md`. **Test plan:** `docs/superpowers/test-plans/2026-11-03-product-picker-v2-test-plan.md` (S5e-2 rows, checks 151 to 160).

## Steps
- [x] 0. Cloned fresh, memory read, roadmap read from the repo and the GitHub API: S1-S5e-1 merged (#213 is S5e-1); open PRs #212 (NO2), #211 (docs), #178, #39, #29, none picker. Next on the picker roadmap = S5e-2 (ToastHost wrap, KI 26), S5e-3, S5e-4 after it.
- [x] 1. Design (plan sections 1 to 3): D1 `rise` progress property instead of raising `slideUp.to` (layout timing cannot be checked without a build), D2 hidden unwrapped measure copy, D3 1 px slack, D4 `Text.Wrap`, D5 6 lines then ellipsis, D6 reading time 5 to 10 s, D7 grow upward, D8 nothing else changes.
- [x] 2. Code: `qml/helper/ToastLayout.js` (new, pure), `qml/components/ToastHost.qml` (measure copy, wrap, `rise`, derived `y`, dismiss time), stale comment in `qml/helper/NewOrderPicker.js`.
- [x] 3. Tests: `functions/test/toastLayout.test.js` TLY-01..14 (+ derived twin `tests/tst_ToastLayout.qml`, registered in `pickerTwin.js`), `functions/test/toastHostLayer.test.js` +TL-8, TL-9, TS-8..15 (TS-5 and TS-7 find `z` by search). Functions 2220/2220 (main 2196), scripts 1199/1199. 32 hand mutants, 32 killed. Lint: one real ORD-1 fixed, one BND-2 false positive written down (plan section 5).
- [x] 4. Docs: plan, test plan (S5e-2 rows, checks 151 to 160, affected area, verification row), KNOWN-ISSUES (26 fixed, the `y` lead removed by construction, footer note updated, new 103 to 106), Skill 184 + index (generator output identical), AGENTS, README, this file.
- [x] 5. Committed and pushed (code + tests, then docs).
- [ ] 6. Read CI on the PR head (QML 3341+, Functions, Rules, E2E; new twin `tst_ToastLayout`); fix if red; record the counts here and in the PR body.
- [ ] 7. Final report to Taher: done / open decisions (Q1 to Q3, plan section 7) / device checks 151 to 160 / next (device pass, then S5e-3, S5e-4; NO2 waits on Q-NO-1).

## If this session is cut off
Resume at the first unticked step. Re-measure counts before claiming any: `cd functions && npm ci && node --test`, `node --test .github/scripts/__tests__/*.test.js`. Do not run `pickerTwin.js --write` without checking `git status` after: it must change nothing.
