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
- [ ] 3. Task 1: `movementLogic.js` + `movementLogic.test.js` (red, green, commit)
- [ ] 4. Task 2: `recordDelta` writes rows; close `stock_movement` entity (red, green, commit)
- [ ] 5. Task 3: `recordDelta` handler pass-through (red, green, commit)
- [ ] 6. Task 4: `recordOperation` writes rows + write budget (red, green, commit)
- [ ] 7. Task 5: mutation spot-check, docs (README, AGENTS, test plan status), counts re-verified with `node --test`
- [ ] 8. Push, open PR, wait for CI, hand to Taher (deploy functions to dev, on-device checklist)

## NEXT
Step 3.
