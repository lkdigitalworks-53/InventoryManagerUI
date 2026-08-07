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

1. ~~**C4 scope**~~ — RESOLVED: Taher said fold `creditStockNoBatch` in. Done, see below.
2. **C3 scope:** the client-side conflict-handling signal (`Gateway.mutationConflicted`) needs to
   be wired into every store that calls `Gateway.recordMutation` to actually be useful. Which
   stores, this pass — just `OrdersStore`/`InventoryStore` (the two most contended per the design
   doc's own examples), or all of them (`StaffStore`, `SupplierStore`, `StockBatchStore`,
   `TransactionStore` too)? **Still unanswered as of this checkpoint — this is the only thing
   blocking C3, the last Critical fix.**

## C4 — done, verified, committed (`49e498f`)

Converted both `restock()` and `creditStockNoBatch()` (folded in per Taher's decision — identical
bug to `restock`, found while implementing) to `recordDelta`. Local `products[]` now updates only
on server confirmation (`result.after.stock`), not optimistically — so `restock()`'s
ActivityLog/TransactionStore/StockBatchStore.addBatch side effects now fire based on confirmed
outcome too, matching `deductStock`'s already-correct pattern. `creditStockNoBatch()` stays
fire-and-forget from its callers (no signature change, matches the existing `restoreFifo`
convention in the returns flow it feeds).

**Verification, real not simulated:** used the actual, unmodified `functions/lib/gatewayLogic.js`
`applyDelta` (requirable directly in Node, no Qt needed) with the same fake-db pattern the real
test suite uses, to confirm the exact new call shape (pure-addition delta, empty floors/clamps)
applies correctly, is idempotent on a retried `requestId`, and stacks correctly with a second
genuine addition. Full `functions/` suite re-run after: still 87/87.

## Next steps

- **Blocking: get Taher's answer on C3's scope** (see open decision #2 above) before starting it.
- Implement C3 once scoped — the last Critical fix, and the largest piece of remaining work.
- Push once complete (a fresh PAT was provided and used for the push after C5 — 7 commits landed
  on origin as of that push; C4's commit `49e498f` and this checkpoint update are local-only until
  the next push).
- After C3 lands: update `SKILLS.md`/`AGENTS.md`/`README.md` per the standing after-implementation
  documentation rule (deliberately deferred until the full fix set is complete).
