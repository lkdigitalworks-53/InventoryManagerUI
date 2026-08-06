# Code review — Async Write Sequencing & Multi-Device Conflict Resolution

**Reviewer:** Claude (session started 2026-08-06), acting as senior reviewer per Taher's request.
**Scope:** the full feature on `docs/async-write-sequencing-design`, from its first commit
`430bd7e` ("docs: design + test plan...") through `b51779b` (branch tip) — 13 commits, 32 files,
+4031/-352 lines. Design: `docs/superpowers/specs/2026-07-29-async-write-sequencing-design.md`.
Test plan: `docs/superpowers/specs/2026-07-29-async-write-sequencing-test-plan.md`. Prior session's
own log: `docs/superpowers/specs/2026-07-29-async-write-sequencing-CHECKPOINT.md` (673 lines, read
in full — many gaps below were already self-flagged there; this review calls out explicitly which
findings are NEW vs. already-known).
**Method:** `/superpowers:requesting-code-review` (read every touched file, no subagent dispatch
available in this environment, so performed directly at the same rigor), `/qt-development-skills:qt-qml-review`,
`/ponytail:ponytail-review`.
**Status: IN PROGRESS.** This is round 1 of the review, committed as a checkpoint per Taher's
request before continuing. Round 2 (dialogs, `_tryAdjustOrder`, deterministic QML lint, ponytail
pass, functions/test + tests/*.qml audit) is not yet done — see open items at the bottom.

---

## How to read this document

Severity follows the code-reviewer template: **Critical** (must fix — bugs, data-integrity risk,
broken functionality), **Important** (should fix — architecture gaps, missing coverage),
**Minor** (nice to have). Each entry says whether it's a **NEW finding** (not mentioned anywhere in
the design doc, test plan, or checkpoint) or a **known gap** (already self-flagged by the prior
session, included here for completeness because Taher asked for a full accounting, not just what's
new).

---

## Strengths (round 1 read)

- The four components are individually well-reasoned and mostly correctly implemented in
  isolation: `applyDelta`'s all-or-nothing floor logic, `_deepEqual`'s order-insensitive CAS
  compare, `lockLogic.js`'s expired/same-holder/reject branching, and the `_classifyDeltaResponse`/
  `_classifyAcquireResponse` terminal-vs-transient split are all clean, dependency-injected, and
  individually correct where they're actually wired up.
- `functions/lib/` is genuinely unit-tested (85/85 per the checkpoint) with real RED-then-GREEN
  discipline and a fake Firestore double that was upgraded (`makeFakeDbWithData`) specifically
  because the old one would have silently passed against the new CAS/delta logic.
- The session's own checkpoint is unusually honest about what it couldn't verify (no Qt toolchain
  in that sandbox) and already caught two real, serious bugs itself
  (`_classifyDeltaResponse`/`_classifyAcquireResponse` conflating infra failure with a real
  decision; `OrdersStore._clone()`/`addOrder` field-whitelist drift). That's good process, and it's
  why several of the findings below are things the prior session already knew and documented
  rather than things it missed — I've tried to be precise about which is which below.
- `InventoryStore.deductStock` itself (the one caller that WAS fully converted) is correctly
  implemented: it doesn't compute the new stock value locally at all, it takes
  `result.after.stock` from the server response — exactly right.

---

## Critical (must fix)

### C1 — Component 3's client-side conflict handling was never built (NEW finding)
**Files:** `qml/model/Gateway.qml:302-323` (`_send`), `:344-375` (`_sendBatch`)

The design doc §5 is explicit: `Gateway._send`/`_sendBatch` must distinguish a `409 conflict`
response from a plain network/5xx failure, and on conflict must NOT `markFailed` (that retries
forever with the same stale `before`) — instead drop the item, patch the calling store's cache from
the response's `current`, and notify the user via a new `Gateway.mutationConflicted(entity,
entityId, current)` signal each store connects to.

None of this exists. `_send` and `_sendBatch` both do:
```js
var ok = xhr.status >= 200 && xhr.status < 300
if (ok) { OutboxStore.markSent(...) } else { OutboxStore.markFailed(...) }
```
A 409 falls into the `else` branch exactly like a timeout or a 500. `markFailed` bumps the backoff
and retries with the **same** `before` — which the server will keep rejecting, since a real
conflict means `before` is stale by construction. There is no `mutationConflicted` signal anywhere
in the codebase (confirmed via full-repo grep). Component 3 is fully implemented and tested
server-side and is **completely inert on the client** for every entity that goes through plain
`recordMutation` — orders, staff, suppliers, and any inventory field edit that isn't a quantity
delta.

**Impact:** the one thing this whole design exists to prevent — a genuine cross-device conflict —
now produces a permanently-stuck outbox item (capped ~10-minute backoff, retried forever), a local
cache that never reconciles with the server's actual state, and a user who never finds out their
edit didn't land. This is worse in one respect than the pre-fix behavior: before this branch, a
racing write would silently overwrite the other (data loss, but the UI moved on); now it silently
never lands at all (no data loss, but a permanently wrong local state and a queue that never
drains).

**Fix shape:** implement the `mutationConflicted(entity, entityId, current)` signal on `Gateway`,
have `_send`/`_sendBatch` parse the response body, check for `status === 409 && body.conflict`,
and on conflict call `OutboxStore.markSent` (or equivalent removal — it must NOT retry) and emit
the signal with `current` so each store can patch its own array, plus a `Toast.show(...)` per the
design doc. This needs the same `_classify*Response` treatment `_sendDelta`/`LockManager.acquire`
already got — reuse that pattern rather than inventing a third shape.

### C2 — `InventoryStore.restock()` was never converted to `recordDelta` (mostly known, but the checkpoint's own claim about it is wrong)
**File:** `qml/model/InventoryStore.qml:808-850`

The design doc §6 explicitly lists `InventoryStore.restock(...) → recordDelta("inventory",
productId, {stock: +addedQty})` as one of five callers to convert. It wasn't done — `restock()`
still computes `arr[i].stock += addedQty` from the local cache and sends it via the old
`Gateway.recordMutation("inventory", productId, "update", before, changed)` (whole-record CAS,
not a delta).

Confirmed by grep: `Gateway.recordDelta(` has exactly **one** call site in the entire `qml/`
tree — `InventoryStore.deductStock`. `restock` is not converted.

This matters because of who flagged it and how: the checkpoint's own audit trail contradicts
itself. Early on (search step, line 74) it's listed as "not yet individually audited." Later
(line 254, 307) it's listed under "Callers ... not yet switched to `recordDelta`." But later still
(line 621) the checkpoint asserts as fact: *"Component 4's caller conversion was completed for
`InventoryStore.deductStock`/`restock` but never for `StockBatchStore`"* — and the
`README.md`/`SKILLS.md` narrative around it reads as if the delta conversion is done for
inventory generally. It isn't; only `deductStock` was actually converted. **This means the
project's own status tracking is wrong on this point, not just incomplete** — worth fixing the
docs at the same time as the code, or a future session will trust the checkpoint's claim and move
on without re-checking.

**Compounds directly with C1**: since `restock` still goes through the CAS path, and the client
never handles 409s (C1), two staff restocking the same product close together will produce one
silently-stuck retry loop with a permanently inflated local stock count.

### C3 — `StockBatchStore.consumeFifo()` runs before the stock delta resolves, with no rollback on rejection (NEW finding)
**Files:** `qml/model/DataModel.qml:472-514` (`_tryCompleteOrder`'s per-line loop),
`qml/model/StockBatchStore.qml:225-273` (`consumeFifo`)

Per line item, `_tryCompleteOrder` calls `StockBatchStore.consumeFifo(productId, qty)`
**synchronously** — it decrements local batch state and fires a fire-and-forget
`Gateway.recordMutation("stock_batch", ..., "update", ...)` per touched batch — and only *after*
that does it call `InventoryStore.deductStock(...)`, whose callback may come back rejected
(`insufficient-quantity`, exactly the case Component 4's `floors` mechanism exists to produce).

On rejection, `_afterAllDeltas()` marks the order `"out of stock"` and surfaces `stockErrorMsg` —
but nothing undoes the `consumeFifo` (and, if it ran, `topUpOldest`) calls that already fired for
that line or any earlier line in the same order. The batches are already decremented, both locally
and on the server, for an order that didn't complete. There's no compensating `restoreFifo` call
in the rejection branch.

This is distinct from the *already-flagged* "StockBatchStore still uses whole-record
`recordMutation` instead of `recordDelta`" gap (checkpoint lines 618-624, real and still open) —
that one is about the FIFO writes being vulnerable to the original clobber bug. This finding is
about **sequencing**: even leaving the clobber issue aside, the round-4 change introduced a reject
path that the FIFO step was never taught to unwind. Before round 4, there was no reject path at
all post-precheck (everything just proceeded), so this specific failure mode looks like a new
consequence of this session's own sequencing work, not a pre-existing condition carried over.

**Impact:** on a genuine concurrent-oversell rejection (two devices completing orders for the same
product near-simultaneously, which is exactly the scenario this whole design targets), the failed
order's line items will have already consumed FIFO batch quantity that no sale actually booked —
a real, silent inventory-ledger drift, in the one place this design was built to eliminate drift.

**Fix shape:** either (a) don't run `consumeFifo`/`topUpOldest` until each line's `deductStock`
callback has confirmed success (defer the FIFO walk into the callback, at the cost of not knowing
which batches to display until the delta resolves), or (b) keep the current up-front FIFO walk but
call `StockBatchStore.restoreFifo` for every already-touched batch when `deltaFailed` is true,
symmetric to how returns already restore FIFO. (b) is probably the smaller change given the
existing `restoreFifo` function already does exactly this job for the returns flow.

### C4 — `LockManager._classifyAcquireResponse` doesn't check HTTP status, misclassifying unrelated failures as "someone else is editing" (NEW finding)
**File:** `qml/model/LockManager.qml:86-91`

```js
function _classifyAcquireResponse(status, body) {
    var isRealResponse = body !== null && typeof body === "object" && typeof body.ok === "boolean"
    if (!isRealResponse) return { granted: false, holder: null, reason: "error" }
    if (body.ok === true) return { granted: true, holder: null, reason: null }
    return { granted: false, holder: body.holder || null, reason: "denied" }
}
```
Every well-formed `{ok:false}` response is classified `reason: "denied"` regardless of *why* the
server said no. But `acquireLock`'s handler in `index.js` returns well-formed `ok:false` bodies for
several cases that are NOT "someone else holds the lock": `400 missing-fields`, `401
invalid-token`, `403 no-tenant-context`, and `500 lock-failed` (the transaction's own catch block)
all produce valid JSON with a boolean `ok` field. Each of those gets bucketed as `"denied"` here,
with `holder: body.holder || null` — for a 401/403/500 that's `null`, so a caller showing "Priya is
updating this" would instead show a blank/garbled holder message for what's actually an auth or
server problem.

This is the **same bug class** the checkpoint documents fixing for `_classifyDeltaResponse` (don't
conflate infrastructure failure with a real business decision) — reintroduced here because this
sibling function checks `body.ok` but never checks `status`. `_classifyDeltaResponse` narrows
"terminal" to `status >= 400 && status < 500` before trusting the body; `_classifyAcquireResponse`
has no equivalent guard at all, and doesn't even single out 409 (the only status the design
actually assigns to a real denial) from any other 4xx/5xx.

**Compounding factor:** `LockManager.acquire()`/`_post()` never call `AuthService.ensureFreshToken()`
before posting (every other Gateway network call that touches auth-sensitive endpoints does). A
dialog opened after the ID token's gone stale is a realistic way to actually hit the 401 case this
bug mishandles, not just a theoretical one.

**Fix shape:** thread `status` into the classification the same way `_classifyDeltaResponse` does;
only treat `status === 409` with a well-formed `holder` as `"denied"`; everything else well-formed
but not `ok:true` should be `"error"`, same bucket as a malformed body. Also add the missing
`AuthService.ensureFreshToken()` call in `acquire()` for consistency with the rest of `Gateway`.

### C5 — Dead code path (`OrdersStore.approveAllPending` / `Logic.approveAllPending` signal) bypasses every safeguard this feature adds (NEW finding, currently unreachable but a real landmine)
**Files:** `qml/model/OrdersStore.qml:606-619`, `qml/model/DataModel.qml:172-175`,
`qml/logic/Logic.qml:43`

`qml/logic/Logic.qml` declares `signal approveAllPending()`. `DataModel.qml`'s `onApproveAllPending`
handler calls `OrdersStore.approveAllPending()`, which flips `status` from `"pending"` to
`"completed"` directly and pushes one `Gateway.recordMutations` batch call — **no stock deduction,
no FIFO consumption, no sale/transaction record, no lock, no delta, no CAS-aware path at all.**

Confirmed by grep across the whole `qml/` tree: **nothing ever calls `logic.approveAllPending()`**
— the signal is declared and handled but never emitted. The actual "Approve all" button
(`OrdersPage.qml:213`) calls the page-local `_approveAllPending()` function directly, which
correctly chains through `dataModel.tryCompleteOrder()` per order (the real, safe path — see
Strengths). So today this is **dead code, not a live bug** — but it's a fully-wired, easy-to-trigger
landmine: the two function names (`OrdersStore.approveAllPending` vs.
`OrdersPage._approveAllPending`) are nearly identical, and a future refactor that wires the button
to the signal instead of the direct call (a completely natural-looking change, and arguably the
more "correct-looking" MVC direction) would silently start completing orders with none of this
session's work applied — no stock deducted, no revenue booked, immune to every lock/CAS/delta
protection. I'd flag this for deletion or an explicit `// DEAD — do not wire this up, see
OrdersPage._approveAllPending` guard comment at minimum, not leave it live and misleadingly named.

### C6 — Leftover debug logging, one of it dumping full document contents (NEW finding, small but real)
**Files:** `functions/lib/gatewayLogic.js:154-156`, `functions/index.js:127`

```js
// gatewayLogic.js, inside applyMutation, using tab indentation that doesn't
// match the rest of the file — a tell that this was pasted in during
// debugging and never cleaned up:
			console.log("[applyMutation]: calling _deepEqual");
			console.log("[applyMutation]: current - ", JSON.stringify(current));
			console.log("[applyMutation]: before - ", JSON.stringify(params.before));
```
```js
// index.js, inside exports.recordMutation:
		console.log("[recordMutation]: calling applyMutation");
```
These read as exactly what they look like — debug statements added while chasing the CAS
before/after-shape bug (checkpoint's "Severe bug found by Taher's own debugging" section) and never
removed. Beyond code cleanliness, `current`/`before` are full working-tier documents — for `order`
that includes customer name/phone/email, for `inventory` that includes cost price — logged
unconditionally to Cloud Functions' log stream on **every single mutation**, forever, in
production. That's a real data-handling concern on top of the noise/cost of logging on every write,
not just a style nit.

---

## Important (should fix)

### I1 — `recordMutationsBatch` has no CAS check at all (known gap, but worth restating plainly)
**File:** `functions/lib/batchMutationLogic.js` (untouched by this branch — confirmed via diff
stat, not part of the 32 changed files)

`applyMutationsBatch` blind-writes every item exactly like pre-Component-3 `applyMutation` did —
no `_deepEqual` check, no conflict rejection. This path is used by the legitimate
`OrdersPage._approveAllPending` → `dataModel.tryCompleteOrder` → ... no, actually the order
*status* update inside `_tryCompleteOrder` goes through single-item `recordMutation`, not the
batch path — but `OrdersStore.approveAllPending()` (C5, dead code) and any other bulk caller of
`Gateway.recordMutations` would be exposed. Not this branch's regression (the file wasn't touched),
but it means Component 3's guarantee is **not actually uniform across the app** the way
`README.md`'s Concurrency section implies ("a backstop... rejects a mutation whose `before` doesn't
match") — it only covers the single-item path. Worth a follow-up decision: extend CAS to
`applyMutationsBatch`, or explicitly document the batch path as CAS-exempt and why.

### I2 — Bulk order approval never acquires a lock (known implicitly, not called out in the design's own component table)
**File:** `qml/pages/OrdersPage.qml:421-452`

The design doc §7.1 table lists lock points as "Complete action, return/adjust flow" for orders,
attached at the dialog level (`OrderDetailDialog.openFor()`). `_approveAllPending()`'s sequential
loop calls `dataModel.tryCompleteOrder(orderId, ...)` directly, never through
`OrderDetailDialog`, so it never acquires a per-order lock. A second device opening
`OrderDetailDialog` on one of the same pending orders while a bulk approve is mid-flight is not
turned away at the lock — it relies entirely on Components 1/3/4 to sort out the resulting race,
and C1 above means Component 3's half of that safety net is currently inert. Not necessarily wrong
as a product decision (locking every order in a bulk operation may be undesirable UX), but it's an
interaction the design doc doesn't discuss, and given C1, currently a real gap in practice, not
just a theoretical one.

### I3 — `acquireLock`'s request validation doesn't check `entity` against the known entity list (NEW, minor-severity but worth a line)
**File:** `functions/lib/lockLogic.js:71-85` (`validateAcquireRequest`)

Unlike `validateMutationRequest`/`validateDeltaRequest`, which both reject an unrecognized `entity`
against `ENTITY_COLLECTIONS`, `validateAcquireRequest` only checks that `entity`/`entityId`/
`requestId` are non-empty strings. A typo'd or made-up entity name silently creates a real lock doc
under `locks/{entity}_{entityId}` for an entity that doesn't exist in `ENTITY_COLLECTIONS` at all.
Low risk (locks are server-authenticated, not directly reachable by an unauthenticated client, and
a typo would just make a lock nobody else contends for), but it's an inconsistency with the
sibling validators worth closing for the same reason the design leans on allowlists everywhere
else: fail loud on the unexpected rather than silently accepting it.

---

## Not yet reviewed (round 2, next)

Per Taher's request, committing round 1 now and continuing immediately with:
- The three lock-wired dialogs (`OrderDetailDialog`, `EditProductDialog`, `StaffDetailDialog`) —
  acquire/release correctness, the already-flagged `ConfirmReturnSheet` lock-span gap, and the
  `_lockState` (`pending`/`granted`/`denied`/`error`) wiring against C4 above.
- `_tryAdjustOrder`'s exchange/added-units path (the ~275-line function, deliberately not given
  the full async-await treatment per the checkpoint) — verify the "known, deliberately kept
  limitation" claim and check for anything beyond what's already flagged.
- `functions/test/gatewayLogic.test.js`, `lockLogic.test.js`, and every `tests/tst_*.qml` file
  added/extended by this branch — do the tests actually exercise the bugs above (several of them,
  e.g. C1/C4, look like exactly the kind of thing that SHOULD have been caught by
  `tst_Gateway.qml`'s "recordDelta's ... unknown-entity paths" coverage the checkpoint claims
  exists, but evidently wasn't extended to plain `recordMutation`'s conflict path at all).
- Deterministic QML lint (`qt_qml_lint.py`) across every touched `.qml` file.
- `ponytail-review` pass for over-engineering/duplication (C5's two near-duplicate "approve all"
  implementations is an obvious candidate, there may be more).
- Cross-check `firestore.rules` actually locks down `locks/**` as the design doc claims (§4) — not
  yet independently verified in this review.
