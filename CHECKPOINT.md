# Session Checkpoint — bulk import >200 rows: chunking, error handling, durable status

**Started:** 2026-08-29
**Branch:** `fix/bulk-import-chunking-durable-status` (new, per standing instruction)
**Status:** In progress
**Prior checkpoint:** archived to `docs/superpowers/specs/2026-08-26-pr_taher_bug_fixes-checkpoint.md`
(preserves the prior session's full step log/history per standing archival convention, rather
than being overwritten in place).

**Rebase note (2026-08-29, later same day):** rebased this branch onto `origin/main` after a
concurrent session (`feature/async-stock-batch-id-minting`, merged as `#53`) landed and touched
several of the same files, including `InventoryStore._upsertManySync`'s signature. Per explicit
instruction, this checkpoint keeps this session's own content as-is rather than merging in that
session's checkpoint text — checkpoints are session-scoped logs, not something two sessions'
worth of content merges into meaningfully. That session's own checkpoint is preserved at
`docs/superpowers/specs/2026-08-27-async-stock-batch-id-minting-CHECKPOINT.md` if needed (see its
own commit for the exact archived filename). The actual code/test conflict resolution from this
rebase is logged in the Step log below, not here.

**Second rebase note (2026-08-30):** rebased again onto `origin/main` after two more concurrent
sessions landed (`d1087b6`/#55 handler-endpoint coverage, and `test/handler-parity-coverage-gap`
merged as `#56`). Same principle applied again: this checkpoint's own content kept as-is; the
`#56` session's checkpoint archived first, to `docs/superpowers/specs/2026-08-30-handler-parity-
coverage-gap-CHECKPOINT.md`, before being overwritten here. `SKILLS.md` needed renumbering again
— see the Step log below for exactly what moved.

**Third rebase note (2026-09-02):** rebased again onto `origin/main` after several more concurrent
sessions landed (PR #49 handler `httpResponse.js` extraction, `orderMath.js` parity coverage, the
`_resetPending` account-switch-mid-sync fix touching `InventoryStore`/`OrdersStore`/`SupplierStore`/
`StaffStore`/`StockBatchStore`/`TransactionStore`, and `feature/pr-ci-status-comment`). Same
principle again: this checkpoint kept as-is; the PR-CI-status-comment session's own checkpoint
archived first, to `docs/superpowers/specs/2026-09-02-pr-ci-status-comment-CHECKPOINT.md`.
`SKILLS.md` needed renumbering again (main now runs through Skill 56). The `_resetPending` fix
touches a different part of each of the 3 stores this fix also modifies (top-of-file pagination
state vs. this fix's `upsertMany`/rollback-handler section) — confirmed no line-level overlap
before assuming a clean auto-merge.

## Ask (Taher, verbatim scope)

Bulk product import fails past 200 rows because `functions/lib/batchMutationLogic.js` caps a
single `recordMutationsBatch` call at `MAX_BATCH_SIZE=200` and returns 400. Client never chunks,
never surfaces the resulting error, and completes the import as if it succeeded — local state
diverges permanently from Firestore with zero user-visible signal. Fix: chunk large imports
client-side, persist status durably so an import survives interruption/crash and resumes, handle
errors/failures properly across **all** stores that go through this path (not just the one
`InventoryStore.upsertMany` case that surfaced it), and write unit/regression/E2E test coverage.
Don't build/run the app. Maintain this checkpoint. Branch, don't push to `main`. Push with the
provided PAT once done, no extra confirmation this session. Don't install Qt tooling.

## Phase 1: Root cause investigation (systematic-debugging skill)

Traced the full chain firsthand rather than trusting the bug report's two line-number pointers at
face value (they were both correct, but the report undersold how deep the problem actually runs):

1. **`functions/lib/batchMutationLogic.js:43`** — `validateBatchMutationRequest` correctly rejects
   `items.length > MAX_BATCH_SIZE (200)` with `400 batch-too-large`. This is a *deliberate,
   documented* server-side limit (keeps a single Firestore transaction under ~500 writes; see the
   file's own header comment) — not itself a bug. Confirmed via `npm test` in `functions/`:
   109/109 passing baseline before any change (Node-executable, no emulator needed — this is the
   one part of this fix genuinely verifiable in this sandbox).
2. **`qml/model/Gateway.qml` `recordMutations(entity, items)`** (client) — accepts an **unbounded**
   `items` array and enqueues it as **one** `OutboxStore.enqueueBatch()` call, one HTTP request.
   Zero awareness of the server's 200-item cap. This is root cause #1 — nothing chunks, ever, for
   any caller.
3. **`qml/model/Gateway.qml` `_sendBatch()`**, the line the bug report points at (`~L499`,
   `OutboxStore.markFailed(item.requestId)`) — every non-2xx, non-409 response (including the
   permanent, payload-shape-only 400 from #1) is treated identically to a transient 5xx/network
   blip: `markFailed()` bumps `attempts` and reschedules with backoff. **`OutboxStore`'s backoff
   schedule (`2s,8s,30s,2m,10m`) caps but never terminates** — a batch that is structurally too
   large retries **forever**, every 10 minutes, always failing the identical way, completely
   silently (only a `console.warn`). Root cause #2: no terminal/permanent-failure classification
   for the batch send path (the single-item `_send()` path and the delta path both already have
   this distinction — `_parseMutationConflict`/`_classifyDeltaResponse` — batch never got it).
4. **`qml/model/InventoryStore.qml` `_upsertManySync()`** (and the identical pattern in
   `qml/model/OrdersStore.qml` `upsertMany()`) — commits the **entire** local array
   (`products = arr` / `orders = arr`) unconditionally, then fires `Gateway.recordMutations(...)`
   fire-and-forget, then calls back to the caller essentially synchronously. The local commit and
   the "done" callback have **zero dependency** on whether the remote write will ever succeed.
   Root cause #3: optimistic-write-without-reconciliation is fine for the *retryable* case
   (that's this app's whole offline-first design, and it's how every other mutation in the app
   already works) but there is no analogous reconciliation path for a *permanent* failure the way
   there already is for a CAS conflict (`Gateway.mutationConflicted` → `_onMutationConflicted` in
   all three of InventoryStore/OrdersStore/SupplierStore, which patch/rollback local state when the
   server's decision can never change on retry). Permanent batch failures have no such signal to
   reconcile against.
5. **`qml/pages/ImportPreviewDialog.qml` `_finishApply()`** — builds its "Imported N rows" message
   **purely from local counts**, with zero knowledge of Gateway/Outbox state, and unconditionally
   calls `importCompleted(msg)`. There is no error branch in this file at all.

**Confirmed via `grep`, not assumed:** `Gateway.recordMutations()` has exactly 3 callers —
`InventoryStore._upsertManySync` (entity `"inventory"`), `OrdersStore.upsertMany` (entity
`"order"`), `SupplierStore.addSupplierWithIdMany` (entity `"supplier"`, itself only ever called
*from inside* `InventoryStore.upsertMany` for newly-discovered supplier names in a product CSV).
All three build `mutationItems`/`docs` where **every item's action is `"create"`** — overwrite/
update rows never go through this batch path (they route through the single-item
`Gateway.recordMutation` via `DataModel.updateProduct`/`updateOrder` elsewhere, which already has
working CAS-conflict handling and is out of scope here). This matters: it means a permanent-failure
rollback for this path is always "remove a row that was optimistically added and never actually
existed server-side," never "revert an edit to something that did." Confirms "all the stores" is a
closed set of exactly 3, all sharing the identical bug shape, all fixed by the same Gateway-level
change plus one reconciliation handler each.

## Phase 2: Design (see full write-up + trade-offs in the response to Taher, not duplicated here)

- Chunk in `Gateway.recordMutations()` itself (single choke point → fixes all 3 stores at once,
  and any future caller, automatically) rather than duplicating chunking logic per store.
- Reuse `OutboxStore`'s **already-durable** (Settings-backed) enqueue as the crash-survival
  mechanism for the chunks themselves — enqueueing N chunks synchronously before `recordMutations`
  returns means every chunk is on disk before the caller's local commit even happens. No new
  persistence needed for "does the data survive a crash" — that already existed and just needed
  to be exercised per-chunk instead of per-oversized-batch.
- Server-side per-item idempotency (`requestId:entityId` audit-log dedup, already implemented in
  `applyMutationsBatch`) means a chunk that partially committed before a crash/network drop is safe
  to blindly retry as long as its `requestId` is stable across retries — already true, no new work.
- Add a narrow, precise terminal/transient classifier for batch failures
  (`_classifyBatchMutationFailure`), deliberately scoped to the exact `validateBatchMutationRequest`
  error codes (never-changes-on-retry payload-shape errors) and NOT broadened to "any 4xx" — 401/
  403 describe caller *state* that legitimately changes between attempts (token refresh, tenant
  context resolving), same reasoning `_parseMutationConflict`'s own header comment already
  documents for the single-item path. Matches existing philosophy instead of introducing a new one.
- New `ImportSessionStore` (Settings-backed, same pattern as `OutboxStore`) is the missing piece:
  a durable record of "this logical import spans N chunks, here's what's still pending / what
  permanently failed," so a permanent failure that resolves after the dialog closes (or after a
  relaunch) is still recoverable/visible, not just silently reconciled in memory.
- Reuse existing `Toast` (immediate, in-app) and `ActivityLog` (durable, cross-session, bell icon)
  for surfacing a permanent failure — both already exist and are already the established pattern
  (`_onMutationConflicted` already uses `Toast`; `_finishApply` already uses `ActivityLog`) rather
  than inventing a third notification mechanism.

## Step log

1. Read `superpowers:systematic-debugging`, `qt-development-skills:qt-qml` skill files.
2. Fresh clone. Baseline: `main` @ `08d9ab8`. `functions/` baseline `npm test`: 109/109 passing.
3. Traced the full root-cause chain (above) across `functions/lib/batchMutationLogic.js`,
   `qml/model/Gateway.qml`, `qml/model/OutboxStore.qml`, `qml/model/InventoryStore.qml`,
   `qml/model/OrdersStore.qml`, `qml/model/SupplierStore.qml`, `qml/pages/ImportPreviewDialog.qml`.
   Confirmed the bug report's two line-number pointers are both correct and found the additional,
   unreported infinite-silent-retry consequence plus the two other affected stores.
4. Created branch `fix/bulk-import-chunking-durable-status` off `main`.
5. Wrote this checkpoint (root cause + initial design).
6. Ran `/ponytail:ponytail` against the design **before writing any implementation code** — cut a
   planned `ImportSessionStore` singleton and a `batchMutationSucceeded` signal, both duplicating
   state/behavior `OutboxStore` already provides. Full reasoning in SKILLS Skill 55 and the
   response to Taher; not re-duplicated here.
7. Implemented `Gateway.qml`: `maxBatchSize` (mirrors server's 200), `_chunkItems()`,
   `recordMutations()` rewritten to chunk, `_classifyBatchMutationFailure()`,
   `batchMutationFailedPermanently` signal, wired into `_sendBatch()`'s failure branch. Brace-
   balance sanity check via `node -e` (no qmllint available) — clean.
8. Wired `_onBatchMutationFailedPermanently` (rollback + `Toast` + `ActivityLog`) into
   `InventoryStore.qml`, `OrdersStore.qml`, `SupplierStore.qml`, each connected in
   `Component.onCompleted` alongside the existing `mutationConflicted` connection.
9. `ImportPreviewDialog._finishApply()`: honest "still syncing in the background" note when
   `counts.chunked` is true; `counts.chunked` added to both `InventoryStore._upsertManySync` and
   `OrdersStore.upsertMany`'s returned counts.
10. `functions/lib/batchMutationLogic.js`: cross-reference comment only, no behavior change
    (the 200 cap itself is correct and deliberate — confirmed in Phase 1).
11. Checked the 3 UI files that map `ActivityLog` `kind` → icon (`ActivityPage.qml`,
    `NotificationsSheet.qml`, `DashboardPage.qml`) — an unregistered `"import_error"` kind falls
    through to the SAME `IconType.questioncircle` a registered `"activity"` mapping would also
    produce, so left unregistered rather than touching 3 files for a cosmetically-identical
    result. Flagged to Taher as a one-line follow-up if a distinct warning glyph is wanted later.
12. Tests written:
    - `functions/test/batchMutationLogic.test.js`: 1 new pinning regression test. **Ran
      `npm test` — 110/110 passing** (genuinely verified, not just written).
    - `tests/tst_Gateway.qml`: 17 new tests (`_chunkItems`, the chunking regression itself,
      requestId stability, the full `_classifyBatchMutationFailure` matrix).
    - `tests/tst_InventoryStore_upsertMany.qml`: 6 new tests (`counts.chunked`, rollback handler,
      live-signal wiring).
    - `tests/tst_OrdersStore_mutations.qml`: 3 new tests (rollback handler, live-signal wiring).
    - New `tests/tst_SupplierStore_batchMutationFailedPermanently.qml`: 4 tests — first unit test
      file for this store (previously e2e-only).
    - New `test/e2e/tst_BulkImportChunkingE2E.qml`: 2 tests against the real Firebase emulator —
      the actual reported bug (250 rows, both chunks verified landed) and a genuine permanent
      rejection (invalid action → real 400 → rollback + `ActivityLog` entry, verified end to end).
    - Total: **33 new test cases**, counted via `grep -oE "function test_...|^test\("` diffed
      against each file's `main` baseline, not estimated.
    - QML-side tests **NOT RUN IN THIS SANDBOX** — no Qt/qmltestrunner toolchain, consistent with
      every existing test file in this repo. Needs a real `qmltestrunner` pass (`tests/` +
      `test/e2e/`, the latter needs the Firebase emulator) before merge.
13. Docs: `SKILLS.md` Skill 55 (full root-cause + the ponytail-driven `ImportSessionStore` cut,
    written so it doesn't have to be re-derived), `AGENTS.md` (fixed a now-stale claim that
    `Gateway.batchFunctionUrl` wasn't exercised in `test/e2e/` — it now is; added a Feature Status
    row), `README.md` (dated Update paragraph in the existing Concurrency & Conflict Resolution
    section, matching that section's established format).
14. This checkpoint, finalized.
15. Commit, then push to the branch using the provided PAT (per this session's explicit
    instruction — no additional confirmation step).

## Final status: implementation + docs complete, functions tests verified (110/110), QML tests
written to convention but unrun (sandbox has no Qt toolchain — flagged, not hidden). Pushed to
`fix/bulk-import-chunking-durable-status`, not `main`. Not built or run on-device, per standing
instruction.

## Post-CI follow-up (2026-08-29, same day)

CI ran green on this branch (QML, Functions, Firestore Rules, E2E jobs all passed) — first real
confirmation the QML/E2E tests actually work, not just written-to-convention.

Rebase (separate turn, see git log for the merge-conflict resolution against
`feature/async-stock-batch-id-minting` landing on `main`) already covered above.

Coverage-gap audit: diffed every new branch in `Gateway.qml`/`InventoryStore.qml`/
`OrdersStore.qml`/`SupplierStore.qml` against the existing test suite line-by-line rather than
assuming "has tests" meant "fully covered." Found 9 real gaps (untested `_chunkItems` fallback
branch, two distinct `_classifyBatchMutationFailure` branches, the empty-items half of 3 stores'
guard clauses, an unknown-orderId no-op case, a missed `revision++` assertion, and
`OrdersStore.upsertMany`'s `counts.chunked` line which needed an E2E test since it's set inside an
async callback no unit test can reach). Closed all 9, committed separately (`7b5a3ad`) so the
coverage work is auditable independent of the original fix.

One gap deliberately NOT closed: `ImportPreviewDialog._finishApply`'s new conditional has no
automated test at any tier — confirmed via `find` that zero page/dialog components in this repo
have ever had a unit test file, so building a first-of-its-kind `BottomSheet` harness for one line
was judged disproportionate. Covered via on-device steps instead (test plan §5.1, H1-H3). Flagged
explicitly, not silently skipped.

Wrote `docs/superpowers/test-plans/2026-08-29-bulk-import-chunking-test-plan.md` following this
project's established test-plan convention (`2026-08-28-async-stock-batch-id-minting-test-plan.md`
for the on-device Happy/Negative/Edge/Monkey structure, `2026-08-22-pr_taher_bug_fixes-test-plan.md`
for the Unit/Regression/E2E coverage-table structure). Caught and fixed a real arithmetic error
before finalizing: an initial "25 unit + 12 regression + 3 E2E = 40" categorization didn't reconcile
against the actual 42 test cases (verified via `grep -c` diffed against the `main` baseline) — root
cause was miscounting which bucket 3 of the tests belonged to. Recounted properly: 27 unit-tier +
15 regression-tier = 42 exactly, with the 3 E2E-tier tests being a subset already inside that
27+15, not a third additive bucket. Every table's row-sum re-verified against its header count
before treating the document as done — this exact kind of arithmetic slip is documented as a known
failure mode in `SKILLS.md`, worth catching here rather than repeating it.

Firestore Rules: confirmed via reading `firestore.rules` directly that this fix doesn't touch it —
the generic working-tier fallback rule only governs the `direct`-mode path, which this fix
deliberately leaves untouched. Documented as "not applicable" in the test plan rather than silently
omitted, since the person explicitly asked what's covered in rules tests.
