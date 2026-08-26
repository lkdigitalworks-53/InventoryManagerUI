# Session Checkpoint — Post-merge follow-up (Phase 2 decision + backlog)

**Started:** 2026-08-25
**Branch:** `chore/post-merge-checkpoint-and-planning` (new, off `main` @ `cf01870`, the merge of
PR #45 / `docs/e2e-testing-phase2-followup`)
**Status:** PR #45 confirmed merged, CI green on `db258d6` (verified via GitHub's API directly, not
taken on report). The full 13-round conflict-test investigation (QTBUG-49896, Skills 40-45) is
archived to `docs/superpowers/specs/2026-08-25-e2e-testing-phase2-followup-CHECKPOINT.md` — see
that file or `SKILLS.md` Skills 40-45 for the full forensic history. This file starts clean.

## Phase 2 probe: answered, closing it out (not "still pending")

Taher ran the probe for the first time this session (`qmltestrunner -input scripts/probes`) and got
a **compile error**, not the runtime-behavior log the probe was designed to produce:

```
Type Constants unavailable
qml/helper/Constants.qml:4,1: the preferred directory has to end with a '/'
```

**What this actually shows**: line 4 of `Constants.qml` is `import Felgo`. Confirmed by grepping the
whole repo that **no test file anywhere — in `tests/` or `test/e2e/` — has ever actually referenced
`Constants.<property>`** (several import the `qml/helper` directory for *other* singletons, but
`pragma Singleton` types are lazily instantiated on first use, so `Constants.qml`'s own `import
Felgo` line has never actually executed under `qmltestrunner` before now). CI's `QML Tests` job
never installs Felgo at all (`jurplel/install-qt-action@v4`, plain Qt 6.8 — confirmed by reading
`.github/workflows/checks.yml`). So this isn't a bug introduced by anything in this codebase — it's
that **the Felgo SDK itself doesn't bootstrap under a bare `qmltestrunner` invocation**, on Taher's
machine *or* in CI, regardless of an `App{}` ancestor. The probe's own header says exactly what
question it was trying to answer ("do dp()/sp()/Constants resolve without an App{} ancestor") — the
honest answer is now: **the question is moot, because the whole import chain can't load under
qmltestrunner at all, App{} ancestor or not.**

**Decision: close this out, don't chase it further right now.** Reasoning, stated as a real
trade-off rather than a default:
- **Cost to actually solve it** is unbounded and outside this codebase: it means researching how
  Felgo's own SDK expects to be bootstrapped for headless testing (undocumented from here, a
  third-party proprietary SDK's internals, not something any of the tools or knowledge in this
  session can resolve by reading this repo's own code).
- **Value if solved** is incremental, not correctness-critical: it would let `NewOrderDialog.qml`/
  `OrderDetailDialog.qml`'s *layout* be headlessly tested. The app already ships and works in
  production without this — this is test-infrastructure nice-to-have, not a functional gap.
- Compare against the rest of the backlog below: several items there are real correctness/reliability
  gaps in code that's already shipped, with clear, bounded effort. Better return on the same hours.

**If Taher wants this revisited later**: the cheaper alternative to chasing Felgo's bootstrap
internals is extracting the *pure* dp()/sp()-style spacing math these two dialogs use into a
Felgo-independent helper (plain `.js`, no `import Felgo`) that can be unit-tested without ever
touching the Felgo runtime — tests the math, not the rendered Felgo `Item` tree. Not scoped further
than that here; flagging it as the direction, not committing effort to it.

## Backlog, prioritized by complexity/effort/time

Ordered highest-priority first. "Effort" is solo, uninterrupted focus time estimate, not calendar
time.

| # | Item | Complexity | Effort | Why this order |
|---|------|-----------|--------|-----------------|
| 1 | `ActivityLog`/`CategoryStore`/`OrderChannelStore` missing `AuthStore.tenantId.length > 0` guard on `Component.onCompleted` | Low | ~30-60 min incl. tests | Same well-understood pattern as an already-fixed store (Skill 39's tenant-context race); small, bounded, real bug |
| 2 | `functions/index.js` handler-level test coverage (currently zero — only `lib/*Logic.js` is tested) | Medium | ~1 session | This is the *exact* untested seam Skill 43's bug lived in. Closing it prevents the same class of bug, not just this one instance |
| 3 | Dedicated conflict-scenario E2E tests for `InventoryStore`/`StaffStore`/`SupplierStore`/`StockBatchStore` (today only `OrdersStore`'s is covered) | Low-medium | ~1 session for all 4 | QTBUG-49896 affected all five stores identically — only Orders' reconciliation path has been *proven* to work end-to-end after the fix; the other four are "correct by code reading," not "confirmed by test" |
| 4 | `orderMath.js`/`qml/helper/OrderMath.js` parity | **Needs rescoping — see below** | Unknown until scoped | Long-deferred; I don't have enough current context to size this honestly rather than guess |
| 5 | Account-switch-mid-sync edge case (`loadingMore` guard) | **Blocked on Taher's design call** | Unknown until decided | Explicitly deferred pending a complexity-tradeoff decision that's Taher's to make, not mine to default |
| 6 | Phase 2 probe / Felgo headless testability | Closed this session | — | See above — not pursuing further without a specific reason to |

**Items 4 and 5 are deliberately not estimated with a made-up number.** For #4, "parity" was defined
in an earlier session's context this checkpoint doesn't carry forward in enough detail to size
honestly — needs a quick re-scoping pass (what does "parity" mean here — with what reference
implementation, checking what specifically?) before it can get a real complexity/effort rating. For
#5, the checkpoint history is explicit that this was left for Taher's own call on the trade-off, not
something to size and schedule without that input.

## Backlog items 1-3: complete (2026-08-25)

**Item 1 (tenant guard on ActivityLog/CategoryStore/OrderChannelStore): turned out to need zero code
changes.** Investigated before touching anything (per the discipline this session's earlier mistakes
made non-negotiable) — the `Component.onCompleted` guard already existed in all three stores, and
`Main.qml`'s central `onTenantContextReady` resync already calls all three
(`ActivityLog.syncFromFirebase()`, `OrderChannelStore.syncFromFirebase()`,
`CategoryStore.syncFromFirebase()`). Nearly reported this as a bug based on a `grep -A 25` window
that cut off one line short of `CategoryStore`'s call — caught it by re-viewing the full function
before writing anything down. The original backlog description was simply stale; closed, no commit
needed for this item specifically.

**Item 2 (`functions/index.js` handler-level tests): done.** New file
`functions/test/index.handlers.test.js` (14 tests) plus a shared harness
`functions/test/testSupport/handlerHarness.js`. Covers `recordMutation`, `recordDelta`,
`recordMutationsBatch` — the three endpoints sharing the auth->validate->apply->respond shape and
Skill 43's exact risk class. Deliberately does NOT cover `acquireLock`/`releaseLock`/
`provisionMember`/`runCutover`/`computeAnalysis` — a scope boundary, stated plainly rather than
silently incomplete, since those share less of this specific risk pattern. Technique (mocking
firebase-admin + local `lib/` deps via `require.cache` injection, `node-mocks-http` for req/res) is
written up as Skill 46. One OPTIONS-preflight test was attempted and dropped — hung due to a
`cors`-middleware/mock interaction unrelated to this codebase's own logic; not worth fighting.
Verified with a real `npm ci` (matching CI exactly, not just the existing node_modules) + `node --test`:
all 109 tests pass (14 new + 95 pre-existing, nothing broken). `node-mocks-http` added as a
devDependency — `functions/package.json` and `functions/package-lock.json` both updated.

**Item 3 (dedicated conflict tests for the other 4 `mutationConflicted`-connected stores): done, with
one honest scope note.** Extended `tst_InventoryE2E.qml` with a conflict test (it already had the
signal-handling scaffolding, just no test exercising it). Created `tst_StaffStoreE2E.qml` and
`tst_SupplierStoreE2E.qml` from scratch, closely mirroring `tst_InventoryE2E.qml`'s proven structure
rather than improvising new boilerplate. All three follow the same shape as
`tst_OrdersStoreE2E.qml`'s proven conflict test, simplified now that QTBUG-49896 is actually fixed
(10s wait instead of the old investigation's 45s; no need for the elaborate diagnostic-on-failure
logic that only existed because the bug was still unsolved).

**`StockBatchStore` needed a different scenario, found by actually reading the code first**: every
numeric mutation in that store (`consumeFifo`/`topUpOldest`/`restoreFifo`) goes through
`Gateway.recordDelta`, not `recordMutation` — confirmed by grepping the whole file, not assumed.
`recordDelta`'s atomic floor/clamp semantics make a CAS conflict structurally impossible there; the
ONLY `recordMutation` call anywhere in the store is `addBatch`'s "create" action. So
`tst_StockBatchStoreE2E.qml`'s conflict test exercises a duplicate-create collision instead of an
update collision — the actually-reachable path — with a direct (non-`StockBatchStore`-API)
server-side update in between so the reconciliation assertion checks a real change, not an echo. This
is explained at length in the file's own header comment, not left implicit.

**Also found in the process, not fixed (out of this item's scope)**: `StockBatchStore.qml`'s own
`_onMutationConflicted` comment claims a conflict can happen via "qtyRemaining via plain
recordMutation" — that doesn't match the current code (it's `recordDelta` now). Reads like a stale
comment surviving a past `recordDelta` conversion. Flagging for Taher rather than fixing opportunistically
mid-backlog-item.

**Not run against a real `qmltestrunner`/Cloud Functions emulator** — same standing sandbox
limitation as every QML test in this whole effort. `functions/test/index.handlers.test.js` (item 2)
WAS actually run and verified, since that's plain Node. All 4 QML files balance-checked (brace/paren
parity against a Python-based check, not real QML parsing) but not executed.

## Next step

1. Taher: run the real E2E suite (`qmltestrunner -input test/e2e`) to confirm all 3 new/extended
   files actually pass — this is the one thing this sandbox cannot verify itself.
2. Two small things surfaced along the way, not acted on: `StockBatchStore.qml`'s stale
   `_onMutationConflicted` comment (see above), and confirming (or not) whether the "real app almost
   certainly never hits this in practice" note in `tst_InventoryE2E.qml`'s `initTestCase()` about
   `AuthService`'s construction-order wipe has ever been traced against `Main.qml`'s actual bootstrap
   sequence — flagged there as "worth Taher's own quick confirmation," still unconfirmed.
3. Items 4 (`orderMath.js` parity) and 5 (account-switch-mid-sync) remain known tech debt, explicitly
   deferred per Taher's instruction, not attempted this round.
4. Phase 2 probe — closed (see the "Phase 2 probe: answered" section above), unchanged.
