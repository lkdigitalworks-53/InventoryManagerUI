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

5. Tests (functions/): harness gained `collection().where(==)` and `db.batch()` (+ `batchCommits`, `batchCommitError`); `photoCleanup.test.js` (+20 BC-U cases, U19/U40-U47 adapted), `gatewayLogic.test.js` (+1, F19 shape), `index.handlers.test.js` (F30 replaced by BC-H01; +BC-H02..H17 incl. gate, audit shape, 409, replay pin, failures, retry, id reuse, 250 batches, ordering, monkey). Suite 446 -> 483 pass (recounted with `git diff 6077c46 -- functions/test | grep -c '^+test('` = 38 added, 1 replaced).
6. Mutation check in-session (script, restored after): drop productId filter, chunk skip, chunk 500, drop first entry, drop role gate, wrong query value, wrong tenant, marker drops actor, drop back-link, random audit id, skip batch step: all killed (2..16 failing tests each).
7. e2e (CI-only, NOT run): E1, E2, E4, E6, replay pin, role gate appended to `test/e2e/recordOperation.e2e.test.js` (already wired in `.github/workflows/checks.yml`, so no workflow edit and no `workflow` PAT scope needed). E3/E5 not e2e (see test plan).
8. Docs: design status, test plan header + README row, KNOWN-ISSUES (BC1 paragraph + 3 new limits), DELETE-FEATURE-ROADMAP item 5, AGENTS.md (photoCleanup bullet + runbook), photos design PH3b note, SKILLS.md Skill 95. README.md has no mention: unchanged.
9. Pushed after each phase (`84f2c82` code, `53ee00c` tests, docs commit last). PAT only in the push header via `/tmp/push.sh`, nothing stored in `.git/config`.

## NOT verified
- CI result of this PR (QML, rules, e2e). The 6 new e2e cases have never run against the emulator; the real Firestore `where().get()` / `batch()` binding is exercised only by harness fakes until CI runs.
- Firestore per-commit write ceiling (chunk 100 = 200 writes, 300 if `serverTimestamp()` counts extra). Existing `MAX_OPS` / `MAX_BATCH_SIZE = 200` remain a latent question (401 vs 601), not changed.
- How the stuck-writes dialog words a parked 403 `role-not-allowed` for a product delete (check on device).
- Nothing deployed.

## NEXT SESSION — start here
1. Read CI on the BC1 PR. e2e failures are the likely first thing: fix test or code, push.
2. Taher reviews + merges BC1, then **deploys functions manually** (`firebase deploy --only functions --project <dev>`). RECORD THE DEPLOY HERE (date, project) before BC2.
3. BC2 (client) on `feat/2026-10-0X-bc2-client-ack-gating` off `main` AFTER merge + deploy: remove the `stock_batch` delete loop in `InventoryStore.deleteProduct`; `Gateway.mutationApplied(entity, entityId, action)` signal (Q-BC-3 A); Activity entry + queued-photo purge on ack (Q-BC-4); resync batches on `mutationConflicted(inventory, delete)`; `DataModel._storesToResync` adds `stock_batch` whenever `inventory` present (R1); QML tests per the test plan (CI-only).
4. Then PH3b (must follow the "PH3b implications" list in the design), then PH4 rest.
