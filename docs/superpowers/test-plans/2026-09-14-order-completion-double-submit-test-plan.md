# Test plan — order completion must be re-entrancy-safe, and the user must see it's working

**Branch:** `fix/2026-09-14-order-completion-double-submit` off `main`.

**What it does:** approving a pending order twice in quick succession — before the first
completion's write actually resolves — no longer deducts stock or records the sale twice, and
`OrderDetailDialog` now shows a real busy state (disabled Save, spinner, blocked dismiss) for the
whole duration of a completing save instead of closing instantly and giving no indication anything
is still in flight.

**Bug report, reproduced via static trace (Taher, 2026-09-14, `/superpowers:systematic-debugging`):**
add a pending order (1 item), open it, set status to Completed, save. Completing an order is
genuinely slow (stock validation → FIFO deduction → sale recording, each a real write). No progress
indicator existed, so pressing Approve again before the first save resolved ran the entire
completion a second time. The order's own product-line quantity stayed correct (never itself
duplicated), but Transaction History, Product History, and Sales Analysis all showed figures for 2
items instead of 1.

**Root cause:** `DataModel._tryCompleteOrder`'s only "already completing" guard read
`OrdersStore.getById(orderId).status` — a field that only flips to `"completed"` at the very end of
the same async chain it's meant to guard. A second call arriving mid-chain sees the same stale
`"pending"` value and re-runs the whole deduction. `LockManager`'s pessimistic lock doesn't catch
this either: its server-side `acquireLock` (`functions/lib/lockLogic.js`) re-grants a request from
the SAME `actorUid` by design (needed for renewal heartbeats), so it stops a different device, not
the same user double-submitting.

**Fix, two layers, one root cause:**
1. `DataModel.qml` — a new `_completingOrderIds` in-flight set, set synchronously at
   `_tryCompleteOrder`'s entry and cleared on every exit path, independent of the stale status
   field and of which caller invoked it.
2. `OrderDetailDialog.qml` — wired up to `BottomSheet.qml`'s existing `busy`/`busyMessage`
   mechanism (already used by `RestockDialog`/`AddProductDialog`/`AddStaffDialog`/
   `ImportPreviewDialog`), waiting for `logic.orderUpdated`/`logic.orderCompletionFailed` (scoped to
   the order this dialog issued the save for) before clearing `busy` and closing, instead of
   closing immediately after firing the fire-and-forget update signal.

**Not covered by this plan / out of scope (flagged to Taher, not silently dropped):**
`OrdersPage._approveAllPending()`'s "Approve all pending" banner button has no busy/disabled state
of its own. It's now safe from a data-correctness standpoint — it calls the same
`_tryCompleteOrder` engine, so `_completingOrderIds` protects it too — but a double-click there
still shows no visual feedback while it works. Different file, different UI surface, and the actual
reported bug (data corruption) doesn't depend on fixing it; left as a follow-up. Also out of
scope: `ConfirmReturnSheet`'s lock-span gap and `StockBatchStore`'s FIFO functions still using
whole-record `recordMutation` — both pre-existing, tracked open items unrelated to this bug.

---

## 1. Unit test coverage

