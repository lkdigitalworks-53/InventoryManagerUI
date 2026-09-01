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

### Failed batch-id mint is silently swallowed — 2 `addBatch` call sites uncallbacked, 3 of 6 `topUpOldest` call sites uncallbacked, and `topUpOldest`'s own callback carries no error signal

**Status (2026-08-29): happy path confirmed working on-device by Taher. This specific gap remains
unconfirmed either way — see below — and is explicitly not treated as a merge blocker.**

**2026-09-01 correction, re-verified directly against current `DataModel.qml`/`StockBatchStore.qml`
(not carried forward from a stale count):** the previous "five of six" figure was wrong and the
title's "3 of 4" was also wrong — neither matched the code. Actual counts:
- `InventoryStore.addProduct()`'s "Initial stock" call (`:490`) and `InventoryStore.restock()`'s call
  (`:1008`) both call `StockBatchStore.addBatch()` with **no callback at all** — 2 of 2 unprotected.
- `DataModel.qml` calls `StockBatchStore.topUpOldest()` at 6 sites (`:538, :626, :689, :971, :1031,
  :1097`). 3 of them (`:538, :626, :1031`) pass a callback; 3 (`:689, :971, :1097`) don't.

**Second, more important finding this correction surfaced**: `topUpOldest()`'s callback (`:418-460`)
calls `callback()` unconditionally at the end of its `Gateway.recordDelta` response handler — it
does NOT check `result.ok` before firing it (contrast `addBatch()`, which correctly distinguishes
`callback(null)` on mint failure from `callback(doc)` on success). So the 3 `topUpOldest` call sites
that DO wait on a callback are still not actually told whether the top-up succeeded — they just get
told "done." This widens the eventual fix's scope beyond "add missing callbacks at 5 call sites": the
callback *contract itself* needs an error channel before any call site's callback would even have
something meaningful to check.

Found while writing the on-device test plan for the async batch-id-minting change
(`docs/superpowers/test-plans/2026-08-28-async-stock-batch-id-minting-test-plan.md`). Before the
async conversion this was harmless (a local array scan can't fail); now it's a real network call that
can (see `docs/superpowers/specs/2026-08-27-async-stock-batch-id-minting-design.md`).

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

**2026-09-01 check-in**: as of the 2026-08-30 triage session, Taher chose to run N3 himself rather
than have a synthetic stopgap built or skip verification — no result reported back yet as of this
session. Still waiting; not re-prompted mid-session per that session's own note not to nudge him on
his own timeline.

### `orderMath.js` / `qml/helper/OrderMath.js` parity — now scoped: it's a coverage gap, not a source gap

**2026-09-01, re-verified against current code:** source parity between `functions/lib/orderMath.js`
and `qml/helper/OrderMath.js` already holds — no logic delta once comment/boilerplate differences are
normalized. The real gap is test-coverage parity: `orderMath.js` is missing the direct
fixture-pair pattern its sibling modules (`realisedMath`, `breakdownMath`) already have
(`functions/test/fixtures/*.js` + `tests/tst_*ParityFixtures.qml` + a dedicated
`functions/test/*.test.js`). Specifically, `lineTax()` and `refundPerUnit()` have zero Node-side
test coverage today (confirmed via `grep` across `functions/test/` — neither name appears anywhere).
Well-scoped now; what's still open is whether it's worth doing given the effort of standing up the
fixture-pair pattern for two functions, which is Taher's call, not a further-scoping question.

### Account-switch-mid-sync edge case (the `loadingMore` single-flight guard)

The `if (loadingMore) return` guard (Skill 39) that fixed the concurrent-reset race has a known,
explicitly-accepted trade-off: a genuine account switch mid-sync won't interrupt the in-flight fetch.
Deliberately left unimplemented pending Taher's own call on whether the added complexity to fix this
properly is worth it given how rarely this scenario likely occurs — not something to default on
without his input.

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

---

## Resolved this arc (for context — full detail in `docs/superpowers/specs/` and `SKILLS.md`)

- **`functions/index.js` handler tests for the other 5 endpoints** (2026-08-29) — `acquireLock`/
  `releaseLock`/`provisionMember`/`runCutover`/`computeAnalysis` now covered in
  `functions/test/index.handlers.remaining.test.js` (49 new tests; full `functions/` suite now 163
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
