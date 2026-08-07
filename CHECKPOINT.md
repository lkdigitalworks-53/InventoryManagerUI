# Session Checkpoint — Implementing async-write-sequencing review fixes

**Started:** 2026-08-06 (implementation phase, same day as the review)
**Branch:** `fix/async-write-sequencing-review-fixes` (off `docs/async-write-sequencing-design` at
`b51779b` — same fork point as the separate `review/async-write-sequencing-audit` branch, which
holds the review document itself; the two are siblings, not ancestor/descendant, so this branch
needed its own copy of the stale-checkpoint archival — done as the first step below).
**Review doc:** `docs/superpowers/specs/2026-08-06-async-write-sequencing-code-review.md` (on the
sibling review branch — not present in this branch's history yet; referenced from memory/the
conversation, not re-derived).
**Skills used:** `qt-development-skills:qt-qml`, `ponytail:ponytail`,
`superpowers:systematic-debugging`, per Taher's explicit instruction for this phase.
**Status:** 6 of 8 Critical fixes done, verified, and committed locally. Not pushed — no PAT
provided this phase (the one from the review-push round was explicitly being rotated by Taher).

## Step log

1. Archived the stale root `CHECKPOINT.md` (left over from `ci/github-actions-pr-checks`, same
   file the review branch already archived — this branch just hadn't seen that commit) to
   `docs/superpowers/specs/2026-07-31-github-actions-pr-checks-CHECKPOINT.md`.
2. Confirmed `functions/` test baseline for real: `node --test` → 87/87 green, before any changes.
   (`functions/lib/`'s files have zero external `require`s beyond Node built-ins, so this runs with
   no `npm install` needed and no Qt dependency — genuine automated verification available here,
   unlike the QML side.)
3. **C8 fixed + committed** (`856eab3`): removed debug `console.log`s in `gatewayLogic.js`
   (`applyMutation`) and `index.js` (`recordMutation` handler) that dumped full before/after
   document contents on every mutation. Verified: `node --test` still 87/87 after.
4. **C1 fixed + committed** (`70939af`): `OrdersStore._normalizeOrder` was reading
   `inv.consumption` (product/inventory record, no such field) instead of `lp.consumption` (the
   order line itself) — introduced in `b51779b` while consolidating two duplicate
   `_normalizeOrder` functions. Wiped FIFO lineage on every order, crashed on any line whose
   product is deleted/missing. Root-caused and fix-verified via a throwaway Node repro (both
   failure modes reproduced pre-fix, both resolved post-fix). Added 2 new regression tests to
   `tests/tst_OrdersStore_normalization.qml` (the existing test only caught the crash by accident,
   via an unseeded `InventoryStore`, not by design — now explicit).
5. **C2 fixed + committed** (`7d83500`, amended once — see process note below): `firestore.rules`
   never got the `locks/**` lockdown the design doc's Component 2 requires. Added a new
   `isServerOnlyCollection` tier distinct from the existing `isLedgerCollection` tier (locks needs
   BOTH read and write denied, unlike the readable-but-write-locked ledger tier — and the generic
   fallback's `allow read` line needed its own carve-out since it isn't gated by
   `isLedgerCollection` at all). Added test coverage to `test/firestore.rules.test.js` — unrunnable
   in this sandbox (no Firebase emulator network access), same status as the rest of that file.
   Needs an actual rules deploy to take effect; deliberately not run here.
6. **C7 fixed + committed** (`cc6152c`): deleted the dead `OrdersStore.approveAllPending()` /
   `Logic.approveAllPending` signal / `DataModel.onApproveAllPending` handler entirely (confirmed
   dead via full-repo grep — nothing ever emitted the signal). Ponytail-aligned decision: delete
   rather than guard, since it had no live caller and the near-identical name to the real
   `OrdersPage._approveAllPending()` was a standing invitation for a future mis-wire. Also fixed 4
   now-stale comments elsewhere that cited the deleted function as their example of a
   `Gateway.recordMutations` batch caller.
7. **C6 fixed + committed** (`a9ef462`): `LockManager._classifyAcquireResponse` didn't check HTTP
   status at all — every well-formed `{ok:false}` body was classified `"denied"`, so a
   400/401/403/500 (auth/request/server problems, none of which mean "someone else holds this
   lock") showed the user a fabricated "someone else is editing this." Now only `status === 409`
   is `"denied"`; everything else well-formed-but-not-ok is `"error"`, matching
   `_classifyDeltaResponse`'s already-fixed reasoning on the delta path. Also added
   `AuthService.ensureFreshToken()` to `acquire()`, matching every other Gateway call that touches
   auth-sensitive endpoints. Verified all 8 cases (4 pre-existing + 4 new) via Node repro before
   editing the QML file; added the 4 new ones as real tests in `tst_LockManager.qml`.
8. **C5 fixed + committed** (`e2814b5`): `StockBatchStore.consumeFifo`/`topUpOldest` run
   synchronously and unconditionally before the corresponding `InventoryStore.deductStock` delta
   resolves, in both `_tryCompleteOrder` and `_tryAdjustOrder`'s added-units path — on rejection,
   the FIFO batches stayed decremented for units no completed sale/exchange accounts for. Fixed by
   calling `StockBatchStore.restoreFifo` on every already-touched batch when `deltaFailed`, in both
   functions (same structural pattern in both, confirmed via the checkpoint's own note that
   `_tryAdjustOrder` was modeled on `_tryCompleteOrder`). Verified via a Node simulation of a
   two-line order where one line's `consumeFifo` already ran before the other line's delta gets
   rejected — confirms full restoration to pre-order batch quantities.
   **Flagged, not fixed:** an adjacent gap where one line's successful delta stays applied when a
   sibling line's delta fails (partial-completion inconsistency beyond FIFO) — needs a
   compensating delta call, bigger than C5's scope. Left for Taher's call, not silently expanded
   into or ignored.
9. While investigating C4 (restock → recordDelta), found `InventoryStore.creditStockNoBatch`
   (used by the returns flow) has the identical bug to `restock` — computes stock locally, sends
   via plain `recordMutation`. Flagged to Taher as a scope question rather than silently folding it
   in or ignoring it. **Not yet resolved — waiting on Taher's answer before touching C4.**

## Process note — a real mistake, caught and fixed

Mid-session, a `git commit -m "..."` message containing a backtick-wrapped inline command mention
(`` `firebase deploy --only firestore:rules` ``) triggered actual bash command substitution — bash
interprets backticks inside double-quoted strings regardless of markdown intent. Harmless this time
only because `firebase` isn't installed in this sandbox (got "command not found," empty output
silently substituted in, corrupting that part of the message). Amended the commit immediately with
corrected text. **Lesson applied for the rest of this session:** no backticks in `-m "..."` commit
messages; use single quotes for inline command mentions instead.

## Open decisions, waiting on Taher (not proceeding further without them)

1. ~~**C4 scope**~~ — RESOLVED: Taher said fold `creditStockNoBatch` in. Done (`49e498f`).
2. ~~**C3 scope**~~ — RESOLVED: Taher said all 5 stores. Done (`5230af8`, `6c24418`).

## C3 and C4 — both done, verified, committed

**C4** (`49e498f`): converted `restock()` and `creditStockNoBatch()` (folded in per Taher's
decision) to `recordDelta`. Local `products[]` now updates only on server confirmation, matching
`deductStock`'s already-correct pattern. Verified end-to-end against the real, unmodified
`applyDelta` (pure-addition delta, empty floors/clamps applies correctly, is idempotent, stacks
correctly with a second genuine addition) plus a full `functions/` suite re-run (87/87).

**C3** (`5230af8` + `6c24418`, two commits): the largest remaining piece.
- Part 1: added `Gateway.mutationConflicted(entity, entityId, current)` signal and a new pure
  `_parseMutationConflict(status, responseText)` helper. Deliberately narrow, not a full
  status-classification rewrite like C6's: only the specific `409 + conflict:true` shape gets
  special handling (drop, don't retry, emit signal) — every other non-2xx keeps using the existing
  retry path unchanged, since those might genuinely resolve on retry where a real conflict never
  will. Scope decision made and explained, not silently applied: `_sendBatch` does NOT get the
  same treatment, since `batchMutationLogic.js` has no CAS check at all (review finding I1) — a
  conflict check there would be untestable, unreachable code. Verified via Node repro (6 cases)
  before touching the QML file; added as real tests in `tst_Gateway.qml`. Also fixed an unrelated
  stale test found as a byproduct (`test_mode_defaults_to_direct` asserted the wrong default).
- Part 2: wired all 5 stores (`OrdersStore`/`InventoryStore`/`StaffStore`/`SupplierStore`/
  `StockBatchStore`) to the signal, per Taher's "all five" decision. Each reconciles its local
  cache using the same normalize function its own sync already uses (or raw splice for
  `StaffStore`, which has no normalize step, matching its own existing convention). Four show a
  `Toast`; `StockBatchStore` deliberately doesn't (explained in its own comment — batch writes are
  an internal side effect of an action the user already got feedback on elsewhere). Verified the
  shared find/replace/append/remove logic via a 4-case Node simulation. Not added, flagged as a
  reasonable follow-up: dedicated QML-level tests for these 5 handlers specifically.

**All 8 Critical findings from the 2026-08-06 review are now fixed.** Pushed to origin as of
`6c24418`.

## Documentation updated (standing rule: update skills/agent/readme after completing work)

`SKILLS.md` Skill 36, `README.md`'s Concurrency & Conflict Resolution section, and `AGENTS.md`'s
Compliance & Audit Agent cross-reference all updated to reflect the actual current state — see
commit `40873ae` for the full rationale. Each doc now explicitly lists what's still genuinely open
(StockBatchStore's FIFO functions still on `recordMutation`, `recordMutationsBatch` still has no
CAS, bulk-approve still doesn't lock, `ConfirmReturnSheet`'s lock-span gap, the partial-multi-line
gap found during C5) so nothing is silently implied as more finished than it is.

## Session status: implementation complete

All 8 Critical fixes (C1–C8) done, verified (real test runs where possible — `functions/`'s 87/87
suite and the real `applyDelta`/`applyMutation` server-side logic directly; Node-simulated repros
for every QML-side pure-logic change, since no Qt toolchain exists in this sandbox), committed, and
pushed. Documentation updated to match. 5 Important findings (I1–I5) from the review remain
unaddressed — not asked for this round, tracked in the docs above for a future session.
