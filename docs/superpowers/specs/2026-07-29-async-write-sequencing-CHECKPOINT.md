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

## Implementation progress (continued)
**Component 3 (CAS backstop) — server-side logic done, full TDD, all green.**
- `applyMutation` now reads `workingRef` inside the transaction and compares to `params.before`
  via a new order-insensitive `_deepEqual` helper (not a naive `JSON.stringify` compare — key
  insertion order must never cause a spurious conflict, tested explicitly). Rejects with
  `{ok:false, status:409, conflict:true, current}` on mismatch, writing nothing. Idempotency check
  still runs first, confirmed via an explicit ordering test (a retry is never rejected as a
  conflict against its own prior result).
- **Introduced and then fixed a real regression, noting honestly rather than glossing over it:**
  adding the CAS read broke 2 pre-existing tests (`applyMutation writes the working doc...` /
  `...deletes the working doc...`), because they used the original `makeFakeDb` (existence-only,
  no real document data) with a non-null `before` — once `applyMutation` actually reads current
  state, that fake always returning "doesn't exist" made every such test look like a false
  conflict. Fixed by switching those two tests to `makeFakeDbWithData` seeded with the state their
  own `before` claims — correctly modeling reality now that the function depends on it, not
  papering over the failure.
- 8 new tests total (mismatch rejection, claimed-create-when-exists, claimed-update-when-missing
  with no crash, matches-proceeds, idempotency-before-CAS ordering, key-order insensitivity, plus
  the 2 fixed pre-existing ones).
- `applyMutation`'s return value changed from `undefined` to a result object (matching
  `applyDelta`'s shape) — checked `index.js`'s only call site, it currently `await`s and ignores
  the return value entirely, so this is non-breaking as-is, but `index.js` will need to actually
  read this result to send `409` instead of always `200` once wired up (still not done, see below).
- Verified: `node --test test/gatewayLogic.test.js` → 31/31. Full `functions/` suite → 61/61, no
  regressions elsewhere.

## Round 4 decision incorporated into the design (not yet implemented)
Taher: reject (not clamp) on insufficient stock — order rejected, status → "out of stock", error
shown on UI. Implemented the `floors` mechanism in `applyDelta` to support this (done, §Component
4 above). But actually delivering "reject the order" requires `_tryCompleteOrder` to **await** the
stock-deduction result before marking the order completed, instead of today's fire-and-forget-
everything-at-once — this is QML-side, not yet started, and can't be executed in this sandbox
(no Qt toolchain). Design doc §7 (Component 4 subsection) and test plan updated with the concrete
shape: `Gateway.recordDelta(..., callback)` following the existing `provisionMember(payload,
callback)` precedent already in this codebase, callback fires for ALL coalesced callers if
Component 1 merges two calls into one outbox item, `_tryCompleteOrder` branches on the callback's
result before proceeding to the order-status/sale/transaction steps. This is also where the very
first ask from the start of this session (synchronized calls + a real busy indicator) actually
gets delivered, for this one flow.

## Not yet done (as of the Component 3 commit)
- `applyDelta`/`applyMutation`'s new CAS/floor logic NOT yet wired into `functions/index.js` as
  deployable endpoints, NOT deployed. No `validateDeltaRequest` written yet.
- `_tryCompleteOrder` async/await sequencing (round 4 consequence, above) — not started.
- Component 1 (client single-flight) — not started.
- Component 2 (locking) — not started. `lockLogic.js` half is node-testable here like the above;
  the QML half is not.
- Callers (`deductStock`/`restock`/FIFO functions) not yet switched to `recordDelta`.

