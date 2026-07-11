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
- [ ] A3. CF unit tests for `runCutover`: owner-only gate rejection; shape of the wipe operation
      (mocked). TDD, verified in-sandbox. Commit.
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

- [ ] B1. Design: `Gateway.recordMutations(entity, items)`, `items = [{entityId, action, before,
      after}, ...]`. Direct mode → single `FirebaseService.putMany` (preserves today's
      performance). Gateway mode → new CF `recordMutationsBatch`: one Firestore batched write
      covering all N working-doc writes + N audit_log entries atomically (all-or-nothing —
      a compliance improvement over N independent writes). One outbox entry represents the
      whole batch (retried as a unit).
- [ ] B2. CF: `recordMutationsBatch` in `functions/index.js` + `functions/test/` coverage
      (rejects empty array, rejects a batch mixing entities beyond a sane cap, atomicity
      contract, per-item idempotency). TDD, verified in-sandbox. Commit.
- [ ] B3. `Gateway.qml`: implement `recordMutations()`. Add coverage to `tst_Gateway.qml`.
      Written to convention; **not runnable in-sandbox**. Commit.

## Phase C — Store migrations (one commit each, push-permission asked after each)

- [ ] C1. `OrdersStore.qml`: create (L116)/update (L184)/delete (L612) → `Gateway.recordMutation`;
      `approveAllPending` (L543) → `Gateway.recordMutations`. Add `order`→`orders` to
      `ENTITY_COLLECTIONS` (functions) and `_collections` (Gateway.qml). Test coverage added to
      an orders test file (written; QML run not verifiable in-sandbox). Commit. **Ask push
      permission.**
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
