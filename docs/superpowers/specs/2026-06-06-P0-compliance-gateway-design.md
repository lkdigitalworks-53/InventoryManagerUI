# P0 — Compliance Gateway + Immutable Audit Log — Design

**Date:** 2026-06-06
**Status:** Approved (design); pending implementation plan
**Parent:** `2026-06-06-india-compliance-roadmap-design.md` (sub-project P0)
**Mandates:** MCA Rule 11(g), CGST Rule 56(8)

---

## 1. Purpose

P0 builds the architectural spine the whole compliance program depends on: a **trusted
server-side gateway** that owns all writes to the immutable ledger tier, plus the locked Firestore
rules and the new `audit_log` collection. Every later sub-project (P1–P7) writes through what P0
establishes.

P0 is deliberately the **smallest safe foundation**: it stands up the gateway and migrates only the
**inventory + stock** write paths. Orders, staff, and suppliers migrate in fast-follow specs.

### Scoping decisions (locked)

| Decision | Value |
|---|---|
| Transport | **A — HTTPS-callable Cloud Function**, invoked via the existing XHR + Bearer-token pattern. No Firebase JS SDK. |
| Write-failure UX | **Queue & retry, keep optimistic UI** — local update is instant; gateway call is enqueued in a persisted outbox and retried with backoff. |
| P0 entity scope | **Inventory + stock only** (`inventory`, `stock_batches`, `stock_movements`). Orders/staff/suppliers deferred to fast-follow. |
| Data cutover | **Fresh start, truly empty** — wipe `transactions`/`stock_batches`/`stock_movements` AND zero every product's `stock`. No archive. User re-counts stock after cutover; those re-entries become the first genuine `audit_log` records. |
| `TransactionStore.renameParty()` | **Removed** — it is dead code (zero callers). The live supplier rename goes through `SupplierStore.updateSupplier`, which propagates by stable `supplierId` and never touches historical rows. No feature lost. |

---

## 2. Components

1. **`functions/` Cloud Functions project** (new) — Node + Firebase Admin SDK. One HTTPS-callable,
   `recordMutation`. A root **`firebase.json`** wires functions + firestore rules (today only
   `firebase-hosting/firebase.json` exists).
2. **`qml/model/Gateway.qml`** (new singleton) — client side of the gateway. Exposes
   `recordMutation(entity, entityId, action, before, after)`. POSTs to the callable reusing the XHR
   + `Authorization: Bearer <idToken>` pattern already in `FirebaseService._request`. No new SDK.
3. **`qml/model/OutboxStore.qml`** (new singleton) — a `QtCore.Settings`-backed persisted queue
   (same pattern as `PartyStore`). Holds pending gateway calls; retries with exponential backoff;
   exposes `pendingCount` for a subtle "pending sync" indicator. Survives relaunch.
4. **`audit_log` collection** + **locked ledger Firestore rules** (`FIRESTORE_RULES.md`).
5. **`InventoryStore` / `StockBatchStore` rewiring** — `addProduct`, `restock`, `updateProduct`,
   `deductStock`, `setPhoto`, `addBatch`, `consumeFifo` route their persistence through `Gateway`
   instead of calling `FirebaseService.put` directly.
6. **Removal** of `TransactionStore.renameParty()`.
7. **Cutover routine** (one-time, gated to owner) — wipes the three ledger collections and zeroes
   product stock.

---

## 3. Data Flow — write path with outbox

```
UI action → InventoryStore mutates local array (optimistic → instant UI)
          → Gateway.recordMutation("inventory", id, "update", before, after)
              → OutboxStore.enqueue(call)              // persisted immediately
              → POST callable (Authorization: Bearer idToken)
                  ├─ success → CF verifies token → derives actorUid / actorRole
                  │             → Firestore txn: write working doc + append audit_log
                  │                (serverTimestamp authoritative)
                  │             → OutboxStore.dequeue(id)
                  └─ failure / offline → stays queued → retry w/ backoff
          → OutboxStore.pendingCount drives a subtle "pending sync" chip
```

The client **no longer writes inventory/stock docs directly**; the Cloud Function owns those writes
so the working doc and the ledger entry are atomic and can never diverge. The optimistic local array
preserves today's snappy feel; the outbox guarantees the ledger write is never silently lost (the
failure mode in the old fire-and-forget path).