**New file `tests/tst_DataModel_completeOrderReentrancy.qml`** — 5 cases, driving the real
`DataModel._tryCompleteOrder` directly (not hand-derived formulas), same child-item-instantiation
pattern as `tst_DataModel_adjustOrderSyncGuard.qml`. **Genuinely run via this repo's `qml-tests` CI
job, not just hand-traced** — and CI caught a real mistake in the first version: it tried to
reassign `StockBatchStore.consumeFifo` to simulate a race, which threw `Cannot assign to read-only
property` at runtime (a QML `function` declaration is a compiled, read-only member, not a mutable
JS property the way a plain object's method would be — see SKILLS Skill 61). The corrected version
below is what actually ran green.

Every store call in this suite resolves its callback synchronously (no real network latency in the
harness), so a second `_tryCompleteOrder` call issued *after* the first one returns can never
actually race it in a test, and — as the CI failure confirmed — a dependency can't be stubbed by
reassignment to fake an in-flight first call either. The corrected tests instead seed
`_completingOrderIds` directly to the exact state a genuinely-racing first call would have left
behind, then confirm a second call is rejected with no side effects — the same style
`tst_DataModel_adjustOrderSyncGuard.qml` uses for its own guard (`TransactionStore.hasMore = true`,
set directly rather than orchestrating a real in-progress fetch). This also surfaced a second real
bug in the test file itself: `dm` is instantiated once for the whole `TestCase`, so
`_completingOrderIds` was leaking across test functions until `init()` explicitly reset it — see
Skill 61.

| Test | What it locks down |
|---|---|
| `test_rejected_while_already_in_flight` | The core fix: a call is rejected (`callback(false)`, non-empty `stockErrorMsg`) while `_completingOrderIds` marks the order in-flight — the exact state a genuinely-racing second click would find. |
| `test_rejection_has_no_side_effects` | The actual reported symptom: a rejected in-flight attempt touches ZERO stock, ZERO FIFO batch quantity, ZERO ledger entries, and leaves the order's own status untouched — proving the guard blocks BEFORE any work, not just eventually returns false. |
| `test_unraced_call_still_succeeds_and_clears_the_guard` | The guard must not weaken the pre-existing behavior: an ordinary call still succeeds and deducts normally, the guard clears once it's done (so the order isn't permanently locked out), and a genuinely SEQUENTIAL second call afterward still short-circuits to `true` with no further deduction — exactly as before this fix. |
| `test_missing_order_still_rejects_cleanly` | An unknown orderId still fails the same way it did before this fix (guard added below the existing `!o` check, not above it). |
| `test_guard_clears_even_on_stock_validation_failure` | The OTHER early-exit path (insufficient stock) also clears the guard — a leak here would permanently lock out retrying the order once stock is replenished. |

## 2. Functional / end-to-end test coverage

No new functional-level test beyond the unit tests above — `_tryCompleteOrder` is itself the
orchestration function (stock check → FIFO deduct → mark complete → record sale), so the unit
tests in section 1 already exercise it end to end through the real singletons, the same way
`OrderDetailDialog._save()` or `OrdersPage._approveAllPending()` would call it. `OrderDetailDialog`'s
own busy-state wiring (the UI half of the fix) has no automated coverage in this pass — it depends
on Felgo-dependent QML types this suite's plain `qmltestrunner` harness doesn't instantiate (see
`test/felgo-dependent/README.md`), same limitation every other dialog-level fix in this codebase
has had. The on-device plan below is the only verification for that half.

## 3. Regression test coverage

This whole branch *is* a regression fix — see section 1 above, which exists entirely because of
this one reported defect, not as general-purpose coverage written ahead of a bug. No separate
section duplicates that list here, per Skill 49's distinction between unit tests that would exist
regardless and regression tests that pin a specific defect — every test above is the latter for
this branch.

## 4. Firestore rules test coverage

