# Code review — Async Write Sequencing & Multi-Device Conflict Resolution

**Reviewer:** Claude (session started 2026-08-06), acting as senior reviewer per Taher's request.
**Scope:** the full feature on `docs/async-write-sequencing-design`, from its first commit
`430bd7e` ("docs: design + test plan...") through `b51779b` (branch tip) — 13 commits, 32 files,
+4031/-352 lines. Design: `docs/superpowers/specs/2026-07-29-async-write-sequencing-design.md`.
Test plan: `docs/superpowers/specs/2026-07-29-async-write-sequencing-test-plan.md`. Prior session's
own log: `docs/superpowers/specs/2026-07-29-async-write-sequencing-CHECKPOINT.md` (673 lines, read
in full). Note on authorship: the branch's final commit (`b51779b`) was made directly by Taher, not
through a reviewed AI session — flagged where relevant below, not to assign blame, but because it's
untested and is where the single most severe bug in this review lives.
**Method:** `/superpowers:requesting-code-review` (every touched file read directly — no subagent
dispatch tool is available in this environment, so the code-reviewer template's criteria were
applied directly rather than via a dispatched subagent), `/qt-development-skills:qt-qml-review`
(deterministic lint run over every touched file, findings triaged for signal vs. pre-existing
codebase convention), `/ponytail:ponytail-review` (duplication/over-engineering pass).
**Status: COMPLETE.** Round 1 (server-side `functions/lib/`, `Gateway.qml`/`OutboxStore.qml`/
`LockManager.qml`, the order-completion path) and round 2 (the three lock-wired dialogs,
`_tryAdjustOrder`, `firestore.rules`, the QML/Node test suites, lint, ponytail) are both done.

---

## How to read this document

Severity: **Critical** (must fix — bugs, data-integrity risk, broken functionality, security),
**Important** (should fix — architecture gaps, missing coverage), **Minor** (nice to have). Each
entry says whether it's a **NEW finding** (not mentioned anywhere in the design doc, test plan, or
prior checkpoint) or a **known gap** (already self-flagged by the prior session — included for
completeness since Taher asked for a full accounting, not just what's new). Findings are ordered by
severity/blast-radius, not by discovery order or file location.

---

## Strengths

- The four components are individually well-reasoned and mostly correctly implemented in
  isolation: `applyDelta`'s all-or-nothing floor logic, `_deepEqual`'s order-insensitive CAS
  compare, `lockLogic.js`'s expired/same-holder/reject branching are all clean, dependency-injected,
  and correct where they're actually wired up.
- `functions/lib/` is genuinely unit-tested (85/85 per the checkpoint) with real RED-then-GREEN
  discipline and a fake Firestore double that was upgraded specifically because the old one would
  have silently passed against the new CAS/delta logic.
- The prior session's own checkpoint is unusually honest about what it couldn't verify (no Qt
  toolchain in that sandbox) and already caught two real, serious bugs itself
  (`_classifyDeltaResponse` conflating infra failure with a real decision; the `_normalizeOrder`
  field-whitelist drift that motivated `afea51d`). That's good process — several findings below are
  things the prior session already knew and documented, and I've tried to be precise about which is
  which.
- `InventoryStore.deductStock` (the one caller that WAS fully converted to `recordDelta`) is
  correctly implemented: it never computes the new stock value locally, it takes `result.after.stock`
  from the server response — exactly right, and the pattern everything below should be measured
  against.
- The lock-acquire-in-background-only-gate-Save pattern in all three dialogs (`OrderDetailDialog`,
  `EditProductDialog`, `StaffDetailDialog`) is a genuinely good UX call — reads are never blocked on
  a network round-trip, only the write is gated. The `_lockState` machine (`pending`/`granted`/
  `denied`/`error`) is applied identically and correctly across all three dialogs.
- `_classifyDeltaResponse`/`_classifyAcquireResponse`'s "error" vs "denied" distinction is the right
  idea, and the tests for it (`tst_Gateway.qml`, `tst_LockManager.qml`) directly encode the real
  incident that motivated it (a tester seeing "someone else is editing" with nobody else online) —
  good regression-test hygiene, tracing a test back to a real bug.

---

## Critical (must fix)

### C1 — `OrdersStore._normalizeOrder` reads `consumption` off the wrong object: crashes on any order line whose product is gone, and silently discards FIFO lineage on every single order, always (NEW, highest confidence, highest blast-radius)
**File:** `qml/model/OrdersStore.qml:302-320`, introduced in the branch's final commit `b51779b`

```js
var inv = lp.productId ? InventoryStore.getById(lp.productId) : null;
...
var consClone = [];
if (Array.isArray(inv.consumption)) {          // <-- inv, not lp
    for (var ci = 0; ci < inv.consumption.length; ++ci) {
        var c = inv.consumption[ci];
        consClone.push({ batchId: c.batchId || "", ... });
    }
}
```
`inv` is the **inventory/product** record (`InventoryStore.getById`), looked up two lines above for
tax resolution. `InventoryStore.qml` has no `consumption` field anywhere on a product record
(confirmed by grep across the whole file) — `consumption` is an **order line's own** field (which
batches THIS line of THIS order drew from). This function needs `lp.consumption` (the raw order
line being normalized), exactly as it read before this commit.

