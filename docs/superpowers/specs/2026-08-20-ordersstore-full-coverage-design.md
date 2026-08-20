# Design: OrdersStore.qml — Full Test Coverage

**Status:** Draft — awaiting Taher's review before any implementation plan is written.
**Branch:** `docs/e2e-testing-phase2-followup`
**Skills invoked to reach this doc:** `superpowers:brainstorming`, `qt-development-skills:qt-qml`,
`qt-development-skills:qt-qml-test`.
Full back-and-forth — including the AuthService-contamination sweep that fed into this scope — is
in `CHECKPOINT.md` (root, this session).

Standing instructions this spec is written against (Taher, this session): always the correct fix
over a shortcut; 100% relevant coverage on anything touched; every scenario dimension covered
(happy path, edge cases, negative tests, async behavior, multi-user usage); Claude decides which
test layer each piece belongs in.

## 1. Problem statement

`qml/model/OrdersStore.qml` is 764 lines, 29 functions. Direct test coverage today: **4** functions
(`_clone`, `_normalizeOrder`, `applyAdjustment`, `getById`), across two files —
`tests/tst_OrdersStore_applyAdjustment.qml` and `tests/tst_OrdersStore_normalization.qml`. The
other 25 have zero direct coverage, including real business logic: tax/discount rounding
(`computeOrderTotals`), order creation, bulk import, multi-page Firestore sync, and the
conflict-reconciliation path that fires when two users edit the same order.

`test/e2e/tst_OrdersE2E.qml` exists (2 tests) but covers `DataModel.completeOrder`'s stock-deduction
path only — it never calls `OrdersStore.addOrder`, `upsertMany`, `nextOrderId`, `_fetchFromFirebase`,
or `syncFromFirebase` at all. Those are OrdersStore's only functions that touch the network, and
right now none of them are exercised beyond a synchronous-exception smoke test at best.

## 2. A note on what "100%" means here, and how it gets verified

