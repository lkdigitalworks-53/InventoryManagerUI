# Checkpoint — Async write ordering / cross-store sequencing brainstorm

**Date:** 2026-07-29
**Branch:** `docs/async-write-sequencing-design` (local only — not pushed; created off `origin/main`
at commit `96a84e6`)
**Status:** Brainstorming in progress. No design approved yet, no code written (hard gate per
`/superpowers:brainstorming` — design must be approved before any implementation).
**IMPORTANT:** This file is NOT committed or pushed yet (no go-ahead given this session). It
exists only in this sandbox's clone and will be lost when the session ends unless Taher asks me
to push it. Treat the chat transcript as the source of truth until a commit actually happens.

## Skills invoked this session (for resume-after-interruption)
1. `superpowers:using-superpowers` (implicit, session start)
2. `superpowers:brainstorming` — explicitly invoked by Taher (`/superpowers:brainstorming`).
   Currently at checklist step 1 ("Explore project context") → transitioning to step 3
   ("Ask clarifying questions"). Steps 2 (visual companion) not yet relevant, no visual question
   has come up yet.

## User's original ask (verbatim intent)
All Firestore/network calls are async; multi-step workflows (e.g. completing a pending order:
update order → reduce stock → record transaction → activity log → mark completed) can have their
responses land out of order, causing state corruption (e.g. a completed order silently reverting
to pending after stock/ledger side effects already ran). Wants: (1) calls in a workflow to be
properly synchronized/sequenced even though each is async, (2) a busy/UI indicator during the
whole sequence to prevent the user from causing further inconsistency mid-flight. Believes this
class of bug may exist in multiple places across the app, not just order completion.

## Project-context findings (step 1 of brainstorming checklist)

