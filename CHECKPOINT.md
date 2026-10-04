# CHECKPOINT — 2026-10-05: BC1 server batch sweep (product-delete cascade, design PR #116/#117)

**Branch:** `feat/2026-10-05-bc1-server-batch-sweep` (off `main` @ `6077c46`). Server only (`functions/`), no QML.
**Skills invoked by Taher:** using-superpowers, qt-qml, qt-ui-design, ponytail (no QML written: qt-qml / qt-ui-design nothing to apply). Caveman FULL (chat only).
**Commit identity:** `lkdwtaher@gmail.com` (this account, stated this session; overrides the stale identities in older checkpoints).
**Rules:** branch only; push without asking (PAT only in the push header, never in `.git/config`, never in a file); no build/run; no Qt tooling in the sandbox (CI = QML signal); small scope; honest advisor. Previous root checkpoint archived to `docs/superpowers/specs/2026-10-05-pr116-review-merged-CHECKPOINT.md`.
**Design:** `docs/superpowers/specs/2026-10-04-product-delete-batch-cascade-design.md` (Q-BC-1..9 all decided). **Test plan:** `docs/superpowers/test-plans/2026-10-04-product-delete-batch-cascade-test-plan.md`.

## Scope decision (honest)
Taher asked "implement the design, complete in one go". Design says BC2 (client) only AFTER BC1 is merged AND deployed (Q-BC-6): client stops sending batch deletes, so BC2 against an undeployed server = batches never deleted, ghosts in valuation. So this session = BC1 only. BC2 not started on purpose.

## Step log
1. Read memory, cloned repo, read root checkpoint, design (163 lines), skills. Baseline `cd functions && npm ci && node --test`: 446 pass.
2. Code reads: `lib/photoCleanup.js`, `lib/gatewayLogic.js applyMutation`, `index.js recordMutation` + `sweepProductPhotos`, `lib/operationLogic.js`, test harness (`testSupport/handlerHarness.js`), PH3 tests in `index.handlers.test.js`, `gatewayLogic.test.js`, `photoCleanup.test.js`.
3. Code (functions/): `buildMarker` + actorUid/actorRole/requestId (R2); `SWEEP_CHUNK = 100` (R3); `sweepStockBatches` + `buildCascadeAuditId`; `sweepMarker` calls `deps.sweepBatches` after the exists-guard, before Storage (required dep); `applyMutation` passes actor fields to the marker; `index.js`: owner/admin gate on inventory delete (Q-BC-8), `sweepProductPhotos` -> `sweepProductCleanup` with `sweepBatches` binding (query `stock_batches where productId == id`, one write batch per chunk), actor fields into the handler's sweep; replay still does NOT sweep (Q-BC-9); `operationLogic.js` comments softened (Q-BC-7).
4. Suite after code, before tests: 432 pass / 14 fail, all expected (new required dep in old fakes, F19/U19 marker shape, F30 pinned the OLD no-gate behaviour).

## NOT verified
Nothing deployed. Firestore per-commit write ceiling still unverified (chunk 100 = 200 writes). e2e cases need the emulator (CI only). Real Firestore `where().get()` / `batch()` binding is covered only by harness fakes + CI e2e.

## NEXT SESSION — start here
(see bottom of file, updated at end of session)