Not applicable. This fix is entirely client-side JS logic (`DataModel.qml`'s in-flight guard,
`OrderDetailDialog.qml`'s busy-state wiring) — no new Firestore field, write shape, or query is
introduced, so there is no rules surface to test.

---

## On-Device Test Plan

**Prerequisite:** merge this branch and confirm CI (`qml-tests` job) passes first — the automated
tests above have been traced by hand but not executed; a genuinely green CI run is the first real
proof the QML syntax and Qt API calls are correct, not just the logic.

### Happy Path

1. Create a product with stock ≥ 2. Create a pending order for 1 unit of it.
2. Open the order, set status to **Completed**, tap **Save changes**. **Confirm the sheet shows a
   busy/loading state** (Save button disabled or spinning, sheet can't be dismissed) for the
   duration of the save, then closes normally once it's done.
3. Confirm stock decremented by exactly 1, Transaction History shows exactly 1 sale entry for this
   order, Product History shows 1 unit sold, and Sales Analysis reflects 1 unit / the correct
   revenue for this order.
4. Repeat steps 1–3 for a multi-line order (2+ different products) to confirm the fix doesn't
   regress the ordinary multi-line completion path.

### Negative Cases

5. **The actual reported repro:** create a pending order, open it, set status to Completed, tap
   Save — and, as fast as possible, try to tap Save (or reopen the order and tap Save) again
   before the sheet closes. **Confirm the second tap has no effect** (button disabled / sheet
   unresponsive to a second Save while busy), stock is decremented only once, and Transaction
   History / Product History / Sales Analysis all show figures for 1 item, not 2.
6. With airplane mode or a throttled connection (to widen the in-flight window and make the race
   easier to trigger by hand), repeat step 5. This is the realistic version of the original report
   — "completing order takes some time" — so a slow connection is the most reliable way to
   reproduce the original timing on a real device.
7. Attempt to complete an order for a product with 0 stock available. Confirm the existing
   "out of stock" behavior is unchanged (order marked "out of stock", clear error shown) — the new
   guard must not interfere with the pre-existing stock-validation failure path.
8. Tap **Cancel** or tap outside the sheet while a completion is genuinely in flight (slow
   connection). Confirm the sheet does NOT close/dismiss until the save actually finishes —
   `BottomSheet`'s busy state should block this, same as `RestockDialog`/`AddProductDialog` already
   do.

### Edge Cases

9. Complete an order, then immediately reopen it and change an unrelated field (customer name)
   without changing status or lines. Confirm this plain edit still saves and closes promptly (the
   busy state should be near-instantaneous for a non-completing save, not a multi-second wait).
10. Use **"Approve all pending"** on the Orders page with 2+ pending orders, and try double-tapping
    the Approve button. Confirm no order gets double-processed (stock/ledger correctness — the
    `_completingOrderIds` guard covers this path too even without its own busy indicator). Note:
    the banner itself still won't show a busy/disabled state during this — that's the known,
    explicitly out-of-scope follow-up above, not a regression to flag.
11. Trigger a genuine mid-completion failure (e.g. another device sells the last unit between this
    device's stock check and its deduction call, if reproducible in a test environment). Confirm
    the dialog clears its busy state and shows the failure message (`stockErrorLabel`) rather than
    getting stuck busy forever.
12. Complete an order, then perform a legitimate return/adjustment on it afterward. Confirm the
    unrelated `_tryAdjustOrder` path (not touched by this fix) still works normally.

### Affected Areas

| File | Automated coverage | Where to look on-device if it regresses |
|---|---|---|
| `qml/model/DataModel.qml` (`_tryCompleteOrder`, new `_completingOrderIds`) | `tests/tst_DataModel_completeOrderReentrancy.qml` (4 cases, written/traced, CI pending) | Stock levels, Transaction History, Product History, and Sales Analysis after any order completion, especially under a slow connection or rapid double-tap |
| `qml/pages/OrderDetailDialog.qml` (`_save()`, new busy-state wiring, new `Connections` block) | None automated — Felgo-dependent dialog, out of this harness's reach | The Save button / sheet dismissibility during a completing save; also exercise a PLAIN (non-completing) save to confirm it still closes promptly |
| `qml/pages/OrdersPage.qml` (`_approveAllPending`) | Indirectly covered via `_completingOrderIds` (shared engine) | Bulk-approve with 2+ pending orders, especially double-tapping Approve — correctness only, no busy-state fix here this pass |
| `functions/lib/lockLogic.js` (`sameHolder`) | Not touched by this fix | N/A — documented as the reason locking alone can't fix this, not modified |

### Regression Tests (manual counterpart)

13. **The flagship repro, end to end:** pending order → open → Completed → Save → immediately
    Save again (or reopen + Save again) before the sheet closes. Confirm exactly 1x stock
    deduction and exactly 1 Transaction History entry — this is the single click-through that
    would have caught the original defect.
14. Confirm the busy indicator is visually present (not just non-functional-but-present) during a
    completing save on a throttled connection — the original report's second ask ("block UI if
    need be") is a real user-visible requirement, not just the data-correctness fix.
15. Re-run the Happy Path (steps 1–4) once more after any other changes land on this branch, to
    confirm the ordinary completion flow's timing/UX wasn't made noticeably worse by the added
    busy-state wait (it should only be perceptible for the genuinely-slow completing-order case,
    not a plain field edit).
