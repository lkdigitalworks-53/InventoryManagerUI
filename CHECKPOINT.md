# CHECKPOINT: 2026-11-16 PR #198 (P1 S4b-1 stock register CLIENT ENGINE, dormant) review sweep - resume here

**Branch:** `feat/2026-11-12-p1-s4b1-register-client-engine` (PR #198). Main @ `503adda` (#201) merged into it on 2026-11-16. Design: `docs/superpowers/specs/2026-11-12-p1-s4b-register-client-design.md`. Test plan: `docs/superpowers/test-plans/2026-11-12-p1-s4b1-register-client-engine-test-plan.md` (section 4 = the sweep).
**Commit identity:** the first four commits are `taher.lkdw@gmail.com` (not rewritten: force-push on an open PR). Sweep commits use `lkdigitalworks@gmail.com`. PAT comes from the chat prompt only; never in `.git/config`, the repo or memory.
**Rules in force:** no build or run; no Qt in the sandbox (CI is the oracle); always a branch; push without asking; tests + test plan for every change; out-of-scope findings go to `docs/superpowers/KNOWN-ISSUES.md`; one reviewer, no parallel agents (this session's prompt).
**Skill number:** 172 (main took 167-171; main's KNOWN-ISSUES item 39 said the second PR to merge renumbers).
**Previous checkpoints archived:** `specs/2026-11-12-p1-s4a-followups-merged-prev-CHECKPOINT.md`; main's AP2 checkpoint, replaced by this one at the merge: `specs/2026-11-16-ap2-pr201-merged-prev-CHECKPOINT.md`.

## What PR #198 is
Pure `qml/helper/StockRegisterModel.js` (IST periods, echoed-window check, flat rows, error wording) + dormant `qml/model/StockRegisterService.qml` (single flight, answers once, on demand). Nothing calls the service until S4b-2 (page).

## Review sweep steps (2026-11-16)
- [x] 0. Memory + repo rules read; fresh clone; PR #198 branch fetched (16 files, 4 commits, 5 behind main).
- [x] 1. Read the whole PR: design doc, model, service, both Node test files, QML twin, test plan, KNOWN-ISSUES diff. Checked the model against the real server (`stockRegisterMath.js`, `computeStockRegister`): error codes, answer fields, roles, window parse, `count` meaning.
- [x] 2. Lint (`qt_qml_lint.py`) on the touched QML: only repo-convention noise (`var`, `!==` flagged as loose, "child after function" inside bodies); bracket balance 0 (the one +1 in the model is `[from, to)` in a comment). Node tests 12/12 before changes.
- [x] 3. Merge main into the branch (docs-only conflicts; both sides kept; skill renumbered 167 -> 172; main's CHECKPOINT archived). Pushed `786237a`.
- [x] 4. Fixes + tests, pushed `e6a1d32`: (a) `load()` cannot strand `loading` on a throw; (b) 2xx bodies not copied per chunk; (c) `window` refusal not retryable; (d) stale guard comment; (e) `moved` / `movementCount` all-time comment. Service battery 130 checks, 60 hand mutants all killed.
- [x] 5. Docs: Skill 172 rules 14-17, test plan section 4, KNOWN-ISSUES items 12-15, design carry list, this checkpoint.
- [x] 6. Docs pushed (`bfdf504`). CI on `bfdf504`: Functions Tests, Firestore + Storage Rules Tests, QML Tests (the QML twin ran in the real engine for the first time: green), E2E Tests, PR Test Summary all success; deploy jobs skipped (PR).

## Findings NOT fixed here (and why)
- 401 may repeat until the session recheck runs (D12, KNOWN-ISSUES S4b-1 item 4): a design trade-off already documented; a second refresh path would break `sessionRecheckWiring`.
- Workspace change in flight keeps `loading` true up to 125 s, cache not cleared on sign-out: the page (S4b-2) owns `cancel()` / `clear()`; recorded as KNOWN-ISSUES 13 and in the design carry list.
- The per-chunk body-copy cost is reasoned, not measured (no device, no Qt here).
- Commit email on the first four commits (KNOWN-ISSUES 14). Dependabot 27 alerts (KNOWN-ISSUES 15).
- `tests/tst_StockRegisterModel.qml` first ran in the real engine on `bfdf504`'s CI: green.

## Suites at last run (sandbox)
Script suite 1061/1061 (after the merge and the fixes). `functions` suite not re-run (no server file touched by this PR; main's own CI covers it). QML not run (no Qt by rule).

## NEXT (if this session stops)
1. CI was green at `bfdf504`. This checkpoint's own commit is docs-only; re-read CI on the final head (`gh api repos/lkdigitalworks-53/InventoryManagerUI/commits/<sha>/check-runs`) before merging.
2. Taher: veto D2..D12 in the design doc, answer the CA question (P1 design section 8) for S4c, merge PR #198 (squash is fine; see item 14 for the email).
3. S4b-2 (page): design in the design doc section 5, plus the carried items from the sweep. Add the emulator e2e QML-to-endpoint case there (S4a KNOWN-ISSUES 9).
If resuming mid-slice: continue at the first unchecked step. The slice is dormant, so any red step can be reverted alone.
