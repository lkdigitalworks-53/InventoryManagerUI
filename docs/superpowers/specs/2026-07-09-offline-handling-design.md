# Offline Handling — Orders / Inventory / Stock / Transactions — Design

**Date:** 2026-07-09
**Status:** Draft — pending review/approval (brainstormed via `/superpowers:brainstorming`)
**Related:** `2026-06-06-P0-compliance-gateway-design.md` (extends and generalizes the
outbox/gateway pattern P0 introduced; does **not** require P0's Cloud Function to be deployed),
`2026-07-06-scale-reads-writes-analytics-design.md` (landed independently, in parallel with this
brainstorm — see Revision note below)

### Revision note (2026-07-10)

The original draft was written against a repo snapshot from earlier on 2026-07-09. Two things landed
in `main` afterward, both from the `scale-reads-writes-analytics` project (merged via PR #22, commit
`ea06c1e`), that changed assumptions this doc depended on:

1. **`OrdersStore`'s whole-collection-overwrite bug is already fixed** (commit `26d8854`,
   independently of this brainstorm) — `_pushAllToFirebase()` is gone; `_commit(arr, changedOrder)`
   now does a single-doc `_pushToFirebase(changedOrder)`, and `approveAllPending()` uses a new
   `FirebaseService.putMany()` for its legitimate multi-doc case. **This narrows what §4.4/§10 need
   to do** — the correctness fix no longer needs to happen here, only the durability layer on top of
   it. See updated §4.4.
2. **A real conflict with our locked 30-day read-cache window.** The sibling design's own audit found
   that `OrdersStore`/`TransactionStore`/`StockBatchStore` are read directly by correctness-critical
   logic (FIFO consumption, Dashboard KPIs, import dedup) that assumes the *complete* local set, and
   explicitly decided **against** windowing them for exactly that reason — windowing "would silently
   miscompute, not just under-display." Our 30-day *offline* read cache would reintroduce that same
   failure mode the moment those computations run offline or against a freshly-seeded cache. **Revised
   below**: the persisted offline cache now mirrors the sibling decision — full data, no age-based
   pruning, for all four in-scope entities. This is a real reversal of something we locked in together;
   flagging it plainly rather than quietly editing the number. See updated §1 table, §3.3, §9.

Separately (not a doc conflict, just a stale detail): **Firebase Blaze billing is already active**
(confirmed in the sibling design, needed for its `computeAnalysis` Cloud Function). The earlier framing
of Blaze as an open/uncertain blocker for the P0 cutover was outdated — the only remaining reason that
stays gated is the irreversible ledger wipe, not billing. Corrected throughout below.

---

## 1. Purpose

Today, the entire app goes non-interactive when the device is offline
(`Navigation { enabled: isOnline }` in `Main.qml`), and no store persists its dataset locally —
every screen is backed by an in-memory array that's wiped and re-fetched on load. So "offline" today
means both **no writes** and, on a cold/relaunch, **no reads either** — blank screens, not just
disabled buttons.

This design makes **Orders, Inventory, Stock, and Transactions** genuinely usable offline: viewing
recent data, and making changes that reliably sync once the device reconnects — without weakening
the correctness guarantees that matter for books-of-account data, and without needing the P0 Cloud
Function to be deployed first.

### Scoping decisions (locked)

