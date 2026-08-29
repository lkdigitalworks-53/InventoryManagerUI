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
account session on two physical devices may work as an untested substitute). Neither is this
repo's/branch's own defect — both are pre-existing product/test-infrastructure gaps, tracked here only
so future test plans don't silently assume they're testable and quietly skip them instead.

---

## Needs Taher's input before it can be scoped or started

### Failed batch-id mint is silently swallowed at 3 of 4 call sites

**Status (2026-08-29): happy path confirmed working on-device by Taher. This specific gap remains
unconfirmed either way — see below — and is explicitly not treated as a merge blocker.**

Found while writing the on-device test plan for the async batch-id-minting change
(`docs/superpowers/test-plans/2026-08-28-async-stock-batch-id-minting-test-plan.md`). `StockBatchStore.
addBatch()` calls back with `null` and logs a `console.warn` if `nextBatchId()`'s mint fails — but
`InventoryStore.addProduct()`'s "Initial stock" call, `InventoryStore.restock()`'s call, and five of
six `topUpOldest()` call sites in `DataModel.qml` pass no callback at all (fire-and-forget, unchanged
from before the async conversion — see
`docs/superpowers/specs/2026-08-27-async-stock-batch-id-minting-design.md`). Before that conversion
this was harmless (a local array scan can't fail); now it's a real network call that can.

Worth being precise about *what kind* of gap this is: `addProduct`'s own productId mint is handled
correctly (`nextProductId` failing aborts the whole add and tells the caller — fail loudly, nothing
half-completes). The stock batch created immediately after is a separate, best-effort side-effect on
an *already-committed* product, with no equivalent path. This isn't the same pre-existing risk class
as everywhere else in the app (every other entity's primary mint fails loudly); it's specifically a
secondary/companion write that used to be infallible and no longer is. If it fails, the surrounding
operation — a product created, stock restocked, an order returned — still reports success to the
user, but the FIFO batch ledger backing it silently never gets its entry: a data-integrity drift with
no user-facing signal and no retry.

**On-device confirmation is currently narrower than originally planned, not blocked outright**:
`main.qml`'s root `Navigation { enabled: isOnline }` disables the entire app's interactivity the
moment connectivity drops, so "start an action already offline" isn't executable through the UI at
all — that rules out the plan's original N1/N2/N4 framing. What remains executable, and still answers
the same question, is dropping connectivity *after* a request is already dispatched (the plan's N3):
tap Save while online, then go offline before the batch's own mint round-trip would plausibly finish,
then reconnect and check whether the batch eventually appears. That's the one on-device result this
entry is still waiting on.

Needs, in order: (1) the plan's N3 actually run on a device to confirm this is reachable and not just
theoretical; (2) if confirmed, a decision on the fix shape — surface an error to the caller (touches
all 4 call sites' UI), some retry-on-next-sync mechanism (bigger, would touch `OutboxStore`/`Gateway`,
neither of which currently know anything about batch-id minting), or something narrower scoped just
to this. Not scoped or estimated yet — deliberately, same reason as the two entries below.

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