## Pushed (round 5)
Taher provided a one-time GitHub PAT, asked to push, said he'd regenerate it immediately after.
Pushed `docs/async-write-sequencing-design` to `origin` (3 commits: docs+design+test-plan,
Component 4, Component 3). Used the token directly in the push URL rather than a stored
credential file (the `credential.helper store` approach failed outright — "could not read
Username" — direct-URL push worked). Confirmed `~/.git-credentials` and `credential.helper` are
both clean afterward. Taher is now reviewing/testing on a real device in parallel; told to
continue working meanwhile.

## Component 1 (client single-flight-per-record) — written, NOT executable in this sandbox
- `OutboxStore.qml`: added `_inFlightKeys` (ephemeral, requestId-valued map keyed
  `"entity/entityId"`), `markInFlight(item)`/`clearInFlight(item)` (take the item object itself,
  not a requestId — avoids a real bug where looking the item back up by requestId AFTER
  `markSent` already removed it would silently leak the in-flight key forever), `enqueue()` now
  coalesces into a matching NOT-in-flight item instead of always appending, `dueItems()` excludes
  any item whose key is currently blocked. Added `enqueueDelta()` (backs Component 4's
  `Gateway.recordDelta`) — same coalescing shape but **sums** deltas instead of taking-latest, per
  the design doc's explicit note that this is the one place the merge rule differs by kind.
- `Gateway.qml`: `drainNow()` now marks every due item in-flight before dispatching;
  `_send`/`_sendBatch` clear it in every exit path including the no-auth guard (verified this
  specific path via a new test — forgetting it there would permanently strand any item enqueued
  before first sign-in). Added `deltaFunctionUrl` (aspirational, endpoint not deployed yet), a new
  `_deltaCallbacks` map (ephemeral, NOT persisted), `recordDelta(entity, entityId, deltas, floors,
  callback)` following the existing `provisionMember(payload, callback)` precedent already in this
  codebase — the one Gateway call that isn't fire-and-forget, since `_tryCompleteOrder` needs the
  real outcome. Requires `mode === "gateway"` — fails fast with an explanatory error via callback
  rather than silently no-op'ing. New `_sendDelta` dispatch function distinguishes a **terminal**
  outcome (success, or a 409/404 the server explicitly explained) from a **transient** one
  (network/5xx/unparseable) — only terminal outcomes remove the item and fire callbacks; transient
  failures retry with backoff exactly like every other outbox item, callbacks staying pending.
- Tests added: `tests/tst_OutboxStore.qml` (+15 cases: coalescing, in-flight exclusion,
  batch-locks-members, delta-sums-on-coalesce) and `tests/tst_Gateway.qml` (+6 cases: recordDelta's
  enqueue/mode-guard/unknown-entity paths, in-flight-doesn't-leak regression) — both extending
  existing files, matching their established header/scope-note convention.
- **Honesty check performed:** confirmed no `qmllint`/`qmltestrunner`/`qml` binary exists in this
  sandbox (only unrelated Qt5 runtime libs as transitive deps of something else) — nothing here has
  been executed, only brace-balance-checked (52/52, 94/94, 127/127, 34/34 across the 4 files) and
  manually re-read. Not the same kind of "done" as the CF-side work.

## Next steps
- `lockLogic.js` (Component 2's server half) — **done, see below.**
- Then the QML-only remainder: `_tryCompleteOrder` sequencing, caller swaps to `recordDelta`,
  `LockManager.qml` + dialog wiring for Component 2 — all written-not-executed like Component 1.
- `index.js` wiring/deployment for all new endpoints — explicitly held for Taher's own action,
  not something to do unilaterally against a live system.

## Component 2 (locking) — server-side logic done, full TDD, all green
- New `functions/lib/lockLogic.js`: `acquireLock(db, params)` — transactionally grants if no lock
  exists, the existing one is expired (`expiresAt <= now`, boundary tested explicitly), or it's
  already held by the same `actorUid` (renewal, pushes `expiresAt` out from `now`, not the old
  value — tested explicitly since that's an easy off-by-one). Rejects with `{status:409,
  holder:{name,role,expiresAt}}` otherwise, writing nothing. `releaseLock(db, params)` deletes only
  if `holderUid` matches what's stored — a stale/duplicate release (e.g. from a session whose lock
  already expired and was taken by someone else) is a silent no-op, never an error, and never
  touches the new holder's lock (tested explicitly — this is the guard against a late release
  stealing someone else's freshly-acquired lock).
- `now`/`ttlMs` are injected params, not `Date.now()` calls inside the module — same
  dependency-injection convention as `gatewayLogic.js`'s `serverTimestamp`/`clientTimestamp`,
  keeps the logic deterministic and fully testable.
- 8 tests, all RED-verified before implementing: grant-when-missing, grant-when-expired,
  renew-when-same-holder, reject-when-held-by-someone-else, expiry-boundary, and the 3
  releaseLock cases above.
- Verified: `node --test test/lockLogic.test.js` → 8/8. Full `functions/` suite → 69/69, no
  regressions anywhere else.
- **Known, intentionally unaddressed limitation:** identity is `actorUid` only, not per-device/
  session. If the same staff member has the same account open on two devices, the second device's
  acquire would "renew" (same holder) rather than being told the record is in use elsewhere —
  Taher's stated scenarios were all about different roles/people contesting a record, not one
  person's own multiple devices, so this wasn't built. Flagging so it isn't mistaken for an
  oversight if it comes up.
- **Not yet done for Component 2:** `LockManager.qml` (client — heartbeat renewal timer, the
  dialog-open integration points from the design doc §7.1 table) — QML, not started, will be
  written-not-executed like Component 1. `index.js` wiring for `acquireLock`/`releaseLock` as
  actual HTTP endpoints — not started, not deployed.
