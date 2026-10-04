# CHECKPOINT — 2026-10-04: BC2 client ack gating (product-delete cascade, design PR #116/#117, BC1 = PR #118 merged)

**Branch:** `feat/2026-10-04-bc2-client-ack-gating` (off `main` @ `ffe02a4`). Client (`qml/`, `tests/`, `test/e2e/`) + docs. No `functions/` change.
**Commit identity:** `allibaas1998@gmail.com` (user.name `allibaas1998`) from 2026-10-04 session 2 on, per Taher. Earlier commits on this branch (`tsadmin`) are not rewritten.
**Rules (standing):** branch only; push without asking (PAT only in the push header via `/tmp/push.sh`, never in `.git/config` or a file); no build/run; no Qt tooling in the sandbox (CI = the QML signal); small scope; honest advisor, grill before deciding. Skills read: brainstorming, ponytail. Caveman FULL (chat only).
**Previous checkpoint archived:** `docs/superpowers/specs/2026-10-05-bc1-server-sweep-and-review-CHECKPOINT.md`.
**Design:** `docs/superpowers/specs/2026-10-04-product-delete-batch-cascade-design.md` (BC2 decisions Q-BC-3/4/6 already decided; new section "BC2 implementation + device-test observations" holds the 5 NEW open decisions D1-D5). **Test plan:** `docs/superpowers/test-plans/2026-10-04-product-delete-batch-cascade-test-plan.md` (BC2 implemented block + section 3.7).

## SESSION 3 (2026-10-04, final-sweep review of PR #119) — resume here
**Branch:** `review/2026-10-04-pr119-final-sweep` (stacked, base = `feat/2026-10-04-bc2-client-ack-gating`). Docs only, no `qml/`, `functions/`, test change. **Commit identity:** `taher.lkdw@gmail.com`. **Skills:** requesting-code-review, ponytail-review, qt-qml-review (deterministic linter run on the 5 changed production files; its hits are repo-wide style, `var`/`==`/`property var`, none on changed lines that break repo convention). Caveman FULL (chat only).
**State of PR #119:** CI green on `b64f0db` (QML, E2E, Functions, Rules, PR comment). Taher: device test done, all pass. BC1 deployed (D4).
**Findings (code):** no Critical, no Important. Checked: every `mutationApplied` consumer filters entity+action; the `markSent` sites besides `_ackSingle` are discard, conflict and the batch/delta/operation paths, none of which may fire it; `_storesToResync` appends `stock_batch` once with no duplicate; `deleteProduct` refusal returns before any write; `restock` refusal sits after the unknown-product check and before supplier auto-promote; the `errorOccurred("inventory", ...)` context lands in the generic "Action Blocked" dialog (`Main.qml`), no new context string needed.
**Findings (Minor, NOT fixed, on purpose):** (a) `InventoryStore._pendingDeletes` keeps an entry after `Gateway.discardParked` of a rejected delete (`parkedWriteDiscarded` carries entity names, not ids). Harmless: only a fresh `deleteProduct` for that id can ack a delete from this device and it overwrites the entry; costs a few bytes per discard. A fix is new blind QML + a new test for no behaviour change. (b) ponytail: `_pendingDeletes` is copied with `Object.assign` on every write though nothing binds to it (-4 lines in place); `_ackSingle` is a one-caller wrapper kept as the test seam (design deviation (b)). Both left: blind-edit risk beats 4 lines. (c) Order-completion deltas still unguarded (UNVERIFIED hang), already open in KNOWN-ISSUES.
**Findings (docs, fixed here):** `tst_ParkedWriteGuard.qml` has 17 test functions (grep-counted), docs said 18 (test plan, README row, this file); first-session "NOT verified" and "NEXT SESSION" blocks still said "do not merge until BC1 deploy recorded" and "read CI"; both retired above.
**Merge order:** (1) merge the stacked review PR into `feat/2026-10-04-bc2-client-ack-gating`; (2) squash-merge PR #119 into `main`. No `functions/` change, so no deploy for BC2.
**NEXT after merge (advice, Taher decides):** (1) PH3b sweeper: retries `pending_cleanup` markers whose batch/photo sweep failed or whose process died after the delete commit (replay does not sweep, Q-BC-9); closes the orphan-batch window; blocks a production publish, not dev. (2) Order-completion delta behind a parked write: write an emulator E2E repro first (seed a parked item, complete an order, assert the callback), then decide; do NOT copy the restock refusal blindly, refusing a sale at the counter costs more than a stale-stock drift. (3) PH4 rest: "already deleted" handling for orphan queued photos (R7 mitigation). (4) Reconcile the older "one atomic `recordOperation` for product + batches" plan with the shipped sweep design (option d): close or restate it so two features do not collide. (5) C-3 Phase 3 / P1 S2+ per roadmap.
**NOT verified:** nothing run here (no Qt toolchain, standing rule). Merge-order and PH3b claims come from the design doc and code read, not a device trace.

