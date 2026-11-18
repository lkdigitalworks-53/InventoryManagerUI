# CHECKPOINT: 2026-11-17 PR #204 (P1 S2e-1) second full-sweep review - resume here

**Branch:** `feat/2026-11-13-p1-s2e1-reason-policy-and-cost-snapshot` (PR #204). Fixes go in THIS PR (not stacked). Earlier checkpoints: `docs/superpowers/specs/2026-11-13-p1-s2e1-prev-CHECKPOINT.md` and `docs/superpowers/specs/2026-11-17-p1-s2e1-sweep1-CHECKPOINT.md` (first sweep).
**Commit identity (this sweep):** `Taher (via Claude session) <lkdigitalworks@gmail.com>` per the saved working rules; the first five commits of the PR carry `taher.lkdw@gmail.com` (KNOWN-ISSUES S2e-1 item 19). Taher: say which one you want and it is fixed with a squash-merge.
**Rules in force:** no build or run; no Qt in the sandbox (CI decides); push without asking; no parallel agents; tests + test plan for every change; out-of-scope findings to `docs/superpowers/KNOWN-ISSUES.md`.
**Skills used (applied by hand, no subagents):** superpowers:requesting-code-review, qt-development-skills:qt-qml-review, ponytail:ponytail-audit.

## Steps
- [x] 0. Re-cloned repo, PR #204 head `bdc93e9` (CI green, clean), read design, test plan, KNOWN-ISSUES.
- [x] 1. Server review (`movementLogic`, `gatewayLogic`, `operationLogic`, `batchMutationLogic`): derive-only paths confirmed, replay path confirmed.
- [x] 2. PROBED the real module with invisible/control/tag characters. FOUND D-1b (bug): the first D-1 fix still let NUL, C0, DEL, C1 controls and Unicode TAG characters (U+E0000-E03FF) count as a visible reason.
- [x] 3. FIX D-1b: `INVISIBLE_RE` now has `\u0000-\u001F`, `\u007F-\u009F` and a surrogate-pair branch for the tag block; mirrored in `qml/helper/StockMovements.js` (BMP escapes, no `u` flag).
- [x] 4. Tests: 12 new refused shapes + 6 accepted shapes in the battery (715 checks per run, counted), 12 new mutants (49 total), RP-06 (all 65,536 code units and the whole tag block, server and client, against an independent hex-range table), 2 QML twins (`tst_StockMovements.qml`), 1 QML pin (`tst_InventoryStore_movementKinds.qml`).
- [x] 5. Evidence (Node, measured after `npm ci`): `functions` 1899/1899; `movementLogic.js` 100% line/branch/function. QML not run (CI).
- [x] 6. Latent finding: `InventoryStore._movementsFor` silently degrades a required kind without a real reason to an unreasoned derived adjustment. Pinned by a test + CAUTION comment; decision recorded (KNOWN-ISSUES 17).
- [x] 7. Docs: README, design (stale "stacked" wording and D-1b amendment), test plan (counts re-measured, curl cases, CI-red meaning), KNOWN-ISSUES 4/17/18/19 and item 39/12 text restored, Skill 173 rules 15 + 16, this checkpoint.
- [x] 8. Committed + pushed `427d71c`; CI green on it (QML incl. the tag-character twin, Functions, Rules, E2E, PR comment): Qt's engine reads the surrogate-pair branch like Node.

## OPEN for Taher
- 17 (decision for S2e-2): should `_movementsFor` REFUSE a required kind with no real reason, instead of degrading? Recommendation: refuse.
- 18 (unverified): does Firestore store a reason with a lone surrogate or a NUL inside? Needs a 2-case emulator test; emulator cannot run in the sandbox.
- 19: commit email mismatch (see above).
- Earlier, still open: D-2 (delete of a product with stock, KNOWN-ISSUES 16), D-3 (punctuation-only reasons: recommendation NO).

## NEXT
S2e-2 (pickers with the reason field, `reasonProblem`; send no `valueAtCost`) or S4b-2 (register page). Taher picks.
