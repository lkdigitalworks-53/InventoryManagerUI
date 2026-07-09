# Bounded Reads, Write-Path Fix, and Server-Side Analytics — Design

**Date:** 2026-07-06
**Status:** Approved (design); pending implementation plan
**Related:** `2026-06-06-P0-compliance-gateway-design.md` (this design extends the same gateway/
Cloud Functions project on the read side, and completes a write-path gap P0 left as fast-follow)

---

## 1. Purpose

Every store today either (a) fetches its entire Firestore collection into a QML array on load, or
(b) overwrites its entire Firestore collection on every single-record mutation. Both patterns were
fine at small scale and now fail in two different ways as data grows:

- **Read side (confirmed bug):** a plain `GET .../documents/{collection}` silently paginates
  server-side once a collection crosses an internal response-size threshold, and
  `FirebaseService.get()` never follows the returned `nextPageToken`. Reproduced directly: a
  250-product inventory returns only 170 products, with no error surfaced anywhere.
- **Write side (confirmed bug, not yet hit but structurally guaranteed to fail):** some stores
  rebuild their *entire* collection into one Firestore `:commit` call on every mutation. Firestore
  hard-caps a single commit at 500 writes. Past 500 records in one of those collections, every
  further write — even editing one row — fails outright, atomically, because the whole commit is
  rejected.

This design fixes both, and separately gets analytics (Revenue/Profit/Sold/Purchased/Stock Value,
by category/supplier/staff, any period) off the phone entirely, so the Analysis page never needs the
full transaction ledger resident in a QML array to begin with.

This design is **read/write-path only**. It does not touch the ledger/working-tier compliance model
(Skill 21) — the Cloud Functions gateway remains the only writer of ledger collections, and this
design's Cloud Function additions are new, separate callables alongside `recordMutation`.

---

## 2. Full Audit (locked reference — do not re-derive during implementation)

### 2.1 Read path — full-collection `GET`, all subject to the truncation bug

| Store | Collection | Priority |
|---|---|---|
| `InventoryStore` | `inventory` | **High** — this is the confirmed 250→170 reproduction |
| `OrdersStore` | `orders` | High |
| `StaffStore` | `staff` | High |
| `StockBatchStore` | `stock_batches` | High |
| `SupplierStore` | `suppliers` | High |
| `TransactionStore` | `transactions` | High |
| `ActivityLog` | `activity_log` | Low — capped at 50 rows client-side already |
| `AuthService` (member list, ~line 205) | `tenants/{tenantId}/members` | Low — typically small |

**Not affected:** `CategoryStore` (`config/categories`) and `OrderChannelStore`
(`config/orderChannels`) are single documents, not collections — Firestore's List-Documents
pagination never applies to a single-document `GET`.

### 2.2 Write path — full-collection bulk overwrite, hard-fails past 500 docs

| Store | Status |
|---|---|
| `OrdersStore` | **Broken** — every mutation (`_commit`) calls `_pushAllToFirebase()` |
| `StaffStore` | **Broken, narrowly** — only `addStaff()`; `updateStaff`/`setAppUid` already use single-doc `PUT` |
| `ActivityLog` | Same anti-pattern, capped at 50 rows → low severity |
| `InventoryStore` | **Already correct** — every mutation routes through `Gateway.recordMutation` → single-doc `_writeDirect` |
| `StockBatchStore` | **Already correct** — same Gateway path; multi-batch FIFO touches do N individual single-doc calls (chatty, not broken) |
| `SupplierStore` | **Already correct** — per-doc `FirebaseService.put` throughout |
| `TransactionStore` | **Already correct** — per-doc via Gateway |
| `CategoryStore` / `OrderChannelStore` | Not the same bug class — legitimately one config document each |
| `PartyStore` | Not Firestore at all — QSettings-only, superseded by `SupplierStore` |

The write-path fix is exactly **3 call sites**: `OrdersStore._commit`, `StaffStore.addStaff`,
`ActivityLog.record`. Everything else in §2.2 is verified unaffected — **do not touch it** during
implementation.

