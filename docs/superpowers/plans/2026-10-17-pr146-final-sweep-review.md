# PR #146 final sweep: review note (2026-10-17)

PR #146 = P1 slice S1a: server-side stock-movement ledger rows (CGST Rule 56(2)) on `recordDelta` + `recordOperation`. Server only (`functions/`), 16 files, +841/-34. Review branch `review/2026-10-17-pr146-final-sweep`, stacked on #146's branch. Method: requesting-code-review (SHA range `0f081f2..cae6d34`, done by hand, no subagent), ponytail-audit (report format), qt-qml-review (see "Not checked"). Commit email taher.lkdw@gmail.com.

**What this repo does:** Qt/QML + Firebase inventory app for one small business. This PR adds the server code that writes one ledger row per stock change, in the same transaction as the change. Load assumed: a few devices, offline-first, one operator at a time, orders of tens of lines.

## Verified by command (not trusted from the PR text)
- CI on `cae6d34`: Functions, QML, Rules, E2E, PR-comment: 5/5 green.
- `cd functions && node --test`: **685/685** reproduced before my change. 693/693 after (8 new tests).
- `movementLogic.js` coverage 100% line / 100% branch (re-run).
- No client writes `stock_movement` (grep of `qml/`, `src/`, rules, tests): closing it (D5) breaks nothing. `Gateway.qml` still maps it and `DataModel.qml` ignores it; both are removed in S2 (D12).
- `firestore.rules`: `stock_movements` is `allow write: if false`; clients cannot forge rows.
- The three hand-applied hunks the PR asked to eyeball (`gatewayLogic.js`, `operationLogic.js`, `handlerHarness.js`): read, correct. Reads stay before writes; a rejection returns before any write.
- 30 adversarial probes on `movementLogic` (prototype names as kind, NaN, `-0`, sparse array, 51 items, huge values, float sums, whitespace reason): all rejected or accepted correctly.
- `main` is 1 commit ahead (#144). GitHub says the PR is **dirty**. Scratch merge: only `CHECKPOINT.md` conflicts (docs). Rule in force: keep the branch version.

## Findings
### Must fix
None found.

### Should fix
1. **The new write budget leans on a Firestore limit nobody has verified** (`functions/lib/operationLogic.js` budget, `movementLogic.js` MAX_TXN_WRITES)
   - **What this is:** An operation is checked so `2*ops + 1 + rows <= 500`. Before this PR the largest operation was 401 writes. Now it can be 499.
   - **Problem:** Two things are unverified (the code comment already says so): is 500 the real ceiling, and does each `serverTimestamp()` count as an extra write. I searched the docs: the JS SDK reference still says 500 writes per transaction; the current quotas page lists only "500 field transformations per document" and says nothing about transforms counting as writes. If transforms do count, the pinned maximum (166 inventory ops) is about 830 writes and fails. A new test pins this ("would exceed 500 if transforms count").
   - **Fix:** Nothing to change for real orders: a 30-line order is 91 writes, 152 if transforms count (test added); 99 lines = 497, 100 lines = 502 pessimistic. Taher decision D-1 below.
   - **If we skip it:** Only a huge operation (>~99 inventory lines) fails, as a 500 error that the client retries until it parks.
2. **`recordDelta` and `recordMutation` accept any `requestId`, so ids from different endpoints can collide** (`gatewayLogic.js` `validateDeltaRequest`/`validateMutationRequest`)
   - **What this is:** Ledger row id = `{requestId}~m{j}`. `recordOperation` forbids `/` and `~` in its ids; the other two endpoints do not.
   - **Problem:** A member can send `recordDelta` with requestId `completeOrder:o1~0`. That writes audit `completeOrder:o1~0` and row `completeOrder:o1~0~m0`. A later real operation `completeOrder:o1` writes the same two ids with `set` and silently overwrites both. The first stock change then has no audit entry and no ledger row. Our client always sends `req-<ms>-<rand>`, so only a buggy or hostile member does this. The weakness already exists for `audit_log`; this PR adds the ledger to it.
   - **Fix:** In the two handlers in `index.js` (not the shared validators: `recordOperation` passes `~` ids through them) reject a requestId with `/`, `~`, or length > 200. A few lines plus tests. Taher decision D-2.
   - **If we skip it:** Dev only, members only; before production a hostile member could erase their own audit trail.
3. **Until S1b and S2 land, the ledger is incomplete by design** (spec R2, R3, R4)
   - **What this is:** Rows exist only for `recordDelta` and `recordOperation` delta ops. `recordMutation`, batch import and edit paths change stock with no row until S1b. The rules still let a member write `inventory` directly until S2.
   - **Problem:** Deploying S1a alone does not make the app Rule 56(2) complete. The PR text and the spec say this; nothing in the app shows it.
   - **Fix:** None in this PR. Do not treat S1a as the compliance milestone; the milestone is S1b + S2.
   - **If we skip it:** A false sense of "done" if someone reads only the PR title.
4. **Any member role can write ledger rows with any `valueAtCost`** (`index.js` `recordDelta` has no role gate; spec Q1 chose none, R1 accepts client-stated cost)
   - **What this is:** Rows record `actorRole`, but nothing stops a low role from writing `theft` or `gift` rows.
   - **Problem:** `valueAtCost` drives the input-tax-credit reversal. A member can state 0, or 1e308 (accepted, no upper bound).
   - **Fix:** Decide before production: role-gate the intent kinds, and cap `valueAtCost` (for example 1e12). Not needed for dev.
   - **If we skip it:** Wrong ITC figures the day this meets real users.

### Nice to have
5. **`CHECKPOINT.md` on the PR is stale** (step 8b says CI pending, but CI is green; identity line names another email). It is also the one file that conflicts with `main`. Fixed by keeping the branch version at rebase and ticking 8b.
6. **Test fake was too forgiving.** The S1a fake accepts anything, real Firestore throws on an `undefined` value, an odd path, or a read after a write. **FIXED here:** `functions/test/movementStrict.test.js` (8 tests); injecting an `undefined` row field makes 6 of 8 fail.

Findings left out: none. Lean: -0 lines, -0 dependencies possible (module is small and every export is used).

## Decisions for Taher
- **D-1 write ceiling.** A keep as is (real orders are tiny; documented; test pins it). B lower `MAX_OPS` now (needs a client change in `Gateway.maxOperationOps` and its pins; safe under both readings at about 99 ops). C measure on dev with one real 120-line operation after deploy. Trade-off: A is free but trusts an unverified number; B is safest but touches QML and CI; C settles it with one test. **Recommended: A now, C at the S1a deploy check.**
- **D-2 requestId guard.** A add the guard in the two handlers now (small, closes ledger overwrite). B do it in S1b with the other handler edits. C skip until prod. Trade-off: A grows this PR slightly; B is one cleaner diff but leaves a window; C risks forgetting. **Recommended: B, written down as an S1b task.**
- **D-3 merge main.** A rebase #146 on `main` after this review merges (only `CHECKPOINT.md` conflicts, keep branch). B merge `main` into the stacked branch now. Trade-off: B hides conflict handling inside a review PR; A is the usual flow. **Recommended: A.**

## Not checked
- QML: the PR touches no `.qml`, so `qt_qml_lint.py` had no changed file to scan and `qmllint` is not installed. I read the QML consumers of the closed entity by grep only (`Gateway.qml`, `DataModel.qml`, 2 test files). The six qt-qml-review agents were not run as subagents.
- Not run: Firebase emulator, rules tests, e2e, any device. Taher still has to deploy `firebase deploy --only functions` and run the S1a checklist in the test plan.
- Not read in full: the other 5 handlers in `index.js`, `batchMutationLogic.js` (S1b scope).