## SESSION 2 (2026-10-04, PR #119 CI fix + D1-D5) (history)
**Decisions (Taher):** D1 no size cap in the app (leave it); D2 refuse restock behind a parked write; D3 refuse delete behind a parked write; D4 BC1 IS deployed to `inventorymanager-48392`; D5 D2+D3 go in PR #119 as a separate commit. Recorded in the design doc.
**CI on `405d209`:** only `E2E Tests` failed (59/60): `StockBatchStoreE2E::test_BC2_stale_product_delete_409_keeps_product_batches_and_activity_clean`. Root cause: `DataModel` is not a singleton and the test file never declared one, so `onMutationConflicted` never re-read batches. Test-only fix.
**Step log:**
1. Cloned repo, fetched PR #119 (`gh api`, REST only; raw job logs are blocked by the sandbox proxy, the bot PR comment + check annotations gave the failing test name).
2. Commit `ee6fe4d` `fix(test)`: `DataModel { id: dm }` in `tst_StockBatchStoreE2E.qml`. Pushed.
3. Commit `2362d9d` `feat(client)` D2/D3: `OutboxStore.hasParkedForEntity`, `InventoryStore.hasParkedWrite/parkedWriteMessage`, guards in `restock` and `deleteProduct`, `DataModel` + `RestockDialog` show the message. Tests: `tst_OutboxStore` +9, `tst_ParkedWriteGuard` (new, 17), E2E +2. Pushed.
4. Docs commit: test plan `2026-10-04-parked-write-guard-test-plan.md` (+README row), design doc decisions, KNOWN-ISSUES status, AGENTS.md, SKILLS.md Skill 98, this checkpoint.
5. CI on `4369a36`: E2E 62/62 green (the `DataModel` fix worked), Functions/Rules green, QML 1660/1662. Both reds were in the NEW `tst_ParkedWriteGuard.qml`, test bugs not product bugs: `_park` ignored that `OutboxStore.enqueue` merges into a pending item and returns the old requestId (so `setStuckMeta` hit nothing), and `_restock` seeded `refusal: null` so `compare(null, undefined)` failed. Fixed in the next commit.
**NOT verified:** nothing ran here (no Qt toolchain, standing rule). New tests, including the 2 E2E cases, are blind until CI. BC1 deploy is Taher's word. The `dm` instance in the E2E file is the diagnosis from code read, not from a CI log (logs not downloadable here): if the 409 E2E is still red, read its CI log first.
**Open:** order-completion deltas are not guarded (UNVERIFIED hang). PH3b sweeper is the next slice. Mutation checks not run.
**NEXT SESSION:** (1) read CI on PR #119 (bot comment lists failing tests); fix red first. (2) Taher device-tests section 4 of the new test plan. (3) merge PR #119. (4) decide the order-completion guard, then PH3b.

## Scope decision (honest)
Taher asked: document the 4 device-test observations, then implement the next part of BC-1 per plan, "design if not done". BC2 design WAS done (Q-BC-1..9), so this session implements BC2 as designed. The observations are NOT all BC2: obs 1 (1 MiB description) and obs 2 (restock dialog hang) are separate defects with no approved design; they are documented with root cause (code read, NOT reproduced) and left as decisions D1-D3, not built. Obs 3 (batches gone, product + rejected list intact) IS the BC2 bug.

## Step log
1. Cloned repo, read checkpoint, design, brainstorming + ponytail skills, `InventoryStore.deleteProduct`, `Gateway._send/_sendDelta/recordDelta`, `OutboxStore` (parked keys), `RestockDialog`, `DataModel` resync, existing tests.
2. Code: `Gateway.mutationApplied(entity, entityId, action)` + `_ackSingle(item)` (fired from `_send` on 2xx, after `markSent`). `InventoryStore.deleteProduct` no longer sends `stock_batch` deletes; batches hidden locally; Activity entry + queued-photo purge moved to `_onMutationApplied` (memory `_pendingDeletes`, dropped on a delete conflict). `DataModel._storesToResync` adds `stock_batch` right after `inventory` (R1); `Connections.onMutationConflicted` re-reads batches on an inventory delete conflict.
3. Tests (CI-only, NOT run): `tst_Gateway.qml` +8, `tst_DataModel_discardResync.qml` (4 changed, +9), `tst_InventoryStore_deleteProductCascade.qml` (8 changed for ack gating, +16 BC2 incl. monkey), `tst_ActivityLog_deleteEntries.qml` (1 changed), e2e `tst_StockBatchStoreE2E.qml` +2 (ack path + stale 409).
4. Docs: KNOWN-ISSUES (observations + root causes), design addendum (D1-D5), test plan, AGENTS.md, SKILLS.md Skill 97.

## NOT verified (session 1; SUPERSEDED by SESSION 3 above)
- (was) CI of this branch: now green on `b64f0db`. (was) BC1 deploy record: recorded, D4, merge gate cleared.
- Obs 2 / obs 3 root causes are from reading code, not from a device trace; the device test (SESSION 3) passed with the D2/D3 guard.

## NEXT SESSION (session 1; SUPERSEDED, see SESSION 3 NEXT)
1. Read CI on the BC2 PR. Fix red first (most likely: e2e blind cases, or a stale pin in a test file not found by grep).
2. Record the BC1 deploy here. Then Taher merges BC2.
3. Answer D1-D5 (design doc). Then: restock-behind-parked-write fix, description size cap, then PH3b, then PH4 rest.
