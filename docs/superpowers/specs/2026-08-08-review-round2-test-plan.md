# Test plan — async-write-sequencing, current state after round 2

**Covers:** the whole feature area as it stands on `fix/async-write-sequencing-review-fixes`
after three implementation passes: the original P0 build (`2026-07-29-async-write-sequencing-
design.md`), the 2026-08-06 review round (C1–C8, `2026-08-06-async-write-sequencing-code-
review.md`), and this round (I1–I4 + 3 known/new gaps, `2026-08-08-review-round2-design.md`).

**Purpose of this doc:** answer two questions precisely — what's actually covered by an
automated test that has genuinely been RUN (not just written), and what has no automated
coverage at all and needs a real device. The two are not the same thing, and conflating them is
exactly the mistake the 2026-08-06 review caught in the prior round's checkpoints (see SKILLS
Skill 36, lesson 2 and its round-2 second instance, lesson 2) — this doc is written to not repeat
that.

---

## 1. What's actually verified — `functions/` (Node, runs in this sandbox)

Every file below was exercised with a real `npm test` run in this session, not a static trace.
**94/94 passing** as of the last run in this session (`cd functions && npm test`).

| File | Covers | This round's additions |
|---|---|---|
| `functions/lib/gatewayLogic.js` (`gatewayLogic.test.js`) | `validateMutationRequest`/`validateDeltaRequest`, `applyMutation`'s CAS check, `applyDelta`'s floor/clamp semantics | `_deepEqual` newly exported for reuse — no new direct tests added for it (already exercised indirectly via every CAS test in this file and the batch file below) |
| `functions/lib/lockLogic.js` (`lockLogic.test.js`) | `validateAcquireRequest`/`validateReleaseRequest`, TTL/expiry logic | **I3**: 2 new tests — entity allowlist rejection on both functions |
| `functions/lib/batchMutationLogic.js` (`batchMutationLogic.test.js`) | Batch validation, single-transaction write, idempotent-replay skip | **I1**: fake DB extended to model working-doc state (previously audit-existence only); 5 pre-existing tests updated to pass matching state; 5 new tests — accepts matching before, accepts null-before create, rejects whole batch on one stale item, reports every conflict not just the first, exempts idempotent replay from the check |
| `functions/lib/cutoverLogic.js`, `breakdownMath.js`, `realisedMath.js` | Unrelated to this feature — untouched this round | — |

**This is the strongest claim in this whole plan: these numbers are real, not asserted.** Run it
yourself to confirm: `cd functions && npm test`.

## 2. What exists but was never run — `qml/` (needs `qmltestrunner`, not in this sandbox)

Every file below was **written correctly by static trace** (variable-by-variable, closure-by-
closure, cross-checked against the actual implementation) and passed a brace/paren balance check,
but **none of it has been executed**. No Qt/QML toolchain exists in this sandbox — confirmed
early this session (`which qmltestrunner` → nothing; only incidental Qt5 libs from `apt`, and this
project needs Qt6 via Felgo). Treat every claim in this section as "should pass," not "passes."

| File | Covers | This round's additions |
|---|---|---|
| `tests/tst_LockManager.qml` | Lock acquire/release, `_classifyAcquireResponse` | Pre-existing, unchanged this round |
| `tests/tst_Gateway.qml` | `_classifyDeltaResponse`, `_parseMutationConflict` (C3) | **I1**: 5 new tests for `_parseBatchMutationConflict` — recognizes a conflict, reports every conflicting item, ignores a 409 without conflicts, ignores non-409 statuses, handles malformed/empty bodies |
| `tests/tst_OutboxStore.qml` | Single-flight coalescing | Unchanged this round |
| `tests/tst_OrdersStore_normalization.qml` | `_normalizeOrder`'s consumption/adjustments shape (C1) | Unchanged this round — already fixed and tested in the 2026-08-06 round |

## 3. What has NO test coverage of any kind — static trace only, no test file exists

This is the honest gap. These files/functions have no dedicated QML test harness in this repo at
all (not "untested this round" — never had one), consistent with this codebase's existing pattern
of not unit-testing deep Firebase/Gateway-dependent singletons at this granularity. Every one of
these was verified by manual trace during implementation (see the commit messages on `fix/
async-write-sequencing-review-fixes` for the specific trace of each), not by any runnable check.

