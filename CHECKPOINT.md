# CHECKPOINT — 2026-10-04: DELETE-FEATURE-ROADMAP item 5 = product-delete destroy-before-ack (design DECIDED, no code)

**Branch:** `docs/2026-10-04-product-delete-batch-cascade-design` (off `main` @ `157dc6b`). Docs only, no code.
**Skills invoked by Taher:** brainstorming, qt-qml, qt-ui-design, ponytail; caveman FULL (chat only). qt-qml / qt-ui-design / ponytail: no code this session, nothing to apply.
**Commit identity:** `taher.lkdw53@gmail.com`. **Previous root checkpoint** (S3, stale: #110 already merged) archived to `docs/superpowers/specs/2026-10-04-s3-merged-CHECKPOINT.md`.
**Rules:** branch only; push without asking (PAT only in the push URL, never in `.git/config`); no build/run; no Qt tooling in the sandbox (CI is the QML signal); small scope (other accounts resume from the remote branch); honest advisor.

## Step log
1. Read memory (overview, ways-of-working, learnings), cloned repo, read `DELETE-FEATURE-ROADMAP.md`, root checkpoint, photos PH3 and PR #113 race checkpoints, photos design (PH3b/PH4/PH5), KNOWN-ISSUES destroy-before-ack entry.
2. Progress check: item 1 (stuck writes) = C, S1, S2a, S2b, S3 all on `main` (#97, #106, #109, #110); only S4 docs cleanup left. Items 2, 3 resolved. Item 4 (photos): PH3 merged (#113, includes the PH4-item-3 loop removal from #115). Open there: PH3b scheduler (designed, unblocked), PH4 rest, PH5, remaining PH3 e2e, photos on discard of a parked product create. New item found: batches/activity/queue still destroyed before the ack.
3. Ranked candidates (table in the design doc). Picked the destroy-before-ack remainder: only item with no design and the only normal-path wrong-data case. Design not done => this session is design only (per Taher's instruction).
4. Code reads for the design: `InventoryStore.deleteProduct`, `Gateway.recordOperation` + signals, `operationLogic.js`, `gatewayLogic.applyMutation` marker, `photoCleanup.sweepMarker`, `DataModel._resyncForDiscard`, `StuckWrites.entitiesOf`. Findings: no per-mutation success signal in `Gateway`; `recordOperation` has no production caller on `main` (PR #90 open); exhausted batches are never pruned; `MAX_OPS` 200 would make a product with >199 batches undeletable under the atomic-op option.
5. Wrote design (options a-d, recommendation d, decisions Q-BC-1..7), planned test plan, roadmap item 5, test-plan index row.

6. Taher answered "default option for all": Q-BC-1..7 decided (ledger in the design doc). Verified by code read: P1 ledger not built (no BC1 interaction); photo UI already owner/admin only (PH4 403 low urgency). Asked: photos pending vs BC order; advice given in chat (BC1 first, then PH3b, PH4 rest after).

## NOT verified
Nothing run. Firestore per-transaction write ceiling (web search did not reach an authoritative statement). Whether the photo UI is already gated to owner/admin (affects PH4 403 urgency). Whether the P1 stock-movements ledger (S1a/S1b) derives rows on stock_batch deletes (must be read before BC1). `recordMutation` role handling for stock_batch delete (not re-read).

## NEXT SESSION — start here
1. Q-BC-1..7 are decided (defaults). Confirm with Taher the ORDER (BC1 vs photos PH3b/PH4/PH5) if not yet answered; recommended: BC1, then PH3b, then PH4 rest.
2. BC1 (server) on `feat/2026-10-05-bc1-server-batch-sweep` off `main`: `sweepBatches` dep in `photoCleanup.sweepMarker`, handler wiring, Node tests (run in-session: `cd functions && npm ci && node --test`), e2e cases E1-E5, docs. Taher deploys functions manually before BC2: record the deploy here.
3. BC2 (client) only after BC1 is merged and deployed.
4. Cheap parallel items if tokens allow: PH4 rest (403 terminal etc.), S4 docs cleanup (own PR). PH3b priority goes up if (d) is chosen.
