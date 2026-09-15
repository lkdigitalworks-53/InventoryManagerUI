# E2E Testing Roadmap

Living document for pending work arising from E2E test development — the QTBUG-49896 investigation
(Skills 40-45), the post-merge backlog (items 1-3), and whatever's found next. Not a point-in-time
checkpoint (those live in `docs/superpowers/specs/`, archived once their arc closes) — this one gets
updated in place as items resolve or new ones surface. Each entry: status, what it is, why it matters,
current thinking. Ordered roughly by priority within each status group, not chronologically.

**Testing environment limitations (noted 2026-08-29, applies to any future item here, not just the
one below):** two gaps constrain what can actually be verified on-device right now, independent of
any specific change. (1) `main.qml`'s root `Navigation { enabled: isOnline }` disables the *entire*
app's interactivity the moment connectivity drops — offline/airplane-mode testing can only exercise
"connectivity drops mid-request," never "start an action already offline," since the latter can't be
initiated through the UI at all. (2) There's currently no way to log a second test session into the
same tenant as staff/manager, which blocks genuine multi-device concurrent testing (a same-owner-
account session on two physical devices may work as an untested substitute). (3) (added 2026-09-01,
found while implementing item 3 below) `FirebaseService.query`/`get`/`put` are plain `function`
declarations on a `pragma Singleton` — not injectable (confirmed directly: reassigning
`FirebaseService.query` from a test throws `Cannot assign to read-only property`). Any test needing
to control the timing or outcome of a Firestore call has no way to exercise the real store singletons
under `qmltestrunner` — the only workaround so far (`tst_TenantContextRaceGuard.qml`, now also
`tst_ResetPendingGuard.qml`) is a hand-written parallel model of the store's control flow, which
proves the *logic* is sound but carries its own risk: if the real `_resetAndFetch`/`_fetchFromFirebase`
pattern changes later without the mirror being updated too, those tests would keep passing while no
longer testing what's actually shipped. Not urgent enough to justify a refactor on its own — noted so
it doesn't get rediscovered from scratch next time this class of bug shows up. None of the three are
this repo's/branch's own defect — all are pre-existing product/test-infrastructure gaps, tracked here
only so future test plans don't silently assume they're testable and quietly skip them instead.

---

## Needs Taher's input before it can be scoped or started

### No XHR request anywhere in this app has a timeout — confirmed systemic, deliberately deferred

Found 2026-09-14 while fixing item 1's follow-up (see "Resolved this arc" below for the full trace).
`FirebaseService._request()` (every plain read/write, including `nextBatchId`/`nextProductId`/etc.'s
underlying mint calls) and `Gateway._send()` (Outbox's own delivery mechanism, a separate XHR
implementation, used by every durable `recordMutation`/`recordDelta` call) both rely entirely on the
OS/Qt network stack to eventually decide a request has failed — confirmed via `grep` across all of
`qml/`, zero `.timeout`/`ontimeout` matches anywhere. Under real dropped connectivity, this can hang
for a long time rather than failing fast, with no way for any retry mechanism (Outbox's backoff,
item 1's pending-mint queue, or anything else) to engage, since nothing has actually failed yet from
the code's own perspective — it's just still waiting.

One instance of this (the batch-id mint specifically) was fixed 2026-09-14, narrowly scoped to just
that one call, using the exact pattern `AuthService._postJson()` already established elsewhere for
this same problem (a 15s/20s safety-net `Timer` racing the real request). That fix does **not**
generalize automatically — every *other* call in the app (product/order/staff/supplier mints, every
plain Firestore read, every `Gateway`-routed durable write) has the identical exposure and would need
either the same per-call treatment or a fix at the shared `_request()`/`_send()` level.

Deliberately not done broadly this session — Taher's own call, given the size of the change (touches
every network call the app makes) relative to what was actually reported (one specific hang). Needs
scoping: probably a shared timeout wrapper at the `_request()`/`_send()` level rather than repeating
the per-call pattern five more times, but that's a design decision for whoever picks this up, not
assumed here.

---

## Explicitly scoped out — not forgotten, just not this round

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

### PR #49 (`review/post-pr45-qml-audit`) — resolved, 2026-09-01

