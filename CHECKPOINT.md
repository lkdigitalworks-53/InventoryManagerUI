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

## OPEN — need Taher before BC1 code
- **Q-BC-8** server owner/admin gate on `inventory` delete (default: add).
- **Q-BC-9** idempotent replay re-runs the sweep if the marker exists (default: yes).
- Order BC1 vs photos PH3b/PH4 (previous advice: BC1 first) still unconfirmed.

## NOT verified
Nothing run (docs only). Firestore per-transaction write ceiling and whether `serverTimestamp()` counts as extra writes (also makes existing `MAX_OPS` / `MAX_BATCH_SIZE = 200` a latent question: 401 vs 601 writes). `qml` review: no QML exists yet for BC2, so the qt-qml-review linter was not run.

## NEXT SESSION — start here
1. Get Taher's answers to Q-BC-8, Q-BC-9 and the order question; update the design ledger.
2. BC1 (server) on `feat/2026-10-05-bc1-server-batch-sweep` off `main`: marker actor fields, `sweepBatches` dep (`SWEEP_CHUNK = 100`), handler wiring (+ replay sweep if Q-BC-9 = a, + role gate if Q-BC-8 = a), comment reword in `operationLogic.js`, Node tests (`cd functions && npm ci && node --test` runs in-session), e2e E1-E7, docs. Record Taher's functions deploy here before BC2.
3. BC2 (client) after BC1 merged AND deployed: remove batch loop, `mutationApplied`, resync on conflict, `_storesToResync` adds `stock_batch` for `inventory` (R1), Activity + queue purge on ack.