| Decision | Value |
|---|---|
| Entities in scope | **Orders, Inventory, Stock (batches), Transactions.** All four unlock together — see §3 for why order-completion doesn't need to wait for Inventory/Stock. |
| Entities explicitly out of scope | Staff, Suppliers, Categories, Order Channels — stay blocked-offline exactly as today. Deliberate deferral (low frequency, low stakes), not a technical limitation. |
| Relationship to P0 | This design **extends** the outbox pattern P0 introduced, generalizing it to work over direct Firestore writes today, and to the recordMutation Cloud Function later, with no redesign at the cutover point. **Does not deploy or require deploying** `functions/`, does not flip `Gateway.mode`, does not run cutover. Blaze billing is already active (confirmed via the sibling `scale-reads-writes-analytics` work) — the sole remaining reason cutover stays gated is the irreversible ledger wipe, not billing. |
| Local storage mechanism | QSettings/JSON (matches existing `OutboxStore`/`PartyStore` convention). SQLite considered and rejected for this app's scale — see §9. |
| Conflict handling | Client-side, best-effort, field-level auto-merge; pick-one prompt only for genuine same-field collisions. Stock quantities use atomic increments instead, sidestepping the conflict question for that field entirely. See §9. |
| Read-cache scope | **Revised 2026-07-10 — full data, not windowed**, for all four entities. `OrdersStore`/`TransactionStore`/`StockBatchStore` are read by correctness-critical logic (FIFO, KPIs, dedup) that the sibling `scale-reads-writes-analytics` design explicitly decided must see the complete set, not a recent window — windowing the offline cache would reintroduce the exact miscomputation risk that decision ruled out. The persisted local cache now mirrors what's already held in memory today (everything), just made durable. A UI list can still choose to *display* only recent entries — that's a separate, optional, display-only decision (see §4.6) that doesn't affect what's actually cached/computed-from. **This reverses our original 30-day call — flagging for your explicit sign-off, see the Revision note above.** |
| Write outbox pruning | Never pruned by age, regardless of the read-cache decision above — only cleared on ack or user-resolved conflict. Unchanged from the original draft. |
| Batch-level FIFO residual risk | Accepted. Per-batch atomic increments reduce clobbering; the rare residual case (two offline devices both drawing down the same batch) self-heals via the existing `StockBatchStore.topUpOldest` drift-repair mechanism. No new distributed-coordination logic built. See §9. |

---

## 2. Components

**New:**
1. **`qml/helper/LocalReadCache.js`** — small shared module. **Full-data** (not windowed — see §1
   revision) QSettings-backed persistence for a store's dataset: `save(settingsKey, items)`,
   `load(settingsKey)` (returns cached array or `[]`). No age-based pruning; mirrors the "keep
   everything locally" model the sibling scale project already locked in for the in-memory case.
2. **Conflict-resolution UI** — a "Sync issues" surface (list + per-item resolve action), and a
   lightweight global sync-status indicator (pending count + conflict count) replacing the current
   blocking "App is offline" banner in `GlassHeader.qml`.
3. **`OfflineCapability` helper** (or a few exported bools on an existing singleton) — drives which
   screens/actions are enabled offline. Replaces the single `Navigation { enabled: isOnline }` toggle
   with a per-entity check.

**Modified:**
4. **`qml/model/OutboxStore.qml`** — item shape gains `conflict` (bool, default false) and
   `serverSnapshot` (object, null unless conflicted). New functions: `markConflict(requestId,
   serverSnapshot)`, `resolveConflict(requestId, resolution, mergedAfter)`. `dueItems()` excludes
   conflicted items (they must not silently auto-retry).
5. **`qml/model/Gateway.qml`** — `drainNow()` stops early-returning for non-`"gateway"` mode; drains
   in **both** modes. `_send(item)` branches on `mode` at send time: `"gateway"` → POST to the CF
   (unchanged); `"direct"` → per-document Firestore write via `FirebaseService` (today's live rules
   already permit this — see §3). `_collections` gains `"order": "orders"`. New `recordIncrement(entity,
   entityId, field, delta)` for the stock-delta case.
6. **`qml/model/FirebaseService.qml`** — new method using the Firestore `:commit` REST endpoint with
   `fieldTransforms` for atomic increments (needed for `recordIncrement`, since a plain `PATCH` can't
   express "add -3 to whatever the server's current value is"). New pre-write `GET` used by the
   client-side compare-and-swap check.
7. **`qml/model/OrdersStore.qml`** — **narrower than originally scoped** (see Revision note): the
   whole-collection-overwrite bug is already fixed independently (commit `26d8854`). What's left is
   durability: `_pushToFirebase(changedOrder)` (already exists, currently a direct
   `FirebaseService.put`) routes through `Gateway.recordMutation("order", orderId, action, before,
   after)` instead. `approveAllPending()`'s multi-doc case loops one `Gateway.recordMutation` call per
   changed order (the outbox stays single-entity-per-item — a bulk UI action just enqueues N items,
   not a new batch-item type) instead of/alongside its `FirebaseService.putMany()` call.
