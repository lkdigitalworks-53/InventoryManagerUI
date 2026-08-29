# Offline Handling — Orders (Pending CRUD) — Design

**Date:** 2026-07-09 (original) — revised 2026-07-10 (v2), 2026-07-10 (v3), 2026-07-10 (v4)
**Status:** Draft — pending review/approval (brainstormed via `/superpowers:brainstorming`)
**Related:** `2026-06-06-P0-compliance-gateway-design.md` (a **concurrent, local, unpushed branch**
is completing Orders' piece of P0's contract — routing `OrdersStore` through `Gateway.recordMutation`
— expected to merge this week. This design now explicitly **depends on** that branch rather than
building the same routing itself — see v4 note below).
`2026-06-06-india-compliance-roadmap-design.md` (the master roadmap — its gateway contract already
enumerates `"order"` as an entity type; only the actual call-site migration was deferred).
`2026-07-06-scale-reads-writes-analytics-design.md` (landed independently, mid-brainstorm — informed
the read-cache decision below).

---

## Revision history

- **2026-07-09 (v1):** Original scope — Orders, Inventory, Stock, Transactions all offline-write-
  capable, including order completion (cascades into Inventory/Stock/Transaction writes). 30-day
  windowed read cache. Atomic stock-delta increments + field-level conflict handling across all four
  entities.
- **2026-07-10 (v2):** Two revisions, both from the user, both narrowing scope:
  1. **Read cache un-windowed.** Found the locked 30-day window conflicts with
     `scale-reads-writes-analytics`'s explicit decision that Orders/Transactions/StockBatches must
     keep the *complete* local set for FIFO/KPI/dedup correctness — windowing the offline cache would
     reintroduce that exact miscomputation risk. Cache is now full-data, no age pruning.
  2. **Offline writes narrowed to pending-order CRUD only.** Since offline is expected to be rare
     (data is meant to be synced across devices), critical operations — order completion/return/
     adjust, and any direct Inventory/Stock/Transaction edit — now simply require `isOnline`, same as
     today. Only create/edit/cancel of a *pending* order becomes offline-capable. This removed a large
     share of v1's scope: no atomic stock increments, no batch-FIFO residual-risk trade-off, no
     multi-entity conflict handling.
  3. v2 also made Orders bypass `Gateway` entirely, reusing `OutboxStore`'s queue directly — reasoning
     that Orders "was never part of P0's scope." **v3 corrects this** — see below.
