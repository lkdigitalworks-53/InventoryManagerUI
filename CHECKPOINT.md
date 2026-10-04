# CHECKPOINT — 2026-10-04: BC2 client ack gating (product-delete cascade, design PR #116/#117, BC1 = PR #118 merged)

**Branch:** `feat/2026-10-04-bc2-client-ack-gating` (off `main` @ `ffe02a4`). Client (`qml/`, `tests/`, `test/e2e/`) + docs. No `functions/` change.
**Commit identity:** `tsadmin@gmail.com` (user.name `tsadmin`). Earlier BC1 history keeps its old identities, not rewritten.
**Rules (standing):** branch only; push without asking (PAT only in the push header via `/tmp/push.sh`, never in `.git/config` or a file); no build/run; no Qt tooling in the sandbox (CI = the QML signal); small scope; honest advisor, grill before deciding. Skills read: brainstorming, ponytail. Caveman FULL (chat only).
**Previous checkpoint archived:** `docs/superpowers/specs/2026-10-05-bc1-server-sweep-and-review-CHECKPOINT.md`.
**Design:** `docs/superpowers/specs/2026-10-04-product-delete-batch-cascade-design.md` (BC2 decisions Q-BC-3/4/6 already decided; new section "BC2 implementation + device-test observations" holds the 5 NEW open decisions D1-D5). **Test plan:** `docs/superpowers/test-plans/2026-10-04-product-delete-batch-cascade-test-plan.md` (BC2 implemented block + section 3.7).

## Scope decision (honest)
Taher asked: document the 4 device-test observations, then implement the next part of BC-1 per plan, "design if not done". BC2 design WAS done (Q-BC-1..9), so this session implements BC2 as designed. The observations are NOT all BC2: obs 1 (1 MiB description) and obs 2 (restock dialog hang) are separate defects with no approved design; they are documented with root cause (code read, NOT reproduced) and left as decisions D1-D3, not built. Obs 3 (batches gone, product + rejected list intact) IS the BC2 bug.

## Step log
1. Cloned repo, read checkpoint, design, brainstorming + ponytail skills, `InventoryStore.deleteProduct`, `Gateway._send/_sendDelta/recordDelta`, `OutboxStore` (parked keys), `RestockDialog`, `DataModel` resync, existing tests.
2. Code: `Gateway.mutationApplied(entity, entityId, action)` + `_ackSingle(item)` (fired from `_send` on 2xx, after `markSent`). `InventoryStore.deleteProduct` no longer sends `stock_batch` deletes; batches hidden locally; Activity entry + queued-photo purge moved to `_onMutationApplied` (memory `_pendingDeletes`, dropped on a delete conflict). `DataModel._storesToResync` adds `stock_batch` right after `inventory` (R1); `Connections.onMutationConflicted` re-reads batches on an inventory delete conflict.
3. Tests (CI-only, NOT run): `tst_Gateway.qml` +8, `tst_DataModel_discardResync.qml` (4 changed, +9), `tst_InventoryStore_deleteProductCascade.qml` (8 changed for ack gating, +16 BC2 incl. monkey), `tst_ActivityLog_deleteEntries.qml` (1 changed), e2e `tst_StockBatchStoreE2E.qml` +2 (ack path + stale 409).
4. Docs: KNOWN-ISSUES (observations + root causes), design addendum (D1-D5), test plan, AGENTS.md, SKILLS.md Skill 97.

## NOT verified
- CI of this branch (nothing run here). The 2 new e2e cases are written blind against the emulator: the first CI run is their first run.
- **BC1 deployed?** Taher said PR #118 is "merged and tested"; no deploy record exists in any checkpoint. BC2 against an undeployed server = batches never deleted. **Do not merge this PR until the deploy (date, project) is recorded here.**
- Obs 2 / obs 3 root causes are from reading code, not from a device trace.

## NEXT SESSION — start here
1. Read CI on the BC2 PR. Fix red first (most likely: e2e blind cases, or a stale pin in a test file not found by grep).
2. Record the BC1 deploy here. Then Taher merges BC2.
3. Answer D1-D5 (design doc). Then: restock-behind-parked-write fix, description size cap, then PH3b, then PH4 rest.
