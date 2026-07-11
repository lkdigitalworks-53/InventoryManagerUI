# Checkpoint — P0 Gateway Fast-Follow (Orders / Staff / Suppliers)

**Date:** 2026-07-11
**Branch:** `feature/p0-gateway-orders-staff-suppliers` (off `main`)
**Status:** Investigation/audit complete. No code changes yet — awaiting sign-off on 3 open design points before implementation starts.

## Context

Asked to complete the India compliance roadmap
(`docs/superpowers/specs/2026-06-06-india-compliance-roadmap-design.md`), starting with P0
(`docs/superpowers/specs/2026-06-06-P0-compliance-gateway-design.md`). Framing: P0 was
"partially implemented for inventory. Orders, staff, suppliers and others were pending as
fast follow up." Session scope agreed: **P0 only** this session; P1–P7 are separate future
sessions.

## Audit findings

### What's actually done for inventory/stock (verified in code this session)
- `functions/index.js`: `recordMutation` (HTTPS+bearer, env-scoped DB, idempotent via
  requestId = audit_log doc id), `runCutover`, `provisionMember` (separate concern — staff
  Auth account provisioning, not gateway/audit-log related) all exist.
- `qml/model/Gateway.qml`: client bridge exists — `recordMutation()`, `runCutover()`,
  `_collections` map for inventory/stock_batch/stock_movement/transaction, exponential-backoff
  outbox integration.
- `qml/model/OutboxStore.qml`: persisted queue, enqueue/dueItems/markSent/markFailed, backoff
  schedule — exists.
- `InventoryStore.qml` / `StockBatchStore.qml`: mutation call sites route through
  `Gateway.recordMutation(...)` — confirmed via grep, multiple sites.
- `TransactionStore.renameParty()`: removed (confirmed absent).
- `firestore.rules`: ledger collections (`audit_log`, `transactions`, `stock_batches`,
  `stock_movements`) locked `write: if false`, server-only — confirmed. Working-tier
  collections (inventory, orders, staff, suppliers, etc.) remain client-writable by tenant
  members under the generic wildcard rule — unchanged, by design (only the ledger needs to be
  tamper-proof, not the working docs).

### Critical finding: none of this is live yet
- `Gateway.mode` defaults to `"direct"` — in this mode `recordMutation()` just does the old
  plain Firestore write; **no audit_log entry is written today**, regardless of what code
  calls it.
- Per `docs/superpowers/KNOWN-ISSUES.md` and the 2026-07-10 checkpoint: Cloud Functions are
  prepared but not deployed; the locked-down Firestore rules are not deployed either.
  Deploying rules before functions/cutover would break current restock/stock-adjustment flows.
- Going live requires, in order: deploy functions → deploy rules → run `runCutover` (wipes
  ledger collections + zeroes stock — **irreversible**) → flip `Gateway.mode` to `"gateway"`
  and ship that. This is ops/deployment work requiring real Firebase project access and
  explicit go-ahead — not something to do or suggest doing unprompted, consistent with
  "don't build/run without permission" and the irreversible nature of cutover.

### Testing gaps found in the already-"done" inventory/stock P0 work
The P0 spec (§6) requires CF unit tests, Firestore rules tests, Outbox tests, and
store-rewiring tests. None exist:
- `functions/test/` only has `breakdownMath.test.js`, `realisedMath.test.js` — nothing for
  `recordMutation`/`runCutover`/`provisionMember`.
- No `rules-unit-testing` anywhere in the repo — no automated rules tests.
- No `tst_Gateway.qml` or `tst_Outbox*.qml` — no QML tests for the gateway/outbox machinery.

### What's pending for Orders/Staff/Suppliers (the actual "fast follow")
All three stores still write directly via `FirebaseService`, confirmed by call-site audit:

| Store | Create | Update | Delete | Bulk |
|---|---|---|---|---|
| `OrdersStore.qml` | line 116 `put` | line 184 `put` | line 612 `remove` | line 543 `putMany` (`approveAllPending`) |
| `StaffStore.qml` | line 155 `put` | lines 221, 234 `put` | line 176 `remove` | — |
| `SupplierStore.qml` | line 173 `put` | line 198 `put` | line 216 `remove` | — |

`functions/index.js`'s `ENTITY_COLLECTIONS` map and `Gateway.qml`'s `_collections` map only
list `inventory`/`stock_batch`/`stock_movement`/`transaction` today — need `order`→`orders`,
`staff`→`staff`, `supplier`→`suppliers` added (names per the roadmap spec's `audit_log.entity`
enum, §4.1).

## Open decisions (need sign-off before writing code)
1. Testing-gap scope: backfill tests for the already-written inventory/stock gateway code this
   session too, or Orders/Staff/Suppliers only (new code gets tests, old gap stays open)?
2. `approveAllPending`'s bulk `putMany` (line 543): loop `Gateway.recordMutation` per order
   (simple, matches the spec's singular contract, more writes) vs. build a batch-aware Gateway
   path (preserves current single-batch-write performance, no spec precedent, more work)?
3. Commit granularity: one atomic commit per store (Orders, then Staff, then Supplier) on this
   single branch, checkpoint updated after each, push-permission asked after each commit —
   confirm or adjust?

## Not yet done / next steps
- Nothing implemented yet. Waiting on the 3 decisions above.
- Once confirmed: TDD per store (test-driven-development skill), update this checkpoint after
  each, commit locally each time, ask permission before each push.
- Explicitly NOT doing this session: deploying functions/rules, running cutover, flipping
  `Gateway.mode`.
