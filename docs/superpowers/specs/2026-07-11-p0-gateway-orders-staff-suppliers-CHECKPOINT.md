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

## Decisions confirmed (2026-07-11)
1. Close testing gaps for old (inventory/stock) AND new (orders/staff/suppliers) code.
2. `approveAllPending` gets a batch-aware Gateway method, not a per-item loop.
3. One commit per logical unit; push-permission requested after each.

Full task breakdown: `docs/superpowers/plans/2026-07-11-p0-gateway-fast-follow.md`.

## Sandbox verification constraints (discovered 2026-07-11, before implementing)
- No Qt/QML toolchain here (no `qmltestrunner`/`qmake`/`cmake`) — same limitation as the
  2026-07-10 checkpoint. All QML test files this plan produces are written correctly but
  **not run here**; need a local `qmltestrunner` pass before merge.
- No network egress to Firebase's emulator distribution — `@firebase/rules-unit-testing`
  needs the Firestore emulator to run. The rules test file gets written but **not run here**.
- Node/`node --test` for Cloud Functions **is** fully runnable and verified here — confirmed
  working, used for real red→green TDD below.

## Progress log

### 2026-07-11 — Phase A1+A2 done: extracted + tested recordMutation's core logic
- New: `functions/lib/gatewayLogic.js` — `parseBearerToken`, `validateMutationRequest`,
  `applyMutation` (all pure/dependency-injected — `db` and `serverTimestamp` passed in, zero
  Firebase SDK import in this file).
- New: `functions/test/gatewayLogic.test.js` — 13 tests, real TDD (watched fail on missing
  module first, then implemented, then green).
- Edited: `functions/index.js` — `recordMutation` now calls `GatewayLogic.*`; removed the
  now-duplicated `ENTITY_COLLECTIONS`/`ALLOWED_ACTIONS` consts (single source of truth is now
  the lib file). Behavior-preserving — verified with `node --check` and a full `npm test` run:
  **22/22 passing** (13 new + 9 pre-existing breakdownMath/realisedMath tests, all still green).
- Committed locally (not pushed yet).
- **Next:** A3 (runCutover CF tests), then A4–A6 (QML/rules tests, written-only), then Phase B
  (batch Gateway method), then Phase C (the actual store migrations).

### 2026-07-11 — Phase A3 done: extracted + tested runCutover's core logic
- New: `functions/lib/cutoverLogic.js` — `validateCutoverRequest`, `buildCutoverMarker`,
  `deleteCollection`, `zeroInventoryStock` (batch-chunk size injectable, so chunking behavior
  is actually testable without 400 fake docs).
- New: `functions/test/cutoverLogic.test.js` — 10 tests, real TDD.
- Edited `functions/index.js`'s `runCutover` to use it. **Caught a real bug while rewiring**:
  my first draft collapsed the original's distinct `no-tenant-context` (403) vs `owner-only`
  (403) error strings into a single `owner-only` response — fixed before committing, test added
  to lock in the distinction. Full suite: **32/32 passing**.
- Order agreed with user: A3 → Phase B (batch Gateway) → Phase C (store migrations) →
  circle back to A4–A6 (write-only QML/rules tests) at the end.
- Committed locally, not yet pushed (will push with the rest of this slice or on request).
