# Test plan — creating an order must be re-entrancy-safe, and the user must see it's working

**Branch:** `fix/2026-09-16-new-order-double-submit` off `main`.

**What it does:** double-tapping "Place order" in `NewOrderDialog` — or tapping it again before the
first submission's server-coordinated ID mint resolves — no longer creates two separate orders (and,
with auto-approve on, no longer double-deducts stock). The sheet now shows a real busy state
(disabled/spinning primary button, blocked dismiss) for the duration of the submit instead of
closing instantly with no indication anything is still in flight.

**How this was found:** not a user-reported bug — found via a scope sweep of
`docs/superpowers/ASYNC-REENTRANCY-BUGS.md` (`/superpowers:brainstorming`, 2026-09-16), checking
every `BottomSheet`-derived dialog in `qml/pages/` against the same "does its primary action call a
callback-taking Store/Gateway function, and is there a busy guard around it" checklist that caught
the original order-completion instance (PR #70, C-1 in that tracker → now F-1). C-2 in the same
tracker. Easier to hit than the original bug in practice: a plain fast double-tap on the button
every single order creation goes through, no need to reopen a completed order or pick a specific
action first.

**Root cause:** `NewOrderDialog.trySubmit()` had no `busy` guard of any kind — no early return, no
flag set before the async work started — and called `dlg.close()` unconditionally on the line right
after firing the fire-and-forget `orderCreated` signal, with no wait for `OrdersStore.nextOrderId`'s
real, server-coordinated counter mint (a genuine network round trip) to actually resolve. Unlike
completion, there is no second call path into `OrdersStore.addOrder` a bulk/background caller could
also reach, so there was nothing for a `DataModel`-layer in-flight set to protect against that a
UI-layer guard doesn't already fully cover on its own.

**Fix, three files, one root cause:**
1. `qml/pages/NewOrderDialog.qml` — `if (busy) return` as the first line of `trySubmit()`,
   `busy = true` set synchronously before the `orderCreated` emit, `dlg.close()` removed from
   immediately after the emit, and a new `Connections { target: logic }` block that waits for a real
   `orderAdded` (success → clear busy, close) or `orderCreationFailed` (failure → clear busy, show
   the message inline, stay open) signal — same shape as `OrderDetailDialog._save()`'s existing
   pattern from PR #70. A defensive `busy = false` added to `onOpened`, matching
   `OrderDetailDialog.openFor()`'s idiom, in case a prior open was abandoned mid-flight.
2. `qml/logic/Logic.qml` — new `signal orderCreationFailed(string errorMessage)`, completing a
   success/failure pair that already existed for completion (`orderUpdated`/`orderCompletionFailed`)
   but was only half-built for creation (`orderAdded` existed with no failure counterpart, because
   nothing needed dialog-side failure feedback for creation before this fix).
3. `qml/model/DataModel.qml` (`onAddOrder`) — failure branch now emits the new
   `orderCreationFailed` instead of the generic `dispatcher.errorOccurred("network", ...)` bus.
   Deliberate, not incidental: that bus is shared across roughly a dozen unrelated handlers, and
   gating this dialog's own `busy` reset on it would mean an unrelated failure elsewhere in the app
   could incorrectly clear this dialog's guard mid-flight — reopening the exact window the fix
   exists to close, just via a different trigger. See SKILLS Skill 65.

**Also done this session, before picking up the fix above (scope review, not implementation):**
found and documented 4 already-safe dialogs the original sweep hadn't listed anywhere
(`ProfileSettingsDialog`, `ForgotPasswordDialog`, `ManageCategoriesDialog`,
`ManageOrderChannelsDialog`) — each traced individually and added to
`ASYNC-REENTRANCY-BUGS.md`'s "Checked, not affected" section. No code changes; covered by that
doc's own record, not by this test plan.

**Not covered by this plan / out of scope (flagged, not silently dropped):**
- **C-1** (reopening a completed order, choosing Exchange, increasing a line's quantity — same
  `_tryAdjustOrder` shape the completion fix's guard doesn't cover) is still open in the tracker.
  Picked C-2 first because it's the easier real-world trigger (no special setup); this is a
  deliberate ordering choice, not a decision that C-1 doesn't matter — flagged to Taher for the next
  session.
- **M-1** (`InviteMemberDialog`, same missing-busy-guard shape, lower severity — a role change,
  not a data-correctness bug) and **L-1** (an already-fixed cosmetic double-toast) are both still
  open in the tracker, untouched this session.
- The "Not yet swept" list in the tracker (`SupplierStore`'s own create/edit path — though no
  standalone `SupplierDialog.qml` was found to exist as a separate file; may already be covered
  indirectly via `AddProductDialog`/`RestockDialog`, or may not exist as a distinct surface at all —
  not conclusively resolved this session) is unchanged.

---

## 1. Unit test coverage

**New file `tests/tst_NewOrderDialogSubmitGuard.qml`** — 9 cases. **Written and hand-traced this
session; not genuinely run** — no Qt/Felgo toolchain in this sandbox, per standing constraint (rely
on CI, not local `qmltestrunner`). CI status on the PR is the first real, executed proof, the same
way PR #70's test file needed two rounds of real CI-driven corrections before it ran green (Skills
61–63) — treat this file's correctness as provisional until CI reports back, not as already
confirmed.

