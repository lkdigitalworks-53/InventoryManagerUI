# CHECKPOINT — 2026-10-05: post-merge review of PR #116 (product-delete batch cascade design). Docs only, no code

**Branch:** `docs/2026-10-05-pr116-design-review` (off `main` @ `1c5a521`).
**Skills invoked by Taher:** requesting-code-review, ponytail-audit, qt-qml-review (no QML written, linter not run). Caveman FULL (chat only).
**Commit identity:** `dextran52@gmail.com` (the old checkpoint said `taher.lkdw53@gmail.com`: stale, finding R9).
**Rules:** branch only; push without asking (PAT only in the push header, never in `.git/config`); no build/run; no Qt tooling in the sandbox (CI is the QML signal); small scope; honest advisor. Previous checkpoint archived to `docs/superpowers/specs/2026-10-05-pr116-design-merged-CHECKPOINT.md`.

## Step log
1. Read memory, cloned repo, read root checkpoint, PR #116 design (120 lines) and test plan (43 lines).
2. Re-read code on `main`: `photoCleanup.js` (`sweepMarker`, `buildMarker`), `gatewayLogic.applyMutation` (marker in txn after CAS), `index.js` `recordMutation` handler (sweep only when `!idempotentReplay`; role gate only for staff), `StockBatchStore._onMutationConflicted`, `InventoryStore.deleteProduct` + conflict handler, `DataModel.onDeleteProduct` (owner/admin gate) and `_resyncForDiscard`, `StuckWrites.entitiesOf`, `operationLogic` / `batchMutationLogic` ceiling comments, `SendPolicy` timeouts.
3. Web search for the Firestore writes-per-transaction ceiling: inconclusive (older SDK reference says 500 and counts each `serverTimestamp()` as an extra write; current quotas excerpt states no such limit). Still UNVERIFIED.
4. Findings R1-R9 written into the design (section "Design review 2026-10-05") and fixed in text where no decision is needed. Test plan updated (rows marked R# / Q-BC-8 / Q-BC-9). Roadmap item 5 status line updated.

## Findings (detail in the design doc)
High: R1 discard path does not restore batches; R2 sweep audit entries have no actor (marker lacks fields). Medium: R3 chunk 200 vs unverified ceiling (now `SWEEP_CHUNK = 100`); R4 replay never sweeps; R5 no server role gate for product delete. Low: R6 old-client ordering text, R7 relaunch leaves queued photos, R8 audit `before` can lag, R9 stale identity.

## DECIDED 2026-10-05 (Taher)
- **Q-BC-8 = yes**: owner/admin gate on `inventory` delete in `recordMutation` (403 `role-not-allowed`, zero writes).
- **Q-BC-9 = no**: idempotent replay does NOT re-sweep. Reason: PH3b (scheduler) is designed and built right after BC1 and is the retry path for every marker; a replay re-sweep would be redundant hot-path code. Condition: reopen if PH3b slips. Crashed-sweep case (old E7) moves to the PH3b test plan. Testing effect: BC1 smaller, handler test pins replay-returns-early.
- **Order**: BC1 -> PH3b -> PH4 rest (confirmed). Design is complete for BC1; waiting for Taher's go to start implementation.
- PH3b design must: not abandon a capped marker silently (money data), pass marker actor fields through, tolerate concurrent handler+scheduler sweeps, accept old-format markers (`system` actor). Listed in the design doc, section "PH3b implications".

## NOT verified
Nothing run (docs only). Firestore per-transaction write ceiling and whether `serverTimestamp()` counts as extra writes (also makes existing `MAX_OPS` / `MAX_BATCH_SIZE = 200` a latent question: 401 vs 601 writes). `qml` review: no QML exists yet for BC2, so the qt-qml-review linter was not run.

## NEXT SESSION — start here
1. Taher says go: start BC1. (Q-BC-8/9 and order already decided; ledger updated.)
2. BC1 (server) on `feat/2026-10-05-bc1-server-batch-sweep` off `main`: marker actor fields, `sweepBatches` dep (`SWEEP_CHUNK = 100`), handler wiring + owner/admin gate for `inventory` delete (no replay sweep), comment reword in `operationLogic.js`, Node tests (`cd functions && npm ci && node --test` runs in-session), e2e E1-E6, docs. Record Taher's functions deploy here before BC2.
3. BC2 (client) after BC1 merged AND deployed: remove batch loop, `mutationApplied`, resync on conflict, `_storesToResync` adds `stock_batch` for `inventory` (R1), Activity + queue purge on ack.
