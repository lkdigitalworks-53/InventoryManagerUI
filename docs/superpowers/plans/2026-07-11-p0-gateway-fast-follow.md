# Plan — P0 Gateway: Close Testing Gaps + Orders/Staff/Suppliers Fast-Follow

**Spec:** `docs/superpowers/specs/2026-06-06-P0-compliance-gateway-design.md`
**Checkpoint:** `docs/superpowers/specs/2026-07-11-p0-gateway-orders-staff-suppliers-CHECKPOINT.md`
**Branch:** `feature/p0-gateway-orders-staff-suppliers`

## Decisions this plan encodes
1. Close testing gaps for the already-shipped inventory/stock gateway code, not just new code.
2. `approveAllPending`'s bulk write gets a new batch-aware Gateway method (not a per-item loop).
3. One commit per logical unit; push-permission requested after each commit.

## Sandbox constraints (read before judging "done")
- **No Qt/QML toolchain in this sandbox** (`qmltestrunner`/`qmake`/`cmake` all absent — confirmed
  same limitation noted in the 2026-07-10 checkpoint for `tst_EnvConfig.qml`). All QML test
  files in this plan are **written to the correct convention but cannot be run here**. They need
  a local `qmltestrunner` pass before merge, same as prior sessions.
- **No network to Firebase's emulator distribution** (only npm/GitHub/PyPI/crates domains are
  allowlisted, not `*.googleapis.com`). `@firebase/rules-unit-testing` needs the Firestore
  emulator to actually run — the rules test file gets written but **cannot be executed here**.
- Node.js CF tests (`node --test`, `lib/*.js` pattern) **are** fully runnable/verifiable here —
  confirmed working sandbox capability, no network dependency.

## Phase A — Close gaps in already-shipped inventory/stock gateway code

- [x] A1. Extract testable request-validation logic (entity/action allowlist checks, idempotency
      key derivation, response shaping) out of `functions/index.js` into `functions/lib/gatewayLogic.js`
      — pure functions, no Admin SDK calls — mirroring the existing `lib/breakdownMath.js` pattern.
      Behavior-preserving refactor (safe: not yet deployed). TDD, verified in-sandbox. Commit.
      **DONE 2026-07-11.** `serverTimestamp` is passed in as a param (not computed inside the lib)
      so `gatewayLogic.js` has zero Firebase SDK dependency of its own.
- [x] A2. CF unit tests (`functions/test/gatewayLogic.test.js`) for `parseBearerToken`,
      `validateMutationRequest`, and `applyMutation` via a hand-rolled fake Firestore
      (dependency-injected `db`, not the real SDK): rejects unknown entity/disallowed
      action/missing fields; correct working-doc set vs delete; correct audit_log shape;
      idempotency (retried requestId → zero writes). 13 new tests, all passing; full suite
      (22 tests) green. `index.js`'s `recordMutation` rewired to call this module — behavior
      preserved, verified via `node --check` + full test run. **DONE 2026-07-11.**
- [x] A3. CF unit tests for `runCutover`: owner-only gate rejection; shape of the wipe operation
      (mocked). TDD, verified in-sandbox. Commit.
      **DONE 2026-07-11.** Extracted to `functions/lib/cutoverLogic.js`
      (`validateCutoverRequest`, `buildCutoverMarker`, `deleteCollection`, `zeroInventoryStock` —
      all batch-chunking-size-injectable for testability). 10 new tests. Caught and fixed a real
      behavior regression during rewiring: my first pass collapsed the original's distinct
      `no-tenant-context` vs `owner-only` error strings into one — restored to match original
      exactly before committing. Full suite: 32/32 passing.
- [ ] A4. `tests/tst_OutboxStore.qml`: enqueue → dueItems → markSent/markFailed; backoff schedule;
      persistence across relaunch. Written to convention; **not runnable in-sandbox**. Commit.
- [ ] A5. `tests/tst_Gateway.qml`: `mode:"direct"` falls through to a plain write (no audit call);
      `mode:"gateway"` routes through the outbox; `_collections` mapping correctness. Written to
      convention; **not runnable in-sandbox**. Commit.
- [ ] A6. `firestore.rules.test.js` (new, root-level `test/` dir, `@firebase/rules-unit-testing`
      convention): ledger collections deny client writes; working-tier collections allow tenant
      members, deny non-members. Written to convention; **not runnable in-sandbox** (needs the
      Firestore emulator). Commit.

## Phase B — Batch-aware Gateway method (needed by Orders' `approveAllPending`)