- **2026-07-10 (v3):** User caught that v2's framing of Orders/Staff/Suppliers as "not in P0's scope"
  was imprecise — the master roadmap's gateway contract (`entity: "inventory" | "order" | "staff" |
  "supplier"`) always intended those to migrate too; P0 only *implemented* inventory/stock/transaction
  first, deliberately phasing the rest as fast-follow work, not excluding them. Routed Orders through
  `Gateway.recordMutation("order", ...)` instead of a bespoke mechanism. Verified this doesn't reopen
  the P0-cutover-gating concern — `orders` is working-tier/client-writable, not a locked ledger
  collection, in both the roadmap's model and the actual staged `firestore.rules`.
- **2026-07-10 (v4, this version):** User flagged that Orders' migration to `Gateway.recordMutation` —
  the exact thing v3 added — is **already being built locally**, on an unpushed branch, as part of
  completing P0's compliance work, expected to merge this week. Building it again here would create a
  real, avoidable merge conflict. **This design now depends on that branch instead of duplicating it**
  — the routing itself (client `Gateway._collections` + server `ENTITY_COLLECTIONS` map entries, and
  `OrdersStore`'s redirect through `Gateway.recordMutation`) comes out of this design's scope entirely.
  Confirmed with the user that the concurrent branch is compliance-routing-only — it does *not* make
  `drainNow()` drain in `"direct"` mode, and has no conflict detection or enqueue-time coalescing — so
  this design still has real, non-duplicated work left: making the outbox actually durable while
  offline, coalescing at enqueue time (a correctness fix discovered this session — see the memory note
  and §4.1), conflict handling, the read cache, and UI gating. See updated §2/§3.1/§8/§9/§10, and the
  new dependency note in §1.

---

## 1. Purpose

Today, the entire app goes non-interactive when the device is offline
(`Navigation { enabled: isOnline }` in `Main.qml`), and no store persists its dataset locally — every
screen is backed by an in-memory array that's wiped and re-fetched on load. So "offline" today means
both **no writes at all** and, on a cold/relaunch, **no reads either** — blank screens, not just
disabled buttons.

This design does two things: lets every in-scope screen render its last-known data when offline
(read-only browsing, not blank screens), and lets **creating, editing, or cancelling a pending order**
work offline with a durable, reliable sync once reconnected. Everything that touches the stock/
transaction ledger — completing an order, returning/adjusting one, or editing Inventory/Stock/
Transactions directly — continues to require connectivity, same as today; only the *button* for those
becomes more granular (per-action, not a blanket app-wide freeze).

### Scoping decisions (locked)

| Decision | Value |
|---|---|
| Offline-**writable** | **Create / edit / cancel a pending order only.** Nothing else. |
| Offline-**readable** (browse, not edit) | Orders, Inventory, Stock, Transactions — full last-synced dataset, no age windowing (see §9). |
| Stays connectivity-gated (`isOnline`), unchanged from today | Completing an order, returning/adjusting a completed order, any direct Inventory/Stock/Transaction edit. Mechanism unchanged — still today's direct, synchronous `FirebaseService`/`Gateway` calls. |
| Out of scope entirely | Staff, Suppliers, Categories, Order Channels — stay blocked-offline exactly as today. |
| Relationship to P0 | **v4: depends on, does not build, Orders' Gateway routing.** A concurrent local branch is completing that piece (client `Gateway._collections` + server `ENTITY_COLLECTIONS` map entries, `OrdersStore`'s redirect through `Gateway.recordMutation`) as part of P0 compliance work, expected to merge this week. This design assumes that lands first. |
| **Dependency — blocks implementation start, not this doc's approval** | The concurrent Orders→Gateway branch (compliance-routing only, confirmed no offline-drain/conflict/coalescing logic). Implementation of this design should branch off `main` *after* that merges, not race it. If it slips, re-check before starting rather than assume. |
| Local storage mechanism | QSettings/JSON (matches existing `OutboxStore`/`PartyStore` convention). |
| Conflict handling | Client-side, best-effort, field-level auto-merge; pick-one prompt only for genuine same-field collisions — scoped to Orders only (nothing else queues offline, so nothing else can conflict from this design). |
| Read-cache scope | Full data, no age-based pruning, for all four entities — see §9 for why the originally-locked 30-day window was reversed. |
| Write outbox pruning | Never pruned by age — only cleared on ack or user-resolved conflict. |

---

## 2. Components

**New:**
1. **`qml/helper/LocalReadCache.js`** — shared module. Full-data QSettings-backed persistence for a
   store's dataset: `save(settingsKey, items)`, `load(settingsKey)` (returns cached array or `[]`). No
   pruning.
2. **Conflict-resolution UI** — a small "Sync issues" surface (list + per-item resolve action) for
   Orders conflicts specifically, and a lightweight global sync-status indicator (pending count +
   conflict count) replacing the current blocking "App is offline" banner.
3. **`OfflineCapability` helper** — drives which actions are enabled offline. Pending-order CRUD:
   always enabled. Order completion/return/adjust and Inventory/Stock/Transaction edits: gated on
   `isOnline`, same condition as today, just applied per-action instead of to the whole `Navigation`.

**Modified:**
4. **`qml/model/OutboxStore.qml`** — item shape gains `conflict` (bool) and `serverSnapshot` (object,
   null unless conflicted). New `markConflict(requestId, serverSnapshot)`, `resolveConflict(requestId,
   resolution, mergedAfter)`. **`enqueue(call)` gains coalescing**: if an unsent item already exists
   for the same `entity + entityId`, merge the new mutation into it (keep the original `before`, update
   `after` to the latest state) instead of appending a second item. `dueItems()` excludes conflicted
   items. This is a correctness fix, not just an offline nicety — see §4.1 and the memory note; without
   it, two queued mutations for the same order can be sent concurrently and arrive out of order,
   reintroducing the exact bug class `WriteCoalescer.js` (branch `fix/orders-write-race-condition`,
   itself now stale against current `main`) was built to prevent. Doing it at enqueue time in
   `OutboxStore` covers every entity that ever uses this outbox, not just Orders, and makes that
   standalone branch redundant rather than needing to be rebased and merged separately.
5. **`qml/model/Gateway.qml`** — **only** the direct-mode drain fix: `drainNow()` no longer
   early-returns for non-`"gateway"` mode — drains in both modes, so queued items actually get sent
   while `mode` stays `"direct"` (today's state). `_send(item)` branches on `mode` at send time as it
   already conceptually does; `"direct"` gains the pre-write `GET`+compare-and-swap check described in
   §3.1. **Does *not* include** `_collections` gaining `"order"` — that's the concurrent branch's job
   (see dependency note, §1).
6. **`qml/model/DataModel.qml`, `InventoryStore.qml`, `StockBatchStore.qml`, `TransactionStore.qml`,
   `OrdersStore.qml`** — each gets `LocalReadCache` wired into `syncFromFirebase()` (save once the
   full paginated fetch completes) and `Component.onCompleted` (seed from cache before the network
   fetch resolves). Purely additive/read-side — doesn't touch write call sites, so no overlap with the
   concurrent branch's diff.
7. **`qml/Main.qml` / `GlassHeader.qml`** — `Navigation { enabled: isOnline }` replaced with granular
   per-action gating via `OfflineCapability`. Blocking offline banner replaced with the sync-status
   indicator from item 2.

**Explicitly not built by this design:**
- `OrdersStore`'s routing through `Gateway.recordMutation`, and the `Gateway._collections`/
  `ENTITY_COLLECTIONS` map entries for `"order"` — **delivered by the concurrent P0/compliance
  branch**, assumed merged before implementation starts (§1 dependency note). Once it lands, this
  design's job is to verify (not assume) that the call sites it touches — especially
  `approveAllPending()`'s bulk case — actually route through `recordMutation` the way this design's
  data flow (§3.1) expects, since that specific detail hasn't been confirmed against code that isn't
  pushed yet.
- `FirebaseService`'s atomic-increment/`fieldTransforms` write path, `InventoryStore.deductStock`,
  `StockBatchStore.consumeFifo`/`topUpOldest` — removed in v2, still out of scope (§9).
- Staff/Suppliers' own Gateway migration — same roadmap, same status Orders was in, nothing here
  forces it.

---

## 3. Data Flow

### 3.1 Write path (pending-order CRUD only)

```
UI action (create/edit/cancel a pending order)
  → OrdersStore mutates local array (optimistic → instant UI)
  → Gateway.recordMutation("order", orderId, action, before, after)     // ← delivered by the
                                                                          //   concurrent P0 branch,
                                                                          //   not built here (§2)
      → OutboxStore.enqueue(call):
          existing unsent item for this entity+entityId? → merge into it (keep original `before`,
                                                              update `after`) — NEW in v4, §2 item 4
          else                                            → persisted as a new item, survives relaunch
      → drainNow() (no longer gateway-mode-only — NEW in v4, §2 item 5; triggered immediately, and
        again on reconnect) → per due item:
          mode === "gateway"  → POST recordMutation CF (only after the separate future cutover)
          mode === "direct"   → pre-write GET current doc
                                  → compare vs `before` (field-level)
                                  ├─ no real collision → merge, PATCH, OutboxStore.markSent
                                  ├─ same field touched both sides → OutboxStore.markConflict
                                  └─ send/network failure → OutboxStore.markFailed (backoff retry)
  → OutboxStore.pendingCount / conflictCount drive the sync-status indicator