`NewOrderDialog.qml` itself cannot be instantiated under plain `qmltestrunner`: it imports
`"../model"` → `Constants.qml` → `import Felgo`, and no CI job in this repo points `qmltestrunner`
at Felgo-dependent files (`test/felgo-dependent/README.md`) — the exact same limitation PR #70's
plan documented for `OrderDetailDialog`'s own busy-state UI. Rather than a hand-derived formula
test, this file models `trySubmit()`'s new guarded control flow with a plain JS-object stand-in,
same technique as the existing `tests/tst_AddStaffSyncClose.qml` — the established precedent in
this codebase for exactly this constraint (see that file's own header comment).

| Test | What it locks down |
|---|---|
| `test_double_tap_while_in_flight_mints_only_once` | The core fix, and the exact reported defect shape: a second `trySubmit()` call while the first is still in flight must not start a second mint attempt — the literal call that used to create a duplicate order. |
| `test_third_and_further_taps_also_rejected_while_busy` | The guard holds under more than one repeated tap, not just exactly two. |
| `test_success_signal_clears_busy_and_closes` | The success path: `onOrderAdded` clears `busy` and closes the sheet. |
| `test_failure_signal_clears_busy_shows_error_does_not_close` | The failure path — the actual reason the dedicated `orderCreationFailed` signal exists: clears `busy` (so the user isn't stuck) and shows the message inline, but does NOT close, unlike success. |
| `test_failure_with_no_message_falls_back_to_default_text` | An empty/missing failure message still shows a usable fallback string instead of a blank error label. |
| `test_can_submit_again_after_success` | A genuinely new submission after a prior success (dialog reopened) is not permanently blocked by the same guard that stops a double-tap. |
| `test_can_retry_after_failure_without_reopening` | A user retrying in place after a failure (sheet stayed open) gets a genuine second mint attempt, not silently swallowed by leftover `busy` state. |
| `test_late_signal_after_already_resolved_is_a_no_op` | A stale/duplicate signal arriving after `busy` has already been cleared once must be ignored, not re-trigger a close or throw re-entering an already-settled state. |
| `test_reopen_clears_any_stuck_busy_state` | Mirrors `onOpened`'s defensive `busy = false` reset: an abandoned/never-resolved prior attempt doesn't permanently wedge the sheet on the next open. |

## 2. Functional / end-to-end test coverage

None beyond the unit tests above. `NewOrderDialog` itself is the UI surface where this bug lived —
there's no separate `DataModel` orchestration function to exercise end to end the way
`_tryCompleteOrder` was for the completion fix (`onAddOrder` is a thin, one-step delegation to
`OrdersStore.addOrder`, unchanged by this fix apart from the one emit-site swap covered in section
4 below). The dialog's own busy-state UI wiring has no automated coverage in this pass, for the same
Felgo-dependency reason as `OrderDetailDialog`'s — the on-device plan below is the only verification
for that half.

## 3. Regression test coverage

This whole branch *is* a regression fix, in the same sense PR #70's plan describes — see section 1
above, which exists entirely because of this one found defect, not as general-purpose coverage
written ahead of time. No separate section duplicates that list here (Skill 49's distinction:
regression tests that pin a specific defect vs. unit tests that would exist regardless — every test
above is the former for this branch).

## 4. Firestore rules test coverage

Not applicable. This fix is entirely client-side QML logic (`NewOrderDialog.qml`'s guard,
`Logic.qml`'s new signal declaration, `DataModel.qml`'s emit-site change) — no new Firestore field,
write shape, or query is introduced, so there is no rules surface to test.

---

## On-Device Test Plan

**Prerequisite status:** CI has not run on this branch yet as of writing this plan (pushed the same
session). Unlike PR #70's plan (written after CI was already green), this on-device plan and the
automated coverage above are BOTH provisional until the `qml-tests` CI job reports back — check CI
status before treating either as confirmed. On-device verification below is the only coverage,
regardless of CI outcome, for `NewOrderDialog`'s own busy-state UI (Felgo-dependent, out of this
harness's reach) and for the true Gateway/mint happy path (needs a live backend).

### Happy Path

1. Create a product with stock ≥ 2. Open **New Order**, add 1 unit of it, fill in a customer name,
   tap **Place order**. **Confirm the sheet shows a busy state** (primary button disabled/spinning,
   sheet can't be dismissed) for the duration of the submit, then closes normally once the order is
   created.
2. Confirm exactly one order appears in Orders (correct customer, item, total) — not zero, not two.
3. Repeat step 1–2 with `autoApproveEnabled` ON (if reachable via Manage settings) to confirm the
   ordinary auto-approve-on-create path still works normally through the new guard.
4. Repeat for a multi-line order (2+ different products, at least one with a per-line discount) to
   confirm the fix doesn't regress the ordinary multi-item creation path.

### Negative Cases

5. **The actual defect, reproduced directly:** open New Order, fill it in, tap **Place order**, and
   — as fast as possible — tap it again (or tap it repeatedly) before the sheet closes. **Confirm
   the second/further taps have no effect** (button disabled while busy) and exactly ONE order is
   created, not two.
6. With airplane mode or a throttled connection (to widen the in-flight window and make the race
   trivially easy to trigger by hand, the same technique PR #70's plan used), repeat step 5. This is
   the most reliable way to reproduce the timing on a real device, not just a lucky fast double-tap.
7. Repeat step 5/6 with `autoApproveEnabled` ON. Confirm stock is deducted exactly once, not twice —
   this is the scenario the doc flags as the worse outcome of the two (creation-only double-tap
   creates a duplicate order; with auto-approve on, it ALSO double-deducts stock, since both
   duplicates get auto-completed). With the fix, there should be no duplicate at all to auto-complete.
8. Trigger a genuine submission failure if reproducible (airplane mode toggled mid-submit, or an
   invalid/expired session). Confirm the sheet clears its busy state and shows the error inline
   (`errorLabel`) rather than getting stuck busy forever, and that the sheet stays open (not closed)
   so the user can retry without re-entering the whole order.
9. Tap **Cancel** or tap outside the sheet while a submission is genuinely in flight (slow
   connection). Confirm the sheet does NOT close/dismiss until the submit actually resolves —
   `BottomSheet`'s busy state should block this, same as `RestockDialog`/`AddProductDialog` already
   do.

### Edge Cases

10. After a failed submission (step 8), retry in place (same sheet, don't close/reopen) with valid
    conditions restored. Confirm the retry succeeds normally and only ONE order results from the
    whole sequence (the failed attempt + the successful retry), not from stale state left over from
    the failure.
11. Create an order, and immediately after it closes, open New Order again and create a second,
    unrelated order right away. Confirm the defensive `busy = false` reset on open doesn't interfere
    with genuinely back-to-back, non-overlapping legitimate submissions.
12. Validation-failure case (e.g. no customer name, or a line quantity exceeding current stock) —
    confirm this still shows the existing inline validation errors and does NOT set `busy`/disable
    the button, since validation failure returns before the guard's `busy = true` line runs (no
    network call was ever started).

### Affected Areas

| File | Automated coverage | Where to look on-device if it regresses |
|---|---|---|
| `qml/pages/NewOrderDialog.qml` (`trySubmit()`, new `Connections` block, `onOpened` reset) | `tests/tst_NewOrderDialogSubmitGuard.qml` (9 cases, written/traced — not yet CI-confirmed) | Order count in the Orders list after any creation, especially under a slow connection or rapid double-tap on "Place order" |
| `qml/logic/Logic.qml` (new `orderCreationFailed` signal) | Indirectly, via the stand-in test's failure-path cases | N/A — a signal declaration; verify by exercising the failure on-device case (step 8) |
| `qml/model/DataModel.qml` (`onAddOrder`'s emit-site change) | Not directly — the new emit line itself depends on `OrdersStore.nextOrderId`'s real network round trip failing, which needs a live/degraded backend to exercise, same reachability limit `_tryCompleteOrder`'s happy path had (Skill 63) | The error message shown inline in `NewOrderDialog` on a genuine submission failure (step 8) — confirm it reads "Could not add order — try again", not a generic/blank message |
| `qml/pages/OrdersPage.qml` (auto-approve-on-create interaction) | Not touched by this fix directly; covered indirectly by the fact that only one order now exists to auto-approve | Stock levels after a create-with-auto-approve-on double-tap (step 7) |

### Regression Tests (manual counterpart)

13. **The flagship repro, end to end:** New Order → fill in → Place order → immediately tap Place
    order again (or repeatedly) before the sheet closes. Confirm exactly 1 order created — this is
    the single click-through that would have caught the original defect.
14. Repeat 13 with `autoApproveEnabled` ON. Confirm exactly 1x stock deduction, not 2x — the
    compounding failure mode the tracker doc specifically calls out.
15. Confirm the busy indicator is visually present (not just non-functionally-present) during a
    submission on a throttled connection — a real user-visible requirement, not just the
    data-correctness fix underneath it.
16. Re-run the Happy Path (steps 1–4) once more after any other changes land on this branch, to
    confirm ordinary order creation's timing/UX wasn't made noticeably worse by the added busy-state
    wait (should be imperceptible on a normal connection; only noticeable when genuinely slow).