- [x] B1. Design: `Gateway.recordMutations(entity, items)`, `items = [{entityId, action, before,
      after}, ...]`. Direct mode → single `FirebaseService.putMany` (preserves today's
      performance). Gateway mode → new CF `recordMutationsBatch`: one Firestore batched write
      covering all N working-doc writes + N audit_log entries atomically (all-or-nothing —
      a compliance improvement over N independent writes). One outbox entry represents the
      whole batch (retried as a unit).
      **DONE 2026-07-11.** Capped at `MAX_BATCH_SIZE = 200` items (400 writes/txn, under
      Firestore's ~500-write transaction ceiling) — documented trade-off, not hidden: a caller
      needing more must split into multiple calls, atomic within each chunk, not across chunks.
- [x] B2. CF: `recordMutationsBatch` in `functions/index.js` + `functions/test/` coverage
      (rejects empty array, rejects a batch mixing entities beyond a sane cap, atomicity
      contract, per-item idempotency). TDD, verified in-sandbox. Commit.
      **DONE 2026-07-11.** New `functions/lib/batchMutationLogic.js`
      (`validateBatchMutationRequest`, `applyMutationsBatch`) + 13 tests. Per-item idempotency
      key = `<batchRequestId>:<entityId>`. Full suite: 45/45 passing.
- [x] B3. `Gateway.qml`: implement `recordMutations()`. Add coverage to `tst_Gateway.qml`.
      Written to convention; **not runnable in-sandbox**. Commit.
      **DONE 2026-07-11** (implementation only — test coverage folded into the A4-A6 pass at
      the end, since `tst_Gateway.qml`/`tst_OutboxStore.qml` don't exist yet and should cover
      both original + batch behavior in one file, not be touched twice). `Gateway.recordMutations()`,
      `_writeDirectBatch()`, `_sendBatch()` added; `OutboxStore.enqueueBatch()` added
      (dueItems/markSent/markFailed already worked generically by requestId, no changes needed
      there). Manually reviewed against qt-qml skill conventions (no toolchain to run
      qmllint/qmltestrunner here).

## Phase C — Store migrations (one commit each, push-permission asked after each)

- [x] C1. `OrdersStore.qml`: create (L116)/update (L184)/delete (L612) → `Gateway.recordMutation`;
      `approveAllPending` (L543) → `Gateway.recordMutations`. Add `order`→`orders` to
      `ENTITY_COLLECTIONS` (functions) and `_collections` (Gateway.qml). Test coverage added to
      an orders test file (written; QML run not verifiable in-sandbox). Commit. **Ask push
      permission.**
      **DONE 2026-07-11.** All 7 call sites migrated (create/update/delete/approveAllPending +
      the `upsertMany` bulk-import create path, which the original audit missed since it wasn't
      counted as one of the 4 "primary" sites). `_commit()` extended to take `action`/`before`
      and route through `Gateway.recordMutation` (was calling the now-removed `_pushToFirebase`).
      `order`→`orders` registered in both `ENTITY_COLLECTIONS` (CF, TDD'd) and `Gateway.qml`'s
      `_collections`. **Test-coverage timing revised**: deferring OrdersStore's Gateway-wiring
      test to the consolidated end-of-session QML pass alongside Gateway/Outbox (same reasoning
      as the B3 deferral — a QtObject singleton with heavy cross-singleton dependencies
      (Gateway/FirebaseService/InventoryStore/AuthStore/TransactionStore) is expensive to test
      in isolation and, since none of it can be run/debugged here anyway, writing it once at the
      end alongside Staff/Supplier keeps unverified QML work in one clearly-flagged place
      instead of scattered partially-right files across commits.
- [ ] C2. `StaffStore.qml`: create (L155)/update (L221, L234)/delete (L176) → `Gateway.recordMutation`.
      Add `staff`→`staff` mapping. Test coverage (written, unverifiable in-sandbox). Commit.
      **Ask push permission.**
- [ ] C3. `SupplierStore.qml`: create (L173)/update (L198)/delete (L216) → `Gateway.recordMutation`.
      Add `supplier`→`suppliers` mapping. Test coverage (written, unverifiable in-sandbox).
      Commit. **Ask push permission.**

## Explicitly out of scope this session
- Deploying Cloud Functions or Firestore rules.
- Running `runCutover` against real data.
- Flipping `Gateway.mode` to `"gateway"`.
- P1–P7 of the roadmap.

## Resume instructions
Check the boxes above as each task's commit lands. If interrupted, `git log --oneline` on this
branch shows exactly which tasks are done; re-read this file's checkboxes + the CHECKPOINT doc
before continuing.
