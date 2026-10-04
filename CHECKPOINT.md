# CHECKPOINT — 2026-10-04: order-completion delta behind a parked write (repro + fix)

## SESSION 2 (2026-10-04, PR #121 device test) — resume here
**Branch:** `docs/2026-10-04-pr121-device-observations` (stacked on `test/2026-10-04-order-completion-parked-delta-repro`). Docs only so far. Commit identity `taher.lkdw53@gmail.com`. Caveman FULL (chat only).
**State of PR #121:** CI green on `e9403ec`; Taher device-tested it: parked edit denies completion as intended. Merge is Taher's.
**New observations (Taher), root causes from code read, recorded in KNOWN-ISSUES "PR #121 device test":** (1) ledger rows for a rejected edit, (2) sale at the unconfirmed local price while the edit retries, (3) relaunch inside the retry window shows the old server price while the edit stays queued.
**Code facts that drive the options:** `updateProduct` writes local state + Activity + `TransactionStore.record*` at click time; every `record*` is its own outbox item; `Gateway.mutationApplied(entity, entityId, action)` exists (BC2) and `_pendingDeletes` is the in-memory precedent (lost on relaunch); `_load` has no outbox overlay; completion already needs the server (its stock delta awaits the server), so it never worked offline.
**Open decisions (asked in chat, answers NOT yet recorded):**
 Q1 local-edit policy: Y overlay queued edits on every server read + "not synced" badge (keeps optimistic UI, survives restart) / X apply only after ack (breaks offline-feel, rewrite) / Z = Y + refuse a sale of a product with any unsynced edit.
 Q2 ledger mechanism: in-memory pending map like BC2 (lost on relaunch = silently lost ledger row) / outbox `dependsOn` (durable, client-only, touches core `OutboxStore`) / atomic server `recordOperation` (correct, needs `functions/` + deploy by Taher).
 Q3 scope of ledger kinds in the first PR: product edit only (`field_change`, `stock_adjustment`, Activity `product_updated`) / all kinds.
**NOT verified:** nothing run; all root causes are code reads. Item 3's "later flips to 30" is inferred from outbox persistence, not seen.

**Branch:** `test/2026-10-04-order-completion-parked-delta-repro` (off `main` @ `f530865`, PR #119 merged).
**Commit identity:** `taher.lkdw53@gmail.com`. **Rules (standing):** branch only; push without asking (PAT only in the push header via `/tmp/push.sh`, never in `.git/config`); no build/run; no Qt tooling in the sandbox (CI = the QML signal); small scope; honest advisor, grill before deciding. Skills read: brainstorming, ponytail, qt-qml. Caveman FULL (chat only).
**Previous checkpoint archived:** `docs/superpowers/specs/2026-10-04-pr119-merged-CHECKPOINT.md`.
**Order agreed (Taher):** #120 -> #119 (both merged) -> order-completion repro -> PH3b.

## Step log
1. Cloned repo, read memory + archived checkpoint, read `DataModel._tryCompleteOrder`, `InventoryStore.deductStock`, `Gateway.recordDelta`, `OutboxStore.enqueueDelta/dueItems/_keysForItem`, E2E parked-write pattern (`tst_StockBatchStoreE2E._parkEditFor`), `tst_OrdersE2E`.
2. Answered the checkpoint's open question (code read, NOT run): order completion does NOT use `recordOperation`. `grep -rn "recordOperation(" qml` finds no caller (only the definition). Completion = one `InventoryStore.deductStock` per line -> `Gateway.recordDelta("inventory", id, {stock:-qty}, {stock:0}, ...)` -> `OutboxStore.enqueueDelta`. A delta has NO CAS `before`; the server applies the increment with a floor. So mechanism (A) needs no CAS reasoning.

## Hypothesis (UNVERIFIED, from code read)
- `enqueueDelta` only coalesces into a non-in-flight item that has `.deltas` for the same key. A parked SINGLE edit has none, so the delta is appended as a separate item with key `inventory/<id>`.
- `OutboxStore.dueItems` marks the parked item's keys `claimed`; the later delta shares `inventory/<id>`, hits `clash`, and is skipped on every drain. Never sent.
- `deductStock`'s callback never fires -> `_afterAllDeltas` never runs -> `dataModel._completingOrderIds[orderId]` stays true -> every retry shows "This order is already being completed — please wait" until app restart. Order stays `pending`. The `stock_batch` FIFO deltas (other keys) already went out, so batches are decremented while `product.stock` is not.
- After relaunch the delta is still in the persisted outbox. When the parked edit is Retried/Discarded, the delta finally sends: stock drops for an order that is still `pending`; completing it again deducts twice. This is the drift risk, bigger than the hang.

## Open decisions (asked in chat, answers not yet recorded)
1. Repro form: red-by-design E2E (draft PR) vs characterization test that flips in the fix commit.
2. Mechanism: (A) deltas ignore a parked single edit's key; (B) refuse completion like restock; (C) leave as is. Parked DELETE must keep blocking under A.
3. Scope of the fix: only `deductStock`/`creditStockNoBatch`, or any delta/all-delta op.

## NOT verified
Nothing run here (no Qt toolchain, standing rule). The hang and drift above are code-read hypotheses until the E2E repro runs on CI.

## Taher's answers (2026-10-04)
1. Mechanism: **B refuse completion** (advice was A; overruled, decision recorded). Honest cost of B: a sale at the counter is blocked until the user Retries/Discards the parked edit for that product. Accepted.
2. Repro form: **red-by-design E2E, draft PR**.
3. Scope: single-entity deltas only. Under B this means: guard in `DataModel._tryCompleteOrder` only. `_tryAdjustOrder` (returns/exchanges), `completeImportedOrder` and the failure-path `creditStockNoBatch` use the same deltas and may hang the same way: NOT touched, listed in KNOWN-ISSUES as open.

## Step log (continued)
3. Commit 1 (red by design): `test_completeOrder_behind_a_parked_write_is_refused_not_hung` in `test/e2e/tst_OrdersE2E.qml`. Expected CI: E2E fails on `completion hung behind a parked write`; everything else green.
4. Draft PR #121 opened (base `main`).
5. Commit 2: guard in `DataModel._tryCompleteOrder` (before `_completingOrderIds` is set, before FIFO), `tests/tst_DataModel_completeOrderParkedGuard.qml` (22 cases incl. monkey), test plan `docs/superpowers/test-plans/2026-10-04-order-completion-parked-write-test-plan.md` (+ index row), AGENTS.md, KNOWN-ISSUES (status + open list), SKILLS Skill 99.
6. NEXT: read CI on PR #121 (bot PR comment lists failing tests). Expect: commit 1 red on the new E2E only; commit 2 green. If a new unit test is red, suspect the offline-harness assumption (`_completingOrderIds` set = proceeded) first. Then Taher device-tests section 4 of the test plan, marks PR ready, merges. After that: PH3b sweeper.

## Open after this PR
- Same hang, not guarded: `_tryAdjustOrder` (returns/exchanges), `completeImportedOrder`, `creditStockNoBatch` failure-path credit. Decide after the repro runs: the same refusal, or the bypass (advice was A, Taher chose B).
- Order-completion E2E cases, new unit file and guard are all UNVERIFIED until CI. Nothing ran in-session.