8. **`qml/model/InventoryStore.qml` / `StockBatchStore.qml`** — `deductStock` / `consumeFifo` /
   `topUpOldest` switch from absolute read-modify-write to `Gateway.recordIncrement(...)` for the
   quantity fields.
9. **`qml/model/DataModel.qml`, `InventoryStore.qml`, `StockBatchStore.qml`, `TransactionStore.qml`,
   `OrdersStore.qml`** — each gets `LocalReadCache` wired into `syncFromFirebase()` (save once the
   full paginated fetch completes — see §3.3) and `Component.onCompleted` (seed from cache before the
   network fetch resolves).
10. **`functions/index.js` `recordMutation`** — (code-only change, not deployed as part of this work)
    adds the same before-vs-current-server-state comparison the client does, for defense in depth once
    the CF is live. Not required for this design to function pre-cutover.
11. **`qml/Main.qml` / `GlassHeader.qml`** — `Navigation { enabled: isOnline }` replaced with granular
    per-screen/per-action gating via `OfflineCapability`. Blocking offline banner replaced with the
    sync-status indicator from item 2.

---

## 3. Data Flow

### 3.1 Why all four entities can unlock together (not staged behind P0's cutover)

`Gateway.mode: "direct"` today is fire-and-forget (`FirebaseService.put`, no queue, no retry) — not
secretly already durable. But the staged locked Firestore rules (which would restrict ledger
collections to CF-only writes) are **not deployed** — deploying them before cutover would break
today's direct writes, per `KNOWN-ISSUES.md`. That means **today's live rules still permit direct
client writes** to `inventory`/`stock_batches`/`stock_movements`/`transactions`. So durability (queue +
retry), atomic increments, and compare-and-swap can all be built against direct Firestore writes,
under today's live rules — none of it requires the Cloud Function or Blaze billing. What the CF deploy
actually buys later is: atomic pairing of each write with an `audit_log` entry, and a hard
security-rule lock against a client writing bad data directly — both compliance properties, orthogonal
to offline durability. When `Gateway.mode` eventually flips to `"gateway"`, the same queued items just
start being sent to the CF instead of direct Firestore — a branch inside `Gateway._send`, invisible to
everything built here.

`DataModel._tryCompleteOrder()` cascades into `StockBatchStore.consumeFifo`, `InventoryStore.deductStock`,
and `TransactionStore.recordSaleFromOrder` — all Gateway-routed. Since Gateway-routed writes are now
durable in direct mode too, order completion doesn't need separate/later treatment from plain Orders
CRUD. One rollout, not two.

### 3.2 Write path (all four entities)

```
UI action → Store mutates local array (optimistic → instant UI)
          → Gateway.recordMutation(entity, id, action, before, after)
              → OutboxStore.enqueue(call)                      // persisted immediately, survives relaunch
              → drainNow() → per due item:
                  mode === "gateway"  → POST recordMutation CF (as P0 designed)
                  mode === "direct"   → pre-write GET current doc
                                          → compare vs `before` (field-level)
                                          ├─ no real collision → merge, PATCH, OutboxStore.markSent
                                          ├─ same field touched both sides → OutboxStore.markConflict
                                          └─ send/network failure → OutboxStore.markFailed (backoff retry)
          → OutboxStore.pendingCount / conflictCount drive the sync-status indicator
```

For Orders specifically: `_pushToFirebase(changedOrder)` is the real call site to redirect through
`Gateway.recordMutation` (§2 item 7) — it already isolates the single changed document, it just
doesn't queue or retry today. `approveAllPending()`'s bulk case becomes a loop of individual
`Gateway.recordMutation` calls, one per changed order, so each gets its own durable queue entry.

Stock-quantity fields skip the compare-and-swap branch entirely and go through
`Gateway.recordIncrement`, which issues an atomic Firestore `fieldTransforms.increment` — order-
independent, no comparison needed, no conflict possible for that field.

### 3.3 Read path (cold start / offline launch)

