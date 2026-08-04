# Design: Async Write Sequencing & Multi-Device Conflict Resolution

**Status:** Draft — awaiting Taher's review before any code is written.
**Branch:** `docs/async-write-sequencing-design`
**Skills invoked to reach this doc:** `superpowers:using-superpowers`, `superpowers:brainstorming`.
Full back-and-forth is in the session checkpoint:
`docs/superpowers/specs/2026-07-29-async-write-sequencing-CHECKPOINT.md`.

## 1. Problem statement

Every Firestore write in Karobar goes through `Gateway.recordMutation()` /
`Gateway.recordMutations()`, which enqueues into `OutboxStore` and sends async, fire-and-forget,
with no acknowledgment path back to the calling store or the UI. This has three independent
consequences, discovered in this order while investigating one reported bug:

1. **A single device can race itself.** Multi-step actions (e.g. `DataModel._tryCompleteOrder`)
   issue several `recordMutation` calls in a row. `OutboxStore.dueItems()`/`Gateway.drainNow()`
   send every due item concurrently with no per-record ordering — if an earlier call is delayed on
   the network past a later one, the later one can be silently overwritten. This is the originally
   reported bug (an order reverting from "completed" to "pending").
2. **Two devices can race each other.** Verified in code: owner/admin/manager can view and act on
   *any* order, while staff are scoped to their own — so a staff member and a manager can
   legitimately act on the same order concurrently. Owner and admin (not manager — verified,
   `canManageInventory`/`canManageStaff` exclude manager) can both edit the same product or staff
   record concurrently. `applyMutation` in `functions/lib/gatewayLogic.js` blind-writes `after`
   with no check against current server state, so whichever request's transaction commits last
   wins, silently, regardless of who was "right."
3. **Quantity fields are doubly at risk, in a way neither of the above fixes.** `InventoryStore.deductStock`
   and `StockBatchStore.consumeFifo`/`topUpOldest`/`restoreFifo` all compute a new **absolute**
   value client-side (`stock: current - qty`) from a possibly-stale local cache, then send that
   absolute number as `after`. Two concurrent, *legitimate* stock movements on the same product
   (e.g. two staff completing two different orders that both sell the same SKU) aren't a
   "conflict" in any meaningful sense — they should both apply — but today, whichever write lands
   last simply overwrites the other's deduction. This is silent inventory corruption, not a
   detectable conflict, and neither locking nor whole-record CAS actually fixes it — the fix is
   narrower and different in kind (see Component 4).

## 2. Scope

**In scope (this design):**
- Component 1 — client-side single-flight-per-record (`OutboxStore`/`Gateway`)
- Component 2 — record locking (new `acquireLock`/`releaseLock` Cloud Functions + client
  integration), applied uniformly to every Gateway-writable entity: orders, inventory, staff,
  suppliers, stock_batch
- Component 3 — server-side whole-record compare-and-swap in `applyMutation`, as a backstop
- Component 4 — atomic server-side deltas for quantity fields (`inventory.stock`,
  `stock_batch.qtyRemaining`, `stock_batch.qtyReceived`)

**Explicitly out of scope / deferred, by Taher's own decision this session:**
- Multi-step workflow rollback / compensating writes (what happens if a mid-workflow conflict
  leaves local optimistic state ahead of what actually persisted) — flagged, not solved here.
  Reason it's deferred: the ledger is append-only, so "rollback" means a compensating write, which
  is a distinct, larger design.
- Server-side role/ownership authorization (staff-role-restrictions are UI-trust-boundary only
  today, confirmed in code and in `docs/superpowers/specs/2026-06-16-staff-role-restrictions-design.md`).
  Related to this work (same Cloud Function file) but a different concern (authz vs. concurrency).
- Field-level CAS (only whole-record, per Taher's choice — simpler, ships now, occasionally
  over-rejects on unrelated-field edits).
