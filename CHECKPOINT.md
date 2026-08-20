# Session Checkpoint — Bug: returned-item revenue/profit not reflected in Sales Analysis

**Started:** 2026-08-19
**Branch:** `fix/return-analysis-revenue-not-updated` (new, off `main` @ `bc0a8fb` — PR #44 merged)
**Status:** Setup done. Starting Phase 1 (root cause investigation) per systematic-debugging skill.

## Goal (as stated by Taher)

Repro: add a new order, complete it with one item, then return that item. Order page and
Inventory page both show correct status afterward. Sales analysis tab's revenue and profit
figures do **not** reflect the return — every other analysis tab does. The exported analysis
XLSX has the same stale-revenue/profit problem. Find root cause, fix it, write tests, commit
and push using the PAT Taher provided this session (he will regenerate it after merge — token
handling follows standing discipline: used only in the push URL, never persisted to
`.git/config`).

Instruction from Taher this session: advise honestly, push back, trade off decisions — do not
just agree and implement the first plausible fix.

## Step log

1. Loaded skills per `using-superpowers` routing: `systematic-debugging` (bug fix →
   process skill first) and `qt-qml` (QML is the domain). Systematic-debugging's Iron Law:
   no fix without completed root-cause investigation (Phase 1–4). That governs the rest of
   this session.
2. Cloned `InventoryManagerUI` fresh over HTTPS using the provided PAT for auth, then
   immediately stripped the token from `origin`'s stored URL (`git remote set-url`) — never
   persisted to `.git/config`, per standing instruction.
3. Confirmed `main` tip is `bc0a8fb` — the merge commit for PR #44
   (`docs/e2e-testing-phase1-followup`). Prior in-conversation memory said Phase 1 was merged
   at `9c7397f`; that was the *design* PR (#43). PR #44 (test-fix follow-up round) has since
   also merged — memory was one merge behind current reality, noted rather than trusted blindly.
4. Archived stale root `CHECKPOINT.md` (the e2e-phase1-followup session's continued log,
   through "2026-08-18, continued") to
   `docs/superpowers/specs/2026-08-18-e2e-testing-phase1-followup-CHECKPOINT.md`. That file's
   own "Next step" list (PR #44 merge decision, OrdersStore coverage, Phase 2 probe, PR #29
   keep-or-close) is **not** part of this session's task — left untouched for Taher/a future
   session, not silently absorbed into this one.
5. Created new branch `fix/return-analysis-revenue-not-updated` off `main`.
6. **Correction, caught by Taher:** commit `c48f304` (step 5's setup) was made locally but I
   did not push it — an actual process miss, not a deliberate withhold. Pushed
   `fix/return-analysis-revenue-not-updated` right after Taher flagged it, using the PAT
   directly in the push URL only (never written to `.git/config` — confirmed via
   `git remote -v` post-push). Independently verified the branch exists via
   `GET /repos/.../branches/fix/return-analysis-revenue-not-updated` (didn't just trust the
   `git push` success line). **Lesson: push immediately after every commit this session,
   don't batch it for "later."**
7. Taher confirmed the repro has no special setup (default tax/discount, single line,
   qty 1) and that BOTH Revenue and Profit tabs are wrong (not just one) — same in the
   exported sheet.
8. Phase 1 root-cause investigation — exhaustive trace, see below. **No root cause found
   yet.** This is an honest dead-end-so-far, not a fix.

## Investigation trace (Phase 1 — root cause NOT yet found)

Traced the full pipeline for a single-item order, complete, full return via the "−" stepper
down to 0 (which removes the row — confirmed, doesn't leave `quantity:0`):

- `ConfirmReturnSheet.qml` → `Main.qml:728 logic.adjustOrder(oid, newLines, reason, condition,
  note)` → `Logic.qml` signal → `DataModel.onAdjustOrder` (RBAC-gated) → `_tryAdjustOrder`
  (DataModel.qml:726) — **the only return code path in the app**; grepped for a second
  "returned"-status route, none exists.
- `_tryAdjustOrder` reads `o = OrdersStore.getById(orderId)` once at the top (pre-adjustment
  snapshot), computes `deltas = OrderAdjust.diffLines(o.products, newLines)`. For a fully-
  removed single line, `diffLines` still yields `returnedQty = oldQty` (verified: a line
  absent from `newLines` is treated as `quantity:0`, same as a line present with `quantity:0`).
- For that delta: `line = _findLine(o.products, d.productId)` (exact productId match, no
  bug), `consumption = line.consumption`, `plan = OrderAdjust.restorePlan(consumption,
  returnedQty)` — traced this function fully; for a qty-1 single-batch consumption it
  correctly reverses the full unit. `reversed[]` gets negative `qtyConsumed`.
- `TransactionStore.recordReturn(o, ..., reversed, ...)` — re-fetches
  `OrdersStore.getById(order.orderId)` (same pre-adjustment state, since
  `OrdersStore.applyAdjustment` hasn't run yet — that's later, in `_finishAdjustmentSync`),
  runs `OrderMath.allocate()` on it, matches the line, computes `rNet/rTax/rDisc` as the
  negative of the full line's net/tax/discount. Doc gets `kind:"return"` (exact string,
  no typo), `net/tax/discountShare` set correctly, `consumption: reversed`. `_push(doc)`
  updates `TransactionStore.entries` **synchronously** (local unshift, `revision++`) —
  confirmed the Gateway persist call happens *after* the local array update, so this isn't
  a "waiting on network" gap either.
- `RealisedMath.byDimension()`/`totals()` — read in full. Correctly includes `kind:"return"`
  rows, correctly handles the negative `qtyConsumed` sign convention (frac resolves to the
  same sign, net contribution comes out negative as expected). `totals()` is literally
  `Σ byDimension("category")` — read to confirm, not just trusting the comment.
- `InventoryStore.realisedTotals/realisedProfitByDimension/realisedBucketWalk` — thin
  passthroughs, read `TransactionStore.entries` fresh on every call. No caching, no stale
  copy.
- **Built and ran a Node.js harness** (`scratch/harness.js`, not committed — scratch only)
  that loads the actual `OrderMath.js`/`OrderAdjust.js`/`RealisedMath.js` (`.pragma`/`.import`
  lines stripped only, nothing else touched) into `vm` contexts and replays this exact
  repro — sale doc + return doc, fed into `RealisedMath.totals()`. **Result: revenue and
  profit both correctly net to 0.** The pure math, given well-formed inputs matching what
  the orchestration code should produce, is not the bug.
- Considered and ruled out a UI-reactivity/stale-binding theory (`_txWatcher` not read by
  the hero computation) — ruled out **because the exported sheet is also wrong**, and export
  recomputes `_exportTotalsBlock()` fresh on click with no dependency on any binding/watcher.
  If it were a reactivity bug, export would show the correct number even if the on-screen
  hero didn't. It doesn't, so the underlying computed *value* must be wrong, not just a
  stale render.
- Considered and ruled out "a background Firestore resync wipes the locally-pushed return
  doc out of `entries`" — ruled out because `TransactionStore.bucketsFor` (backs the
  Sold/Purchased tabs, which Taher confirms DO update correctly) reads the exact same
  `entries` array fresh each call. If `entries` were losing the return doc, Sold/Purchased
  would be wrong too.
- Considered and ruled out a date/period-window scope exclusion — `_dateFilter` defaults to
  `"all"` (`_dateWindow()` returns `null`), and export uses `periodScoped:false`, so by
  default neither the on-screen hero's week-intersected window nor the export's window
  should be excluding same-day events. Not impossible at a week boundary, but doesn't fit
  "reliably reproduces every time."

**Where this leaves things:** the one structural fact that's still consistent with the
evidence is that `RealisedMath.byDimension`/`totals` are the only computation in the whole
pipeline that depend on `consumption[]` being correctly populated on the return event —
`bucketsFor` (Sold/Purchased, confirmed working) doesn't care about `consumption` at all,
just `quantity`. Every place I can *read* that builds/reverses `consumption` looks correct
on paper. I can't tell from static reading alone whether the REAL `consumption` array on
Taher's actual return event is what the code says it should be. Further progress needs live
data, not more code reading.

## Root cause: NOT YET FOUND — need live evidence, not more static tracing

## Fix: not decided — no fix without root cause (Iron Law)

## Verification status: pure-math layer verified via Node harness (scratch, uncommitted).
Orchestration layer (DataModel/TransactionStore/OrdersStore) verified by reading only —
not yet verified against real data.

## Open question for Taher — blocking (in progress)

Taher chose option 2: temporary debug logging, his own build/run, he pastes back the logcat.

Added 4 `console.log("[TEMPDBG] ...")` lines, all tagged and marked "remove before merge":
1. `DataModel._tryAdjustOrder`, return branch — logs `line.consumption` as read from the
   order (the INPUT to `restorePlan`) and the `restorePlan` OUTPUT. Narrows down whether an
   empty/malformed consumption originates upstream (order persistence) or downstream.
2. `TransactionStore.recordReturn` — logs the fully-constructed return doc right before
   `_push(doc)`. Shows exactly what enters `TransactionStore.entries`.
3. `InventoryStore.realisedTotals` — logs `entries.length`, every `kind:"return"` row
   found in `entries` at call time, and the final computed result. Shows exactly what
   `RealisedMath.totals` receives and returns.

Repro to run: add order (1 line, default tax/discount) → complete → return the item via the
"−" stepper to 0 → open Sales Analysis (Revenue or Profit tab) once (this calls
`realisedTotals`, firing log #3). Grep logcat for `TEMPDBG`.

**What each outcome would tell us:**
- Log #1's `line.consumption` is `[]` or `null` → bug is upstream, in order completion/
  persistence not actually attaching consumption (contradicts my read of
  `_tryCompleteOrder`, but read ≠ reality — would need a second debug pass there).
- Log #1's `line.consumption` is populated but `restorePlan` output is `[]` → bug is in
  `OrderAdjust.restorePlan` itself, or in how the input is being read that a read-through
  of the source didn't reveal (types, structural mismatch).
- Log #2's doc looks well-formed (`kind:"return"`, `net`/`tax` non-zero-negative,
  `consumption` non-empty) but log #3 shows it MISSING from `entries` or with `kind`/`net`
  altered → bug is between `_push` and the read in `realisedTotals` (something mutates or
  filters `entries` between write and read that I haven't found).
- Log #3 shows the return row present and correct in `entries` but `result.net`/
  `result.profit` still wrong → bug is inside `RealisedMath.totals`/`byDimension` itself,
  contradicting the Node harness — would mean the harness doesn't faithfully match
  production (worth re-checking scope/opts differences).

Pushed as commit (see below) directly to `fix/return-analysis-revenue-not-updated`. Will be
reverted/removed as part of the eventual fix commit once root cause is confirmed.
