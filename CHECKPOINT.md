# CHECKPOINT — functions/index.js handler tests for the 5 remaining endpoints

**Session date:** 2026-08-29
**Branch:** `test/functions-remaining-endpoint-handlers` (off `main` @ `61f85e0`)
**Previous arc archived to:**
`docs/superpowers/specs/2026-08-29-async-stock-batch-id-minting-CHECKPOINT.md`

## What this session is

Picked up `docs/superpowers/E2E-TESTING-ROADMAP.md`'s "Explicitly scoped out" item:
`functions/index.js` handler tests for the 5 endpoints Skill 46's original handler-test file
deliberately left uncovered — `acquireLock`, `releaseLock`, `provisionMember`, `runCutover`,
`computeAnalysis`. Deliberately did NOT touch the three "Needs Taher's input" items (silent
batch-id-mint failure, `orderMath.js` parity, account-switch-mid-sync) — none of them are scoped
or decided yet, and none of this session's instructions named one explicitly the way the last
session named "Option A."

## Status: implementation complete, verified, not yet committed/pushed as of this checkpoint

### Done
- [x] Fresh clone, branch created, previous CHECKPOINT.md archived
- [x] Read `functions/index.js` end to end (all 8 handlers) plus `lib/lockLogic.js`,
      `lib/cutoverLogic.js`, and their existing test files before designing — confirmed
      `acquireLock`/`releaseLock`/`runCutover` delegate their Firestore work to already-fully-tested
      `lib/` modules (same shape as Skill 46's 3 endpoints), while `provisionMember`/
      `computeAnalysis` have zero delegation — their logic lives directly in `index.js` with no
      prior coverage anywhere. Two different problems, not one.
- [x] Extended `functions/test/testSupport/handlerHarness.js`: LockLogic/CutoverLogic mocking
      (mock only their Firestore-writing exports, keep `validate*`/`buildCutoverMarker` real — same
      convention Skill 46 established for GatewayLogic/BatchMutationLogic); Firestore mock deepened
      with `doc().set()`, `runTransaction()`, and `collection().orderBy().limit().startAfter().get()`
      with real doc-id cursor semantics (needed for `provisionMember`'s transaction and
      `computeAnalysis`'s `readAllPaged` pagination, neither of which existed before)
- [x] Verified the harness extension didn't break Skill 46's original 3-endpoint file — ran it
      standalone against the extended harness before writing anything new: 14/14 still pass
- [x] `functions/test/index.handlers.remaining.test.js` (new) — 49 tests across the 5 endpoints:
      auth (missing/invalid token), request validation (real, unmocked `validate*` functions),
      no-tenant-context, method-not-allowed, the lib-result-forwarding seam (holder info, conflicts,
      `after`), and for `provisionMember`/`computeAnalysis` specifically: `canAssignRole`'s both
      branches, `findOrCreateAuthUser`'s new/existing/invite-by-uid paths, the transaction's
      existing-user-tenant-preservation merge logic, `readAllPaged`'s actual 2-page pagination
      (501 synthetic docs — the one test in this file that would catch a cursor off-by-one; every
      other fixture fits in a single page and wouldn't exercise that branch at all), and the
      `needsOrders` read-skipping optimization for sold/purchased view modes
- [x] Found and fixed a real gap in my own first pass via the coverage report, not by guessing:
      missing `releaseLock` invalid-token test
- [x] Found one broken approach and root-caused it properly rather than working around it blind:
      tried to patch `require.cache[firestorePath].exports.getFirestore` mid-test to simulate a
      transaction failure — silently had no effect (test asserted 500, got 200). Root cause:
      `index.js` destructures `const { getFirestore } = require(...)` at MODULE LOAD time, so its
      local binding is fixed to whatever was in `require.cache` before `index.js`'s first
      `require()` — a later mutation of `require.cache` doesn't reach it. Same load-order
      constraint Skill 46 already documented, hit from the opposite direction (fixing after first
      require, not before). Fixed with a `mockState.runTransactionError` flag read live inside the
      one `runTransaction` closure `index.js` actually holds — full trace in SKILLS Skill 52.
- [x] Full `functions/` suite: **163 tests, 0 failures** (114 pre-existing + 49 new)
- [x] Coverage check (`node --test --experimental-test-coverage`): `index.js` line coverage
      93.27% → 95.32%. All 5 target endpoints at 100% line coverage on their own logic. Remaining
      gaps in `index.js` are entirely pre-existing and outside this session's scope — see "Findings
      not fixed" below.
- [x] Syntax check (`node -c`) + brace/paren/bracket balance check on both touched/new files — clean
- [x] `SKILLS.md` — Skill 52 added
- [x] `AGENTS.md` — Testing & QA Agent section: new bullet under the `functions/test/` entry
      documenting the handler-level test files and the harness's `require.cache`-timing rule
- [x] `README.md` — dated update note under **Testing**
- [x] `docs/superpowers/E2E-TESTING-ROADMAP.md` — item moved from "Explicitly scoped out" to
      "Resolved this arc"; findings below folded into that entry too

### Findings surfaced, not fixed (flagged, per this repo's established discipline)

- **`canAssignRole()`'s `else return false` branch is unreachable** via its only call site —
  `provisionMember` already gates non-owner/admin callers earlier. Not exported, so not directly
  unit-testable either. Likely-dead defensive code, not a bug. Worth a look next time
  `provisionMember` is touched; not urgent enough to act on unilaterally.
- **`send()`'s `JSON.stringify`-failure `catch` block has no reachable trigger** through any current
  handler's real response bodies (all hand-built from plain, non-circular fields). Pre-existing,
  applies equally to all 8 endpoints, not something this session's changes created or could fix by
  adding a test — there's no legitimate code path that reaches it.
- **A pre-existing gap in Skill 46's original scope, found while comparing coverage output, NOT
  fixed here**: `recordMutation`/`recordDelta`/`recordMutationsBatch` are still missing
  method-not-allowed (405) tests for all three, and `recordDelta` specifically is still missing
  invalid-token (401) and write-failed (500) tests that `recordMutation` already has. That's a
  different, already-"resolved" backlog item — reopening it wasn't part of this session's brief, so
  it's flagged in the roadmap rather than silently bundled into this branch's diff. Cheap to close
  if/when it's picked up: same harness, same pattern, no new mocking needed.

## Next action if resumed

Working tree has all changes described above; nothing committed yet as of this checkpoint. If
resumed: `git add -A`, review the diff, commit, push using PAT injected into the URL per the
standing workflow rule, verify `.git/config` is clean of the token, redact in any terminal output
shown. No build/run requested or performed this session (QML side untouched entirely — this arc is
Cloud Functions test coverage only).