```

Today (`Gateway.mode: "direct"`), this behaves as a durable, coalesced, direct-write outbox. The
`"order": "orders"` collection mapping (concurrent branch) and the `mode` branch (this design) are
what make it automatically start flowing through the compliance Cloud Function later, with zero
rework, once that separate cutover decision happens.

### 3.2 Read path (cold start / offline launch) — all four entities

```
Store Component.onCompleted → LocalReadCache.load(key) → seed items immediately (full last-known set)
                             → syncFromFirebase() attempted (pages to exhaustion)
                                 ├─ completes (hasMore === false) → LocalReadCache.save(key, items)
                                 └─ offline / fails partway → keep the seeded cache, retry on reconnect
```

No age-based pruning (§9). `LocalReadCache.save` fires only once the full paginated fetch finishes,
never on a partial page.

### 3.3 Reconnect sequencing

Connectivity regain triggers `Gateway.drainNow()` first, then `syncFromFirebase()` per store — in
that order, so a freshly-fetched server snapshot doesn't look like a false conflict against a write
that hasn't sent yet.

---

## 4. Low-Level Design

### 4.1 Enqueue-time coalescing (new in v4 — a correctness fix, not just efficiency)

Before appending a new item, `OutboxStore.enqueue(call)` checks for an existing **unsent** item with
the same `entity + entityId`. If found: merge — keep the original item's `before` (the earliest known
starting state), replace its `after` with the new mutation's `after`. If not found: append as usual.

This guarantees at most one in-flight write per record. Without it, editing the same pending order
twice while offline produces two queued items; `drainNow()` (§3.1) fires every due item's request
without waiting for the previous one to ack, so both could be in flight at once with no guaranteed
arrival order — silently letting the older write win and revert the newer one. That's the exact bug
class `WriteCoalescer.js` was built to fix for `OrdersStore`'s old write path; doing it here instead
covers every entity that ever uses this outbox, and makes that standalone (now-stale) branch
unnecessary to merge — see the Revision History v4 note and §9.

### 4.2 Conflict detection — field-level auto-merge, Orders only

Compare three snapshots per field on a queued order: `before` (what we started from), `serverCurrent`
(what's on the server now), `after` (what we want to write).

- `serverCurrent[f] === before[f]` → nobody else touched this field; apply `after[f]`.
- `serverCurrent[f] !== before[f]` and `after[f] === before[f]` → we didn't touch it, they did; keep
  `serverCurrent[f]`, no conflict.
- `serverCurrent[f] !== before[f]` and `after[f] !== before[f]` and `after[f] !== serverCurrent[f]` →
  genuine collision on that field. Merge every non-colliding field automatically; hold the item as
  `conflict: true` with `serverSnapshot` attached; stop auto-retrying it.

### 4.3 Conflict resolution UI

A conflicted order shows in a distinct "Sync issues" list (not blended into ordinary "pending sync").
Per item: the colliding field(s) only, your value vs. the server's, with **Keep mine** / **Use
server's**. "Keep mine" resends with an explicit override that skips the compare check for that one
retry. "Use server's" drops the queued item and refreshes local state from `serverSnapshot`.

### 4.4 UI gating

Pending-order create/edit/cancel: always enabled, routes through §3.1 regardless of connectivity.
Order completion/return/adjust, and Inventory/Stock/Transaction edits: `enabled: isOnline`, applied
per-action/per-button rather than to the whole `Navigation` — same underlying condition as today, just
no longer an all-or-nothing freeze of the entire app.

Two distinct indicators for the Orders sync state:
- **Pending sync** — routine, no action needed. Per-record badge + a global "N changes waiting" chip.
- **Conflict** — needs attention. Visually distinct, links to the Sync issues list (§4.3).

Mid-edit disconnect: nothing special happens when the device drops offline while a pending-order form
is open — the save action is what routes to the outbox. No interruption, no "you went offline" modal.

### 4.5 Display-only pagination is a separate concern from cache scope

Full local caching (§9) means "safely computed from," not "necessarily all rendered in one list at
once." If long order/transaction lists ever feel slow to render, that's a windowed/virtualized list
view over the full local cache — a UI/perf choice, not a reason to re-introduce cache windowing.

---

## 5. Error Handling

- **Send fails (network/5xx)** → stays queued, retried with backoff (2s/8s/30s/2m/10m capped), same
  pattern as `OutboxStore` already uses.
- **Genuine field-level conflict** → held as `conflict: true`, excluded from auto-retry, surfaced in
  Sync issues until resolved. Never silently dropped, never silently overwritten.
- **App killed mid-queue** → outbox is QSettings-backed, survives relaunch.
- **Sign-out with pending items** → existing `OutboxStore.clear()` behavior applies unchanged (drop
  the queue so it never replays under a different account).

---

## 6. Testing

- **Orders durability**: an order edit made offline survives an app kill and sends once reconnected;
  `approveAllPending()`'s multi-doc case durably queues each changed order.
- **Gateway direct-mode drain**: an `"order"` item enqueued while `mode: "direct"` is actually sent via
  `FirebaseService`, not silently skipped; `_collections["order"]` resolves correctly; a hypothetical
  future mode-swap mid-queue resolves correctly (not reachable today since nothing flips `mode`, but
  cheap to verify).
- **Field-level merge**: non-overlapping concurrent edits on the same order merge with zero prompt;
  same-field concurrent edits produce exactly one conflict, only for that field.
- **LocalReadCache**: cold launch offline renders the last-synced full dataset for all four entities;
  a save never fires on a partial/mid-page fetch.
- **UI gating**: pending-order CRUD stays interactive offline; order completion/return/adjust and
  Inventory/Stock/Transaction edits stay blocked exactly as today, now per-action instead of app-wide.
- **Regression check**: Inventory/Stock/Transaction write paths are unchanged by this design — existing
  tests for those should need no updates; worth confirming as a smoke check.
- **Standalone simulation first** (matching how the earlier `OrdersStore` race condition was
  validated): reproduce out-of-order delivery and concurrent-offline-edit scenarios against the outbox
  extension before wiring into the app, per the repo's systematic-debugging convention.

---

## 7. In Scope

- Pending-order create/edit/cancel: durable offline writes, coalesced at enqueue time, field-level
  conflict handling. Builds on top of Orders' `Gateway.recordMutation` routing (delivered by the
  concurrent P0/compliance branch — see dependency note, §1), not duplicating it.
- Full local read cache (no windowing) for Orders/Inventory/Stock/Transactions, enabling read-only
  browsing offline.
- Granular per-action UI gating replacing the blanket `Navigation { enabled: isOnline }`.

## 8. Out of Scope

- **Order completion, returns/adjustments, direct Inventory/Stock/Transaction edits** — stay
  connectivity-gated, mechanism unchanged from today. Not a technical limitation — a deliberate choice
  given offline is expected to be rare and these operations carry real ledger/compliance weight (see
  §9).
- **Orders' routing through `Gateway.recordMutation`** (the `_collections`/`ENTITY_COLLECTIONS` map
  entries, `OrdersStore`'s redirect off direct `FirebaseService` calls) — **owned by the concurrent
  P0/compliance branch**, not this design (§1 dependency note, §9). Building it here too would create
  an avoidable merge conflict with real in-progress work.
- **Staff, Suppliers, Categories, Order Channels** — stay blocked-offline, unchanged. Their own
  Gateway migration (same roadmap, same "half-implemented fast-follow" status Orders was in) is real,
  documented, and not pursued here — nothing in this design forces it the way Orders' offline
  durability forces Orders' migration. Separate future work.
- **Deploying `functions/`, deploying the locked `firestore.rules`, flipping `Gateway.mode`, running
  cutover** — separate, later, explicitly-gated decision (irreversible ledger wipe), unaffected by and
  not required for this work.
- **Extending the durable-outbox pattern to Inventory/Stock/Transaction** for general online-but-flaky-
  network reliability — a real, separate, smaller idea surfaced during this brainstorm, not pursued
  here since it wasn't the ask.
- **List-view display pagination/virtualization** — separate UI-perf concern, see §4.5.
- **P1–P7** (stock-movement taxonomy, HSN/GSTIN, legal docs, DPDP, retention, breach detection,
  warehouse mapping) — unrelated, unaffected by this work.

---

## 9. Trade-offs Considered

| Question | Options weighed | Recommendation | Why |
|---|---|---|---|
| Offline-write scope | (A) All four entities, including order completion — v1's original scope, technically buildable via atomic stock increments + compare-and-swap. (B) Pending-order CRUD only; everything ledger-touching stays connectivity-gated. | **B** (your call) | (A) is real and buildable — confirmed earlier in this brainstorm that today's live Firestore rules permit it without waiting for P0. But it costs real complexity: atomic increment writes, a batch-level FIFO residual-risk trade-off, conflict handling across four entity shapes instead of one. Given offline is expected to be rare (data's meant to stay synced across devices), that cost buys safety margin for a scenario that barely occurs. (B) keeps the app's highest-value offline case (jot down/edit orders when signal drops) without touching the ledger at all. |
| Read-cache scope | (x) Windowed (originally 30 days) — smaller local footprint. (y) Full data, no windowing. | **y** | `OrdersStore`/`TransactionStore`/`StockBatchStore` feed correctness-critical logic (FIFO, KPIs, dedup) that a sibling design (`scale-reads-writes-analytics`) explicitly decided must see the complete set — windowing the offline cache would silently miscompute exactly what that decision protected. The app already holds everything in memory today; persisting the same "everything" durably isn't a new cost, just the existing one made crash-safe. |
| Conflict handling depth (for Orders) | (1) None — silent last-write-wins. (2) Whole-document compare-and-swap. (3) Field-level auto-merge, pick-one only on genuine same-field collisions. | **3** | (1) is what caused the earlier Orders race-condition bug's blast radius. (2) forces a manual choice even when two edits didn't actually collide (e.g. phone number vs. notes changed on different devices). (3) costs a bit more than (2) to build but the UI a person sees is no more complex, and it only appears for genuine collisions. |
| Extending durable-outbox to Inventory/Stock/Transaction | (i) Route them through the same outbox as Orders, for free retry-on-transient-failure even though they stay `isOnline`-gated at the trigger point. (ii) Leave them exactly as they work today. | **ii** | (i) is a reasonable idea and cheap to add later, but it's solving a different problem (online-but-flaky-network reliability) than the one asked for (offline support), and expanding scope right after being asked to narrow it works against the goal. Flagged in §8 as a separate future option, not built now. |
| Orders' write mechanism | (a) Bespoke Orders-only durable queue, bypassing `Gateway` entirely (v2's approach). (b) Route through `Gateway.recordMutation("order", ...)`, completing the deferred piece of P0's own contract. | **b** (v3) | (a) was based on an imprecise premise — that Orders "was never in P0's scope." It was always in the roadmap's contract (`entity` enum already includes `"order"`); only the call-site migration was deferred as phased fast-follow work, not excluded. Verified (b) doesn't reopen the earlier P0-cutover-gating concern — `orders` is working-tier/client-writable in the roadmap's own model and in the actual staged `firestore.rules`, unlike the locked ledger collections. |
| Building Orders' Gateway routing here vs. depending on the concurrent branch | (a) Build `_collections`/`ENTITY_COLLECTIONS`/`OrdersStore` redirect in this design, as v3 did. (b) Treat that routing as a dependency delivered by the concurrent, unpushed P0/compliance branch (confirmed landing this week), and build only the offline-specific pieces on top. | **b** (v4, corrected) | The user flagged that (a) duplicates real, in-progress local work — same files, same functions, guaranteed merge conflict for no benefit. Confirmed the concurrent branch is compliance-routing-only (no direct-mode drain, no conflict handling, no coalescing), so there's no risk of *this* design becoming redundant — real, non-overlapping work remains. (b) costs a sequencing dependency (implementation should start after that branch merges, not before) but avoids building the same code twice. |

---

## 10. Required Existing-Code Changes (summary)

- **Dependency, not built here:** `OrdersStore`'s redirect through `Gateway.recordMutation("order",
  ...)`, and the `Gateway._collections`/`functions/index.js` `ENTITY_COLLECTIONS` map entries for
  `"order"` — delivered by the concurrent P0/compliance branch. Verify these landed as expected
  (especially `approveAllPending()`'s bulk case) before building on top.
- `OutboxStore.qml`: item shape gains `conflict`/`serverSnapshot`; new `markConflict`/`resolveConflict`;
  `dueItems()` excludes conflicted items; **`enqueue()` gains entity+entityId coalescing** (§4.1 — a
  correctness fix, not optional).
- `Gateway.qml`: `drainNow()` no longer early-returns for `mode !== "gateway"` — drains in both modes.
  (Does not touch `_collections` — that's the dependency above.)
- New `qml/helper/LocalReadCache.js`; wired into `syncFromFirebase()`/`Component.onCompleted` for
  `OrdersStore`, `InventoryStore`, `StockBatchStore`, `TransactionStore` (read-only for the latter
  three — no write-path changes to them at all).
- `Main.qml` / `GlassHeader.qml`: replace the blanket `Navigation { enabled: isOnline }` with granular
  per-action gating and the two-tier sync-status indicator.
- New Sync-issues UI (list + resolve actions), scoped to Orders.
- **No changes** to `functions/index.js` beyond the dependency above, `FirebaseService.qml`'s write
  methods, `InventoryStore.deductStock`, or `StockBatchStore.consumeFifo`/`topUpOldest` — v1 items,
  removed in v2, unaffected by v3/v4.
- **Superseded, not merged:** `fix/orders-write-race-condition` (`WriteCoalescer.js`) — already stale
  against current `main`, and made redundant by the `OutboxStore` coalescing above. Recommend closing
  it once this ships rather than rebasing it just to have it become partially dead code.

---

## 11. Next Steps

1. **Review this doc** — this is a substantially smaller scope than the original draft; confirm it
   still matches what you want before moving on.
2. **Wait for the concurrent P0/compliance branch to merge** (expected this week) before starting
   implementation. Once it lands: verify `OrdersStore`'s call sites actually route through
   `Gateway.recordMutation` the way §3.1 assumes — especially `approveAllPending()` — since that
   couldn't be confirmed against code that isn't pushed yet. Branch this work off that result, not off
   current `main`.
3. Move to `/superpowers:writing-plans` to break §10 into an ordered implementation plan (suggest:
   `OutboxStore` coalescing + conflict-handling extension first since everything else depends on it,
   then `Gateway.drainNow()`'s direct-mode fix, then read cache, then UI gating last since it's the
   most visible surface).
4. Each implementation step gets its own checkpoint entry and its own branch; nothing gets committed/
   pushed without your explicit go-ahead and a session-scoped token.
5. Build/run stays off until you say so.
6. The separate, later decision on P0 deploy + cutover (irreversible ledger wipe) stays its own
   approval gate — not triggered by, or blocking, this work.
7. Recommend closing `fix/orders-write-race-condition` once this ships (§10) rather than rebasing
   stale code that's about to become redundant — your call, not assumed.