---

## 3. Scoping decisions (locked)

| Decision | Value |
|---|---|
| Analytics approach | **On-demand server-side compute** (`computeAnalysis` Cloud Function), not persisted rollups. Reuses the existing `RealisedMath`/`BreakdownMath` logic (ported to Node) rather than introducing write-time aggregate maintenance. Rollups are a documented future upgrade if/when a full-ledger scan per view becomes slow — the client-facing contract doesn't change if that swap happens later. |
| Pagination transport | Firestore's structured-query REST endpoint (`:runQuery`), not the List-Documents endpoint — needed for `orderBy` + cursor control that List-Documents doesn't give us. |
| Bounded vs. unbounded collections | **Revised (see §3.1) — all six stores auto-page to exhaustion in Phase 1.** Original plan was "orders/ledger keep a recent window, older data pages in on demand"; deeper audit found `OrdersStore`/`TransactionStore`/`StockBatchStore` are read directly by correctness-critical logic (FIFO consumption, Dashboard/KPI sums, import dedup, live Analysis) that assumes the complete set today. Windowing them now would silently miscompute, not just under-display. |
| Shared math | **Ported, not literally shared** — `RealisedMath.js`/`BreakdownMath.js` use QML's `.pragma library` + `.import`, which isn't valid Node. Parity is enforced by shared JSON fixtures run against both the existing `tst_RealisedMath.qml`/`tst_BreakdownMath.qml` and new Node tests. |
| Write-path fix scope | Exactly the 3 call sites in §2.2 — no broader rewrite. |
| Firebase billing plan | **Blaze (pay-as-you-go), already active.** Cloud Functions, outbound network calls from functions, and other Blaze-only Firestore/Functions features are all available — nothing in this design or its future-work items is blocked on a billing upgrade. |

### 3.1 Why the scope was revised (audit findings)

Phase 1's original goal — get `FirebaseService.get()`'s truncation bug fixed everywhere — is
unchanged. What changed is *how* the three growing collections get fixed. A deeper audit (prompted
mid-implementation) of every consumer of `OrdersStore`, `TransactionStore`, and `StockBatchStore`
found:

- `StockBatchStore.batches` is scanned directly by `InventoryStore`'s FIFO/stock-value functions,
  which filter for `qtyRemaining > 0` **after** iterating the whole array — an old, large batch that
  hasn't sold through yet would silently vanish from stock value and FIFO consumption order if it
  fell outside a "recent" window. Also consumed directly by `DataModel.qml`'s `consumeFifo` /
  `topUpOldest` / `restoreFifo` (the actual stock-deduction logic) and `SalesPage.qml` (COGS/supplier
  lineage).
- `TransactionStore.entries` feeds directly into `SalesPage.qml`'s live RealisedMath scope (today,
  not just after Phase 2) and its own direct full-array scans (`bucketsForFiltered`,
  `lastSupplierFor`).
- `OrdersStore.orders` is scanned in full by `SalesStore.qml`'s KPI derivation (Dashboard revenue/
  order-count totals), `ImportPreviewDialog.qml`'s duplicate-detection map, `ProfilePage.qml`'s
  per-staff order count, and `DashboardPage.qml`'s several KPI scans.

None of these are display-only; they're correctness-critical aggregations that assume the complete
local set right now. Splitting "what needs everything" from "what's just a display list" for these
three stores is a real, separate architecture project (redesigning Dashboard KPIs, import dedup, and
FIFO consumption to not require full local data) — out of scope here. **Decision: keep full local
data for all six stores in Phase 1** (unchanged app behavior), and fix only the read/write
*mechanics* so they don't fail or truncate as data grows. The genuine memory-bounded design — windowed
lists in-app, all analytics computed server-side — remains the documented long-term direction (§10),
now more clearly reachable given Blaze is active.

---

## 4. Components