**Two distinct failures result:**
1. **Silent, universal data loss.** `Array.isArray(inv.consumption)` is `false` for every real
   product, so `consClone` is always `[]` — every order's FIFO lineage (`batchId`, `supplierId`,
   `qtyConsumed`, `unitCost`) is wiped on every normalization. `_normalizeOrder` runs via `_clone()`
   on essentially every order mutation (that's the whole point of the commit that introduced this —
   "used both when rebuilding the local cache... and when constructing the payload for a brand-new
   order"). This is exactly the lineage the extensive comments elsewhere in this codebase (see
   `_tryAdjustOrder`'s "bug 14" commentary) say is required for Revenue-by-supplier and COGS
   accuracy in order-sourced reports — this commit reintroduces that exact class of bug, universally,
   on every order, not as an edge case.
2. **Hard crash.** If `lp.productId` is falsy, `inv` is explicitly `null` (see the ternary above);
   `InventoryStore.getById` also returns `null` for a productId with no match — which happens for
   real the moment a product referenced by any historical order is deleted (`InventoryStore.
   deleteProduct` exists and is reachable). Either way, `inv.consumption` throws `TypeError: Cannot
   read property 'consumption' of null`, crashing `_normalizeOrder` — and therefore crashing
   whatever touched that order (open the dialog, adjust it, or even just having it pass through
   `_clone()` as part of an unrelated bulk operation).

**This was traced precisely:** compared against the pre-`b51779b` state (`afea51d`), the function
this replaced correctly read `lp.consumption`/`p.consumption` (there were two near-duplicate
`_normalizeOrder` functions before this commit; this commit correctly consolidated them into one —
a good instinct — but introduced this variable substitution while merging the two bodies together).

**The good news:** `tests/tst_OrdersStore_normalization.qml` (added in the prior commit, `afea51d`)
already exercises `_normalizeOrder` directly. Its fixture line item has `productId: "SKU-1"` with no
seeded `InventoryStore` product behind it — meaning `InventoryStore.getById("SKU-1")` returns `null`
in that test context, so **this exact test would throw a TypeError the moment it's actually run**,
before even reaching its assertions. Nobody has run `qmltestrunner` yet (every session's caveat, this
one included), so this hasn't surfaced — but it's sitting there ready to catch this the moment
someone does. Worth running that suite specifically before anything else, given this.

**Fix:** change `inv.consumption` → `lp.consumption` (two occurrences: the `Array.isArray` check and
the loop). One-line-class fix, but please add an explicit regression test for "order line references
a deleted/unknown product" alongside it — the existing test fixture happens to hit this path by
accident, not by design, and a future "helpful" fix to seed `InventoryStore` in the test setup would
silently remove the only thing currently catching this.

### C2 — `firestore.rules` was never updated to lock down the new `locks/**` collection: Component 2's entire guarantee is unenforced (NEW, security-relevant)
**File:** `firestore.rules` (confirmed via `git log` — untouched anywhere in this branch's 13
commits, `430bd7e^..b51779b`)

The design doc §4 is explicit: *"`firestore.rules`: deny direct client read/write on `locks/**`,
same lockdown pattern as `audit_log`/`transactions`/etc. — only the Cloud Functions below may touch
it."* This was never done. The rules file's ledger-collection guard
(`isLedgerCollection(name)` at line 46) only lists `['audit_log', 'transactions', 'stock_batches',
'stock_movements']` — `locks` isn't in it, and there's no dedicated `match /locks/{lockId}` block
either (compare to the explicit `match /audit_log/{docId} { allow write: if false; }` block that
DOES exist). That means the generic tenant-collection fallback at the bottom of the file applies:

```
match /{collection}/{docId} {
  allow read: if isMember(tenantId);
  allow create, update, delete: if isMember(tenantId) && !isLedgerCollection(collection);
}
```

**Any signed-in tenant member can read, create, update, or delete lock documents directly**,
completely bypassing `acquireLock`/`releaseLock`'s transactional TTL/holder logic. Concretely, any
client (a bug in a future app version, a second app built against the same backend, or just the
Firebase console/REST API) can: delete another device's active lock to instantly free a record it
believes it holds exclusively; write a fake lock with a far-future `expiresAt` to deny a record to
everyone; or overwrite `holderUid`/`holderName` to impersonate holding a lock without ever calling
`acquireLock`. This defeats Component 2 — the single largest piece of this whole feature — as an
actual guarantee; today it's advisory only, resting entirely on every client behaving.

**Fix:** add a `match /locks/{lockId} { allow read, write: if false; }` block (clients never need
direct access — both dialogs only ever go through `LockManager` → the Cloud Functions), and add
`'locks'` to `isLedgerCollection`'s name check for defense in depth against the generic fallback.
This needs a rules deploy, same as the P0 ledger lockdown the checkpoint references as already
live — it's the same mechanism, just never extended to this new collection.

### C3 — Component 3's client-side conflict handling was never built (NEW)
**Files:** `qml/model/Gateway.qml:302-323` (`_send`), `:344-375` (`_sendBatch`)

Design doc §5: `Gateway._send`/`_sendBatch` must distinguish a `409` CAS-conflict response from a
plain network/5xx failure, and on conflict must NOT `markFailed` (retries forever with the same
stale `before`) — instead drop the item, patch the calling store's cache from the response's
`current`, and notify via a new `Gateway.mutationConflicted(entity, entityId, current)` signal each
store connects to. None of this exists — confirmed via full-repo grep, `mutationConflicted` appears
nowhere. `_send`/`_sendBatch` both do `ok = status in [200,300)`; a 409 falls into the same `else`
branch as a timeout, and `OutboxStore.markFailed` retries with the **same** `before` on a capped
(~10 min) backoff, forever, since the server will keep rejecting a request whose `before` is stale
by construction.

**Impact:** the exact thing this design exists to prevent — a genuine cross-device conflict — now
produces a permanently-stuck outbox item, a local cache that never reconciles, and a user who's
never told their edit didn't land. This is a *different* failure mode than the pre-fix behavior
(silent overwrite → the edit lands but wrong) rather than strictly worse, but it's not the fix the
design promised either.

**Test coverage gap, not just implementation gap:** `tst_Gateway.qml` tests `_classifyDeltaResponse`
(the sibling helper used for `recordDelta`) at 409, but never tests `_send`'s or `_sendBatch`'s
actual status-branching logic at all — the file's own comment (line 27) says the XHR success/
conflict branch "isn't testable here." That's true of the network round-trip, but the missing piece
is a pure classification helper (like `_classifyDeltaResponse` already is) that COULD be unit
tested and isn't, because it doesn't exist yet.

**Fix shape:** give `_send`/`_sendBatch` the same `_classify*Response`-style treatment `_sendDelta`
already has; add `Gateway.mutationConflicted(entity, entityId, current)`; wire each store to patch
its cache and show a `Toast` per the design doc.

### C4 — `InventoryStore.restock()` was never converted to `recordDelta`, and the checkpoint's own text asserts it was (mostly known, but the tracking claim is wrong)
**File:** `qml/model/InventoryStore.qml:808-850`

Design doc §6 lists `InventoryStore.restock(...) → recordDelta(...)` as one of five callers to
convert. It wasn't — `restock()` still computes `arr[i].stock += addedQty` locally and sends it via
the old whole-record `Gateway.recordMutation`. Confirmed by grep: `Gateway.recordDelta(` has exactly
**one** call site in `qml/` — `InventoryStore.deductStock`. `restock` isn't it.

This is worth flagging precisely because the checkpoint's own audit trail contradicts itself: early
on it's "not yet individually audited," later it's listed under callers "not yet switched," but at
line 621 it asserts as fact that *"Component 4's caller conversion was completed for
`InventoryStore.deductStock`/`restock`"* — which is factually wrong against the actual code. A
future session trusting that line would move on without re-checking. **Compounds directly with
C3:** since `restock` is still CAS-checked (not delta) and the client never handles 409s, two staff
restocking the same product close together produces one silently-stuck retry loop with a
permanently inflated local stock count.

### C5 — `StockBatchStore.consumeFifo()`/`topUpOldest()` run before the stock delta resolves, with no rollback on rejection — and this is a systemic pattern, not a one-off (mostly NEW; adjacent to a known, narrower limitation)
**Files:** `qml/model/DataModel.qml:472-514` (`_tryCompleteOrder`), `:897-924` (`_tryAdjustOrder`'s
added-units branch), `qml/model/StockBatchStore.qml:225-273`

In both `_tryCompleteOrder` and `_tryAdjustOrder`, the FIFO batch walk (`consumeFifo`, and
`topUpOldest` if it undershoots) runs **synchronously and unconditionally**, decrementing local
batch state and firing a fire-and-forget whole-record `recordMutation` per touched batch — and only
*after* that does the code call `InventoryStore.deductStock(...)`, whose callback may reject
(`insufficient-quantity` — exactly the case Component 4's `floors` mechanism exists to produce, and
exactly the scenario this whole design targets: two devices completing/adjusting orders for the
same product near-simultaneously). On rejection, both functions correctly report the failure back
via `callback(false)`/`stockErrorMsg` — but neither undoes the FIFO consumption that already ran for
that line or any earlier line in the same call. The batches are already decremented, locally and on
the server, for units that no completed sale actually accounts for.

**Where this overlaps a known, deliberate decision, and where it doesn't:** the checkpoint documents
a *"known, deliberately kept limitation"* that `_tryAdjustOrder`'s return/price-adjust side effects
aren't rolled back on a rejected added-unit deduction, explicitly scoping out full compensating-
write rollback (design §2) as out of scope for round 1. That's a real, documented, reasonable
scope call for the *business-ledger* side effects (refund amounts, `TransactionStore` records). This
finding is narrower and, I'd argue, still worth a second look even under that same rationale: it's
specifically about the **FIFO batch ledger** (`stock_batches`, a separately-persisted collection
that feeds Value/Potential-profit/Revenue-by-supplier reporting per this codebase's own extensive
comments) drifting out of sync with reality — and `StockBatchStore.restoreFifo` already exists and
is already used for exactly this compensating purpose in the *returns* path. Restoring FIFO batches
on a rejected addition is a much smaller, targeted change than "full compensating-write rollback,"
reuses code that's already there, and doesn't touch the parts that were explicitly scoped out
(refunds, sale/price-adjust ledger entries). Also worth noting: before this session's round-4
sequencing work, there was no reject path at all post-precheck, so this specific failure mode looks
like a new consequence of the async conversion, not a pre-existing condition being carried forward.

**Fix shape:** on `deltaFailed`, call `StockBatchStore.restoreFifo` for every batch already touched
by that call (both functions), symmetric to the returns path.

### C6 — `LockManager._classifyAcquireResponse` doesn't check HTTP status, misclassifying auth/server failures as "someone else is editing this" (NEW)
**File:** `qml/model/LockManager.qml:86-91`

```js
function _classifyAcquireResponse(status, body) {
    var isRealResponse = body !== null && typeof body === "object" && typeof body.ok === "boolean"
    if (!isRealResponse) return { granted: false, holder: null, reason: "error" }
    if (body.ok === true) return { granted: true, holder: null, reason: null }
    return { granted: false, holder: body.holder || null, reason: "denied" }
}
```
Every well-formed `{ok:false}` body is `"denied"`, regardless of *why*. But `acquireLock`'s handler
returns well-formed `{ok:false, ...}` bodies for `400 missing-fields`, `401 invalid-token`, `403
no-tenant-context`, and `500 lock-failed` (the transaction's own catch), none of which mean "someone
else holds the lock." This is the same bug class the checkpoint documents fixing for
`_classifyDeltaResponse` — that sibling narrows "terminal" to `status >= 400 && status < 500` before
trusting the body; this one has no status guard at all, and doesn't even single out 409 specifically.
Concretely reachable via `OrderDetailDialog`/`EditProductDialog`/`StaffDetailDialog`'s `_save`/
`_submit`, which shows `"<holder> is currently editing this"` (or a blank-holder variant) on
`reason==="denied"` — for what could actually be an expired token or a transient server fault.

**Compounding factor:** `LockManager.acquire()`/`_post()` never call
`AuthService.ensureFreshToken()` before posting, unlike every other Gateway call that touches
auth-sensitive endpoints — a dialog opened after the ID token's gone stale is a realistic way to
actually hit the 401 case this bug mishandles.

**Test coverage gap, precisely characterized:** `tst_LockManager.qml`'s five tests are thorough on
*body shape* (malformed, missing `ok`, granted, denied-with-holder, denied-without-holder) but only
ever use status `404` (malformed-body case) or `409` (real cases). **No test combines a well-formed
`{ok:false}` body with a non-409 status** — exactly the combination C6 lives in. The fix should ship
with a test for `_classifyAcquireResponse(401, {ok:false, error:"invalid-token"})` (and ideally
400/403/500) asserting `reason === "error"`, alongside the code fix.

**Ponytail note:** `_classifyDeltaResponse` and `_classifyAcquireResponse` are near-duplicate
decision logic that already diverged once (one got the status-range fix, the other didn't). Worth
extracting a single shared classifier (status range + body shape → terminal/transient) that both
call, so a future fix in one place can't be silently forgotten in the other — this is exactly how
this specific bug happened.

### C7 — Dead code (`OrdersStore.approveAllPending` / unused `Logic.approveAllPending` signal) bypasses every safeguard this feature adds (NEW, currently unreachable but a real landmine)
**Files:** `qml/model/OrdersStore.qml:606-619`, `qml/model/DataModel.qml:172-175`,
`qml/logic/Logic.qml:43`

`Logic.qml` declares `signal approveAllPending()`. `DataModel`'s handler calls
`OrdersStore.approveAllPending()`, which flips `status` to `"completed"` directly via one batch
mutation — **no stock deduction, no FIFO consumption, no sale/transaction record, no lock, no
delta, no CAS.** Confirmed by grep: nothing in the codebase ever calls `logic.approveAllPending()` —
the real "Approve all" button (`OrdersPage.qml:213`) calls the page-local `_approveAllPending()`
directly, which correctly chains through `dataModel.tryCompleteOrder()` (the safe path). So this is
dead code today, not a live bug — but the two names are nearly identical, and a future refactor that
wires the button to the signal instead (a very natural-looking, arguably "more correct" MVC change)
would silently start completing orders with none of this feature applied. Recommend deleting it, or
at minimum an explicit `// DEAD — do not wire up, see OrdersPage._approveAllPending` guard comment.

### C8 — Leftover debug logging, one line dumping full document contents (NEW, small but real)
**Files:** `functions/lib/gatewayLogic.js:154-156`, `functions/index.js:127` — both added in
`b51779b`, the same commit as C1, apparently left in from Taher's own debugging of the CAS-mismatch
bug that commit fixes (the mixed tab/space indentation on these specific lines, inconsistent with
the rest of both files, is a tell).

```js
console.log("[applyMutation]: calling _deepEqual");
console.log("[applyMutation]: current - ", JSON.stringify(current));
console.log("[applyMutation]: before - ", JSON.stringify(params.before));
```
Beyond noise/cost on every single mutation forever in production, `current`/`before` are full
working-tier documents — for `order` that includes customer name/phone/email, for `inventory` that
includes cost price — logged unconditionally to Cloud Functions' log stream. Remove both.

---

## Important (should fix)

### I1 — `applyMutationsBatch` has no CAS check at all (known gap, restated plainly)
**File:** `functions/lib/batchMutationLogic.js` (untouched by this branch). Blind-writes every item,
same as pre-Component-3 `applyMutation`. Not this branch's regression, but it means Component 3's
guarantee isn't actually uniform across the app the way README's Concurrency section implies. Worth
an explicit decision: extend CAS to the batch path, or document it as CAS-exempt and why.

### I2 — Bulk order approval never acquires a lock (known implicitly; not in the design's own lock-point table)
**File:** `qml/pages/OrdersPage.qml:421-452`. `_approveAllPending()`'s sequential loop calls
`dataModel.tryCompleteOrder` directly, bypassing `OrderDetailDialog`'s lock acquisition entirely. May
be a fine product trade-off, but given C3, it's currently a real gap in practice (Components 1/4
partially cover it; Component 3's backstop is inert), not just a theoretical one, and the design
doc's §7.1 table doesn't discuss this interaction.

### I3 — `acquireLock`'s validation doesn't check `entity` against the known allowlist (NEW, low severity)
**File:** `functions/lib/lockLogic.js:71-85`. Unlike `validateMutationRequest`/`validateDeltaRequest`,
`validateAcquireRequest` only checks non-empty strings, not membership in `ENTITY_COLLECTIONS`. Low
risk (server-authenticated, worst case is an uncontested phantom lock), but inconsistent with its
siblings, and `lockLogic.test.js` doesn't cover this either.

### I4 — All three dialogs' "try again" error message doesn't actually retry lock acquisition (NEW)
**Files:** `qml/pages/OrderDetailDialog.qml:324-336`, `EditProductDialog.qml:1043-1055`,
`StaffDetailDialog.qml` (same pattern, confirmed via grep across all three)

On `_lockState !== "granted"`, `_save()`/`_submit()` shows a message ending in "try again" (or "try
again shortly" / "try again in a moment") and returns — but nothing re-calls `LockManager.acquire()`.
`acquire()` is only ever called from `openFor()`. Clicking Save again after a failed/pending
acquisition just re-shows the same stale `_lockState`; the only actual way to retry is closing and
reopening the dialog, which the message doesn't say. Minor UX bug, but a real one, and cheap to fix:
either re-issue `LockManager.acquire()` from within `_save()`/`_submit()` when state isn't
`"granted"`, or change the copy to say "close and reopen to try again."

### I5 — The one existing regression test for `_normalizeOrder` will fail on first run, for a reason unrelated to what it was written to test (see C1)
Restated here as a test-suite finding rather than a code finding: `tst_OrdersStore_normalization.qml`
was written and reviewed against `afea51d`'s state and never re-run or updated against `b51779b`'s
changes. It will hit C1's crash before reaching any of its own assertions. Recommend running
`qmltestrunner` on this file specifically, first, once C1 is fixed — it's the fastest way to confirm
the fix and to confirm no toolchain surprises are hiding in this specific file.

---

## Test-suite assessment

The split between server-side Node tests (`functions/test/*.test.js`, testing `functions/lib/` in
isolation, 85/85 passing) and client-side QML tests (`tests/tst_*.qml`, written but never executed
in any sandbox so far) is a real structural reason several of the above slipped through: C1, C3, and
C6 all live entirely on the QML/client side, in code paths the passing server-side suite has no way
to see. This isn't a criticism of the server-side coverage, which is genuinely solid — it's a
reminder that "85/85 passing" describes only half the feature, and the half that's currently
un-run is where 3 of this review's 8 Critical findings live. Getting `qmltestrunner` actually
executing (even just locally, once, on a build-capable machine) would very likely surface C1
immediately (it crashes the exact test written for it) and gives a real chance at C6 once the
missing status-branch test above is added.

## QML lint pass

Ran the deterministic lint (`qt_qml_lint.py`) across all 11 touched `.qml` files. The overwhelming
majority of hits (`JS-1` var-vs-let/const, `JS-2` loose equality, `BND-1` untyped `property var`,
`ORD-1` declaration-order) are pre-existing, codebase-wide conventions already used identically in
files this branch didn't touch — not regressions introduced here, so not itemized individually to
avoid diluting the findings above with noise. One pattern worth a look, not a bug: `OutboxStore.qml`
reassigns `items` imperatively in 8 places (`BND-2`); given `items` is a plain JS-array-backed
`property var` on a data-store singleton (not bound to anything elsewhere), this is very likely the
correct/intended pattern for this store type rather than an accidental binding break — flagged for
awareness, not action.

## Ponytail (over-engineering / duplication) pass

- **C7's two "approve all" implementations** are the clearest instance — genuine, dangerous
  duplication that should collapse to one.
- **C6's root cause is duplication**, not just a missing check: `_classifyDeltaResponse` and
  `_classifyAcquireResponse` are the same decision shape (status + body → terminal/transient) that
  already diverged once. Worth unifying into one shared classifier both call.
- **The `_normalizeOrder` consolidation itself (this commit's actual goal) was the right instinct** —
  eliminating two near-identical functions that had already drifted apart once (that drift is what
  caused `afea51d`'s bug) is exactly the kind of deduplication that prevents this class of bug long
  term. It just needs the one-line fix in C1 and a test that's actually run.
- No other significant speculative abstraction, unused flexibility, or reinvented-wheel patterns
  found in the diff — the four components are each about as much machinery as their job needs, not
  more.

---

## Direct answers to what was asked

**Regressions in existing functionality:** C1 is a real regression (the pre-`b51779b` normalization
was correct on this exact field). Everything else is new-code-doesn't-do-what-the-design-said
(C2–C6) or new-code-with-a-bug (C1, C8) rather than breakage of previously-working behavior.

**Gaps for future issues:** C2 (rules), C3 (client conflict handling), C4 (`restock` delta), C5
(FIFO rollback), I1 (batch CAS), I2 (bulk-approve locking) are all exactly this — code paths that
will misbehave under real concurrent use even though nothing is "broken" in a single-user test.

**Pending implementation** (per the design doc's own plan, not yet done):
1. `firestore.rules` lockdown for `locks/**` (C2) — blocks Component 2 from being a real guarantee.
2. `Gateway.mutationConflicted` + `_send`/`_sendBatch` 409 handling (C3) — Component 3 is
   server-only today.
3. `InventoryStore.restock` → `recordDelta` (C4).
4. `StockBatchStore`'s three FIFO functions → `recordDelta` (known gap, restated, still open).
5. FIFO rollback on rejected delta in `_tryCompleteOrder`/`_tryAdjustOrder` (C5).
6. `ConfirmReturnSheet`'s lock-span gap (known, still open, unchanged since last checkpoint).
7. A decision on `applyMutationsBatch` + CAS (I1).

**Bugs found**, ranked: C1 (crash + universal silent data loss) → C2 (locking unenforced) → C3
(conflict backstop client-inert) → C4 (restock still CAS-only, docs wrongly claim otherwise) → C5
(FIFO drift on rejected deltas) → C6 (lock error misclassification) → C7 (dead-but-dangerous code)
→ C8 (debug logging incl. PII) → I1–I5.

---

## Suggested priority order for fixing

1. **C1** — one-line fix, highest blast radius, has a test ready to confirm it.
2. **C2** — a rules-file change + deploy; nothing else in Component 2 matters until this is fixed.
3. **C8** — trivial, do it alongside C1 since it's the same commit/area.
4. **C3 + C6** — both are "give the client the same status-aware classification the server already
   has correctly"; genuinely similar shaped fixes, worth doing together per the ponytail note.
5. **C4, C5** — the remaining Component 4 caller conversions + the FIFO-rollback fix.
6. **C7** — delete or guard the dead code.
7. **I1–I5** as time allows; none are blocking.

Nothing here has been changed yet — this document is the review only. Let me know which of these
you'd like implemented and I'll scope it into a proper design/plan before touching any code, per the
usual workflow.