```
Store Component.onCompleted → LocalReadCache.load(key) → seed `items`/`orders`/etc. immediately
                                                            (full last-known-good dataset)
                             → syncFromFirebase() attempted (pages to exhaustion, per the sibling
                               pagination work — hasMore/loadingMore drive repeated loadMore() calls)
                                 ├─ online, completes (hasMore === false) → LocalReadCache.save(key, items)
                                 └─ offline / fails partway → keep the seeded cache, retry on reconnect
```

No age-based pruning (see §1 revision) — the persisted cache holds the same complete dataset the
in-memory array already holds today, just durable across relaunch. `LocalReadCache.save` fires only
once the full paginated fetch finishes, not after the first page, so a save never persists a partial
mid-page snapshot as if it were complete.

### 3.4 Reconnect sequencing

Connectivity regain triggers `drainNow()` first, then `syncFromFirebase()` per in-scope store —
**in that order**. Draining first avoids a freshly-fetched server snapshot looking like a false
conflict against a write we haven't sent yet.

---

## 4. Low-Level Design

### 4.1 Conflict detection — field-level auto-merge (Option C)

At send time (direct mode) or inside the CF transaction (gateway mode, future work), compare three
snapshots per field: `before` (what we started from), `serverCurrent` (what's on the server now),
`after` (what we want to write).

- `serverCurrent[f] === before[f]` → nobody else touched this field since we started; apply `after[f]`.
- `serverCurrent[f] !== before[f]` and `after[f] === before[f]` → we didn't touch it, they did; keep
  `serverCurrent[f]`, no conflict.
- `serverCurrent[f] !== before[f]` and `after[f] !== before[f]` and `after[f] !== serverCurrent[f]` →
  genuine collision on this field. Merge every non-colliding field automatically; hold the whole item
  as `conflict: true` with `serverSnapshot` attached; stop auto-retrying it.

### 4.2 Conflict resolution UI

A conflicted item shows in a distinct "Sync issues" list (not blended into ordinary "pending sync").
Per item: the colliding field(s) only, your value vs. the server's, with **Keep mine** / **Use
server's**. "Keep mine" resends with an explicit override that skips the compare-and-swap check for
that one retry (the person has now made an informed choice). "Use server's" drops the queued item and
refreshes local state from `serverSnapshot`.

### 4.3 Stock-quantity deltas

`InventoryStore.deductStock(productId, qty)` and `StockBatchStore.consumeFifo`/`topUpOldest`
(per-batch `qtyRemaining`) move from "read current value, compute and write an absolute new value" to
`Gateway.recordIncrement(entity, entityId, field, -qty)`. `FirebaseService` gains a `:commit`-based
write with `fieldTransforms: [{ fieldPath, increment: { integerValue } }]`.

Residual risk, accepted (see §9): *which* batch(es) to draw from is still decided from a possibly-stale
local read when offline. Per-batch increments prevent one device's write from erasing another's, but
two devices both offline-consuming the tail of the same batch can still over-draw it. `topUpOldest`
already exists as a self-heal for exactly this class of drift and is relied on rather than duplicated.

### 4.4 OrdersStore — durability on top of an already-fixed write path

**Correction from the original draft** (see Revision note): the whole-collection-overwrite bug this
section originally described as the thing to fix is already fixed, independently, by commit `26d8854`
— `_pushAllToFirebase()` is gone. `_commit(arr, changedOrder)` already isolates the single changed
document via `_pushToFirebase(changedOrder)`. What's actually missing is **durability**, not
correctness: `_pushToFirebase` is still a direct, fire-and-forget `FirebaseService.put` — nothing
queues it, nothing retries it, an offline call is simply lost. This design's remaining job for Orders
is narrow: redirect `_pushToFirebase` through `Gateway.recordMutation("order", orderId, action,
before, after)` instead of calling `FirebaseService` directly, and give `approveAllPending()`'s
multi-doc case the same treatment via a loop (§3.2). Smaller diff than originally scoped — the
correctness half of this work was already done for us.

### 4.5 UI gating

`Navigation` stops using a single `enabled: isOnline` bool. Orders/Inventory/Stock/Transactions screens
stay interactive offline; their mutating actions route through the outbox instead of a live call.
Staff/Suppliers/Categories/Channels keep today's blocked-offline behavior unchanged.

Two distinct indicators, not one:
- **Pending sync** — routine, no action needed. Per-record badge + a global "N changes waiting" chip.
- **Conflict** — needs attention. Visually distinct, links to the Sync issues list (§4.2).

Mid-edit disconnect: nothing special happens when the device drops offline while a form is open — the
save action is what routes to the outbox. No interruption, no "you went offline" modal.

### 4.6 Display-only pagination is a separate concern from cache scope

The original 30-day window conflated two different things: how much data is safely *cached/computed
from* (§1 revision: all of it, no pruning) and how much is *rendered in a list at once* (a pure UI/
perf choice). If long order/transaction lists ever feel slow to render, that's solvable the same way
the sibling pagination work already solves it for network fetches — a windowed/virtualized list view
over the full local cache — without touching what's actually stored or what feeds FIFO/KPI/dedup
logic. Not designed further here; flagged so a future "the list feels slow" complaint doesn't get
mistaken for a reason to re-introduce cache windowing.

---

## 5. Error Handling

- **Send fails (network/5xx)** → stays queued, retried with existing backoff (2s/8s/30s/2m/10m capped),
  same as P0's outbox.
- **Genuine field-level conflict** → held as `conflict: true`, excluded from auto-retry, surfaced in
  Sync issues until resolved. Never silently dropped, never silently overwritten.
- **App killed mid-queue** → outbox is QSettings-backed, survives relaunch, same guarantee as P0.
- **Stock increment on a doc that's since been deleted** (e.g. product removed while offline) →
  increment write fails (`NOT_FOUND`); surfaced like any other failed item, not silently dropped or
  auto-retried into a new doc.
- **Sign-out with pending items** → existing `Gateway.clear()` / `OutboxStore.clear()` behavior
  applies unchanged (drop the queue so it never replays under a different account).

---

## 6. Testing

- **OutboxStore extension**: conflict marking excludes items from `dueItems()`; `resolveConflict`
  (`keep-mine` / `use-server`) produces the correct follow-up state; existing enqueue/drain/backoff
  tests still pass unchanged.
- **Gateway direct-mode drain**: item enqueued in `"direct"` mode is actually sent via
  `FirebaseService`, not silently skipped; mode-swap mid-queue (an item enqueued in `"direct"`, mode
  flips to `"gateway"` before it sends) resolves correctly.
- **Field-level merge**: non-overlapping concurrent edits merge with zero user prompt; same-field
  concurrent edits produce exactly one conflict, only for that field.
- **Stock increments**: concurrent offline increments from two simulated sessions land correctly
  (order-independent); a deleted product's queued increment fails visibly.
- **OrdersStore durability**: `_pushToFirebase`/`approveAllPending` route through
  `Gateway.recordMutation` and survive an app-kill mid-send (they didn't before); existing
  `_tryCompleteOrder` cascade (stock/inventory/transaction) still fires correctly end-to-end. (The
  single-doc-write correctness property itself is already covered by existing tests for commit
  `26d8854` — not re-verified here.)
- **LocalReadCache**: cold launch offline renders the last-synced full dataset (no pruning); a save
  never fires on a partial/mid-page fetch, only once `hasMore === false`.
- **UI gating**: Orders/Inventory/Stock/Transactions screens remain interactive offline;
  Staff/Suppliers/Categories/Channels remain blocked, matching today.
- **Standalone simulation** (matching how the earlier `OrdersStore` race condition was validated):
  reproduce out-of-order delivery and concurrent-offline-edit scenarios against the new outbox before
  wiring into the app, per the repo's systematic-debugging convention.

---

## 7. In Scope

- Orders (create/edit/cancel/complete/return/adjust), Inventory, Stock (batches), Transactions:
  durable offline writes, full local read cache (no age windowing — see §1 revision), field-level
  conflict handling, granular UI gating.
- Adding durability (outbox routing) on top of `OrdersStore`'s already-fixed single-doc write path.
- `Gateway`/`OutboxStore` generalization to drain in `"direct"` mode, not just `"gateway"` mode.
- Atomic-increment write path in `FirebaseService` for stock-delta fields.
- `functions/index.js` before/current comparison addition (code-only — see §8, not deployed here).

## 8. Out of Scope

- **Staff, Suppliers, Categories, Order Channels** — stay blocked-offline. Deliberate deferral (low
  edit frequency, no compliance angle, small blast radius) — a real gap, not a claim these will never
  need it, just not this pass.
- **Deploying `functions/`, deploying the locked `firestore.rules`, flipping `Gateway.mode` to
  `"gateway"`, running cutover** — all separate, later, explicitly-gated decisions per your call
  earlier in this brainstorm. Blaze billing is already active (see Revision note) so that's no longer
  part of what's being deferred — only the irreversible ledger wipe is. This design is deploy-ready for
  that transition but doesn't trigger it.
- **True server-side transactional conflict enforcement** — the client-side compare-and-swap here is
  best-effort (small race window between the pre-write `GET` and the `PATCH`). Real atomicity arrives
  with the CF's transaction, later, as a strict upgrade with no redesign needed.
- **Cross-device real-time collaboration UX** (e.g. live "someone else is editing this order" presence)
  — out of scope; this design only handles the two devices having been offline at different times, not
  simultaneous live editing while both online.
- **Distributed batch-selection coordination** — accepted residual risk, see §4.3/§9.
- **List-view display pagination/virtualization** — a separate, optional UI-perf concern, decoupled
  from cache scope (see §4.6). Not designed here.
- **P1–P7** (stock-movement taxonomy, HSN/GSTIN, legal docs, DPDP, retention, breach detection,
  warehouse mapping) — unrelated, unaffected by this work.

---

## 9. Trade-offs Considered

| Question | Options weighed | Recommendation | Why |
|---|---|---|---|
| Local storage mechanism | (A) QSettings/JSON, matches existing convention, no new deps, but no querying and a full-blob rewrite per save. (B) SQLite via Qt SQL — scales better, enables real offline queries, but a new dependency, new build-platform surface (Android/iOS driver bundling), and a second local-storage pattern alongside every existing store's QSettings convention. | **A** | This app's realistic scale (a single small business, hundreds of SKUs, tens of orders/day) doesn't need SQLite's benefits yet, and B's cost (new module, new build surface, inconsistent-with-existing-code risk) isn't worth paying pre-emptively. (Originally paired with windowing to bound A's main weakness — full-blob rewrite cost — but windowing itself was reversed on 2026-07-10; see next row. The full-blob cost is the same one the in-memory model already accepts today.) |
| Conflict handling depth | (1) None — silent last-write-wins. (2) Whole-document compare-and-swap, pick-one on any difference. (3) Field-level auto-merge, pick-one only on genuine same-field collisions. | **3** | (1) is what caused the earlier Orders race-condition bug's blast radius; unacceptable given "zero regression." (2) is simpler to build than (3) but forces a manual choice (and real data loss) even when two edits didn't actually collide — e.g. phone number vs. notes changed on different devices. (3) costs a bit more to build than (2) but the UI a person sees is no more complex than (2)'s, and it only appears for genuine collisions, which will be rare for a small team. |
| Stock quantity conflicts | (a) Same compare-and-swap as everything else. (b) Model as atomic deltas instead of absolute values. | **b** | Stock changes are naturally commutative (order doesn't matter, only magnitude) and this is the single highest-frequency Gateway-routed write (fires on every order completion) — worth the small extra implementation cost of a `:commit`/`fieldTransforms` write path to eliminate the conflict class entirely rather than detect-and-prompt for it. |
| Batch-level FIFO selection under concurrent offline use | (i) Build real coordination/locking so two offline devices can never over-draw the same batch. (ii) Accept the residual risk; rely on the existing `topUpOldest` self-heal. | **ii** | (i) is a genuinely hard distributed-systems problem for a scenario that will be rare (two staff simultaneously offline, selling down to the last units of the exact same batch, for a small team). The codebase already made the call elsewhere that ledger drift should self-heal rather than block a sale (`topUpOldest`'s own comment: "we never want a sale to fail because the batch ledger drifted") — building new coordination here would contradict a design decision already made and accepted in the existing code. |
| Sequencing relative to P0 | (x) Wait for P0 deploy+cutover, build offline support only for what's then CF-backed. (y) Build now against direct writes; CF deploy becomes a pure implementation swap later, whenever that separate decision is made. | **y** | Correctly identified partway through this brainstorm (see §3.1) — today's live Firestore rules already permit the direct writes this needs, so there's no technical reason to block offline support on a deploy decision that's explicitly being deferred (which, per the Revision note, is now about the irreversible ledger wipe only — Blaze billing is no longer part of that blocker). Blocking on it would have delayed real value for no safety benefit. |
| Read-cache scope | (x) Windowed, e.g. 30 days — smaller local footprint, older history still safely on the server. (y) Full data, no windowing — matches what's already held in memory today. | **y**, revised 2026-07-10 | Originally locked as (x) for footprint reasons before the sibling `scale-reads-writes-analytics` design's audit was known. That audit found `OrdersStore`/`TransactionStore`/`StockBatchStore` feed correctness-critical logic (FIFO, KPIs, dedup) that must see the complete set — windowing the offline cache would silently miscompute exactly the things that decision was written to protect. (x)'s footprint benefit isn't worth reintroducing that risk; the app already accepts holding everything in memory today, so persisting the same "everything" durably isn't a new cost, just the existing one made crash-safe. Flagging this as a real reversal of a call we made together, not a unilateral edit. |

---

## 10. Required Existing-Code Changes (summary)

- `OrdersStore.qml`: redirect `_pushToFirebase(changedOrder)` (already isolates the single changed
  doc, per commit `26d8854`) through `Gateway.recordMutation("order", ...)` instead of calling
  `FirebaseService` directly; `approveAllPending()` loops one `Gateway.recordMutation` call per
  changed order for durability.
- `Gateway.qml`: `drainNow()` no longer early-returns for `mode !== "gateway"`; `_send` branches per
  mode; `_collections` gains `"order"`; new `recordIncrement(...)`.
- `FirebaseService.qml`: new `:commit`/`fieldTransforms`-based increment write; pre-write `GET` for
  compare-and-swap.
- `OutboxStore.qml`: item shape gains `conflict`/`serverSnapshot`; new `markConflict`/`resolveConflict`;
  `dueItems()` excludes conflicted items.
- `InventoryStore.qml` / `StockBatchStore.qml`: `deductStock`/`consumeFifo`/`topUpOldest` switch to
  `Gateway.recordIncrement` for quantity fields.
- New `qml/helper/LocalReadCache.js`; wired into `syncFromFirebase()`/`Component.onCompleted` for
  `OrdersStore`, `InventoryStore`, `StockBatchStore`, `TransactionStore`.
- `Main.qml` / `GlassHeader.qml`: replace the blanket `Navigation { enabled: isOnline }` and blocking
  banner with granular per-entity gating and the two-tier sync-status indicator.
- New Sync-issues UI (list + resolve actions) — new component, reusable across the four entities.
- `functions/index.js` `recordMutation`: add the before/current comparison (code-only, not deployed as
  part of this work — see §8).

---

## 11. Next Steps

1. **Review this doc** — confirm nothing above misrepresents a decision made during the brainstorm.
   **In particular, confirm or push back on the read-cache scope reversal in §1/§9** — that's a real
   change from what we locked in together, not a cosmetic edit.
2. Once approved, move to `/superpowers:writing-plans` to break §10 into an ordered implementation
   plan (suggest: OutboxStore/Gateway generalization first since everything else depends on it, then
   OrdersStore durability, then stock deltas, then read cache, then UI gating/conflict UI last since
   it's the most visible surface and benefits from the underlying mechanism being solid first).
3. Each implementation step gets its own checkpoint entry (per your session rules) and its own branch;
   nothing gets committed/pushed without your explicit go-ahead and PAT.
4. Build/run stays off until you say so, per your standing instruction.
5. The separate, later decision on P0 deploy + cutover (irreversible ledger wipe — no longer a billing
   question, see Revision note) stays its own approval gate — not triggered by, or blocking, this work.
