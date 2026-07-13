# Test Plan — P0 Gateway Gap-Closure + Orders/Staff/Suppliers Fast-Follow

**Branch:** `feature/p0-gateway-orders-staff-suppliers`
**Related:** `docs/superpowers/plans/2026-07-11-p0-gateway-fast-follow.md` (what was built),
`docs/superpowers/specs/2026-07-11-p0-gateway-orders-staff-suppliers-CHECKPOINT.md` (full session log)

This covers three tiers: automated unit tests (verified, CI-safe today), automated tests that
exist but need a local run before you can trust them, and manual on-device scenarios that no
automated test in this repo covers.

---

## 1. Unit tests — automated, verified, safe to run anywhere (`cd functions && npm test`)

48 tests, `node --test`, no network/emulator dependency. All passing as of the last commit on
this branch.

### `functions/test/gatewayLogic.test.js` (16 tests) — covers `recordMutation`'s core logic

| Function | Scenarios covered |
|---|---|
| `parseBearerToken` | missing header → null; malformed header → null; valid `Bearer <token>` → extracted; case-insensitive scheme |
| `validateMutationRequest` | unknown entity rejected; disallowed action rejected; missing `entityId`/`requestId` rejected; valid request accepted + collection resolved; `inventory`→`inventory`, `stock_batch`→`stock_batches`, `order`→`orders`, `staff`→`staff`, `supplier`→`suppliers` all resolve correctly |
| `applyMutation` | update writes working-doc + audit_log entry with correct shape; delete removes the working doc but still writes the audit entry; a retried `requestId` is a complete no-op (idempotency) |

### `functions/test/cutoverLogic.test.js` (10 tests) — covers `runCutover`'s core logic

| Function | Scenarios covered |
|---|---|
| `validateCutoverRequest` | non-owner rejected; missing tenant context rejected (distinct error from non-owner); missing/wrong confirmation string rejected; owner + exact `"CUTOVER"` string accepted |
| `buildCutoverMarker` | produces the exact audit_log marker shape (`action: "cutover"`, `entity: "tenant"`, etc.) |
| `deleteCollection` | single commit when under the batch-size limit; chunks into multiple commits at the boundary; empty collection is a true no-op |
| `zeroInventoryStock` | every doc's `stock` set to 0; chunks at the boundary same as `deleteCollection` |

### `functions/test/batchMutationLogic.test.js` (13 tests) — covers the new `recordMutationsBatch`

| Function | Scenarios covered |
|---|---|
| `validateBatchMutationRequest` | unknown entity, missing batch `requestId`, empty `items[]`, batch over `MAX_BATCH_SIZE` (200), and an item with a disallowed action or missing `entityId` are all rejected; a batch exactly at 200 items and a valid batch both accepted |
| `applyMutationsBatch` | one working-doc write + one audit entry per item; delete-action items remove the working doc; an already-applied item (by `requestId:entityId`) is skipped on retry; a batch where *every* item was already applied is a complete no-op; the whole batch runs as exactly **one** `runTransaction` call, not N |

### Pre-existing, unchanged (9 tests)
`breakdownMath.test.js`, `realisedMath.test.js` — untouched this session, still passing, confirms
the CF-side refactor didn't regress unrelated analytics logic.

**Regression value:** these 48 tests are your fast, no-setup safety net. Run them before every
commit on top of this branch and before merging.

---

## 2. Written but NOT verified in this environment — run these before trusting them

None of the three files below could be executed in the sandbox this work was done in (no Qt
toolchain, no network access to Firebase's emulator). They're written to the repo's existing
conventions and manually reviewed, but treat them as **unverified** until you've actually run them.

### `tests/tst_Gateway.qml` + `tests/tst_OutboxStore.qml` — run with:
```bash
qmltestrunner -input tests -platform offscreen
```

**`tst_Gateway.qml`** (7 tests): `mode` defaults to `"direct"`; `_collectionFor` resolves all 7
registered entities (`inventory`, `stock_batch`, `stock_movement`, `transaction`, `order`,
`staff`, `supplier`) and returns `""` for an unknown one; in `"gateway"` mode, `recordMutation`
and `recordMutations` enqueue into the outbox correctly (entity/action/requestId/items shape) —
does **not** exercise the actual network send (see §4).

**`tst_OutboxStore.qml`** (14 tests): `enqueue`/`enqueueBatch` store items with correct defaults;
`dueItems` excludes backed-off entries; `markSent` removes only the matching item; `markFailed`
follows the exact documented backoff schedule (2s/8s/30s/2m/10m, then caps); `nextDueInMs`
reports the soonest due time; persistence survives a simulated relaunch (`_load()` re-invoked
against the real Settings-backed store); `clear()` wipes both in-memory and persisted state.

**If these fail:** check first whether it's a real bug vs. an environment issue (missing
singleton import path, `Settings` backend unavailable, etc.) before assuming the underlying code
is wrong — these were never executed even once before now.

