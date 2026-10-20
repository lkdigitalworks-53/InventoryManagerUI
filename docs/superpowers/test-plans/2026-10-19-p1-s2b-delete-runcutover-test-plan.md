# Test plan — P1 S2b: delete server `runCutover`

**Branch:** `feat/2026-10-19-p1-s2b-delete-runcutover`, stacked on `docs/2026-10-19-p1-s2-design` (design + checkpoint) off `main` @ fe9aa86. **Design:** `specs/2026-10-19-p1-s2-design.md` (Q1-Q3 approved 2026-10-19).
**Covers:** `functions/index.js` (export + `CutoverLogic` require removed), `functions/lib/cutoverLogic.js` and `functions/test/cutoverLogic.test.js` (deleted), `testSupport/handlerHarness.js` (cutover mock removed), `index.handlers.remaining.test.js` (9 runCutover tests removed, 1 guard added), comments, README, AGENTS.md, Skill 123.
**Not covered:** the client. `Gateway.runCutover`, `cutoverUrl`, `cutoverFinished` stay until S2a (no caller anywhere, verified by grep). No QML, rules or e2e file changed.

## 1. Unit / functional (run 2026-10-19, sandbox, Node 22)
| Check | Command | Result |
|---|---|---|
| Baseline before the change | `cd functions && node --test` | 740/740 |
| After the change | same | 722/722 (-10 cutoverLogic, -9 handler, +1 guard) |
| Guard fails if the lib file returns | `touch lib/cutoverLogic.js`, run `index.handlers.remaining.test.js` | 1 fail (guard), restored |
| Guard fails if the export returns | append `exports.runCutover = exports.recordMutation;`, run same file | 1 fail (guard), restored |
| No server code reference left | `git grep -n -i cutover -- functions` | 5 lines, all in `index.handlers.remaining.test.js` (2 comments + the guard test); none in `index.js`, `lib/` or the harness. Dead `deleteCollection*`/`zeroInventoryStock*` mock fields removed from the harness in the PR review (nothing read them) |
| Skills index current | `node .github/scripts/skills-index.js --write` | 124 skills |
Coverage: pure deletion, so no new branch exists. Every remaining line is covered by the unchanged suites (the other 4 endpoints' handler tests all still pass with the harness change).

## 2. Rules / e2e
None changed. Rules tests and the emulator e2e job are not affected (no reference to `runCutover` in `test/`, `tests/` or the emulator suites). CI runs them as the regression signal.

## On-device test plan (Taher, after `firebase deploy --only functions` to dev)
- **Happy path:** deploy prompts to delete `runCutover`: answer yes. Then restock a product, import 5 rows, complete an order, add a staff member, open Analysis. All work as before.
- **Negative:** `curl -X POST .../runCutover` (any body) returns 404 (function gone). No in-app screen calls it, so nothing in the UI changes.
- **Edge cases:** deploy answered "no" to the delete prompt leaves the OLD function live (still owner-only and `CUTOVER`-confirmed): delete it with `firebase functions:delete runCutover --region asia-south1`. An old app build that still has the client `runCutover` would just get an HTTP error.
- **Multiple scenarios:** deploy with the S1b functions in one go; run the S1a/S1b checklist in `2026-09-24-p1-stock-movements-test-plan.md` after it (the ledger rows are not touched by this slice).
- **Monkey:** not applicable (no UI, no input path). Re-run the 4 remaining endpoints' normal use for 2 minutes.
- **Regression watch:** a dev tenant can no longer be wiped from the app. To reset a dev ledger, create a new tenant (D10 says testing uses new tenants).