There is no coverage-instrumentation tool available for QML/JS in this codebase or this sandbox (no
`gcov`/`istanbul` equivalent proven to work here). "100% coverage" in this spec means: **every
function, and every conditional branch inside it, has at least one test that exercises it** —
verified by manual audit (every line cross-checked against the test plan line by line), the same
method this codebase has used throughout (see `CHECKPOINT.md`'s "cross-checked every store-member
reference" language from earlier sessions). This is not a tooling gap unique to this task, and it's
flagged here rather than silently assumed, since "100%" is a specific, checkable claim and I don't
want to make it and have it mean something looser than it sounds.

## 3. Function classification — routes every function to a test layer

**Group A — pure/local logic. `tests/*.qml` (`qmltestrunner`), fully verifiable, no network
involved even indirectly.** (22 functions)

| Function | Current coverage | Notes |
|---|---|---|
| `_onMutationConflicted` | none | Multi-user reconciliation logic — see §5 |
| `_normalizeOrders` | none | Batch wrapper around `_normalizeOrder` |
| `clear` | none | |
| `_normalizeOrder` | partial (via `_clone`/`applyAdjustment` tests) | Needs direct, exhaustive tests of its own default-filling branches |
| `computeOrderTotals` | none direct (only indirectly exercised) | Real math: per-line discount (flat/percent, clamped), per-rate tax breakdown, rounding order. Highest-value gap in this file. |
| `_mergeOrder` | none | |
| `_refreshCounts` | none direct | |
| `_commit` | none direct | Calls `Gateway.recordMutation` — safe under the established `Gateway.mode="gateway"` + `AuthStore.idToken=""` test pattern (fire-and-forget, no real network) |
| `_clone` | existing | |
| `pendingCount` | none | Trivial getter |
| `completedThisMonth` | none | Trivial getter |
| `parseCurrency` | none direct | |
| `formatCurrency` | none | Uses `Intl.NumberFormat` — will confirm it resolves under `qmltestrunner`'s JS engine while writing; flagged, not expected to be a real blocker |
| `findIndexById` | none direct | |
| `get` | none | |
| `getById` | existing | |
| `openOrdersForProduct` | none | |
| `updateOrder` | none | Same safe-`Gateway.recordMutation` pattern as `_commit` |
| `applyAdjustment` | existing | Already covered, not in this pass |
| `deleteOrder` | none | Calls `Gateway.recordMutation` directly (not via `_commit` — a minor structural inconsistency in the source, noted, not a bug worth fixing here) |
| `totalRevenue` | none | |
| `processingCount` | none | |

**Group B — Firebase-touching, genuinely async. Smoke-tested at the `qmltestrunner` layer (matches
this codebase's existing convention — see `CategoryStore::test_syncFromFirebase_dispatches_without_throwing`,
which is a bare `verify(true)` after the call), fully verified at the E2E/emulator layer.** (7 functions)

| Function | Why it can't be a real qml-layer test |
|---|---|
| `_load` / `_resetAndFetch` | Wraps `_fetchFromFirebase`; **the `loadingMore` re-entrancy guard itself is pure and local** — testable at the qml layer the same way `TransactionStore_resetGuard::test_resetAndFetch_is_a_no_op_while_a_fetch_is_already_in_flight` already does for a different store. Real fetch behavior still needs the emulator. |
| `_fetchFromFirebase` | Calls `FirebaseService.query(...)` — real network |
| `syncFromFirebase` | Thin wrapper over `_resetAndFetch` |
| `nextOrderId` | Calls `FirebaseService.mintCounterValue` — real network, and the whole reason it exists (vs. `max(existing)+1`) is concurrent-mint safety, which is meaningless to test without concurrent real requests |
| `addOrder` | Depends on `nextOrderId` |
| `upsertMany` | Calls `FirebaseService.mintCounterBatch` — same reasoning as `nextOrderId` |

## 4. Adjacent things found during the audit — not new work, flagging so nothing gets duplicated

- **`functions/lib/orderMath.js`** is a Node port of **`qml/helper/OrderMath.js`** — a *different*
  module from `OrdersStore.computeOrderTotals`, used for per-line/per-consumption analytics
  allocation. Its own docstring says it deliberately mirrors `computeOrderTotals`'s rounding so
  analytics reconcile to order totals. It already has parity-fixture tests
  (`functions/test/fixtures/`, exercised by both `tests/tst_RealisedMath.qml` /
  `tests/tst_BreakdownMath.qml` and `functions/test/*.test.js`). **Open question for Taher, §7.**
- **Tenant/multi-user access control for the `orders` collection** is already covered generically:
  `firestore.rules.test.js`'s `WORKING_COLLECTIONS` array includes `"orders"` and is looped over
  (`for (const collection of WORKING_COLLECTIONS)`), so tenant-isolation is already tested for
  orders, not something this pass needs to add. `firestore.rules` itself has no order-specific rule
  — orders fall under the generic `match /{collection}/{docId}` working-tier rule.
- **Role-based "own orders" filtering** (a Staff role seeing only their own orders) is a separate
  module, `StaffScope`, already tested (`StaffScope::test_ownOrders_filters_to_self` etc.) — not
  part of `OrdersStore.qml` itself. This pass doesn't duplicate that.

## 5. Scenario taxonomy (per Taher's explicit ask — not just line coverage)

- **Happy path / edge / negative**, per Group A function: e.g. `computeOrderTotals` needs zero-line
  orders, 100%-discount lines (net floors at 0, not negative), discount-exceeds-gross clamping,
  mixed taxable/non-taxable lines, multiple tax rates in one order (breakdown array), and the
  rounding-order dependency itself (subtotal/discount/tax each rounded before net/total are
  derived, not rounded once at the end — a real, easy-to-get-wrong detail in the source).
- **Async behavior** (Group B, E2E/emulator): pagination continuation (seed >50 orders, past
  `_pageSize`, confirm the recursive `_fetchFromFirebase` call assembles the full set and `hasMore`
  correctly reaches `false`); a failed/rejected fetch (confirm `loadingMore` still resets and
  nothing throws).
- **Multi-user usage** — the one dimension nothing in this file currently tests at all:
  1. **Concurrent `addOrder`** from two simulated sessions — confirms `mintCounterValue`'s
     collision-avoidance actually holds under real concurrent requests, not just in the code
     comment's stated intent.
  2. **Conflicting edits to the same order** from two sessions — one write wins, the other's
     `Gateway.recordMutation` gets rejected by the server's CAS check, and **`_onMutationConflicted`
     fires and reconciles the loser's local state**. This is the standout scenario for "multi-user":
     it's Group A code (pure, qml-testable in isolation) but its real trigger is inherently
     multi-user, so the *end-to-end* version of this test belongs at the E2E layer, seeded through
     two real emulator-backed writes — not simulated by calling the function directly with a fake
     payload.

## 6. Proposed file layout

**New `tests/*.qml` files** (matches the existing per-concern split —
`_applyAdjustment`/`_normalization` are already separate files):

- `tests/tst_OrdersStore_totals.qml` — `computeOrderTotals`, `parseCurrency`, `formatCurrency`
- `tests/tst_OrdersStore_queries.qml` — `get`, `getById` (new direct cases beyond existing),
  `findIndexById`, `openOrdersForProduct`, `pendingCount`, `completedThisMonth`, `totalRevenue`,
  `processingCount`
- `tests/tst_OrdersStore_mutations.qml` — `addOrder` (smoke-test half), `updateOrder`, `deleteOrder`,
  `clear`, `upsertMany` (smoke-test half), `_mergeOrder`, `_commit`, `_refreshCounts`, `nextOrderId`
  (smoke-test)
- `tests/tst_OrdersStore_sync.qml` — `_onMutationConflicted` (full coverage), `_load` /
  `_resetAndFetch` (re-entrancy guard, real coverage) / `_fetchFromFirebase` / `syncFromFirebase`
  (smoke-test only)

**E2E additions** — proposed as new test functions in the existing `test/e2e/tst_OrdersE2E.qml`
(same file as the current `completeOrder` scenarios — it's already the established "Orders" E2E
home, and keeps everything Orders-related in one place rather than fragmenting into a second E2E
file). Open to splitting into a separate file if Taher prefers — noted as an open question, §7:

1. `addOrder` against the real emulator — verify the minted ID, the persisted document shape, and
   that stored totals match `computeOrderTotals`'s math.
2. Concurrent `addOrder` calls — no ID collision.
3. `upsertMany` bulk import against the emulator — skip / rename / overwrite policies each verified
   against real resulting Firestore state.
4. `syncFromFirebase` pagination — seed >50 orders, confirm the full set assembles across pages.
5. The multi-user conflict scenario from §5.2.

## 7. Open questions for Taher — not decided unilaterally

1. **`orderMath.js`/`OrderMath.js` parity**: fold a parity check into this pass, or leave it as a
   separate, later piece of work? It's related (same rounding rules, by design) but a distinct
   module with its own existing test suite — my default lean is **defer**, since it's not
   `OrdersStore.qml` and folding it in would blur this pass's scope, but it's a real finding worth
   a decision either way.
2. **E2E file layout**: extend `test/e2e/tst_OrdersE2E.qml` (my proposal, §6) or create a new file
   scoped to OrdersStore's own async surface specifically?
3. Any Group A function Taher considers **not worth testing** (e.g. the two one-line getters
   `pendingCount`/`completedThisMonth`)? Default in this spec is still "test it" per the 100%
   instruction, but flagging in case that's more than intended for trivial wrappers.

## 8. Rollout order (proposed, pending Taher's review of this spec)

1. This spec, reviewed and adjusted per Taher's answers to §7.
2. Implementation plan (`docs/superpowers/plans/`), broken into the same four-plus-E2E slices as §6,
   each its own commit — matching how the original OrdersStore test-coverage work was already
   scoped (see `CHECKPOINT.md`'s "four-file split approved" note from earlier this project).
3. Group A files first (`tests/tst_OrdersStore_totals.qml` → `_queries` → `_mutations` → `_sync`) —
   no emulator dependency, fastest feedback loop, and de-risks the E2E work by nailing down
   `computeOrderTotals`'s exact behavior before writing E2E assertions that depend on it.
4. E2E additions last, once the Group A math tests have settled `computeOrderTotals`'s exact
   expected outputs to assert against.
