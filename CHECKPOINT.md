# CHECKPOINT — roadmap triage: picking the next E2E-testing-roadmap item

**Session date:** 2026-08-30
**Branch:** `docs/2026-08-30-roadmap-next-item-triage` (off `main` @ `ad84ccc`)
**Previous arc archived to:** `docs/superpowers/specs/2026-08-30-handler-parity-coverage-gap-CHECKPOINT.md`
(was sitting at root describing an already-merged arc — PR #56 merged into `main` as `ad84ccc` before
this session started; archiving now per convention, nothing wrong found in its content this time).

## What this session is

Instructed to fresh-clone, read `docs/superpowers/E2E-TESTING-ROADMAP.md` live (not from prior-session
memory), and pick up the next actionable item. Read it end to end: **all three open items are marked
"Needs Taher's input before it can be scoped or started."** The one item that wasn't gated
(handler-parity-coverage-gap) is already done and merged. So there's no item to silently pick up
this time — correctly so, per the roadmap's own explicit gating, not a gap in this session's search.

Spent the session doing the investigation each of the three items needs *before* Taher's decision,
so his decision is informed rather than a guess:

1. **Silent batch-id-mint swallow** — re-verified the call-site count directly against current
   `DataModel.qml` (found and corrected a stale "five of six" claim — it's 3 of 6) and traced
   `StockBatchStore.topUpOldest()` (`:418-460`) end to end. Real finding: `topUpOldest()`'s own
   callback has no error channel at all, so even the 3 call sites that DO wait on it aren't actually
   protected. Widens the eventual fix's scope. Written up in the roadmap doc's own entry.
2. **`orderMath.js` parity** — confirmed source parity already holds (diffed both files, zero
   logic delta once comment punctuation/module boilerplate is normalized). The real gap is test-
   coverage parity: `orderMath.js` is the one of its three-module family (`orderMath`/`realisedMath`/
   `breakdownMath`) missing the direct fixture-pair pattern (`functions/test/fixtures/*.js` +
   `tests/tst_*ParityFixtures.qml` + its own `functions/test/*.test.js`). `lineTax`/`refundPerUnit`
   specifically have zero Node coverage, direct or indirect (unreachable from `functions/`, confirmed
   by grep). Now well-scoped; written up in the roadmap doc's own entry.
3. **Account-switch-mid-sync `loadingMore` guard** — re-read Skill 39 in full. A concrete fix (the
   "pending reset" flag: `_resetPending = true` on a guarded call, re-run `_resetAndFetch()` when the
   in-flight fetch completes) is already designed there, just not implemented. This is purely
   Taher's rarity-vs-complexity call, not something more code-reading resolves further.

Full findings and the options for each presented to Taher in-chat this turn, not just summarized here
(this file is for session-resumability, not a substitute for that conversation).

**Process note on sandbox capability (carried forward, not re-verified this session):** per the
archived checkpoint above, this sandbox CAN run the real `qmltestrunner` suite and `functions/`
Node tests (315/337 QML files, 174/174 Node tests, as of 2026-08-30) via
`scripts/setup-sandbox-qmltestrunner.sh`. Not exercised this session since no implementation
happened — analysis only. "Do not build or run app" (this session's standing instruction) is read as
covering the actual Felgo/Qt app, not automated test suites; flagged explicitly rather than assumed,
since running verification suites will be needed once an item is chosen and implemented.

## Update: Taher picked item 1 (batch-id mint), immediately hit its own stated blocker

Asked which of the 3 to scope next; he picked the batch-id-mint item. Before any fix-shape design:
re-confirmed N3 (`docs/superpowers/test-plans/2026-08-28-async-stock-batch-id-minting-test-plan.md`
§3.2) is a **physical on-device action** — tap Save while online, toggle airplane mode ON before the
mint round-trip completes, wait, toggle back OFF, observe whether the batch eventually appears.
Neither buildable-and-run here (this session's standing "no build/run" instruction) nor something a
synthetic test can fully stand in for: this exact codebase already has one precedent (QTBUG-49896)
of real on-device Qt/XHR network behavior diverging from what code-reading alone predicted, found
only by an actual run. Read `StockBatchStore.nextBatchId()` (`:192-199`) — it delegates to
`FirebaseService.mintCounterValue(key, seedMax, function(ok, value){...})`, so a forced-`ok:false`
or never-resolving stub IS constructible as a store-level test, but it only proves "the code handles
a clean ok:false correctly," not "a real mid-flight connectivity drop actually produces ok:false
rather than silently hanging" — the second question is exactly the kind QTBUG-49896 turned out to
answer unpredictably in this codebase. Presented Taher the exact N3 steps to run himself plus this
honest caveat, rather than either (a) blocking silently or (b) building the synthetic test and
presenting it as equivalent confirmation. Awaiting his choice: run N3 himself / have me build the
synthetic stopgap test now (explicitly non-equivalent) / skip verification and pick a fix shape on
the unconfirmed assumption anyway.

## Status: item 1 selected, blocked on N3 on-device confirmation, awaiting Taher's choice of path

### Done
- [x] Fresh clone, branch created off `main` @ `ad84ccc`
- [x] Read `docs/superpowers/E2E-TESTING-ROADMAP.md` live end to end
- [x] Read `CHECKPOINT.md` (root, now archived), `SKILLS.md` Skill 39, both `orderMath.js` files,
      `StockBatchStore.qml`, `InventoryStore.qml`, `DataModel.qml` call sites, before writing anything
- [x] Corrected a stale count ("five of six" → 3 of 6) in the roadmap doc's batch-id-mint entry,
      flagged as a correction, not silently rewritten
- [x] Added scoping findings to the roadmap doc's `orderMath.js` parity entry — parity is now
      well-defined (test-coverage gap, not source-code gap), decision on whether to act still open
- [x] Archived the previous (already-merged) arc's `CHECKPOINT.md`
- [x] This file

### Explicitly not touched, and why
- No production code changed — this session is doc-only (roadmap corrections + this checkpoint).
- No test files created yet for `orderMath.js` — per brainstorming's hard gate, no implementation
  before Taher approves a design, and the parity item still needs his go/no-go given #2's functions
  are currently dead code server-side.
- Batch-id-mint fix shape untouched — still needs the on-device N3 result plus Taher's shape decision
  (surface error / retry-on-sync / narrower fix).
- `loadingMore` pending-reset flag untouched — Skill 39 already designed it; implementing without
  Taher's rarity-vs-complexity call would be exactly the kind of default-without-input this repo's
  conventions warn against.

## Next action if resumed

Item 1 (batch-id mint) is picked but stuck on N3. Check chat history for which path Taher chose:
- **Ran N3 himself, reports result** → if "batch never appeared": proceed to the 3-shape decision
  in this file's item-1 writeup above (narrower fix recommended first). If "batch appeared fine":
  this item may not need fixing at all (ponytail rung 1) — confirm with Taher before closing it out.
- **Asked for the synthetic stopgap test** → build it in `tests/tst_StockBatchStoreE2E.qml` or a new
  file, forcing `FirebaseService.mintCounterValue`'s callback to `ok:false`/never-resolve, verify
  `topUpOldest`/`addBatch`/call-site behavior. Still flag results as "code confirmed to behave as
  read, real-world N3 still open" — don't let a passing synthetic test get treated as N3 done.
- **Said skip verification, pick a shape anyway** → proceed to the 3-shape table, but the checkpoint
  and any commit message should say explicitly that this was done without N3 confirmation, at
  Taher's direction, not silently.

If none of the above yet: re-ask, don't guess which path he meant.
