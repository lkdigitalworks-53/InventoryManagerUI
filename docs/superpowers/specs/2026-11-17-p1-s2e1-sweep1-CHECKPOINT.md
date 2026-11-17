# CHECKPOINT: 2026-11-17 PR #204 (P1 S2e-1) rebase + full-sweep review - resume here

**Branch:** `feat/2026-11-13-p1-s2e1-reason-policy-and-cost-snapshot` (PR #204). Fixes go in THIS PR (not stacked). Previous checkpoint kept as `docs/superpowers/specs/2026-11-13-p1-s2e1-prev-CHECKPOINT.md`.
**Commit identity:** `taher.lkdw@gmail.com` as git user AND last line of every commit message. PAT from the chat prompt only, per command, never stored.
**Rules in force:** no build or run; no Qt in the sandbox (CI decides); push without asking; no parallel agents this session; tests + test plan for every change; out-of-scope findings to `docs/superpowers/KNOWN-ISSUES.md`.
**Skills used (read, applied by hand, no subagents):** superpowers:requesting-code-review, qt-development-skills:qt-qml-review (Phase 1 linter run on the changed QML tests; phase 2 done by hand), ponytail:ponytail-audit.

## Steps
- [x] 0. Read memory, cloned repo (PAT stripped from `.git/config`), PR #204 metadata (was `dirty`).
- [x] 1. Rebase: own 3 commits replayed with `git rebase --onto origin/main b18c53a` (#198 squash tree == b18c53a on its files), no conflict. Force-pushed with lease: head `164d881`. Backup ref was local only (`backup/pre-rebase-204`).
- [x] 2. Review sweep, server: `movementLogic`, `gatewayLogic.applyDelta`, `operationLogic.applyOperation`, `batchMutationLogic`/whole-record paths (derive only, never valued: OK), replay path (audit read first, rows not re-written: OK).
- [x] 3. Review sweep, client: `StockMovements.js`, `FailureCause.js`; Phase 1 lint on `tst_StockMovements.qml` / `tst_FailureCause.qml`: only repo-wide `JS-1 var` style (convention), nothing on a logic line.
- [x] 4. Legal check (web): 17(5)(h) names free samples; 57th GST Council (8 Oct 2026) recommended removing that block; not law yet. Rationale for free_sample optional stands (KNOWN-ISSUES 9).
- [x] 5. FIX D-1 (bug): invisible-only text passed as a reason. Shared `INVISIBLE_RE` + `visibleLength` (server), mirror in `StockMovements.js`; 18 invisible-only shapes refused, 7 visible shapes accepted; 10 new mutants; RP-05 real-module branch checks; 2 QML twin tests.
- [x] 6. Evidence: functions 1898/1898, scripts 1061/1061, `movementLogic.js` 100% line/branch/function. QML not run (CI).
- [x] 7. Docs: README, design E1, test plan (+ curl step), KNOWN-ISSUES 4 reworded, 13 refreshed, 15 and 16 added, Skill 173 rule 13 recounted + rule 14, this checkpoint.
- [x] 8. Committed + pushed `62318d3`; CI green on it (QML, Functions, Rules, E2E, PR comment); PR #204 `mergeable_state: clean`, base `main`.

## OPEN for Taher
- D-2: should a delete of a product that still has stock ask for a reason/kind (KNOWN-ISSUES 16)? Belongs to S2e-2.
- D-3: reject punctuation-only ("...") reasons? Recommendation: NO (a content check is a guess; KNOWN-ISSUES 4).
- Merge order: #196 (merged) -> #198 (merged) -> #204 now clean on `main`.

## NEXT
S2e-2 (pickers with the reason field, `reasonProblem`; send no `valueAtCost`) or S4b-2 (register page). Taher picks.