- Full offline support (read cache, offline-writable records, merge UI) — see the abandoned draft
  at `docs/superpowers/specs/2026-07-09-offline-handling-design.md` for that separate scope.
- The still-unmerged P1 manual-stock-adjustment "kind picker" — if/when that lands, its absolute
  stock-set path needs to be reconciled with Component 4's delta model (see §7.4).

## 3. Component 1 — client-side single-flight-per-record

**Problem it solves:** one device's own outbox firing overlapping/out-of-order writes at itself.
**Does not solve:** cross-device conflicts (that's Components 2/3) or quantity races (Component 4).

`OutboxStore` items currently have no notion of "dispatched, awaiting response" — only
`nextAttemptAt`. Two gaps follow directly from this:
- `enqueue()` never coalesces; two calls for the same `entity+entityId` become two separate items.
- `drainNow()` can send the *same* item twice if called again before the first XHR resolves (safe
  today only by accident, via the Cloud Function's requestId-keyed idempotency — not by design).

**Change — `OutboxStore.qml`:**
- Add an in-memory (not persisted — doesn't need to survive relaunch) `_inFlightKeys: {}` map,
  keyed `entity + "/" + entityId`.
- `dueItems()` excludes any item whose key is in `_inFlightKeys`.
- New `markInFlight(requestId)` / `clearInFlight(requestId)`, called by `Gateway._send`/`_sendBatch`
  around the XHR lifecycle (batches mark/clear every entityId they carry).
- `enqueue(call)`: if an existing **not-in-flight** item shares the same key, merge into it instead
  of appending — keep the *earliest* `before` and `action` (so a create-then-update burst still
  audit-logs as `"create"`), take the *latest* `after`. If the existing item for that key IS
  in-flight, append as today (don't mutate a payload that's already been serialized onto the
  wire) — it will merge with any further same-key arrivals while it waits, and become eligible to
  send the instant the in-flight predecessor's response clears that key.
- `enqueueBatch()`: same idea, one key per member entityId; a batch holds all of them in-flight for
  its duration, and a new single-entity mutation for any entityId inside an in-flight batch waits
  the same way.

**Trade-off made explicit:** coalescing away intermediate states means an intermediate transient
state (e.g. an order sitting "pending" for the ~1 second before being completed in the same user
action) generates no separate `audit_log` entry. Deliberate — that state was never meaningfully
observed, and it's what was causing the corruption in the first place.

## 4. Component 2 — record locking

**Problem it solves:** proactive cross-device conflict avoidance with immediate feedback, instead
of letting a second device do real work only to be rejected at save time.

**Why not a raw mutex flag:** a lock is just another Firestore document; acquiring one safely uses
the same transaction primitive as everything else here (read-then-conditionally-write in one
transaction). No new Firestore capability is needed. What *is* new is the failure-mode handling: a
manual acquire/release-only lock leaves a record permanently locked if the holder's client crashes,
loses connectivity, or the user just closes the app. TTL + client-side renewal heartbeat makes that
self-healing — no cleanup job required.

**New collection:** `tenants/{tenantId}/locks/{entity}_{entityId}`
```
{
  entity, entityId,
  holderUid, holderName, holderRole,
  acquiredAt: <server timestamp>,
  expiresAt: <server timestamp>,
  requestId          // the acquire call's own idempotency key
}
```
`firestore.rules`: deny direct client read/write on `locks/**`, same lockdown pattern as
`audit_log`/`transactions`/etc. — only the Cloud Functions below may touch it. (Read access isn't
needed client-side; the acquire/deny response carries holder info directly.)

**New Cloud Functions** (Gen-2 `onRequest`, `asia-south1`, pure logic in a new
`functions/lib/lockLogic.js`, dependency-injected and `node --test`-covered — same pattern as
`gatewayLogic.js`/Skill 35):

- **`acquireLock`** — body: `{ env, entity, entityId, requestId, ttlMs }`. Inside one transaction:
  read the lock doc. Grant (write it with fresh `acquiredAt`/`expiresAt`) if it doesn't exist, is
  expired, or is already held by this same caller (renewal). Otherwise reject with
  `{ ok: false, status: 409, holder: { name, role, expiresAt } }`.
- **`releaseLock`** — body: `{ env, entity, entityId, holderUid }`. Deletes the lock doc **only**
  if `holderUid` still matches the caller — a stale/duplicate release call can't steal-delete
  someone else's already-re-acquired lock.

**TTL and renewal:** proposing **90s TTL, 30s client renewal heartbeat** (renew at 1/3 of TTL —
tolerates two missed heartbeats before expiry). Tunable; flagging as a number to sanity-check
against real dialog-open durations, not a hard commitment.

**Client integration:**
- New `LockManager.qml` singleton (or a set of `Gateway` methods — leaning `LockManager` to keep
  `Gateway` from growing a second responsibility) exposing `acquire(entity, entityId, cb)`,
  `release(entity, entityId)`. Owns the renewal `Timer` for whatever lock is currently held (one
  at a time, matching "one edit dialog open" — revisit if that assumption turns out wrong).
- **Every entry point that opens an edit action** for a locked entity — confirmed by role-audit in
  §7.1 — calls `acquire` first:
  - Orders: Complete, the return/adjust flow (`OrderDetailDialog`'s adjust button →
    `ConfirmReturnSheet`)
  - Inventory: `EditProductDialog`, `RestockDialog`
  - Staff: `StaffDetailDialog`
  - Suppliers: (supplier edit dialog — need to locate exact file at implementation time)
- **Denial behavior (Taher's choice): block opening the dialog entirely.** Show a message
  identifying the holder ("Priya is updating this — try again shortly"). Viewing/reading the
  record is unaffected either way — locks only ever gate the edit entry point, never a read.
- Release on dialog save-success or cancel/close. If the release call itself fails, no special
  handling needed — TTL expiry is the real safety net, not the explicit release.

## 5. Component 3 — server-side whole-record CAS (backstop)

**Problem it solves:** anything Component 2 misses — clock skew, a lock that expired mid-edit while
the client kept going, a client that bypassed the lock flow. With locking in place, this should
fire rarely; it's a correctness backstop, not the primary mechanism.

**Change — `applyMutation` in `functions/lib/gatewayLogic.js`:**
```
await db.runTransaction(async (txn) => {
  const existingAudit = await txn.get(auditRef)
  if (existingAudit.exists) return                     // idempotent retry — unchanged

  const currentSnap = await txn.get(workingRef)         // NEW
  const current = currentSnap.exists ? currentSnap.data() : null
  if (!deepEqual(current, params.before)) {              // NEW — whole-record compare
    return { conflict: true, current }                   // reject, don't write
  }

  if (params.action === "delete") txn.delete(workingRef)
  else txn.set(workingRef, params.after || {}, { merge: false })
  txn.set(auditRef, { ...auditEntryFields })
})
```
Order matters: idempotency check first (unchanged — safe retries of an already-applied request
still short-circuit before ever reaching the CAS check), CAS check second, only for genuinely new
attempts. On conflict, the response carries `current` — the just-read authoritative state — so the
client can reconcile that one record's local cache without a second round trip.

**Client — `Gateway._send`/`_sendBatch`:** distinguish a `409 conflict` response from a plain
network/5xx failure. On conflict: **don't** `markFailed` (that would retry with the same stale
`before` forever, failing every time) — instead drop the item via `markSent`-equivalent removal,
patch the calling store's local cache for that entityId from the response's `current`, and call
`Toast.show(...)` with a message naming the entity ("This order was changed elsewhere — refreshed
to the latest version."). This needs a new signal path from `Gateway` back to individual stores —
there is currently *no* error-propagation path at all, for any failure type. Proposing a
`Gateway.mutationConflicted(entity, entityId, current)` signal that each store connects to and
handles by patching its own array.

## 6. Component 4 — atomic server-side deltas for quantity fields

**Problem it solves:** the inventory-corruption case from §1.3, which neither locking nor
whole-record CAS actually fixes — two legitimate concurrent stock movements on the same product
should both apply, not conflict.

**Why this is a different mutation kind, not a CAS variant:** a delta doesn't depend on knowing the
prior value — `current + delta` is correct regardless of what `current` turns out to be when the
transaction actually runs (within its floor). CAS is for "apply my `after` only if the record still
looks like what I last saw"; delta is for "adjust this field by this amount, whatever it currently
is." Firestore's transaction read-then-write gives both their safety, but for different reasons.

**New action kind — `functions/lib/gatewayLogic.js`:** add `"delta"` to `ALLOWED_ACTIONS`; body
carries `deltas: { fieldName: numericDelta, ... }` and optional `floors: { fieldName: minValue }`
instead of `before`/`after`. New `applyDelta(db, params)`:
```
await db.runTransaction(async (txn) => {
  const existingAudit = await txn.get(auditRef)
  if (existingAudit.exists) return                       // idempotent retry

  const currentSnap = await txn.get(workingRef)
  if (!currentSnap.exists) return { ok: false, status: 404, error: "not-found" }
  const current = currentSnap.data()

  const before = {}, after = {}
  for (const field in params.deltas) {
    const curVal = current[field] || 0
    const nextVal = curVal + params.deltas[field]
    const floor = params.floors && (field in params.floors) ? params.floors[field] : null
    if (floor !== null && nextVal < floor)
      return { ok: false, status: 409, error: "insufficient-quantity", field, current: curVal }
    before[field] = curVal
    after[field] = nextVal
  }
  txn.set(workingRef, Object.assign({}, current, after), { merge: false })
  txn.set(auditRef, { ...auditEntryFields, before, after })   // real values, not client guesses
})
```
Note the audit_log entry now records the *actual* server-observed before/after for the touched
fields, which is more correct for compliance purposes than today's client-guessed absolute values.

**Client — new `Gateway.recordDelta(entity, entityId, deltas, floors)`**, going through the same
`OutboxStore`/single-flight path as Component 1 (delta items key on `entity+entityId` the same
way; coalescing two queued deltas for the same key should **sum them**, not take-the-latest — this
is the one place where the Component-1 merge rule differs by mutation kind).

**Callers to change:**
- `InventoryStore.deductStock(productId, qty)` → `recordDelta("inventory", productId, {stock: -qty}, {stock: 0})`
- `InventoryStore.restock(...)` → `recordDelta("inventory", productId, {stock: +addedQty})`
- `StockBatchStore.consumeFifo` → per-batch `recordDelta("stock_batch", batchId, {qtyRemaining: -take}, {qtyRemaining: 0})`
- `StockBatchStore.topUpOldest` → `recordDelta("stock_batch", batchId, {qtyReceived: +deficit, qtyRemaining: +deficit})`
- `StockBatchStore.restoreFifo` → `recordDelta("stock_batch", batchId, {qtyRemaining: +qty})`

**Resolved by Taher (round 4):** reject, don't clamp — when a delta would take stock below its
floor, the order should be rejected, its status set to `"out of stock"`, and the user shown an
error. Implemented in `applyDelta` as the `floors` mechanism (§6 above, done, tested).

**This answer implies more than a floor check, though — flagging the consequence explicitly.**
`DataModel._tryCompleteOrder` today fires all four of its steps (stock deduct, order-status
update, sale record, transaction record) synchronously and fire-and-forget — none of them wait for
the network response of the one before it. For "reject the order and show an error" to actually
work, the stock-deduction step's *real, server-confirmed* outcome has to be known **before** the
order gets marked completed, not sometime later after completion has already been optimistically
shown. That means:
- `Gateway.recordDelta` needs a callback that fires with the real result once the Cloud Function
  responds — not fire-and-forget like every other Gateway call. There's already a precedent for
  this in the codebase: `Gateway.provisionMember(payload, callback)` follows exactly this shape.
- `_tryCompleteOrder` needs to actually **await** that callback before proceeding to the
  order-status/sale/transaction steps, branching to `status: "out of stock"` + the existing
  `dataModel.stockErrorMsg` mechanism (already used for the synchronous pre-check — the same UI
  path, now also reachable from this later, async check) on rejection, and to the normal
  completion path on success.
- If the coalescing rule in Component 1 merges two deltas for the same key into one outbox item,
  the merged item needs to carry an *array* of pending callbacks, not one — all of them fire with
  the same outcome when that one item's request resolves.
- This is the concrete, scoped piece of "workflow sequencing" this design ended up needing — not
  the full general compensating-transaction rollback deferred in §2, just this one specific,
  well-defined wait-then-branch for order completion's stock step. It also directly closes the
  loop on the very first thing asked for at the start of this whole session: synchronized calls
  with a real busy indicator, rather than the decorative one that exists today (§4 of the original
  busy-overlay design) — this is where that finally gets wired to something real, for this flow.

## 7. Cross-cutting notes

### 7.1 Entities and lock points, as verified in code this session
| Entity | Who can write | Where locking attaches |
|---|---|---|
| order | staff (own only, no return/adjust), owner/admin/manager (any order) | Complete action, return/adjust flow |
| inventory (product) | owner/admin only — **not manager** | `EditProductDialog`, `RestockDialog` |
| staff | owner/admin only — **not manager** | `StaffDetailDialog` |
| supplier | owner/admin/manager (assumed — confirm exact dialog file at implementation time) | supplier edit dialog |
| stock_batch | not directly user-edited — touched only as a side effect of order completion/returns/restock | no direct lock entry point; protected by Component 4's delta safety instead |

### 7.2 How the four components compose, worked through the original bug
Order completion (`_tryCompleteOrder`): acquire lock on the order (Component 2) → if granted,
proceed → stock deduction goes through `recordDelta` (Component 4, no conflict possible against
other concurrent sales of the same product) → order status update and transaction record go
through the normal `recordMutation` path, now single-flighted against the device's own outbox
(Component 1) and CAS-backstopped server-side (Component 3) → release lock on completion. A
second device attempting to touch the *same order* while this is in flight is turned away at the
lock (Component 2), immediately, before doing any local work at all — exactly what Taher asked for.
A different device selling a different order with an overlapping product is never blocked at all —
Component 4 lets both deductions land correctly.

### 7.3 Toast timing
Existing `Toast` auto-dismisses at 1800ms. That's fine for conflict/lock-denied notices (user is
actively looking at the screen where the action just failed) — no new UI component needed, per
earlier finding.

### 7.4 P1 interaction (flagged, not resolved)
P1's still-unmerged manual-stock-adjustment "kind picker" will likely need an absolute-set path
(admin types a target stock number), which doesn't fit the delta model directly. When P1 merges,
that path should compute its delta as `target - currentAtSubmitTime` and go through
`recordDelta` like everything else here, rather than reintroducing an absolute `recordMutation`
write on the same field — needs a short follow-up conversation when P1 actually lands, not solved
in this doc.

## 8. Rollout order (proposed)
1. Component 4 (delta) — narrowest, highest silent-corruption risk today, no UI changes needed.
2. Component 3 (CAS backstop) — small, self-contained Cloud Function change.
3. Component 1 (single-flight) — client-only, no Cloud Function deploy needed.
4. Component 2 (locking) — largest, touches every edit dialog's open/close flow; sequenced last so
   it lands on top of an already-hardened write path underneath it.

Each component ships independently and is individually testable — see the companion test plan,
`docs/superpowers/specs/2026-07-29-async-write-sequencing-test-plan.md`.
