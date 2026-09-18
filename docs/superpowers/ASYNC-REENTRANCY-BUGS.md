# Async Re-entrancy / Double-Submit Bug Tracker

Severity-ranked tracker for one specific bug *pattern*, kept separate from
`docs/superpowers/KNOWN-ISSUES.md` (that file is a flat, chronological log of assorted deferred
issues with no severity structure; this one is scoped to a single, well-defined defect class and
ranks every instance found so far by real-world impact). Started 2026-09-15 after fixing the
order-completion double-submit bug (PR #70, SKILLS Skill 61) and sweeping the rest of the app for
the same shape of defect. Update this file (don't replace it) whenever a new instance is found or
an existing one is fixed — move fixed items to the bottom under "Fixed" rather than deleting them,
so the pattern's history stays visible. `KNOWN-ISSUES.md` gets a one-line pointer here rather than
duplicating detail.

## The pattern, in one paragraph

A user action fires a fire-and-forget signal into an async, multi-step `DataModel` orchestration
function, and the triggering dialog/page closes or re-enables itself immediately — with no busy
indicator and no re-entrancy guard tied to the actual async completion. If the user repeats the
action (double-tap, reopen-and-retry, a slow connection making the first attempt look like it did
nothing) before the first attempt's real network round trip resolves, the orchestration runs a
second time against the same stale local state the first call started with, producing duplicate
writes: duplicate stock deductions, duplicate ledger entries, or duplicate records outright. See
`AGENTS.md`'s Data Model & Orchestration Agent and Pages & Dialogs Agent sections for the standing
convention this pattern violates, and SKILLS Skill 61 for the original, fully-traced instance.

**How to tell if a given action is actually at risk** (the checklist used for this sweep):
1. Does the action's `DataModel` handler call a **callback-taking** Store/Gateway function
   (`deductStock`, `recordDelta`/`recordMutation` directly, an ID-minting call like
   `nextOrderId`)? Those depend on a real network round trip and can genuinely still be running
   when a second attempt starts. A **callback-less** local-apply helper (`creditStockNoBatch`,
   `restoreFifo`, a plain `updateX(...)` with no callback param) resolves synchronously in this
   codebase's offline-first design — re-running it twice just reapplies the same values and is
   usually harmless.
2. If yes to (1): does the dialog/page set `busy` (or an equivalent bound state) and wait for a
   real completion signal before allowing the action again, or does it fire the signal and
   close/reset immediately?
3. If yes to (1) and no busy/wait exists: is there a `DataModel`-layer in-flight guard
   (`_completingOrderIds`-style) independent of the UI? If not, the UI gap is the *only* thing
   between this and a duplicate write — same category as the original bug, not a narrower one.
4. `LockManager` does **not** count as protection for any of this — its server-side `acquireLock`
   re-grants a request from the same `actorUid` by design (needed for renewal heartbeats), so it
   only stops a different device/user, never the same user re-entering their own still-resolving
   action. Don't let a `LockManager.acquire` call anywhere in the path read as "this is handled."
5. (Added 2026-09-16, C-3) A "yes" to question 3 isn't the end of the check — an in-flight guard
   that exists is only as good as its recovery story. If the guard is in-memory only, ask what
   happens when the guarded request never comes back at all (a genuine hang, not just slow) rather
   than assuming any guard is sufficient protection. If the only way anyone would ever recover from
   a stuck guard is a workaround that resets in-memory state (logout/login, an app restart), check
   whether that workaround's fresh retry can re-run a step that already durably succeeded.

---

## Critical

### C-1: `ConfirmReturnSheet` → `DataModel._tryAdjustOrder` — exchanges and quantity-increases on a completed order can double-deduct stock and double-record the sale

**Where:** `qml/pages/ConfirmReturnSheet.qml` `onPrimaryClicked` (confirms a return/exchange/modify
on a completed order) → `Main.qml`'s `onConfirmed` → `logic.adjustOrder(...)` (fire-and-forget
signal) → `DataModel.onAdjustOrder` → `DataModel._tryAdjustOrder`.

**Trace:**
- `ConfirmReturnSheet.onPrimaryClicked` (lines 82–85): emits `confirmed(...)` then calls `close()`
  on the very next line — no `busy`, no wait for any ack, even though this `BottomSheet` has the
  same `busy`/`busyMessage` machinery `OrderDetailDialog` now uses.
- Worse than the original bug: `onClosed: LockManager.release("order", orderId)` (line 95) fires
  the instant the sheet closes — meaning the pessimistic lock on this order is released *before*
  `_tryAdjustOrder` has done any of its real work, actively inviting a second edit to start rather
  than merely failing to prevent one.
- `DataModel._tryAdjustOrder` (`qml/model/DataModel.qml:763`) has **no in-flight guard at all** —
  no `_completingOrderIds`-equivalent, unlike `_tryCompleteOrder` after PR #70. Its only
  precondition checks are `o.status !== "completed"` and `TransactionStore.hasMore` — neither
  catches a second call arriving while the first is still resolving.
- For lines with `addedQty > 0` (an exchange, or a plain quantity increase on a completed order),
  `_tryAdjustOrder` calls `InventoryStore.deductStock(dCaptured.productId, dCaptured.addedQty,
  function(result) {...})` (`DataModel.qml` ~line 1053) — the exact same callback-taking function
  at the center of the original bug, wired to a real `Gateway.recordDelta` → `XMLHttpRequest` round
  trip (see SKILLS Skill 63). Pure returns (only `returnedQty`, no additions) go through the
  callback-less `restoreFifo`/`creditStockNoBatch` path and are not exposed to the *async* race the
  same way, but still have no guard against a same-tick double-invocation if `_tryAdjustOrder`
  itself is ever called twice in immediate succession.

**Impact:** reopen a completed order, choose Exchange or increase a line's quantity, confirm —
then, before the round trip resolves (slow connection, or just re-navigating back into the order
because the sheet already closed and gave no indication anything was still happening), do it again.
Stock gets deducted twice for the added units, and the exchange's sale/transaction event
(`TransactionStore.recordSaleFromOrder`-equivalent inside `_finishAdjustment`) is recorded twice —
the same downstream symptom as the original bug (Transaction History / Product History / Sales
Analysis overcounting), reached via a different door.

**Suggested fix:** same two-layer pattern as PR #70 — an entity-scoped in-flight guard in
`DataModel._tryAdjustOrder` (e.g. `_adjustingOrderIds`, or fold into a single `_orderOpsInFlight`
set shared with `_completingOrderIds` since they can't legitimately overlap for the same order
anyway), plus wiring `ConfirmReturnSheet` up to `busy`/`busyMessage` and waiting for a real
completion signal instead of closing on `onPrimaryClicked` — mirroring `OrderDetailDialog._save()`.
The lock-release-on-close (line 95) needs to move to *after* the real completion too, not before —
right now it's actively counterproductive.

**Not yet fixed.** Not attempted in this sweep (audit only, per this session's scope) — flagged for
a dedicated session.

---

### C-2: `NewOrderDialog` — double-submitting "Create Order" mints two separate orders, and can double-deduct stock if auto-approve is on

**Where:** `qml/pages/NewOrderDialog.qml` `trySubmit()` → `Main.qml`'s `onOrderCreated` →
`logic.addOrder(...)` → `DataModel.onAddOrder` → `OrdersStore.addOrder` → `OrdersStore.nextOrderId`.

**Trace:**
- `trySubmit()` (`qml/pages/NewOrderDialog.qml:565`) has no `if (busy) return` guard, no `busy`
  usage of any kind. Its last two lines emit `orderCreated({...})` then call `dlg.close()`
  immediately (line 611) — identical shape to `OrderDetailDialog._save()` before PR #70.
- `OrdersStore.addOrder(...)` (`qml/model/OrdersStore.qml:731`) is callback-based specifically
  because its first step is `nextOrderId(function(id) {...})` — minting a new sequential order ID
  is a genuinely server-coordinated operation (to avoid collisions across devices), not a local,
  synchronous allocation. There is no local-apply shortcut here at all: the entire order object is
  built and persisted only inside that callback.
- Every part of `DataModel.onAddOrder` (`qml/model/DataModel.qml:69`) that runs after a successful
  mint — `_syncOrdersModel()`, `dispatcher.orderAdded(...)`, and, if
  `OrdersStore.autoApproveEnabled` is on, an immediate `_tryCompleteOrder(newOrderId, ...)` call —
  only happens once, genuinely, per successful ID mint. Two overlapping `trySubmit()` calls mint
  two different IDs and produce two separate order documents; there's no de-duplication of
  create-type mutations the way updates get CAS conflict detection.

**Impact:** this needs neither a slow connection nor unusual timing to hit — a plain fast
double-tap on "Create Order" (common on a touchscreen, or when a user isn't sure the first tap
registered because nothing visibly happens until the sheet closes) creates two duplicate orders for
what the user intended as one sale. If the workspace has `autoApproveEnabled` on, **both** duplicate
orders also get auto-completed via `_tryCompleteOrder` — meaning this single double-tap deducts
stock and records a sale twice, using the exact mechanism PR #70 just fixed, just reached from order
*creation* instead of order *approval*. This is arguably the single easiest-to-trigger instance in
this whole sweep — no need to reopen anything, just a real-world double-tap on the primary flow
every order goes through.

**Suggested fix:** `if (busy) return` + `busy = true` in `trySubmit()`, waiting for
`logic.orderAdded`/an equivalent failure signal (`dispatcher.orderAdded` already exists and fires
exactly once per successful mint — `NewOrderDialog` just needs to listen for it, the same
`Connections`-on-`logic` pattern `OrderDetailDialog` now uses) before closing. This one doesn't
need a `DataModel`-layer guard the way completion did — there's no *second* call path into
`OrdersStore.addOrder` the way `_approveAllPending` provides for completion, so fixing the one UI
entry point closes the whole gap.

**Not yet fixed.** Flagged for a dedicated session — likely the next one to pick up given how easily
this triggers in normal use.

---

### C-3: `DataModel._tryCompleteOrder` — a hung `deductStock`/status-update leaves an in-memory-only guard stuck, and the only recovery path re-runs `consumeFifo` from scratch

**Where:** `DataModel._tryCompleteOrder` (`qml/model/DataModel.qml:425`) — specifically the gap
*between* `StockBatchStore.consumeFifo()` succeeding and `OrdersStore.updateOrder(orderId,
{status: "completed", ...})` actually landing.

**This is a different sub-case of the pattern than C-1/C-2, worth being precise about**: PR #70's
`_completingOrderIds` in-flight guard is present and does work exactly as designed — it correctly
blocked every same-session retry attempt in the on-device report below. The gap isn't a missing
guard; it's that the guard is **in-memory only**, with nothing checking question 3 of this file's own
checklist against the specific failure mode of *"the guarded operation never comes back at all."**

**Trace:** `_tryCompleteOrder` performs three separate, independently-fallible writes with no
atomicity between them and — critically — no persisted record of which ones already succeeded:
1. `StockBatchStore.consumeFifo()` — durably decrements `stock_batch.qtyRemaining` via its own
   `Gateway.recordDelta` call, batch by batch.
2. `InventoryStore.deductStock()` — a *separate*, independent `Gateway.recordDelta` call that
   decrements `product.stock`.
3. `OrdersStore.updateOrder(orderId, {status: "completed", ...})` — fires only after both of the
   above resolve.

Both #1 and #2 are durable (queued via Outbox, will eventually retry) — but neither is *linked* to
the order in any way the code can check later. The order's own `status` field is the *only* signal
`_tryCompleteOrder` uses to decide "has this already run" (`if (o.status === "completed") return`),
and status is the **last** thing to update, not the first. Combined with the separate, already-
tracked finding that no XHR request in this codebase has a timeout (`E2E-TESTING-ROADMAP.md`'s
"Needs Taher's input" section, 2026-09-14) — `deductStock`'s request can hang indefinitely rather
than failing, leaving `_completingOrderIds[orderId]` stuck `true` forever with no way for the app
itself to recover.

**On-device reproduction, confirmed (2026-09-16):** product P with one batch of 10, order for 1 unit.
Pressed Approve, immediately airplane mode on, 5s, airplane mode off. `consumeFifo`'s delta
eventually landed (batch → 9, durable, survived the interruption); `deductStock`'s never did (stock
stayed at 10, order stayed "pending"). Every same-session retry correctly hit the in-flight guard —
confirming C-1/C-2's fix works as designed, this is not a same-session gap. After waiting 3+ minutes
with no resolution, logging out and back in and retrying is what caused the actual damage: this
abandons the original hung request and its guard with no persisted trace that `consumeFifo` had
already succeeded, so the fresh attempt reran `consumeFifo` from scratch (batch 9 → 8) before
`deductStock` finally went through for real (stock 10 → 9, correctly reflecting only one sale). Net
result: the batch ledger now shows 2 units consumed for a 1-unit order while `product.stock` shows
only 1 — silently out of sync, in the dangerous direction (ledger under-counts what's actually
available, which is exactly the condition `topUpOldest`'s drift-repair exists to paper over, not
something that should be manufactured by the completion flow itself).

**Impact:** Critical — confirmed real inventory/data corruption on-device, not theoretical. Same
severity class as C-1/C-2, reached via a different mechanism (a permanently-stuck request plus a
user workaround, rather than a same-session double-tap).

**Suggested fix — Taher's explicit direction, stated 2026-09-16: he wants idempotency and atomicity
for network calls generally, not a narrow patch for this one call site.** Options range from
narrowest to most robust, not yet designed or chosen:
- Persist a checkpoint immediately after `consumeFifo` succeeds (e.g., stamp the order with its
  resulting `products`/consumption data and an intermediate marker) *before* attempting
  `deductStock`, so a retry — from any cause, not just this one — can detect "FIFO consumption
  already happened for this order" and resume from `deductStock` onward instead of re-deriving
  consumption from scratch. Fits the existing client-driven architecture; the data this needs
  (`linesWithConsumption`) is already built by the current code, just not persisted early enough.
- The same idea, scoped more narrowly to just this call site rather than a general resume-from-
  checkpoint mechanism.
- True atomicity via a server-side (Cloud Function) transaction wrapping all three writes — most
  robust, but this codebase has no precedent for server-side transactional writes anywhere
  currently; every mutation goes through the client-driven `Gateway`/Outbox pattern. Much larger
  architectural shift than either option above.

Given the stated goal is general, not instance-specific, whoever picks this up should also look at
whether the same checkpoint/resume shape is the right general answer for C-1 and C-2 above (both
still "Not yet fixed" as of this entry) rather than solving each independently — that decision
belongs to the design session that picks this up, not assumed here.

**Not yet fixed.** Flagged for a dedicated session, per Taher's explicit request to keep this one
scoped to documentation only.

---

## Medium

### M-1: `InviteMemberDialog` — no busy state, no completion feedback at all, and nothing stops resubmitting a still-pending invite

**Where:** `qml/pages/InviteMemberDialog.qml` `onPrimaryClicked` → `Main.qml`'s
`onMemberInviteRequested` → `logic.inviteMember(...)` → `Main.qml`'s `onInviteMember` →
`AuthService.inviteMemberToCurrentTenant(...)`.

**Trace:** `onPrimaryClicked` (lines 22–24) emits `memberInviteRequested(...)` and does **nothing
else** — no `close()`, no `busy`, no error label, no success message, no `Connections` back to
`AuthService` anywhere in the file (confirmed: zero matches for `busy`, `Connections`,
`AuthService`, `close()`, `errorLabel`, or `successMessage` in `InviteMemberDialog.qml`).
`AuthService.inviteMemberToCurrentTenant` is a real network call (Firebase Auth / a Cloud
Function), genuinely slow and genuinely async.

**Impact:** different in kind from C-1/C-2 — there's no local stock/ledger to double-write here, so
the *data*-correctness risk depends entirely on whether the server-side invite endpoint is itself
idempotent for a repeated `(uid, tenant)` pair (not verified in this sweep — out of scope, no
`functions/` invite-handler code was traced). The concrete, confirmed problem is UX: the dialog
gives the user **zero** indication of success, failure, or even that anything is happening, and
nothing stops them from pressing the button repeatedly while wondering if it worked — each press
fires another real invite call. Contrast with `MemberManagementDialog` (`qml/Main.qml:687-690`),
which correctly binds `busy: AuthService.membersBusy` to a real service-level state — the pattern
already exists in this codebase, just wasn't applied here.

**Suggested fix:** wire `busy` to a request-in-flight state (either a new
`AuthService.inviteBusy`-style property mirroring `membersBusy`'s existing pattern, or a local
`busy` toggled around the call), and add a success/error `Connections` handler so the dialog
actually tells the user what happened and closes on success — right now it apparently just sits
open indefinitely either way.

**Not yet fixed.** Server-side idempotency of the invite endpoint itself is unverified — worth
checking `functions/` before assuming this is UX-only.

---

## Low / informational

### L-1: `OrdersPage._approveAllPending()` bulk-approve banner has no busy/disabled state

Already flagged in PR #70 (SKILLS Skill 61's "still open" note) — cross-referenced here so this
file is the single place to look. **Data-safe**: it calls the same `_tryCompleteOrder` engine PR #70
added the `_completingOrderIds` guard to, so a double-click there is now rejected at the
`DataModel` layer with no duplicate writes. What's still missing is purely cosmetic: the banner's
Approve button doesn't disable itself or show a spinner while the bulk loop runs, so a user who
double-clicks gets a silent no-op on the second click rather than a disabled button. Low priority
because the underlying risk this whole file is about (data corruption) is already closed for this
path.

---

## Checked, not affected

Listed so this sweep's negative results are visible too — "checked and found fine" is different
from "not checked."

- **`EditProductDialog`** (`_submit()`) — `productUpdateRequested` → `DataModel.onUpdateProduct` →
  `InventoryStore.updateProduct(...)` is called with no callback and `dispatcher.productUpdated`
  fires synchronously right after. No genuine async round-trip gates this action's own completion
  (offline-first local-apply, same shape as a plain non-completing order edit) — closing
  immediately is architecturally consistent, not a gap. `_reconcileBatchesForStockEdit` (the other
  DataModel orchestration function, `qml/model/DataModel.qml:1141`) runs synchronously off the same
  call and wasn't separately re-traced in this pass.
- **`StaffDetailDialog`** (`staffUpdateRequested`) — `DataModel.onUpdateStaff` calls
  `StaffStore.updateStaff(...)` with no callback, same shape as above. Not affected.
- **Delete flows** (order/product/staff, all routed through the shared `ConfirmDialog`) —
  `DataModel.onDeleteOrder`/equivalent handlers call their Store's delete function synchronously,
  no callback. A repeated delete on an already-deleted record is a harmless no-op, not a
  duplicate-write risk. `ConfirmDialog.qml` itself wasn't deeply audited for its own
  double-tap-on-Confirm behavior, since the actions routed through it are idempotent regardless.
- **`RestockDialog`, `AddProductDialog`, `AddStaffDialog`, `ImportPreviewDialog`** — all already use
  `busy`/`busyMessage` correctly (confirmed present and wired in each file). These were the
  examples PR #70 pointed to as the established, correct pattern; re-confirmed here, not re-derived
  from scratch.
- **`MemberManagementDialog`** — binds `busy: AuthService.membersBusy`, a real service-level state
  rather than a manually toggled flag. Correct pattern, different implementation shape (bound
  property vs. imperative set/clear) — both are fine.

## Not yet swept — flag before assuming clean

This pass covered every `BottomSheet`-derived dialog's primary action plus the two known
`DataModel` orchestration functions with callback-taking Gateway dependencies
(`_tryCompleteOrder`, `_tryAdjustOrder`). Not covered, and worth a follow-up pass:

- `OrdersStore`/`StaffStore`/`SupplierStore`'s other gateway-routed write paths beyond the ones
  reached from the dialogs above (per `overview.md`'s P0 gateway migration note — "all
  gateway-writable entities use uniform locking" doesn't mean all of them have UI-level re-entrancy
  guards, as C-1/C-2 demonstrate for orders specifically).
  `SupplierStore`'s own create/edit dialog wasn't traced in this pass.
- `functions/` server-side idempotency for create-type mutations in general — this whole bug class
  exists on the client because creates/deltas aren't deduplicated server-side either; whether that's
  fixable/worth fixing server-side (vs. purely client-side guards) wasn't evaluated.
- Bulk operations beyond `_approveAllPending` and `ImportPreviewDialog`'s already-guarded import
  flow (StockBatchStore FIFO reconciliation functions, `feature/p1-stock-movement-taxonomy`'s
  in-progress work) — not re-audited against this specific pattern.

---

## Fixed

### F-1 (2026-09-14, PR #70): `DataModel._tryCompleteOrder` / `OrderDetailDialog` order-completion double-submit

The original instance. `_tryCompleteOrder`'s only "already completing" guard read a local cache
field that only updated at the end of the same async chain it was meant to guard; `OrderDetailDialog`
fired its update signal and closed immediately with no busy indicator. Fixed with an entity-scoped
`_completingOrderIds` in-flight set (DataModel layer) plus wiring the dialog up to `BottomSheet`'s
existing `busy`/`busyMessage` mechanism. Full writeup: SKILLS Skill 61 (root cause), 62–63 (test
file corrections). Branch: `fix/2026-09-14-order-completion-double-submit`, PR #70.