### 1. Gateway.mode flipped from "direct" to "gateway" TODAY, outside any session
Commit `649046d` ("fix(gateway): change mode from \"direct\" to \"gateway\" for compliance with
Cloud Function deployment"), authored directly by Taher today, **hours before this session**.
`docs/superpowers/KNOWN-ISSUES.md` still documents `Gateway.mode` as `"direct"` and describes a
`firestore.rules` deploy blocked on this exact cutover — that doc is now stale and the rules-deploy
question is now live. **Flagged to Taher as an open question, not yet resolved.**

### 2. Two pieces of directly-relevant prior art found, neither merged
- **`fix/orders-write-race-condition`** (branch, 1 commit, 2026-07-08, prior Claude session):
  patched `OrdersStore._pushAllToFirebase()`'s bulk-push race with a `WriteCoalescer.js`. **Now
  stale/obsolete** — `OrdersStore._commit()` on current `main` no longer calls
  `_pushAllToFirebase()` at all; it now calls `Gateway.recordMutation()` per the P0 migration.
  Merging this branch as-is would not fix today's actual bug and may not even apply cleanly.
- **`docs/offline-handling-design-update`** (branch, docs-only, 2026-07-09 to 07-11, prior Claude
  session): draft spec `docs/superpowers/specs/2026-07-09-offline-handling-design.md`
  (**Status: Draft — pending review/approval, never finalized**). §4.1 "Enqueue-time coalescing"
  already identifies and designs a fix for **the exact same bug class** Taher is describing today
  — explicitly calls out that it supersedes `fix/orders-write-race-condition`. Bundled inside a
  much larger offline-handling scope (read cache, offline-writable pending orders, conflict
  resolution UI) that Taher has not asked for today. Its dependency ("Orders' Gateway routing
  merges first") is now satisfied — see finding 1.

### 3. Confirmed root-cause mechanism (verified by reading code, not assumed)
`Gateway.recordMutation()` → `OutboxStore.enqueue()` (plain append, no coalescing) →
`drainNow()` fires **every due item concurrently** as independent XHR calls, no per-entity
in-flight lock. Server side, `functions/lib/gatewayLogic.js`'s `applyMutation()` does a **blind**
`txn.set(workingRef, after, { merge: false })` keyed only on `requestId` for idempotency — **no
compare-and-swap against `before`**. So two mutations queued close together for the same
`entity+entityId` can have their Cloud Function invocations resolve in either order, and whichever
resolves last wins, regardless of client send order. This is **gateway-wide** (inventory,
stock_batch, stock_movement, transaction, order, staff, supplier), not order-specific.

### 4. Busy overlay (shipped, commit `0f229cb`) is UI-only, not network-aware
`BusyOverlay`/`BottomSheet.busyMessage` is driven by a dialog's own local `busy` flag, not by any
acknowledgment from Gateway/OutboxStore. It reassures the user visually but doesn't guarantee the
underlying writes have landed, and doesn't prevent a background outbox retry from applying after
the dialog has already closed.

### 5. The fire-and-forget pattern is systemic, confirmed in `DataModel._tryCompleteOrder`
Every store mutation (`InventoryStore.deductStock`, `StockBatchStore.consumeFifo`,
`OrdersStore.updateOrder`, `TransactionStore.recordSaleFromOrder`) is: instant local-state write +
fire-and-forget `Gateway.recordMutation()` call. `_tryCompleteOrder()` chains 4 of these
synchronously and returns success/failure based on **local** validation only, before any network
call resolves. Same shape likely repeats in `approveAllPending`, returns/adjustments, imports,
restock (not yet individually audited — flagged as scope-decomposition work, not yet confirmed).

### 6. P1 (`feature/p1-stock-movement-taxonomy`) still unmerged, 10 commits
Unrelated to this bug directly, but shares the same `Gateway`/`OutboxStore` foundation. Its
`tst_StockMovementStore.qml` is spec/plan-only per standing test-first rule — not implemented.
Relevant to branch sequencing if this new work also touches `Gateway.qml`/`OutboxStore.qml`.

## Proposed decomposition (presented to Taher, not yet agreed)
- **A. Write-ordering correctness fix** — OutboxStore enqueue-time coalescing (or equivalent),
  gateway-wide. Bounded, ~80% already designed (draft §4.1). My recommendation: do this first.
- **B. Cross-store workflow sequencing + busy-indicator wiring** — make multi-step flows
  (order completion first, others after audit) surface a real busy state tied to actual
  completion/failure of underlying writes, not just local optimistic state. Broader, depends on A.
- **C. Full offline-handling design** (read cache, offline pending-order writes, conflict UI) —
  already drafted, never approved, NOT requested today. Recommend explicitly deferring unless
  Taher wants full offline support — flagged that its conflict-detection design (§4.2/4.3) assumed
  direct-mode client GET+compare, which doesn't exist under gateway mode; would need new,
  undesigned server-side compare-and-swap logic in `gatewayLogic.js` if ever revived.

## Answered
1. Cloud Functions + locked `firestore.rules` ARE deployed, tested, and working (confirmed by
   Taher, 2026-07-29). Docs were stale. `runCutover` (irreversible ledger wipe/stock zero) status
   NOT independently confirmed — flagged in all 3 doc updates below, not resolved, just noted.
2. Taher: update docs, then go straight to the recommended approach (sub-project A) — decomposition
   (A/B/C) accepted as proposed, no pushback on leaving B/C for later.

## Docs updated this step (not yet committed — no push go-ahead yet)
- `docs/superpowers/KNOWN-ISSUES.md` — "Leave-workspace: self-leave rule staged but not deployed"
  marked likely-resolved (deploy that blocked it has happened), original content kept for context.
- `AGENTS.md` §8 "P0 implementation status" — updated 2026-07-11 → 2026-07-29, "NOT live" →
  "LIVE", documents the mode flip + confirmed CF/rules deploy, flags runCutover status as unknown.
- `SKILLS.md` Skill 21 area (compliance ledger tiers) — same update, same runCutover caveat.

## New finding while designing sub-project A (important — changes the fix, not just the framing)
The dead draft spec's §4.1 "enqueue-time coalescing," read literally, has a real bug: it doesn't
distinguish an item that's merely **queued** from one that's already **dispatched, awaiting HTTP
response**. If a second mutation for the same `entity+entityId` arrives while the first is
in-flight, naively "merging into the existing item" would mutate a JS object whose `after` payload
was already serialized into an outbound XHR body — the in-flight request still carries the STALE
`after`, but `markSent` on that request's original `requestId` would then remove the coalesced
entry from the queue, **silently discarding the second mutation entirely** (worse than the
original bug — data loss, not just reordering). Also independently confirmed: `OutboxStore` today
has no in-flight/dispatched flag on items at all, so `drainNow()` can genuinely double-fire the
same item as two concurrent XHRs if called again before the first resolves (mitigated only by the
Cloud Function's requestId-keyed transaction idempotency, so no data corruption there — just
wasted calls).

## Sub-project A — approaches proposed to Taher, awaiting design approval
- **Approach 1 (recommended):** client-side true single-flight-per-record. Extend `OutboxStore`
  with an in-flight tracking map (ephemeral, per entity+entityId, keyed in `Gateway`, doesn't need
  to survive relaunch). Coalesce only into NOT-in-flight items; queue-but-hold anything arriving
  while a predecessor for the same key is in-flight, coalescing those waiters together, and release
  exactly one follow-up send when the in-flight predecessor's response lands. Batches
  (`recordMutations`) lock all their member entityIds for the duration. Merge semantics: keep
  earliest `before` + earliest `action` (so a create-then-update burst still audit-logs as
  "create"), take latest `after`. Net effect: intermediate transient states (e.g. the ~seconds a
  new order sits "pending" before being completed) generate no separate `audit_log` entry at all —
  flagged as a deliberate, not accidental, trade-off given P0's audit-trail purpose.
  Fully client-side, no Cloud Function changes, no deploy risk against the now-live gateway.
  **Does not protect against two different devices/staff concurrently mutating the same record** —
  each client has its own independent Outbox.
- **Approach 2:** server-side compare-and-swap in `functions/lib/gatewayLogic.js`'s
  `applyMutation` — read-current-then-compare-against-`before` inside the transaction, reject
  (not blindly overwrite) on mismatch. Protects cross-device races too, but requires Cloud
  Function + client conflict-handling changes and a deploy against a system that's already live.
- **Approach 3:** hybrid (1 now, 2 later if multi-device conflicts turn out to matter).
- Question put to Taher: is protecting against concurrent multi-device/multi-staff edits to the
  same record in scope now, or a later phase? This determines whether Approach 1 alone suffices.

## Answered (round 2)
3. Taher: solve multi-device now, not later. Described a mechanism: BE allows reads always;
   for writes, lock the record and sync requests; compare `before` in payload vs actual DB state,
   reject on mismatch; UI handles the error and refreshes with a message.

## Technical correction made to Taher (pushback, not blind implementation)
A hand-rolled pessimistic lock (lock doc/field, acquire-before-write, release-after) is the wrong
primitive for Firestore here: it adds new failure modes (orphaned locks if a client dies mid-write,
timeout tuning, extra round trips) and doesn't remove the need for the CAS check anyway. Firestore
transactions already provide "lock and sync" for free for genuinely simultaneous commits to the
same doc (automatic conflict retry inside `db.runTransaction`) — that part needs no new code.
What Firestore does NOT give for free is the "stale but not literally racing" case: a client's
`before` was captured seconds ago and something else already committed since — this needs the
explicit read-current-then-compare-to-`before`-then-reject logic in `applyMutation`, which is net
new work. Proposed a unified design combining round-1's Approach 1 (client-side single-flight,
avoids self-inflicted false conflicts) with Approach 2 (server-side CAS, the actual cross-device
guarantee) — not either/or, both together, each covering a different layer.
- Reads: no change needed anywhere — already unrestricted by current rules regardless of writes.
- **Flagged as new, not-yet-existing scope:** there is currently NO error/conflict propagation
  path from Gateway/OutboxStore back to any store or UI at all — everything today is fully
  fire-and-forget, even for plain network failures. Delivering "let UI handle error and show a
  message" requires building this feedback channel for the first time. Asked Taher whether to
  roll this out to all Gateway-routed writes uniformly or scope to order-completion first.
- **Flagged as a granularity decision:** whole-record CAS (matches what Taher described literally,
  simpler, ships faster, occasionally over-rejects on unrelated-field changes) vs. field-level CAS
  (more precise, meaningfully more design work — this is what the abandoned offline-design draft's
  §4.2/4.3 explored). Recommended whole-record now, field-level as a later refinement if it proves
  too noisy in practice.

## RBAC verification (Taher asked me to confirm in code — round 3)
Checked `qml/model/AuthStore.qml`, `qml/pages/OrderDetailDialog.qml`, `qml/helper/StaffScope.js`,
`EditProductDialog.qml`, `StaffDetailDialog.qml`:
- **Orders:** confirmed. Staff only see/act on their own orders (`StaffScope.ownOrders`, gated by
  `canViewAllSales: role !== "staff"`). The return/adjust button is hard-disabled for staff
  (`enabled: !AuthStore.isStaffRole` in `OrderDetailDialog.qml`) — staff cannot return/modify even
  their own orders, confirmed. Owner/admin/manager can view AND act on every order, no ownership
  scoping applied to them in the code.
- **Products/Inventory:** `canManageInventory: role === "owner" || role === "admin"` — **manager
  is NOT included.** This corrects Taher's framing — the real conflict pair is owner-vs-admin (or
  two owner/admin sessions), not "admin and manager."