Was flagged 2026-08-26 as `mergeable: false` / `dirty`. Re-checked instead of trusted: the only
actual conflict was `CHECKPOINT.md` (expected — living doc, rewritten every session). The real
change (`send()` extracted to `functions/lib/httpResponse.js`, 4 new direct-coverage tests for the
try/catch fallback added in PR #45) merged clean against `functions/index.js` and against Skill 53's
later `index.handlers.test.js` parity work — no functional overlap, despite touching adjacent code.
Branch updated: `main` merged forward into `review/post-pr45-qml-audit`, conflict resolved, full
`functions/` suite re-run clean (178/178). `index.js` line coverage 99.32% → 99.88% — the try/catch
lines move out of `index.js` entirely and gain 100% coverage in their new home. The one remaining
`index.js` gap (`canAssignRole()`'s unreachable `else`, Skill 52/53) is untouched, out of scope here.
**2026-09-01: merged into `main`** (confirmed via GitHub API, `merged_at: 2026-09-01T03:06:26Z`) —
closed, not just mergeable.

## Resolved this arc (for context — full detail in `docs/superpowers/specs/` and `SKILLS.md`)

- **Failed batch-id mint, silently swallowed — confirmed on-device, both decisions implemented**
  (2026-09-14) — the plan's N3 (restock, drop connectivity right after submit) came back with a
  definitive result from Taher: the batch was permanently lost, not recovered on reconnect, matching
  this entry's original prediction exactly. Root-caused end to end against the actual code, not
  inferred from the report: `InventoryStore.restock()` writes `product.stock` first (fast, atomic —
  why the stock count updated before airplane mode could be toggled on), then calls
  `StockBatchStore.addBatch()` with no callback; `addBatch()`'s `nextBatchId()` mint was still in
  flight when connectivity dropped, and on failure it just warns and returns — nothing to receive
  that signal since no callback was passed.
  **Second, worse finding this surfaced, beyond the original scope**: completing an order against
  that product (3 units, only 1 unit recorded across batches) triggered the existing drift-repair
  (`topUpOldest`), which — when at least one batch already existed — didn't create a new batch for
  the shortfall; it applied an additive delta directly onto the *existing* batch's own
  `qtyReceived`/`qtyRemaining`, rewriting its history (`1 → 3`, confirmed matching exactly what Taher
  saw). Since the delta only touched quantity fields, the phantom units silently inherited that
  batch's cost/supplier rather than the actual restock's — a second, distinct bug (wrong data, not
  just missing data) from the same root cause.
  **Decision 1 (Taher's call): retry on reconnect, no error/warning surfaced, product hidden from
  order-entry pickers until resolved.** `StockBatchStore` gained a small, durable (`Settings`-backed,
  survives a relaunch), retry queue: a failed mint is queued instead of dropped
  (`_queuePendingMint`), retried automatically on `AuthService.isOnlineChanged` (and defensively at
  startup, in case the app was relaunched while already online with leftovers) via
  `retryPendingMints()`/`_retryOnePendingMint()`, deduped against concurrent/overlapping retries via
  an in-flight set (same pattern `OutboxStore._inFlightKeys` already established). `hasPendingMint
  (productId)` lets a caller check whether a product has one outstanding; wired into both
  `NewOrderDialog._rebuildPickerNames()` and `OrderDetailDialog._rebuildCatalog()` to skip such
  products from the "add a line" picker entirely (existing lines already on an order are untouched —
  only new selection is blocked). `NewOrderDialog` needed a small structural fix alongside this: its
  picker resolved selection via a raw `InventoryStore.products[idx]` index with no filtering layer
  (unlike `OrderDetailDialog`, which already built a separate parallel `catalog` array) — filtering
  the display names without also fixing this would have silently misaligned every selection after the
  first hidden product, so a matching parallel `_pickerProducts` array was added, mirroring
  `OrderDetailDialog`'s already-correct pattern.
  **Decision 2 (Taher's call, "go with the recommended fix"): `topUpOldest` always synthesizes a new,
  clearly-labeled batch now, never mutates an existing one's history** — removed the two-branch split
  entirely (previously: synthesize only when zero batches existed, otherwise mutate the newest one);
  now always takes the synthesize path regardless. Same `addBatch()` call either way, so this cost
  nothing extra to make unconditional, and it also means a top-up whose *own* mint fails is covered by
  Decision 1's same retry queue for free, with no separate handling needed.
  **Verification**: new `tests/tst_PendingMintAndTopUpSafety.qml` (11 tests, all passing) models both
  decisions and their interaction using this repo's established minimal-plain-JS-object technique
  (`tst_TenantContextRaceGuard.qml`'s pattern) — `addBatch`/`topUpOldest` are read-only methods on a
  `pragma Singleton`, same class of limitation as `FirebaseService.query` found earlier this session,
  so the real singleton can't be driven deterministically from a test. Full suite re-run: 359 passed
  (was 178 before this session's various work started), 29 failed — same pre-existing
  `AuthStore`/`QtCore` cause as always, confirmed via the actual error text and a diff against the
  failure list from before this change (zero new failures; `StockBatchStore.qml` gaining
  `import QtCore` for its new `Settings` block changes nothing, since the whole `qml/model` directory
  was already tainted by `AuthStore.qml`'s own `QtCore` import). **On-device/CI confirmation that the
  real singleton and the two dialogs behave like the model is still outstanding** — same category of
  gap as items 2 and 3's own mirror-model tests, flagged rather than treated as equivalent to real
  verification. New test plan: `docs/superpowers/test-plans/2026-09-14-batch-mint-retry-and-topup-
  safety-test-plan.md`.
  **Follow-up, same day, after on-device re-test (Taher, N3 re-run on latest code): the fix above was
  necessary but not sufficient.** Restocking with a brand-new supplier and dropping connectivity right
  after submit still lost the batch — worse, the app hung (restock dialog never closed), over a
  minute with the app left open and reopened, batch still never appeared in Firestore. Root cause:
  **no XHR request anywhere in this codebase has a timeout** (confirmed by grep — zero
  `.timeout`/`ontimeout` matches in all of `qml/`). `nextBatchId()`'s mint can hang indefinitely
  rather than failing, which meant `addBatch()`'s failure branch (the retry queue above) never even
  ran — nothing had failed yet from its own perspective. Separately, `restock()` nested
  `StockBatchStore.addBatch()` *inside* `Gateway.recordDelta`'s callback, so a slow/hung stock delta
  blocked the batch from being attempted at all, independent of the mint issue. This is a systemic,
  app-wide gap — Gateway's own outbox-sending XHR (`Gateway.qml`'s `_send()`, a separate
  implementation from `FirebaseService._request()`) has the identical gap — but Taher asked for the
  broad fix to go to the roadmap for a future session (see the new item below) while the batch's own
  reliability got fixed now: **`nextBatchId()`** now races the real mint against a 15s safety-net
  `Timer`, mirroring the exact pattern `AuthService._postJson()` already established for this same
  class of problem elsewhere ("20s timeout fallback so a hung request never leaves the UI silent") —
  whichever settles first wins, the other is discarded, so a hung request now behaves exactly like a
  fast one that failed. **`restock()`** now fires `StockBatchStore.addBatch()` immediately after
  supplier resolution, in parallel with the stock delta rather than nested inside its callback — a
  FIFO batch doesn't need the stock counter to have landed to be correct (it's the ledger's own ground
  truth), so there was never a real dependency forcing the old ordering, just an incidental one.
  `ActivityLog`/`TransactionStore` stay gated on delta confirmation, unchanged, per the original C4
  design's own reasoning (they record something happened, so unlike a batch they legitimately
  shouldn't fire for a write that might not have landed). Note: the restock *dialog* itself can still
  take a while to close if the stock delta specifically is what's hung — that half of the symptom is
  the broader timeout gap, deferred to the new item below, not silently reintroduced as an unstated
  limitation. 4 new tests (`tst_PendingMintAndTopUpSafety.qml`, now 15 total) model the timeout-vs-mint
  race directly: normal resolution, timeout-fires-first, and both orderings of "the other one resolves
  late" to confirm no double-fire and no duplicate batch risk. Full suite: 363 passed, 29 failed, same
  pre-existing cause, zero new regressions.

- **`functions/index.js` handler tests for the other 5 endpoints** (2026-08-29) — `acquireLock`/
  `releaseLock`/`provisionMember`/`runCutover`/`computeAnalysis` now covered in
  `functions/test/index.handlers.remaining.test.js` (49 new tests; full `functions/` suite now 164
  tests, all passing). `provisionMember`/`computeAnalysis` had zero coverage anywhere before this
  (their logic lives directly in `index.js`, not a `lib/` module) — everything else only had the
  three endpoints Skill 46 covered. Design/approach: Skill 52.
  **Two new, honest findings, not fixed, flagged instead**: (1) `canAssignRole()`'s `else return
  false` branch is unreachable via its only call site (`provisionMember` already gates non-owner/
  admin callers earlier) — likely-dead defensive code, not exported so not directly testable either;
  worth a look next time `provisionMember` is touched, not urgent on its own. (2) `send()`'s
  `JSON.stringify`-failure `catch` block has no reachable trigger through any current handler's real
  response bodies (all hand-built from plain fields) — same conclusion, same non-urgency. Neither is
  new; both pre-date this arc and apply equally to the 3 endpoints Skill 46 already covered.
  **One pre-existing gap found, not fixed in this arc — since resolved, see below**:
  `recordMutation`/`recordDelta`/`recordMutationsBatch` (Skill 46's original scope, marked resolved
  under backlog item 2) were missing method-not-allowed (405) tests for all three, and `recordDelta`
  specifically was missing invalid-token (401) and write-failed (500) tests that `recordMutation`
  had. Found while comparing coverage output before/after this arc, not while editing those
  endpoints — flagged here rather than silently bundled into this branch's diff.

- **`recordMutation`/`recordDelta`/`recordMutationsBatch` handler-test parity** (2026-08-30) — the
  gap flagged directly above is closed. `recordDelta`/`recordMutationsBatch` now have the same
  401/403/405/500 coverage `recordMutation` already had; `recordMutation` itself gained the one
  405 test it was missing too. 11 new tests, `functions/` suite now 174 passing, `index.js` line
  coverage 95.32% → 99.32%. Design: `docs/superpowers/specs/2026-08-30-handler-parity-coverage-gap-
  design.md`; technique: SKILLS Skill 53. This was the only item on this roadmap not gated on
  Taher's input — the three entries above it under "Needs Taher's input" are still exactly that,
  untouched.

- **`orderMath.js`/`qml/helper/OrderMath.js` parity** (2026-09-01) — scoping (source parity holds,
  real gap is `lineTax()`/`refundPerUnit()` having zero Node-side coverage) confirmed, then
  implemented same session with Taher's go-ahead: `functions/test/fixtures/orderMathFixtures.js` +
  `functions/test/orderMath.test.js` (Node, fixture-pair pattern matching `realisedMath`/
  `breakdownMath`) and `tests/tst_OrderMathParityFixtures.qml` (QML side of the pair). 6 new
  edge-case tests added to `tests/tst_OrderMath.qml` first, as the source-of-truth this repo's
  convention requires fixtures to trace back to — covering branches the existing suite didn't reach
  (percent-type discount + its clamps, flat-discount clamps, null/undefined line, non-numeric price,
  taxable-true-but-zero-rate, negative/zero `originalQty` clamps). `lineTax`/`refundPerUnit`
  (`functions/lib/orderMath.js:77-114,290-297`) confirmed at 100% line AND branch coverage via direct
  lcov `BRDA` inspection, not just the summary percentage (summary branch % can look deceptively
  high/low across an entire file when other functions in it are un-instrumented by the tests that
  ran). Verified for real: `qmltestrunner` (38/38 in `tst_OrderMath.qml`, 13/13 in the new parity
  file) and `node --test` (190/190 across all of `functions/`, up from 178). Scope held to just
  these two functions, matching what was presented — `allocate`/`spreadOrderDelta`/
  `spreadLineDeltaBySupplier`/`eventProfit`'s coverage is unchanged, out of scope here.

- **Account-switch-mid-sync edge case (the `loadingMore` single-flight guard)** (2026-09-01) — the
  `if (loadingMore) return` guard (Skill 39) that fixed the concurrent-reset race had a known,
  explicitly-accepted trade-off: a genuine account switch mid-sync would silently drop instead of
  interrupting the in-flight fetch. Taher gave the go-ahead same session. Fix: `_resetAndFetch()` now
  sets a `_resetPending` flag (plus which reset it is, for stores where that matters) instead of
  dropping when `loadingMore` is true; the in-flight fetch's callback checks that flag the instant it
  completes and, if set, abandons the now-stale response unprocessed and re-runs `_resetAndFetch()`
  immediately rather than applying data for an account the app has already moved on from. Applied
  identically to all 6 paginated stores (`TransactionStore`, `InventoryStore`, `OrdersStore`,
  `StaffStore`, `StockBatchStore`, `SupplierStore`) — verified each has the exact same
  `_resetAndFetch`/`_fetchFromFirebase` shape before editing, not assumed. New test file
  `tests/tst_ResetPendingGuard.qml` (6 tests, all passing) models the race with a minimal plain-JS
  object mirroring the real control flow — the same technique `tst_TenantContextRaceGuard.qml`
  already established in this repo — since the real singletons can't be exercised this way under
  `qmltestrunner`: `FirebaseService.query` turned out to be a read-only method (confirmed by trying
  to reassign it), and importing the real stores to work around that hits this sandbox's separate,
  pre-existing `AuthStore unavailable`/`QtCore` compile issue. Full `tests/` suite re-run: 340 passed
  (up from 315), 22 failed — same pre-existing count, same pre-existing cause, confirmed via the
  error text, not just the number. **On-device/CI confirmation that the real singletons behave the
  same way as the model is still outstanding** — this session couldn't verify that part directly.

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
- `StockBatchStore._nextBatchId()`'s missing server-side counter (above) — **Option A implemented**
  2026-08-27, per Taher's explicit direction, not Option B as this doc leaned toward. Worth recording
  honestly: reading `InventoryStore.upsertMany` end to end first showed the actual blast radius was
  smaller than this doc's original estimate — the file already reserves ids in bulk for products and
  suppliers the same way Option A needed for batches, and `SupplierStore` already had the exact
  sync/async function-split precedent (`addSupplier` vs. `addSupplierWithId`/`addSupplierWithIdMany`)
  this needed. Doesn't mean the original "leaning towards B" call was wrong given what was known when
  it was written — it means a risk estimate is worth re-checking against the current code, not just
  taken as settled, once there's a decision to actually act on. Design:
  `docs/superpowers/specs/2026-08-27-async-stock-batch-id-minting-design.md`; lesson: SKILLS Skill 50.
