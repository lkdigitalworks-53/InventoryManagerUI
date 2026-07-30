# Test plan — Async Write Sequencing & Multi-Device Conflict Resolution

**Covers:** the design at `docs/superpowers/specs/2026-07-29-async-write-sequencing-design.md`
(4 components: client single-flight, record locking, server CAS backstop, atomic quantity deltas).
**Status:** plan only — no implementation code exists yet, per standing rule. Written for review
before any component is built.

**Same caveat as prior test plans in this repo:** no Qt toolchain or Firebase emulator is available
in this sandbox. Cloud Function logic (`lockLogic.js`, the `gatewayLogic.js` extensions) will be
verified with `node --test` against hand-rolled Firestore transaction fakes, matching the existing
pattern (Skill 35). QML-side logic will be verified with `qmltestrunner` test files. **None of this
touches a real device, build, or Firestore backend** — flagging honestly rather than glossing over
it, same as the 2026-07-17 test plan did.

---

## 1. Component 1 — client single-flight-per-record (`OutboxStore`/`Gateway`)

New file: `tests/tst_OutboxStore.qml` (extends the existing outbox test coverage referenced in
SKILLS.md's Skill list).

**Unit**
- `enqueue()` coalesces a second call for the same `entity+entityId` into the existing item when
  that item is **not** in-flight: result keeps the *first* item's `before`/`action`, takes the
  *new* call's `after`.
- `enqueue()` does **not** mutate an in-flight item's payload — a second call for the same key
  while the first is in-flight is appended as a distinct, held item.
- A held item becomes eligible in `dueItems()` the instant `clearInFlight()` runs for its key, and
  is itself now the sole representative of everything that queued during the hold (verify a third,
  fourth arrival during the same hold window all collapse into that one held item, not three).
- `dueItems()` excludes any item whose key is currently in `_inFlightKeys`.
- `markInFlight`/`clearInFlight` correctly key on `entity + "/" + entityId`; a batch item marks
  every member entityId and clears all of them together, not one at a time.
- Delta-kind coalescing **sums** deltas for the same key instead of take-latest (differs from the
  regular merge rule — needs its own explicit test, easy to get backwards).

**Regression**
- Existing persistence (`_load`/`_save` via `Settings`), `markFailed` backoff schedule, and
  `clear()` on sign-out are unaffected by the in-flight map (which is intentionally NOT persisted).
- `enqueueBatch`'s existing "retried as a unit" behavior for network failures is unchanged; only
  new is what happens when a member entityId collides with something else in flight.

**Functional**
- Reproduce the originally reported bug directly: two `recordMutation` calls for the same order
  (first: pending, second: completed) fired back-to-back, first artificially delayed past the
  second in a fake transport — assert the *outcome* the fix guarantees (only one coalesced,
  correctly-ordered request is ever actually sent) rather than the old symptom.

**Negative**
- `enqueue()` with a missing `entityId` — existing warn-and-no-op behavior preserved, not silently
  swallowed by the new coalescing path.

**Edge cases**
- Coalescing across an action-type change within one hold window (e.g. update → delete arriving
  while an update is in flight) — confirm the merged item ends up with `action: "delete"`, not a
  meaningless partial merge.
- A single-item mutation arriving for an entityId that's a member of an **in-flight batch** —
  must wait for the whole batch to clear, not just that one entityId.

---

## 2. Component 2 — record locking

New files: `functions/lib/lockLogic.js` + `functions/test/lockLogic.test.js` (node --test, fakes
matching the existing `gatewayLogic.test.js` pattern), `tests/tst_LockManager.qml`.

**Unit — `lockLogic.js`**
- Grant when no lock doc exists.
- Grant (with fresh `acquiredAt`/`expiresAt`) when the existing lock doc's `expiresAt` is in the
  past.
- Grant/renew when the existing lock is held by the *same* `holderUid` (re-entrant call).
- Reject with `{ holder: { name, role, expiresAt } }` when held by a different caller and not
  expired — verify the response carries enough for the UI message, no more (don't leak unrelated
  fields).
- `releaseLock` deletes the doc only when the caller's `holderUid` matches what's stored; a
  mismatched release is a silent no-op (not an error, not a delete) — this is the guard against a
  stale/duplicate release call stealing someone else's freshly re-acquired lock.
- Idempotency: two acquire calls with the same `requestId` in quick succession don't double-write
  or produce inconsistent `acquiredAt` values.

**Regression**
- None directly — new collection, new functions. Confirm existing `recordMutation`/
  `recordMutationsBatch`/`runCutover` tests are untouched by adding `lockLogic.js` alongside them.

**Functional**
- Two simulated concurrent `acquireLock` calls for the same `entity+entityId`, fired at the fake
  clock's same instant — exactly one grants, the other gets the holder-info rejection.
- Full hold-then-release cycle: acquire → (simulated edit work) → release → a subsequent acquire
  from a different caller now succeeds immediately, without waiting for TTL.

**Negative**
- Missing/malformed `entity` or `entityId` in the request body → `400`.
- Missing/invalid auth token → `401`, consistent with the existing `recordMutation` auth handling.

**Edge cases**
- TTL boundary: lock's `expiresAt` exactly equal to "now" — decide and test which side of the
  boundary counts as expired (recommend: expired, i.e. `expiresAt <= now` grants a new acquire).
- Renewal heartbeat arriving a moment before vs. a moment after expiry (the "just missed it" case)
  — document the resulting behavior (a late renewal that lands after expiry should be treated as a
  fresh acquire attempt, competing normally with anyone else, not an automatic renewal).
- Simulated client crash (never calls `release`) — confirm a different caller can acquire once the
  fake clock advances past the TTL, with no manual cleanup step.
- Client-side (`LockManager.qml`): heartbeat timer stops correctly on release/dialog-close (no
  leaked timer still renewing a lock nobody holds a dialog for anymore).

---

## 3. Component 3 — server-side whole-record CAS backstop

Extends `functions/test/gatewayLogic.test.js`.

**Unit**
- Matching `before` vs. currently-stored doc → write proceeds exactly as today; add this as an
  explicit case rather than assuming existing tests already cover it.
- Mismatched `before` vs. current → rejected, `workingRef` untouched, response includes `current`.
- `before: null` (claiming "create") when a doc already exists at `workingRef` → detected as a
  conflict, not silently treated as an update.
- `before: {...}` (claiming "update") when `workingRef` doesn't exist (already deleted by someone
  else) → detected as a conflict, not a crash on `.data()` of a non-existent snapshot.