- **Staff records:** same pattern, `canManageStaff: role === "owner" || role === "admin"` — manager
  excluded here too.
- **Important adjacent finding, not yet acted on:** `docs/superpowers/specs/2026-06-16-staff-role-restrictions-design.md`
  explicitly states all of this is **client-side only** — "A technical staff user can still read
  cost price, supplier names, other staff's sales, and revenue directly from Firestore" — "This is
  a UI-trust boundary, not a security boundary." The live P0 gateway's `applyMutation` does not
  enforce role/ownership either (confirmed by re-reading `gatewayLogic.js` — no auth/role check
  exists there). Flagged to Taher as a related-but-distinct gap (authorization vs. concurrency
  control) — not folded into this feature's scope without his explicit say-so.

## Pivot (round 3): from CAS-only to lock-first, confirmed possible
Taher asked to acquire a lock before any local/online updates begin, get a positive response, only
then proceed, release after. Confirmed this is buildable and is the right call given the now-
verified, narrower conflict surface. Design: a `locks/{entity}_{entityId}` doc, acquired via a new
Cloud Function endpoint using the same Firestore-transaction primitive as before (read lock doc,
grant if absent/expired/same-caller, else reject with holder info) — TTL + client-side renewal
heartbeat while a dialog stays open, so an abandoned/crashed session self-heals via expiry without
needing a cleanup job. Explicit release on save/cancel for fast reclaim; TTL is the real safety
net. Round-1's client-side single-flight-per-record fix is STILL needed — it solves a different
problem (one device's own outbox reordering its own writes) that the lock doesn't touch. The CAS
check from round 2 is also kept, but its role shifts to a defense-in-depth backstop rather than the
primary mechanism, since the lock should make it fire only in genuine edge cases.

## Open questions for Taher (round 3, not yet answered)
1. Lock-denied UX: block the specific edit action with a message (view stays read-only, matches
   "reads always allowed"), vs. something else.
2. Which entities get the lock: orders + products only (as Taher named), or uniformly across all
   Gateway-writable entities (orders, inventory, staff, suppliers) to match the "all writes now"
   scope from round 2?
3. Whether the newly-found authorization gap (no server-side role/ownership enforcement at all) is
   in scope now or explicitly deferred as its own future item.

## Implementation progress (this step)
**Component 4 (atomic deltas) — server-side logic done, full TDD, all green.**
- Resolved open items 3/4 from round 3 along the way: no dedicated supplier dialog exists —
  `updateSupplier()` is called from inside `EditProductDialog.qml` (already gated by
  `canManageInventory`), so "supplier" doesn't need its own lock entry point, it shares the
  product-edit one. TTL/heartbeat kept at the proposed 90s/30s (no evidence found to change it).
  Auto-stamped-fields concern (open item 2) checked: `applyMutation` never adds anything to the
  working doc beyond the client's `after` — no server-side auto-stamping exists today, so the CAS
  false-positive risk is currently theoretical, not observed. Still worth a final check when CAS
  actually lands (Component 3), noted there.
- **Not yet resolved:** open item 1 (reject-vs-clamp on insufficient stock) — implemented the
  `floors` mechanism as reject-on-violation (my recommended default from the design doc), but this
  is what a caller passing `floors: {stock: 0}` would get; **Taher has not explicitly confirmed
  this is what he wants for `deductStock` specifically** — flagging again before wiring
  `InventoryStore.deductStock` to actually pass that floor.
- `functions/lib/gatewayLogic.js`: added `applyDelta(db, params)` — reads current value(s) inside
  the transaction, computes `current + delta` per field, all-or-nothing floor rejection, writes
  server-observed before/after to `audit_log`. Extracted `_refs()` shared helper (refactor step,
  no behavior change) since `applyMutation` had the same ref-construction duplicated.
- `functions/test/gatewayLogic.test.js`: added `makeFakeDbWithData()` (a second fake Firestore
  double that tracks real document data, not just existence — needed for CAS/delta, unlike the
  original `makeFakeDb` which only tracked existence). 9 new tests for `applyDelta`, all written
  RED-first and verified failing for the right reason before implementing: single-field delta,
  audit_log before/after, floor violation (all-or-nothing), floor-exactly-met boundary, not-found,
  missing-field-as-zero, multi-field atomicity, idempotent retry.
- Verified: `node --test test/gatewayLogic.test.js` → 25/25 pass. Full `functions/` suite
  (`node --test test/*.test.js`) → 55/55 pass, no regressions in `batchMutationLogic`,
  `cutoverLogic`, `breakdownMath`, `realisedMath`.

## Not yet done (explicitly, so a resumed session knows exactly where this stopped)
- `applyDelta` is NOT yet wired into `functions/index.js` as an actual HTTP endpoint, NOT deployed.
  No `validateDeltaRequest` request-parsing/validation function written yet (mirroring
  `validateMutationRequest`) — needed before wiring.
- Component 3 (CAS backstop in `applyMutation`) — not started.
- Component 1 (client single-flight in `OutboxStore.qml`/`Gateway.qml`) — not started. Can't be
  executed/verified in this sandbox (no Qt toolchain) — will be written against the test plan and
  flagged as unexecuted, same honesty precedent as `tst_ImportMath.qml` history in this repo.
- Component 2 (locking) — not started, same QML-execution caveat as above, plus its Cloud Function
  half (`lockLogic.js`) which CAN be node-tested here the same way `applyDelta` was.
- Callers (`InventoryStore.deductStock`/`restock`, `StockBatchStore.consumeFifo`/`topUpOldest`/
  `restoreFifo`) not yet switched from `recordMutation` to `recordDelta` — blocked on Taher's
  reject-vs-clamp answer above, and on `Gateway.recordDelta()` existing client-side (Component 1
  work).
- Nothing committed yet this step (paused here to check in before continuing further).

## Next steps
- Report progress to Taher; get the outstanding reject-vs-clamp answer.
- Continue in rollout order: Component 3 (CAS backstop) next — same node --test approach, fully
  executable in this sandbox, same TDD rigor.