---

## 4. Low-Level Design

### 4.1 `recordMutation` callable contract

```
recordMutation(entity, entityId, action, before, after, requestId) -> { ok, entryId }
```

- `entity` ∈ `"inventory" | "stock_batch" | "stock_movement"` (P0 scope).
- Verifies the Firebase Auth ID token (from the callable context) → derives `actorUid`,
  `actorRole`, `tenantId` **server-side**. Client-supplied identity is ignored.
- Stamps `serverTimestamp` (authoritative).
- Single Firestore transaction: upsert the working-tier doc **and** append the `audit_log` entry.
- `requestId` makes the call idempotent — a retried outbox item never double-appends.

### 4.2 `audit_log/{entryId}` document

```
{ entryId, tenantId, actorUid, actorRole,
  action: "create" | "update" | "delete" | "opening_balance",
  entity, entityId,
  before: {…} | null, after: {…} | null,
  serverTimestamp, clientTimestamp, requestId }
```

### 4.3 Locked Firestore rules (ledger tier)

```
match /tenants/{tenantId}/audit_log/{id}      { allow read: if isMember(tenantId); allow write: if false; }
match /tenants/{tenantId}/transactions/{id}   { allow read: if isMember(tenantId); allow write: if false; }
match /tenants/{tenantId}/stock_batches/{id}  { allow read: if isMember(tenantId); allow write: if false; }
match /tenants/{tenantId}/stock_movements/{id}{ allow read: if isMember(tenantId); allow write: if false; }
```

Only the Admin SDK (inside the Cloud Function) writes these → DB-layer immutability. This is what an
MCA Rule 11(g) auditor tests for.

### 4.4 OutboxStore shape

```
entry: { requestId, entity, entityId, action, before, after,
         enqueuedAt, attempts, nextAttemptAt }
```

Backoff: `min(2^attempts * base, cap)`. Drained on app start, on connectivity regain, and on a
short repeating timer while `pendingCount > 0`.

### 4.5 Cutover routine (one-time, owner-gated, irreversible)

1. Delete every doc in `transactions`, `stock_batches`, `stock_movements`.
2. Set every product's `stock` to `0` (via the gateway, so the zeroing itself is audited).
3. After cutover the user physically re-counts and re-enters stock; each re-entry flows through the
   gateway and produces the first genuine `audit_log` / batch records of the immutable era.
4. Guarded behind an explicit owner confirmation; logs a single `audit_log` "cutover" marker.

---

## 5. Error Handling

- **Gateway unreachable / 5xx / offline** → item stays in outbox, retried with backoff; UI shows
  "pending sync". No data loss.
- **Auth token expired** → `AuthService.ensureFreshToken()` before drain; on 401 re-queue.
- **Permission denied (403)** → surfaced (misconfigured rules); item held, not dropped.
- **Idempotency** → `requestId` dedupes server-side so retries never double-write the ledger.
- **No silent drops** — the old fire-and-forget `console.warn` path is replaced; a failed ledger
  write is always either retried or visibly surfaced.

---

## 6. Testing

- **CF unit**: token→identity derivation; atomic doc+log write; idempotency on duplicate
  `requestId`; rejection of unauthenticated/cross-tenant calls.
- **Rules**: a client `write` to any ledger collection is denied; `read` as member is allowed.
- **Outbox**: enqueue→drain→dequeue; persistence across relaunch; backoff; offline→online drain.
- **Store rewiring**: each inventory/stock mutation produces exactly one working-doc write + one
  `audit_log` entry; optimistic UI still updates instantly.
- **Cutover**: collections emptied; product stock zeroed; re-entry produces first audit records.

---

## 7. Out of Scope (P0)

- Orders / staff / suppliers gateway migration (fast-follow specs).
- Stock-movement taxonomy enum & opening/closing register (P1).
- HSN/GSTIN fields (P2). Legal docs (P3). DPDP (P4). Retention/erasure (P5). Breach (P6).
  Warehouse (P7).

---

## 8. Required Existing-Code Changes

- Remove `TransactionStore.renameParty()` (dead code).
- Rewire `InventoryStore` + `StockBatchStore` write paths through `Gateway`.
- Add root `firebase.json` (functions + firestore); keep `firebase-hosting/` as-is.
- Update `FIRESTORE_RULES.md` with the locked ledger rules.
