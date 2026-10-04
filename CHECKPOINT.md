# CHECKPOINT — 2026-10-05: BC1 server batch sweep (product-delete cascade, design PR #116/#117)

**Branch:** `feat/2026-10-05-bc1-server-batch-sweep` (off `main` @ `6077c46`). Server only (`functions/`), no QML.
**Skills invoked by Taher:** using-superpowers, qt-qml, qt-ui-design, ponytail (no QML written: qt-qml / qt-ui-design nothing to apply). Caveman FULL (chat only).
**Commit identity:** BC1 commits `84f2c82`/`53ee00c`/`f222a44` carry `lkdwtaher@gmail.com` (the account that wrote them). Review-session commits (below) carry `lkdigitalworks@gmail.com`, `Taher (via Claude session) <lkdigitalworks@gmail.com>`. History not rewritten.
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
- ~~CI result of this PR~~ RESOLVED by the review session: CI green on `f222a44` (QML 1601, Functions 323, Rules 45, E2E 58, run 37206327547). Per-case e2e results NOT confirmed (job log download returned empty): the emulator run exercises the real `where().get()` / `batch()` binding only if the 6 BC e2e cases were in the 58; check the CI log for E1/E2/E4/E6 by name.
- Firestore per-commit write ceiling (chunk 100 = 200 writes, 300 if `serverTimestamp()` counts extra). Existing `MAX_OPS` / `MAX_BATCH_SIZE = 200` remain a latent question (401 vs 601), not changed.
- How the stuck-writes dialog words a parked 403 `role-not-allowed` for a product delete (check on device).
- Nothing deployed.

## NEXT SESSION — start here
1. Read CI on the BC1 PR. e2e failures are the likely first thing: fix test or code, push.
2. Taher reviews + merges BC1, then **deploys functions manually** (`firebase deploy --only functions --project <dev>`). RECORD THE DEPLOY HERE (date, project) before BC2.
3. BC2 (client) on `feat/2026-10-0X-bc2-client-ack-gating` off `main` AFTER merge + deploy: remove the `stock_batch` delete loop in `InventoryStore.deleteProduct`; `Gateway.mutationApplied(entity, entityId, action)` signal (Q-BC-3 A); Activity entry + queued-photo purge on ack (Q-BC-4); resync batches on `mutationConflicted(inventory, delete)`; `DataModel._storesToResync` adds `stock_batch` whenever `inventory` present (R1); QML tests per the test plan (CI-only).
4. Then PH3b (must follow the "PH3b implications" list in the design), then PH4 rest.

## REVIEW SESSION 2026-10-04/05 (PR #118, branch `review/pr118-fixes` -> pushed to the PR branch)
Skills: requesting-code-review, ponytail-review, qt-qml-review (no QML in diff). Rules: caveman, branch only, push without asking, no build/run, no Qt tooling.
1. Cloned repo, read memory, read the full PR diff (19 files, +879/-51), PR checks (all green), design, test plan, docs diff.
2. Traced: collection `stock_batches` + field `productId` match client; no index needed; `FieldValue` imported; chunk = 200 writes; gate before prefix build; replay unchanged; old-client 409 path = design R6. Ran `node --test`: 483 pass.
3. FINDING C1 (Med): `cascade~` audit ids collide with client requestIds (3 validators + 2 photo endpoints unvalidated). FIXED: `PhotoCleanup.isReservedAuditId` + `CASCADE_AUDIT_PREFIX`, guard in `validateMutationRequest`, `validateDeltaRequest`, `validateBatchMutationRequest`, `uploadProductPhoto`, `deleteProductPhoto`. +8 tests, suite 491 pass, mutation check (guard off) => 7 fail.
4. Docs: design "Code review 2026-10-05 (PR #118)" C1-C7 + PH3b implications 1 and 6, KNOWN-ISSUES (d), roadmap count, AGENTS.md, test plan (review paragraph + new section 3.0 BC1-only on-device), SKILLS.md Skill 96. PR title/body updated.
5. NOT done on purpose: C7 (requestId/entityId charset validation on recordMutation/recordDelta, pre-existing, own branch); BC2; PH3b; deploy.
6. NOT verified: CI on the review-fix commit (pending); e2e per-case names in CI log; real Firestore write ceiling.

## NEXT SESSION — start here (supersedes the list above where it differs)
1. Read CI on PR #118 (fix commit). Fix if red.
2. Taher merges #118, deploys (`firebase deploy --only functions --project inventorymanager-48392`, region asia-south1) and RECORDS the deploy here (date, project).
3. Run test plan section 3.0 on device. Then BC2 per the list above, then PH3b (must reuse `sweepProductCleanup` binding, see design PH3b item 1).
