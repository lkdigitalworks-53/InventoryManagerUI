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

## Status: analysis complete, no item chosen yet, awaiting Taher's direction

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

Check for Taher's decision on which of the three items (if any) to proceed with, and at what scope.
If none yet: re-present the three findings above rather than re-deriving them from scratch — this
session already did the investigation; don't repeat it. Once he picks one (or none): branch off
`main` fresh for that specific item, run brainstorming's design step, then writing-plans, per normal
flow.
