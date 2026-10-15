# CHECKPOINT — 2026-10-16 P1 slice S1a: server-side stock movements (resume here)

**Branch:** `feature/2026-10-16-p1-s1a-server-movements`, cut from `main` @ `0f081f2`.
**Commit identity:** `Taher <lkdwtaher@gmail.com>` (this account). PAT only in the push command, never in a file or git config; after push `grep -c ghp_ .git/config` must print 0.
**Rules in force:** do not build/run the app; no Qt in the sandbox (CI is the QML oracle); push without asking, Taher reviews in the PR; short scope (token budget, multi-account hand-off); honest trade-offs.
**Skills used:** `superpowers:brainstorming`, `qt-development-skills:qt-qml`, `qt-development-skills:qt-ui-design`, `ponytail:ponytail`. Caveman FULL.
**Previous checkpoint archived:** `docs/superpowers/specs/2026-10-15-pr139-test-plan-rewrite-CHECKPOINT.md`.

## Why this item
Compliance status vs master spec (`specs/2026-06-06-india-compliance-roadmap-design.md`), grep-verified on `main` @ `0f081f2`:
P0 gateway + audit_log done. P1 design rev 2 + S1a/S1b plans merged (#85, #86) but **no code**: no `functions/lib/movementLogic.js`, no `movements` in `functions/index.js`.
P2 (HSN/GSTIN), P3-P7: nothing in `qml/` or `functions/`. Next priority by Taher's own chain (P1 checkpoint step 19) = **implement S1a**.
S1a is server-only (`functions/`), already scoped as one slice = one PR = one session, fully testable with `node --test` here. No QML, so no UI design needed in this slice (qt-ui-design / qt-qml apply from S2).

## Scope
Plan: `docs/superpowers/plans/2026-09-24-p1-server-side-stock-movements-s1a.md` (5 tasks, code embedded). Spec: `specs/2026-09-24-p1-server-side-stock-movements-design.md` D1-D13.
Plan base drift: PR #80 added `removed_staff` to `ENTITY_COLLECTIONS`, plan Task 2 patch may not `git apply`; hand-edit then. Base has moved a lot since (BC1/PH3 touched `gatewayLogic.js`/`index.js`): re-check every patch with `git apply --check`.
Baseline before any change: `cd functions && node --test` = 626 pass, 0 fail.

## Steps (tick as done)
- [x] 1. Cloned, read master spec, P1 design, checkpoints, S1a plan; confirmed S1a not built. Skills loaded.
- [x] 2. Branch + identity + `npm ci` + baseline 626/626. Old checkpoint archived.
- [x] 3. Task 1 (2c60791): `movementLogic.js` + 24 tests. Red (module missing) then 24/24.
- [x] 4. Task 2 (dc694c4): `recordDelta` writes rows, `stock_movement` closed, `recordMutation` rejects `movements`. Plan patch failed `git apply` (base drift), same edits applied by hand. 17 tests, red 11 fail then green. Suite 667.
- [x] 5. Task 3 (00a9bd8): handler pass-through (`index.js` +1 line), harness captures `applyDelta` params (hand edit, line drift). 5 tests, 2 red then green. Suite 672.
- [x] 6. Task 4 (2803e9d): `recordOperation` rows + write budget; `operationLogic.js` edited by hand (patch drift), test patch applied clean. 13 tests, 9 red then green. Suite 685.
- [x] 7. Task 5: coverage `movementLogic.js` 100/100, `gatewayLogic.js` and `operationLogic.js` 100% line; 7 mutations caught (derive removed, `completeOrder` default, budget row term, `stock_movement` re-added, handler pass-through, mutation reject, sum check), files restored. README, AGENTS, test plan + its index row, S1b plan drift note updated. `SKILLS.md` untouched (no new lesson worth a numbered skill).
- [x] 8a. Pushed (proxy needed `add_repo` with push access first; no PAT used) and opened **PR #146** (`gh pr create` is blocked, GraphQL; used `gh api .../pulls`).
- [ ] 8b. Wait for CI on the PR tip (functions tests are the real proof; no QML changed).
- [ ] 9. **Taher:** `firebase deploy --only functions` to dev, confirm unauthenticated `POST recordDelta` = `401 missing-token`, run the S1a on-device checklist in the test plan. Rows do not appear before the deploy (R3).
- [ ] 10. **Next session (new branch off `main` after S1a merges):** S1b per `plans/2026-09-24-p1-server-side-stock-movements-s1b.md` (run `git apply --check` on each patch first, hand-edit on drift). S2 planning only after S1b's checklist passes.

## Open items
- No QML touched, so no QML CI delta expected; CI must still be green on this PR (functions tests + existing QML/E2E).
- Compliance items still not started: P2 (HSN/GSTIN, client-only, could run in parallel), P3-P7.

## NEXT
Step 8b: check CI on PR #146 (S1a). If red, read the failing job first; functions suite is 685 locally.