| File / function | What changed this round | Trace performed |
|---|---|---|
| `qml/pages/OrderDetailDialog.qml`, `EditProductDialog.qml`, `StaffDetailDialog.qml` | **I4**: retry lock acquisition on "try again" | Traced the `_retryLockAcquire()` guard (`openedId` capture) against each dialog's existing lock-state machine |
| `qml/model/DataModel.qml` (`_tryCompleteOrder`, `_tryAdjustOrder`) | Partial-multi-line-completion fix (2 sites) | Traced a 2-succeed-1-fail scenario by hand for both sites — see the commit message |
| `qml/pages/OrderDetailDialog.qml` + `ConfirmReturnSheet.qml` | Lock-span handoff | Traced all 3 close paths (confirm/cancel/dismiss) against `BottomSheet.qml`'s actual button-click behavior — confirmed `GhostButton` auto-closes, `onClosed` fires uniformly |
| `qml/pages/OrdersPage.qml` (`_approveAllPending`) | **I2**: per-order locking | Traced the closure capture (`_next()`'s recursion gives each iteration its own `orderId` binding) |
| `qml/model/StockBatchStore.qml` (all 3 FIFO functions) | Full async rewrite | Traced all 7 `DataModel.qml` call sites' closures individually; this is the highest-risk change of the round and deserves the most scrutiny on-device (see §4) |
| `qml/pages/ImportPreviewDialog.qml` | `completeImportedOrder` loop restructured to sequential/async | Traced against the pre-existing `_nextAdjust()` pattern in the same file, which this mirrors |

## 4. On-device checklist — what Taher needs to actually click through

In priority order (highest-risk first). Each item names the specific failure mode this round was
supposed to fix, so a pass/fail is unambiguous rather than a vague "seems fine."

1. **Run the QML test suite for real**: `qmltestrunner` (or the project's usual CI invocation)
   against every file in §2. This alone would catch the large majority of any mistake in this
   round, faster than manual clicking.
2. **Multi-batch order completion.** Set up a product with 2+ stock batches (different suppliers/
   costs), place an order for a quantity spanning both batches, complete it. Confirm: the order's
   line-level `consumption[]` shows the correct batch attribution and quantities: total consumed
   matches, `product.stock` decremented correctly. This exercises the StockBatchStore rewrite's
   core path.
3. **Order completion with a genuinely insufficient product** (qty > total stock across all
   batches). Confirm the order is correctly rejected — this exercises `floors` correctly returning
   `ok:false` rather than silently under-delivering.
4. **Two-line order, force one line to fail.** Hardest to set up manually (needs a genuine
   concurrent edit or an artificially deleted product mid-flow) — if there's an existing way to
   simulate an inventory delta rejection, use it; otherwise this is the one item worth a deliberate
   test hook. Confirm: the line that already succeeded gets its `product.stock` credited back (not
   just its FIFO batches, which C5 already handled) — this is the partial-multi-line-completion fix.
5. **Exchange/return via `ConfirmReturnSheet` across two devices** (or two browser sessions/
   accounts). Open an order for return on device A, confirm the lock badge/message shows correctly
   on device B mid-review (before A taps Confirm). This is the lock-span fix — the bug was a window
   where B could edit while A was still reviewing the confirm sheet.
6. **Bulk-approve with a concurrent single-order edit.** Start editing one pending order on device
   A (open `OrderDetailDialog`, don't save), trigger bulk-approve from device B including that same
   order. Confirm B's result shows that order under "being edited elsewhere," not silently skipped
   or wrongly reported as insufficient stock.
7. **"Try again" on all 3 dialogs.** Get a device into a lock-denied state (open the same
   product/order/staff record for edit on two devices), tap Save on the denied one, close the
   dialog on the OTHER device (releasing the lock), tap Save again on the first. Confirm it now
   succeeds — this is the I4 fix; before it, tapping Save again did nothing.
8. **Entity allowlist (I3) — low priority, defense-in-depth only.** No normal user flow can trigger
   this (it requires a malformed request), so this is really only worth a manual `curl`/Postman
   call against `acquireLock` with a bogus `entity` value if you want to confirm the 400 directly;
   otherwise the `functions/` test coverage (§1, actually run) is sufficient confidence here.
9. **Bulk import with a genuine conflict (I1) — hardest to stage, most consequential.** Import the
   same CSV/file twice concurrently from two sessions, OR edit a record on device A between
   generating an import file and applying it on device B, such that an import row's `before` no
   longer matches. Confirm: the whole batch is rejected (not partially applied), the affected
   stores' local cache reconciles via the conflict signal, and — importantly — that nothing was
   silently overwritten. This is the highest-value check on this whole list given the stated
   business invariant ("imports must never silently overwrite data").

## 5. What this plan deliberately does NOT cover

- **Firestore rules deploy verification.** `firestore.rules`' `locks/**` lockdown was C2, already
  shipped in the prior round — not touched this round, not re-verified here.
- **The separately-tracked "counter seeding failure from paginated product loading" investigation**
  (a prior-session open item, unrelated root cause). I1's CAS check makes this SAFER regardless of
  whether that bug is real (a wrong `before` now gets conservatively rejected instead of silently
  applied), but doesn't fix it — that's still open, separate work.
- **Load/performance testing** of the sequential (not parallel) `consumeFifo` batch walk under a
  genuinely large multi-batch consumption. Expected to be rare in practice (see the code comment
  in `StockBatchStore.qml`) but not measured.