- **Ordering regression, important to lock in:** an idempotent retry (existing `audit_log` entry
  for this `requestId`) short-circuits *before* the CAS read ever happens — a retried request must
  never be rejected as a "conflict" against its own already-applied result.
- Deep-equal comparison is not sensitive to object key insertion order (don't implement this as a
  naive `JSON.stringify` compare — write a test that constructs the same object two different ways
  and asserts they're still considered equal).

**Regression**
- Existing `applyMutation` behavior for the non-conflicting path (create/update/delete, batch
  variant) is unchanged in output shape and audit_log content.

**Functional**
- Two simulated concurrent `applyMutation` calls for the same `entityId` with different
  `before`/`after` — first (by transaction commit order, not necessarily send order) succeeds,
  second is rejected and its response's `current` matches exactly what the first one wrote.

**Negative / critical edge case to verify against real schemas at implementation time**
- **Server-side auto-stamped fields** (if any working-tier doc gets a field set outside the
  client's `before`/`after` — e.g. a server timestamp added by some other path) would make whole-
  record CAS spuriously fail on *every* write touching that doc. Needs an explicit audit of the 5
  working-tier collections' actual field sets before this ships — flagging now so it isn't
  discovered mid-implementation.

---

## 4. Component 4 — atomic server-side deltas

Extends `functions/test/gatewayLogic.test.js` with `applyDelta` coverage; updates
`tests/tst_InventoryStore.qml`/`tests/tst_StockBatchStore.qml` (if they exist — confirm at
implementation time) to assert the new `recordDelta` call shape.

**Unit — `applyDelta`**
- Single-field delta: `current + delta` computed and written correctly.
- Multi-field delta (the `topUpOldest` case: `qtyReceived` and `qtyRemaining` together) — both
  fields land atomically in one transaction, never one without the other.
- Floor violation → rejected, `{ error: "insufficient-quantity", field, current }`, and — critical
  — **no fields at all** get written for that call, even ones that individually wouldn't have
  violated their own floor (all-or-nothing across the whole `deltas` map).
  - Floor exactly met (delta brings the value to *exactly* the floor, not below) → succeeds. This
    is an off-by-one worth its own explicit test (`>=` vs `>` at the boundary).
- Missing field on the current doc (`undefined`) is treated as a `0` baseline, not a crash.
- `workingRef` doesn't exist at all → `404`, not-found, no attempt to compute a delta against
  nothing.
- Idempotent retry (existing `audit_log` entry) short-circuits before the delta logic runs, same
  ordering guarantee as Component 3.
- `audit_log` entry's `before`/`after` reflect the server-observed values from inside the
  transaction, not whatever the client happened to send (there's nothing client-sent to compare
  against here, which is the point — verify the audit entry is still fully populated and correct).

**Regression**
- `StockBatchStore.consumeFifo`'s FIFO batch-selection logic itself (which batches, how much from
  each) is **unchanged** — only how the resulting quantity change gets written changes. Existing
  FIFO-selection tests (if any — locate at implementation time) must still pass untouched.
- `InventoryStore.restock`'s supplier-resolution and batch-creation side effects (unrelated to the
  delta itself) are unaffected.

**Functional**
- Two simulated concurrent `deductStock` calls for the *same product* from two different "devices"
  (two independent `applyDelta` invocations, not serialized by a lock — this is exactly the
  scenario locking does NOT cover) — both deltas land, final `stock` equals
  `original - qty1 - qty2`, neither is silently lost. This is the direct regression test for the
  bug that motivated Component 4 in the first place.

**Negative**
- `deductStock` requesting more than available stock — behavior depends on the still-open
  reject-vs-clamp decision in the design doc §6; write the test to match whichever Taher confirms,
  not both speculatively.

**Edge cases**
- Delta of exactly `0` — still goes through the same transaction path, idempotent, no spurious
  audit noise beyond what any other zero-effect call would produce.
- A delta mutation (stock) and a whole-record CAS mutation (e.g. product name/price edit) landing
  concurrently on the *same* inventory doc — both should succeed independently, since the delta
  path never reads or depends on non-quantity fields. Important interaction test between
  Components 3 and 4 sharing one document.

---

## 5. Cross-component integration

- Full worked scenario from the design doc §7.2 (order completion): lock acquired → FIFO
  consumption via deltas → order/transaction writes via single-flighted, CAS-backed
  `recordMutation` → lock released. Build this as one fake-driven scenario test exercising all four
  components together, not just each in isolation.
- A second simulated "device" attempting to act on the *same order* mid-flow is turned away at the
  lock-acquire step, before any local state changes on that second device at all — this is the
  concrete behavior Taher asked for and it deserves its own named test, not just implied by the
  unit coverage above.
