# E2E Testing Roadmap

Living document for pending work arising from E2E test development — the QTBUG-49896 investigation
(Skills 40-45), the post-merge backlog (items 1-3), and whatever's found next. Not a point-in-time
checkpoint (those live in `docs/superpowers/specs/`, archived once their arc closes) — this one gets
updated in place as items resolve or new ones surface. Each entry: status, what it is, why it matters,
current thinking. Ordered roughly by priority within each status group, not chronologically.

---

## In progress

### `StockBatchStore._nextBatchId()` has no server-side counter — real production risk, fix approach needs a decision

**Found:** 2026-08-26, as a side effect of debugging `tst_StockBatchStoreE2E.qml`'s first real CI
failure (see `docs/superpowers/specs/2026-08-25-e2e-testing-phase2-followup-CHECKPOINT.md`'s
follow-up round).

**What's wrong:** unlike `SupplierStore.nextSupplierId()` / `StaffStore.nextStaffId()` (both use
`FirebaseService.mintCounterValue` — a real Firestore-transaction-backed counter), `_nextBatchId()`
purely scans the local `batches` array for the highest `BAT-<year>-NNN` and returns +1. Two clients
with incomplete/stale local caches (or, as happened in the E2E suite, one client whose cache was
never populated in the first place) can independently compute the identical "next" id and both
attempt to create it.

**Why this isn't data-corruption-risk, but is a reliability gap:** Firestore's CAS check on
`applyMutation` already rejects the second colliding create — confirmed working end-to-end by
`tst_StockBatchStoreE2E.qml`'s conflict test. So nobody's data gets silently overwritten. The actual
harm: the LOSING client's create is dropped, `StockBatchStore._onMutationConflicted` reconciles that
client's local cache to match the winner's doc, and — today — nothing retries the losing client's
own intended batch. A real restock action could silently vanish from the acting user's perspective.

**Blocked on a decision, not effort — two real options, meaningfully different risk/scope:**

- **Option A — full parity with Staff/Supplier.** Convert `_nextBatchId()` to async
  (`mintCounterValue`-backed), which cascades: `addBatch()` and `addBatchMany()` are both called
  *synchronously* today, and `InventoryStore.qml`'s bulk-import loop (`upsertMany`, ~line 660-731)
  relies on that — it calls `addBatch(..., deferWrite=true)` once per imported row in a tight
  synchronous `for` loop, depending on each call seeing the previous call's freshly-pushed local
  entry to avoid collisions *within* that loop. Converting to async means restructuring that loop to
  sequence N mint calls one at a time (or minting a range up front) — a real change to a working,
  sensitive bulk-import feature, unrelated to anything else in this effort. Higher effort, higher
  risk, but closes the gap at the source and matches the established pattern exactly.
- **Option B — retry-on-conflict, zero changes to `addBatch()`'s contract.** Leave `addBatch()`/
  `addBatchMany()` fully synchronous (no changes anywhere in `InventoryStore.qml` or the import
  loop). Instead, extend `StockBatchStore._onMutationConflicted()`'s handling of a `stock_batch`
  create-conflict specifically: instead of only reconciling the local cache to the winner's doc,
  automatically re-mint a fresh id (now collision-aware, since the local cache just learned about the
  winner) and re-attempt the create with the original doc's data. Smaller, contained, touches only
  `StockBatchStore.qml`. Doesn't prevent the first collision, but does prevent the silent data loss —
  the actual harm identified above.

Leaning towards B for the effort/risk trade-off, but this is Taher's call — not implemented pending
his decision.

---

## Needs Taher's input before it can be scoped or started

### `orderMath.js` / `qml/helper/OrderMath.js` parity

Long-deferred. Not enough carried-forward context to define "parity" honestly (parity with what
reference implementation, checking which specific values) — needs a quick scoping conversation before
this can get a real complexity/effort estimate rather than a guess.

### Account-switch-mid-sync edge case (the `loadingMore` single-flight guard)

The `if (loadingMore) return` guard (Skill 39) that fixed the concurrent-reset race has a known,
explicitly-accepted trade-off: a genuine account switch mid-sync won't interrupt the in-flight fetch.
Deliberately left unimplemented pending Taher's own call on whether the added complexity to fix this
properly is worth it given how rarely this scenario likely occurs — not something to default on
without his input.

---

## Explicitly scoped out — not forgotten, just not this round

### `functions/index.js` handler tests for the other 5 endpoints

`functions/test/index.handlers.test.js` (added for backlog item 2) covers `recordMutation`/
`recordDelta`/`recordMutationsBatch` — the three sharing the auth→validate→apply→respond shape and
Skill 43's specific response-contract risk. `acquireLock`/`releaseLock`/`provisionMember`/
`runCutover`/`computeAnalysis` share less of that exact risk pattern and weren't covered. Worth doing
eventually; not urgent since nothing found so far implicates them specifically.

### Phase 2 probe (Felgo headless component testing)

Closed as answered, not "still open" — see the phase-2-followup checkpoint's own entry. Felgo's SDK
doesn't bootstrap under bare `qmltestrunner` at all (confirmed: no test in this repo had ever actually
exercised `Constants.qml`'s `import Felgo` before the probe's first real run; CI never installs Felgo
either). Cost to actually solve (reverse-engineering Felgo's own testing story) is unbounded; value
(headless-testing 2 dialogs' layout) is incremental — app already ships without it. If this ever
becomes worth revisiting: the cheaper alternative is extracting the pure spacing/sizing math those
dialogs use into a Felgo-independent helper and testing *that*, rather than testing Felgo's runtime
directly.

---

## Coordination / process (not code)

### PR #49 (`review/post-pr45-qml-audit`) likely conflicts with this session's `functions/index.js` work

Different session, already showing `mergeable: false` / `dirty` against `main` as of 2026-08-26 —
extracts `send()` into `functions/lib/httpResponse.js` with its own test file, which overlaps with
this effort's own changes to the same function (the try/catch safety net, PR #45) and its own test
coverage (`functions/test/index.handlers.test.js`, backlog item 2). Taher is handling this directly;
noted here so it doesn't get lost given how test-development-adjacent it is.

---

## Resolved this arc (for context — full detail in `docs/superpowers/specs/` and `SKILLS.md`)

- QTBUG-49896 (QML XHR losing `status` at DONE) — root cause found and fixed, confirmed on a real CI
  run. Skills 40-45.
- Dropped `conflict` field in `recordMutation`'s 409 response (Skill 43) — real bug, fixed, though not
  the cause of the E2E failure it was originally diagnosed for (Skill 44 covers that correction).
- `functions/index.js` handler-level test coverage — added (Skill 46 covers the testing technique).
- Conflict-scenario E2E coverage for all five `mutationConflicted`-connected stores (previously only
  `OrdersStore` had one) — Inventory/Staff/Supplier/StockBatch all added.
- Two real id-collision bugs found and fixed in the *new* test files themselves (Supplier's
  `nextSupplierId` seedMax, StockBatchStore's `_nextBatchId` — the latter being how the item above was
  found).
- Stale comment in `StockBatchStore.qml`'s `_onMutationConflicted` (claimed a conflict path that no
  longer exists post-`recordDelta`-conversion) — corrected.
