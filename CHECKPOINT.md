# CHECKPOINT — 2026-09-24: compliance reassessment + P1 branch triage (docs only, no code)

**Branch:** `docs/2026-09-24-compliance-reassessment`, cut from `main` @ `2c1e5f6`
**Previous checkpoint archived to:** `docs/superpowers/specs/2026-09-21-atomic-operation-outbox-phase2-CHECKPOINT.md`
(C-3 arc; its step 13 is still open: Phase 3 not started).
**Skills invoked by Taher:** `superpowers:brainstorming`, `qt-development-skills:qt-qml`, `ponytail:ponytail`. Caveman FULL.
**Commit identity:** `Taher (via Claude session) <tsowner@lkdigitalworks.com>`. PAT comes from chat, never stored in repo/config/memory.
**Constraints this session:** no app build/run; no Qt in sandbox (CI is the QML test oracle); short scope per session
(multi-account, token-limited); push without asking, review happens in the GitHub PR.

## Compliance status vs master spec (`specs/2026-06-06-india-compliance-roadmap-design.md`)

Grep-based on `main` @ `2c1e5f6` plus the P1 branch's own checkpoint.

| Item | Status |
|---|---|
| P0 gateway + immutable `audit_log` | Done. `Gateway.mode = "gateway"` live since 2026-07-29. |
| C-3 atomic `recordOperation` (order completion) | Phase 1 (endpoint, #78) + Phase 2 (pure helpers, #79) merged. **Phase 3 (Outbox/Gateway/stores/DataModel/UI, plan Tasks 6-11) not started.** Needs Taher to deploy `recordOperation` to dev. |
| P1 stock-movement taxonomy | **Partial, unmerged, untested, stale.** Branch `feature/p1-stock-movement-taxonomy`: 10-value kind enum, write-only `StockMovementStore`, 5 wiring points, required kind picker. Zero tests. Register report (opening/closing balance) not started. |
| P2 tax identity (HSN, GSTIN) | Not started. No `hsnCode`/`gstin` anywhere in `qml/` or `functions/`. |
| P3 legal docs + acceptance, P4 DPDP consent, P5 erasure/retention, P6 breach, P7 warehouse | Not started (no consent/erasure/breach code; only an OAuth "consent" string in `GoogleAuthService.qml`). |
| Deferred (56(12), 56(15), OIDAR) | Out of scope per spec. |

## P1 branch verdict: NOT usable as-is, do not rebase-and-continue

- 337 commits behind `main`; merge-base `2748d1b` (2026-07-13). Predicted textual conflicts: `Main.qml`, `Logic.qml`,
  `DataModel.qml`, `InventoryStore.qml`, `qmldir`, `EditProductDialog.qml`.
- Trial rebase (scratch branch, aborted, remote untouched) stopped at commit 4 of 10, `94c6e51` (restock wiring). The conflict is
  semantic, not just textual: `restock()` on main is async + callback-based, uses `Gateway.recordDelta`, and
  `StockBatchStore.addBatch` no longer returns a batch synchronously (async batch-id minting), so the branch's
  `batch.batchId` and `Gateway.recordMutation` wiring is wrong for main even if hunks are merged by hand.
- Order completion (`_tryCompleteOrder`) was reworked on main (atomic completion, `recordOperation`) and Phase 3 will rewrite it again.
  The branch's `sale` wiring is throwaway.
- Reusable from the branch: `kind` enum + `sales_return`/`destroyed` reasoning (CGST 56(2)), `StockMovementStore` shape, kind-picker UX
  in `EditProductDialog`, master test plan `specs/2026-07-11-p0-p1-master-test-plan.md`. Re-apply by hand on fresh `main`; leave old branch untouched.

## Step log (append-only; resume from the last ticked step)

- [x] 1. Cloned repo, read spec, status, P1 checkpoint, C-3 checkpoint. Read skills: brainstorming, qt-qml, ponytail.
- [x] 2. Trial rebase of P1 onto `main`: fails semantically at commit 4/10 (above). Aborted. Old remote branch untouched.
- [x] 3. Wrote this reassessment (docs only: no test plan needed, no code changed).
- [ ] 4. **Waiting on Taher: decision Q1** (how movements get written; options below).
- [ ] 5. After Q1: brainstorm remaining design questions one at a time, write spec `docs/superpowers/specs/2026-09-24-p1-stock-movement-atomic-design.md`, get approval, then plan (`superpowers:writing-plans`).

## Q1 options (recommendation: B, sliced)

- **A. Client-side second write** (old branch's way): `StockMovementStore.recordMovement` after each stock change.
  Cheap, QML-only. But not atomic with the stock change: crash/offline/kill between the two writes leaves stock changed with no ledger row,
  which is the exact failure an auditor tests. Needs idempotent ids too. Contradicts spec 2 ("working-tier doc AND ledger entry in one transaction").
- **B. Server-side atomic**: `recordDelta` (and `recordOperation` ops) accept an optional `movement {kind, reason, valueAtCost, batchRef}`;
  the function creates the `stock_movements` row in the same transaction, deterministic id from `requestId`, `kind` validated against the enum,
  `actorUid`/`serverTimestamp` server-stamped. Fully testable with `node --test` in this sandbox (100% coverage feasible). Costs: functions change + Taher deploys (D4).
- **C. Hybrid**: B for `sale` (inside `completeOrder`, after C-3 Phase 3), A for the rest. Two mechanisms to maintain; A's gap stays.

Proposed slices if B: S1 server support + tests; S2 client wiring for restock / manual adjust / returns; S3 `sale` via `completeOrder` (after C-3 Phase 3);
S4 opening/closing register report.

## Resume instructions

Fresh session: clone, read this file, ask Taher for Q1 if unanswered. Do not force-push or rebase `feature/p1-stock-movement-taxonomy`. No build/run.