1. **`FirebaseService.query(path, opts, callback)`** — new method alongside `get()`. `opts:
   {orderBy, direction, limit, startAfter}`. Builds a Firestore `structuredQuery` and POSTs to
   `:runQuery`. Fetches `limit + 1` and trims, so `hasMore` is exact at the page boundary.
2. **`PagingHelper.js`** (new `.pragma library`, pure — same convention as `BreakdownMath.js`) —
   `mergePage(existingItems, newItems, limit) -> {items, hasMore}` and `cursorFrom(items,
   orderByField) -> value|null`. Centralizes cursor bookkeeping so it isn't copy-pasted per store.
3. **Store changes (6 stores, §2.1 High priority list)** — each gains `hasMore`, `loadingMore`,
   `loadMore()`. First load becomes "first page" instead of "everything," then auto-continues
   calling `loadMore()` until `hasMore === false` — **all six**, per the §3.1 scope revision, so the
   app's in-memory data ends up complete either way, just fetched in bounded chunks instead of one
   unbounded request that silently truncates.
4. **`FirebaseService.putMany(path, docsById, callback)`** — chunks `Object.keys(docsById)` into
   groups of ≤500, issues one `:commit` per chunk sequentially, reports which chunk failed (if any)
   rather than swallowing partial failure.
5. **Write-path fix** — `OrdersStore._commit(arr, changedOrder)` (new optional param) calls
   `_pushToFirebase(changedOrder)` for the single touched doc instead of `_pushAllToFirebase()`;
   deletes call `FirebaseService.remove()`. `approveAllPending()` (the one legitimate multi-doc
   action) calls `FirebaseService.putMany()`. `StaffStore.addStaff()` switches to single-doc `PUT`.
   `ActivityLog.record()` switches to single-doc `PUT` of just the new entry.
6. **`functions/computeAnalysis.js`** (new HTTPS-callable, Admin SDK, same project as
   `recordMutation`) — verifies the ID token, derives `tenantId` server-side (never client-supplied,
   same as `recordMutation`), reads the ledger with its own internal Admin-SDK pagination
   (accumulator pattern — never materializes the whole ledger in Cloud Function memory either),
   runs the ported `RealisedMath`/`BreakdownMath` equivalent, returns the aggregated numbers only.
7. **Ported math library** (`functions/lib/realisedMath.js`, `functions/lib/breakdownMath.js`) —
   Node versions of the two pure QML libraries, same function bodies, CommonJS `module.exports`
   instead of `.pragma library`/`.import`. Kept in sync via shared fixtures (§7), not by file
   identity.