### `test/firestore.rules.test.js` — run with:
```bash
npm install   # root package.json, first time only
firebase emulators:exec --only firestore "node --test test/"
```

25 tests, matrix of {4 ledger collections + 4 working-tier collections} × {member / non-member /
anonymous} × {read / write}, plus one test isolating the wildcard match's ledger guard
specifically. Confirms: a member can read but never write any ledger collection
(`audit_log`/`transactions`/`stock_batches`/`stock_movements`); a member can create/update/delete
any working-tier collection (`inventory`/`orders`/`staff`/`suppliers`); a non-member or
unauthenticated request is denied everywhere.

---

## 3. Regression checklist — areas touched indirectly, re-verify these didn't break

Nothing here should behave differently (`Gateway.mode` is still `"direct"`), but these code paths
were edited or sit downstream of edited singletons:

- [ ] **App launches without QML errors.** `Gateway.qml` and `OutboxStore.qml` were both edited
  (new functions/properties added). A bad edit here would show up as a QML console error at
  startup or a broken binding — this is the single most important smoke test to run first, since
  nothing in this repo's automated tests can catch a QML load failure.
- [ ] **Inventory & Stock flows still work** (add product, restock, adjust stock, FIFO
  consumption). Not touched this session, but they share the same `Gateway`/`OutboxStore`
  singletons — a regression there would most likely surface here too.
- [ ] **CF suite still green** after any further edits: `cd functions && npm test` → expect 48/48.

---

## 4. On-device manual test scenarios

Everything below exercises code this session actually changed. `Gateway.mode` stays `"direct"`
for all of it — you're verifying the *new indirection* (store → `Gateway.recordMutation`/
`recordMutations` → `FirebaseService`) behaves identically to the old direct calls, not testing
the gateway/audit-log path itself (that needs the deploy+cutover sequence, out of scope here —
see §5).

### Orders
- [ ] Create a new order (NewOrderDialog) → appears in the list, persists to Firestore.
- [ ] Edit an existing order's fields (customer/status/items/notes/etc.) → persists correctly.
- [ ] Apply a line-item adjustment to a completed order → adjustment recorded, totals recompute.
- [ ] Delete an order → removed from the list **and** from Firestore (not just hidden locally).
- [ ] **Approve All Pending** with:
  - [ ] zero pending orders (no-op — confirm no crash, no spurious network call)
  - [ ] one pending order
  - [ ] a realistic bulk batch (a few dozen) — this is the new batch code path
    (`Gateway.recordMutations`); this is the highest-risk scenario in this whole session's
    change set since it replaced a working `FirebaseService.putMany()` call
- [ ] Bulk-import orders from CSV, specifically new rows (not overwrites) — exercises the
  `upsertMany` create path, migrated this session.

### Staff
- [ ] Add a new staff member → appears, persists.
- [ ] Update staff fields (name/email/phone/role/department/status/salary/joinDate).
- [ ] Set/change a staff member's app login link (`setAppUid` path) — a separate update site from
  the one above, test it independently.
- [ ] Delete a staff member → removed correctly; confirm any staff-count/activity-feed displays
  update too.

### Suppliers
- [ ] Add a new supplier → appears, persists.
- [ ] Update a supplier's fields → persists; confirm the list stays sorted by name afterward.
- [ ] Delete a supplier → removed correctly.

### Cross-cutting
- [ ] Kill the app mid-action (e.g. right after tapping Approve All Pending) and relaunch —
  confirm no corrupted local state (this doesn't test the outbox's real persistence-across-
  relaunch guarantee, since that only activates in `"gateway"` mode, but it's a reasonable
  general resilience check).
- [ ] Test with the device offline / poor connectivity during a write — confirm the existing
  error-handling/toast behavior is unchanged from before this session.

---

## 5. Explicitly out of scope for this test plan

Validating the gateway/audit-log path *actually recording entries* requires deploying Cloud
Functions + the locked Firestore rules to a real (ideally `dev`) environment, running
`runCutover`, and flipping `Gateway.mode` to `"gateway"` there. That's a deliberate, separate,
higher-stakes step — not part of merging this branch. If/when you do that in a dev environment,
the scenarios worth adding at that point: confirm an `audit_log` entry appears for each mutation
type (create/update/delete/batch), confirm offline queuing + drain-on-reconnect actually works
end-to-end, and confirm the locked ledger rules reject a manual client write attempt for real
(not just in the emulator).