8. **`AnalysisService.qml`** (new singleton, same XHR + Bearer-token pattern as `Gateway.qml`) —
   `compute(period, viewMode, dims, scope, periodScoped, callback)` POSTs to `computeAnalysis`,
   async/callback-based (it's a network call). **Correction after investigation (§9.1): this is
   NOT a thin, shape-preserving passthrough.** `InventoryStore.realisedProfitByDimension` /
   `realisedTotals` / `realisedBucketWalk` are called *synchronously* at 15+ call sites in
   `SalesPage.qml` today (the main `_rebuildBreakdown()` view and a 5-call export flow) — a
   synchronous function cannot return a value that depends on an async network response. Actually
   cutting `SalesPage.qml` over requires rewriting its data-loading flow to be callback-driven, not
   swapping one function body. This is deferred — see §9.1 and §10.
9. **Doc fix (small, unrelated to the code but worth doing alongside):** SKILLS.md's Skill 12 still
   describes the old Realtime Database REST shape (`firebasedatabase.app`, single-arg
   `function(data)` callback). Skill 11's "Adding a New Store" template has the same stale
   single-arg callback shape in its `_fetchFromFirebase()` example. Neither matches the actual
   Firestore v1 REST `FirebaseService.qml` (`callback(ok, data)`, two args), which was updated in
   the P0/env-config work without updating these two skill docs. Correct both alongside this
   change so a future contributor copying Skill 11's template doesn't wire a callback that silently
   never fires its success branch.

---

## 5. Data Flow

**A — Paginated reads**
```
Store.loadMore()
  → FirebaseService.query(path, {orderBy, limit:50, startAfter})
      → POST {parent}:runQuery  (structuredQuery: from/orderBy/limit+1/startAt, tenant-scoped)
      → decode docs (existing _decodeDoc), drop the +1 overflow row if present
  → PagingHelper.mergePage(store.items, newItems, 50) → {items, hasMore}
  → store.items = merged; store.hasMore = hasMore; cursor = PagingHelper.cursorFrom(items, orderBy)
```

**B — Write-path fix**
```
Logic signal → DataModel handler → OrdersStore.updateOrder/addOrder/deleteOrder(...)
  → optimistic local array mutation (unchanged, instant UI)
  → _pushToFirebase(theOneChangedOrder)      ← replaces _pushAllToFirebase()
  → approveAllPending() → FirebaseService.putMany("orders", changedDocsById, cb)
       → chunks into ≤500-write commits, reports first failed chunk if any
```

**C — Analysis compute (backend built; SalesPage cutover deferred, see §9.1)**
```
[future, not yet wired] SalesPage's async-rewritten data flow
  → AnalysisService.compute(period, viewMode, dims, scope, periodScoped, callback)
      → POST computeAnalysis callable {env, period, viewMode, dims, scope, periodScoped}
          → CF: verify token → derive tenantId server-side → resolve env-scoped database
            → Admin SDK reads ledger collections in CF-internal pages (§6.5's honest scope note:
              paginated reads, single in-memory materialization -- not a true streaming reducer)
            → runs ported RealisedMath.totals / .byDimension / .bucketWalk equivalent
      ← callback(ok, {totals, byDimension, bucketWalk})   — async; SalesPage today calls the
        InventoryStore adapters SYNCHRONOUSLY at 15+ call sites, so this requires a real rewrite
        of its data-loading flow, not a drop-in swap (§9.1)
  → BreakdownBarCard renders once the callback resolves
```

---

## 6. Low-Level Design

### 6.1 `FirebaseService.query`

```
query(path, { orderBy, direction /* default "ASCENDING" */, limit, startAfter }, callback)
  → callback(ok, { items: [...], nextCursor: value|null, hasMore: bool })
```

Builds `structuredQuery: { from: [{collectionId}], orderBy: [{field:{fieldPath}, direction}],
limit: limit+1, startAt: startAfter !== undefined ? {values:[_encodeValue(startAfter)], before:false}
: undefined }`, tenant-scoped the same way `_resolvePath` already does for `get`/`put`. POSTs to the
tenant-scoped parent path + `:runQuery`. Response is an array of `{document, readTime}`; decode each
present `.document` via the existing `_decodeDoc`. If `decoded.length > limit`, trim the last row and
set `hasMore = true`; else `hasMore = false`.

### 6.2 `PagingHelper.js`

```js
.pragma library
function mergePage(existingItems, newItems, limit) {
    var hasMore = newItems.length > limit
    var page = hasMore ? newItems.slice(0, limit) : newItems
    return { items: (existingItems || []).concat(page), hasMore: hasMore }
}
function cursorFrom(items, orderByField) {
    if (!items || items.length === 0) return null
    return items[items.length - 1][orderByField]
}
```

### 6.3 `FirebaseService.putMany`

```
putMany(path, docsById, callback)
  → chunk Object.keys(docsById) into groups of ≤500
  → for each chunk (sequential, not parallel — avoids write contention/rate spikes):
      build writes via existing _buildCommitWrites, POST :commit
      on failure → stop, callback(false, { failedAtChunk: index })
  → all succeed → callback(true, null)
```

### 6.4 Write-path fix call sites

- `OrdersStore._commit(arr, changedOrder)` — when `changedOrder` is provided, call
  `_pushToFirebase(changedOrder)` (already exists, unused by `_commit` today) instead of
  `_pushAllToFirebase()`. Delete paths call `FirebaseService.remove("orders/" + orderId, cb)`.
  `_pushAllToFirebase()` itself is deleted once no call sites remain, except it's kept internally
  as the implementation backing the new `approveAllPending` → `putMany` path is a *different*
  function, not a rename of the old one (the old one built a `{id: doc}` object for ALL orders; the
  new one only for the *changed* subset).
- `StaffStore.addStaff()` — replace `_pushAllToFirebase()` with `FirebaseService.put("staff/" + id,
  newRecord, cb)`, matching the pattern `updateStaff`/`setAppUid` already use.
- `ActivityLog.record()` — replace `_pushAllToFirebase()` with `FirebaseService.put("activity_log/"
  + entry.id, entry, cb)`.

### 6.5 `computeAnalysis` contract

```
computeAnalysis({
  period,          // 0=Day 1=Week 2=Month 3=Year — same index as SalesPage's period selector
  viewMode,        // "revenue" | "profit" | "sold" | "purchased"
  dims,            // ["category","supplier"]
  scope: { window: {from,to}|null, channel, staffId, category, supplierId },
  periodScoped     // mirrors SalesPage._realisedScope(periodScoped)
}) -> {
  totals:     { gross, discount, net, tax, cogs, profit },
  byDimension: { category: {key -> {revenue,cogs,profit,tax,discount,margin}}, supplier: {...} },
  bucketWalk: { net: [...bins], profit: [...bins] }
}
```

- Auth/tenant derivation identical to `recordMutation` — verified token, server-derived `tenantId`,
  client-supplied tenant/actor fields ignored.
- **Must be env-aware from day one** — resolves the dev/test/prd database the same way
  `EnvConfig.js` does client-side. This closes the gap Skill 30 already flags for `recordMutation`'s
  write side, on the read side too, rather than adding a second unrelated gap.
- Internally reads via Admin SDK using its own cursor loop (batches of, e.g., 500), accumulating
  running totals/dimension maps rather than materializing the full ledger array — this is strictly
  better than porting the QML version's array-in-memory style verbatim, since even Admin SDK memory
  isn't unlimited.
- No idempotency/`requestId` needed — this is a read, not a mutation.

---

## 7. Error Handling

- **Pagination failures** — keep already-loaded items on screen; surface a retry affordance; reuse
  the existing `lastError`/`lastStatusCode` pattern on `FirebaseService`, don't introduce a new one.
- **Cursor stability** — each collection pages on a stable, monotonic field (`createdAt` for
  orders/staff/suppliers/inventory, `timestamp` for transactions/stock_batches) so a mid-scroll
  insert doesn't shift already-fetched pages.
- **`putMany` partial failure** — caller retries only the failed chunk's docs, not the whole action.
- **Token expiry** on any new `query`/`putMany`/`computeAnalysis` call — same
  `AuthService.ensureFreshToken()` dance `Gateway.drainNow()` already uses.
- **`computeAnalysis` failure** — `AnalysisService` surfaces `lastError`; `SalesPage` shows a retry
  state instead of rendering stale/zero charts. This stays within Skill 29's already-documented
  coverage ceiling (SalesPage can't load under `qmltestrunner`), so this path is verified manually,
  same as the rest of that page.
- **Env-mismatch guard** — `computeAnalysis` fails loudly (not silently) on a stage/database
  mismatch, matching `EnvConfig.js`'s fail-safe-to-prd philosophy.

---

## 8. Testing

- **`PagingHelper.js`** → new `tests/tst_PagingHelper.qml`, pure library, same fixture-based
  qmltestrunner style as Skill 27 (assert `mergePage`'s `hasMore`/trim logic and `cursorFrom` with
  fixture arrays — no network).
- **`FirebaseService.query`/`putMany`** — XHR-based, same coverage ceiling as the rest of
  `FirebaseService`; verified manually (device/desktop run), same convention as
  SalesPage/XlsxService (Skill 29).
- **`computeAnalysis` math parity** — extract the fixtures already embedded in
  `tst_RealisedMath.qml`/`tst_BreakdownMath.qml` into standalone JSON files consumed by BOTH those
  existing qmltestrunner tests AND new `functions/test/realisedMath.test.js` /
  `breakdownMath.test.js`. Identical expected output on both runtimes is what proves the "one source
  of truth" invariant (Skill 29) still holds now that the logic exists twice.
- **Write-path fix** — grep-guard: zero remaining bulk-collection `_pushAllToFirebase()` call sites
  after this lands, except where explicitly chunked via `putMany`.
- **Regression note** — `InventoryStore`/`StockBatchStore` (Gateway path) and `SupplierStore`
  (per-doc path) are verified unaffected (§2.2); add them to the PR description as "intentionally
  untouched" so a reviewer doesn't assume they were missed.

---

## 9. Phasing

- **Phase 0 (ship first, small diff, urgent):**
  - Write-path fix — the 3 call sites in §2.2, plus `FirebaseService.putMany()` for
    `approveAllPending`.
  - Immediate stop-gap for reads — follow `nextPageToken` in the *existing* `FirebaseService.get()`
    so nothing silently truncates while Phase 1 is being built. Small, non-breaking, no store
    changes required.
- **Phase 1:** `FirebaseService.query()` + `PagingHelper.js` + `loadMore()` wiring across all six
  stores in §2.1. **All six auto-page to exhaustion** (see §3.1) — full local data, same app
  behavior as before, just fetched in bounded chunks instead of one unbounded request that silently
  truncates. No "recent window" truncation for any store in this phase.
- **Phase 2:** `computeAnalysis` + `AnalysisService.qml`, env-aware Cloud Functions, ported math +
  shared-fixture parity tests. **Delivered as a standalone, callable backend capability.** Does
  *not* include cutting `SalesPage.qml` over to it — see §9.1.
- **Phase 3 (future, not scheduled):** the genuine memory-bounded redesign — `OrdersStore` /
  `TransactionStore` / `StockBatchStore` move to real windowed loading in-app, with Dashboard KPIs,
  import dedup, and FIFO consumption redesigned to not require the full local set (targeted queries
  or server-side logic instead). Blaze is already active, so nothing here is blocked on billing —
  this is purely an engineering-scope decision for later.

### 9.1 SalesPage.qml cutover — deferred as its own future project (not part of this spec)

The original plan (earlier draft of this section) was to "cut `SalesPage.qml` over from local
`RealisedMath`/`BreakdownMath` scans to the compute endpoint" as part of Phase 2, on the assumption
that `InventoryStore.realisedProfitByDimension` / `realisedTotals` / `realisedBucketWalk` could
become thin, shape-preserving pass-throughs to `AnalysisService.compute(...)`.

**That assumption was wrong, found during implementation.** Those three functions are called
*synchronously* — they `return` a value immediately — at 15+ call sites across `SalesPage.qml`:
the main `_rebuildBreakdown()` view (the on-screen hero/charts) and a 5-call export flow that builds
one export document from five separate per-dimension calls. `AnalysisService.compute(...)` is
necessarily asynchronous (it's a network request to a Cloud Function). A synchronous function
cannot return a value that depends on an async response — there is no "thin passthrough" version of
this swap.

Actually cutting over means rewriting `SalesPage.qml`'s data-loading flow to be callback-driven:
every chart/hero needs a loading state, `_rebuildBreakdown()` needs restructuring around a callback,
and the export flow's 5 separate dimension calls should be batched into one `computeAnalysis`
request (the API already supports this via `dims: [...]`) — which means rewriting the export
function's control flow too. That's a substantial change to a large file with **no automated test
coverage** (Skill 29's coverage ceiling — `SalesPage.qml` can't load under `qmltestrunner`, so this
would be manually-verified-only, same risk profile as the rest of that page).

**Decision: this is explicitly out of scope for this design (see §10) and deferred as its own,
separate, dedicated future project** — not scheduled, not designed yet. `computeAnalysis` and
`AnalysisService.qml` remain built, tested (as far as a container without a real Firestore/
qmltestrunner allows), and available for whenever that future project is taken up. Nothing about
their contract needs to change to support it later.

Each phase is independently shippable and testable — same P0-then-fast-follow convention this repo
already established.

---

## 10. Out of Scope

- **The `SalesPage.qml` cutover to `AnalysisService`** (§9.1) — found during implementation to be a
  genuine async rewrite of a large, only-manually-verifiable file, not the thin passthrough
  originally assumed. Deferred as its own future project; `computeAnalysis`/`AnalysisService.qml`
  are built and available whenever that project is taken up.
- **The Phase 3 redesign described above** — deferred, not because of any technical blocker, but
  because it touches Dashboard KPIs, import dedup, and FIFO consumption simultaneously and deserves
  its own dedicated spec rather than being folded into this one.
- Persisted rollup/aggregate documents (§3 — documented future upgrade, not built now; the
  `computeAnalysis` contract is designed so this swap wouldn't change the client side at all).
- Migrating `orders`/`staff`/`suppliers` writes onto the `Gateway`/ledger pattern — that's the P0
  spec's own deferred fast-follow and is orthogonal to this design (this design just stops those
  stores from bulk-overwriting; it doesn't route them through the compliance gateway).
- Native Firestore aggregation queries (`runAggregationQuery`) — rejected in design discussion: no
  group-by, and can't express the FIFO/stamped-only/price_adjust exclusion rules that live in
  `RealisedMath.js`.
- Offline write queueing for the paginated read paths — reads simply retry; no new outbox needed
  (the existing `OutboxStore` is a write-path concept, untouched here).

---

## 11. Required Existing-Code Changes

- `FirebaseService.qml` — add `query()`, add `putMany()`.
- `InventoryStore.qml`, `OrdersStore.qml`, `StaffStore.qml`, `StockBatchStore.qml`,
  `SupplierStore.qml`, `TransactionStore.qml` — add `hasMore`/`loadingMore`/`loadMore()`; change
  `_fetchFromFirebase()` to fetch the first page instead of everything.
- `OrdersStore.qml` — `_commit()` gains the `changedOrder` param; `approveAllPending()` switches to
  `putMany`; `_pushAllToFirebase()` removed once no call sites remain.
- `StaffStore.qml` — `addStaff()` switches to single-doc `PUT`.
- `ActivityLog.qml` — `record()` switches to single-doc `PUT`.
- New: `qml/helper/PagingHelper.js`, `qml/model/AnalysisService.qml` (built, available, **not yet
  called from anywhere in the app** — see §9.1), `functions/index.js`'s `computeAnalysis` export,
  `functions/lib/{orderMath,realisedMath,breakdownMath}.js`.
- `functions/index.js` — `scopedDb(env)` helper added; `db` changed from a module-level global to
  per-request (`deriveContext(db, uid)`, `deleteCollection(db, path)` now take `db` explicitly);
  `recordMutation`/`provisionMember`/`runCutover` all updated consistently.
- `Gateway.qml` — injects `env: FirebaseService.environment` into its 3 outgoing request bodies.
- **`InventoryStore.realisedProfitByDimension` / `realisedTotals` / `realisedBucketWalk` are
  UNCHANGED** — still call `RealisedMath` locally over `TransactionStore.entries`/`getById`, exactly
  as before this design's work started. The originally-planned passthrough to
  `AnalysisService.compute(...)` turned out to require an async rewrite of `SalesPage.qml`, not a
  drop-in swap (§9.1) — deferred as its own future project, not attempted here.
- SKILLS.md — correct Skill 12 (real Firestore v1 REST shape, not RTDB) and Skill 11's
  `_fetchFromFirebase()` template (`callback(ok, data)`, not single-arg `function(data)`).
