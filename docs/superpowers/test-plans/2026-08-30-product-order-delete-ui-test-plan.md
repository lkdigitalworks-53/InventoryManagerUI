# Test plan — feature/product-order-delete-ui

**Covers:** row-level delete buttons for products (`InventoryPage.qml`) and orders
(`OrdersPage.qml`), success toasts on delete, and delete-specific conflict-toast wording
(`Gateway.mutationConflicted`'s new `action` param, `InventoryStore`/`OrdersStore`'s
`_onMutationConflicted`). Full design and trade-offs: `docs/superpowers/specs/2026-08-30-product-order-delete-ui.md`.

**Read this first:** the delete *logic* this branch's buttons trigger — role checks, the
open-order-reference guard for products, the completed-status guard for orders, audit-log
routing — already existed and was untouched by this branch. What's new here is narrow: the
visual trigger for both, the two success toasts, and the delete-specific wording for one
specific rare failure mode (CAS conflict). Section 1.1 below covers the pre-existing guard
logic anyway, since it had **zero** test coverage before this branch despite being real,
already-shipped code — that gap predates this branch, closing it wasn't optional given the
explicit ask to check delete-failure notification.

**Status (2026-08-30):** written and committed this session, **nothing executed against a real
Qt toolchain** (none available in this sandbox, per this project's standing rule against
installing one here — see `SKILLS.md`). Two of the five test files
(`tst_InventoryPage_deleteButton.qml`, `tst_OrdersPage_deleteButton.qml`) are the **first
page-level UI-interaction tests in this repo's 51-file `tests/` suite** — every existing file
tests a singleton or plain type directly. Treat those two as higher-risk than the rest: if they
fail to even *compile* rather than reporting a real assertion failure, that's most likely a
test-setup problem (Felgo Page bootstrap, layout sizing) worth fixing in the test file itself,
not evidence the buttons don't work.

---

## 1. Unit tests

### 1.1 Written this session (in `tests/`, not run)

- **`tests/tst_DataModel_deleteGuards.qml`** (9 tests) — `DataModel.onDeleteProduct`/
  `onDeleteOrder`, pre-existing logic, zero coverage before this branch. Permission-denied for
  both entities, open-order-reference block for products (and that it clears once the
  referencing order reaches `completed`), completed-status block for orders (and that it clears
  once reopened to `pending`), success path for both, and the specific `errorOccurred`
  context/message pairs — this is the direct check for "does a blocked delete notify the user,"
  and it does, correctly, already.
- **`tests/tst_InventoryStore_mutationConflicted.qml`** (7 tests, new file) — this handler had
  zero coverage before this branch, unlike its `OrdersStore` twin. Covers the pre-existing
  reconcile behavior (replace/push/remove/no-op) plus the new `action` branch: a rejected
  delete-conflict restores the product and shows the delete-worded toast; a rejected
  update-conflict keeps the original wording.
- **`tests/tst_OrdersStore_sync.qml`** (2 new tests appended to the existing file, 12 total in
  the section that matters here) — same `action`-branch coverage as above, for orders.
- **`tests/tst_InventoryPage_deleteButton.qml`** (4 tests) — the actual button: visible when
  `canManage` true, hidden when false, tapping it emits `deleteProductClicked` with the right
  id, and the tap doesn't also bubble into `viewProductClicked`.
- **`tests/tst_OrdersPage_deleteButton.qml`** (5 tests) — same shape for orders, plus one test
  specifically confirming the button stays visible on a `completed` order (the deliberate
  no-row-level-status-gating decision from the spec doc — DataModel's own guard message
  explains the block on tap instead).

### 1.2 Not covered by any committed test, on purpose — see spec doc

- **`Gateway._send`'s single-item conflict-emit change** (`item.action` added as the 4th arg to
  `mutationConflicted`) — this codebase's own `tests/tst_Gateway.qml` documents that `_send`'s
  actual XHR success/conflict/failure branches aren't testable in a QML `TestCase` at all
  without new mock-HTTP infrastructure this repo doesn't have. The one-line change itself reads
  an already-available field (`item.action`); its correctness is covered indirectly by 1.1's
  `InventoryStore`/`OrdersStore` tests, which exercise the receiving side with the param already
  populated, exactly as `_send` would populate it.
- **Terminal non-conflict delete failures** (persistent 403/5xx/network error retried forever by
  `Gateway._send`'s existing backoff, no terminal classification) — not fixed by this branch
  (see spec doc, matches an already-known sibling gap from the chunked-import work), so nothing
  to test here. Flagging again because it's the one part of "notify on delete failure" that
  genuinely isn't handled anywhere yet.

---

## 2. Regression tests

Nothing here should have changed behavior — existing call sites, unchanged signatures for
anyone not passing the new 4th arg.

- [ ] Any existing flow that triggers an **update** conflict (not delete) for a product or
      order still shows the original wording exactly as before — `action` defaults to
      `undefined` for any caller not yet updated to pass it, and both handlers' `if (action ===
      "delete")` branch is false for `undefined`, falling through to the unchanged message.
- [ ] Restock button (products) and the price/status display (orders) — both sit directly next
      to the new delete button in the same row; confirm neither the layout nor their own tap
      targets shifted or became harder to hit.
- [ ] Existing `Toast.show(...)` usages elsewhere in the app (e.g. "Press back again to exit")
      unaffected — `Toast.qml` itself wasn't touched.
- [ ] `permissionErrorDlg` for non-delete `errorOccurred` calls (e.g. an existing restock
      permission check) still opens with the same title/message logic — that `onErrorOccurred`
      handler in `Main.qml` wasn't touched, only two new sibling handlers were added next to it.

---

## 3. On-device plan

### 3.1 Happy paths

| # | Scenario | Expect |
|---|---|---|
| H1 | As owner/admin, tap the trash icon on a product row with no open orders referencing it, confirm in the dialog. | Product disappears from the list, "Product deleted" toast appears. |
| H2 | As owner/admin/manager, tap the trash icon on a pending or processing order, confirm. | Order disappears from the list, "Order deleted" toast appears. |
| H3 | As staff (or any role `AuthStore.canManageInventory`/`canDeleteOrders` excludes), open Inventory/Orders. | Delete icon is not present on any row — not just disabled, absent, matching the same gate Restock already uses. |

### 3.2 Negative / failure-notification paths — the actual point of this branch's third ask

| # | Scenario | Expect |
|---|---|---|
| N1 | As owner/admin, try to delete a product that's referenced by a **pending or processing** order. | Delete is blocked, a modal opens naming the specific blocking order id(s) — not a silent no-op, not a generic error. |
| N2 | As owner/admin/manager, try to delete a **completed** order. | Delete is blocked, a modal says to reopen it to pending first. |
| N3 | Reopen a completed order to pending (existing, untouched flow), then delete it. | Succeeds — confirms the guard's own documented escape hatch actually works end to end, not just in isolation. |
| N4 | **Conflict case, needs two sessions/devices on the same tenant:** load a product's/order's detail on device A, edit and save it from device B, then attempt delete from device A (now working from a stale snapshot). | Delete is rejected; the item reappears in device A's list (not silently gone, not stuck showing a deleted item that still exists server-side); toast reads "Couldn't delete — this was updated elsewhere. It's been restored with the latest version." — **not** the generic update-conflict wording. This is the one on-device scenario that actually exercises the code changed in commit 2 (the `action`-threading fix) rather than just the new buttons. |
| N5 | **Not testable on-device, informational only:** a delete that hits a persistent server-side failure (not a conflict — e.g. a genuine permission/rules rejection after the client-side check passed) currently retries forever in the background with zero user-visible indication, ever. No repro steps exist that don't require deliberately breaking Firestore rules for the test tenant. Documented as a known, out-of-scope gap in the spec doc — worth being aware of, not something to chase down here. |

### 3.3 Edge cases

| # | Scenario | Expect |
|---|---|---|
| E1 | Delete the last remaining product/order in the list. | Empty-state UI appears correctly, no crash. |
| E2 | Delete a product/order while offline (or right as connectivity drops). | Given `main.qml`'s `Navigation { enabled: isOnline }` disables the whole app's interactivity while offline (same pre-existing constraint noted in the 2026-08-28 stock-batch test plan), this likely can't be triggered mid-action at all — confirm that assumption still holds rather than assuming it, then skip if so. |
| E3 | Rapid double-tap the delete icon before the confirm dialog finishes opening. | Exactly one confirm dialog opens, not two stacked; confirming once doesn't fire two delete mutations. |
| E4 | Delete a product, then immediately scroll the now-shorter list. | No stale/ghost row, no index-shift misrender (products/orders are both keyed by id in their delegates, not position, but worth a direct look since this branch touched both row templates). |

### 3.4 Monkey testing

- Rapid multi-tap the delete icon itself across several different rows in quick succession —
  confirm each opens its own correctly-scoped confirm dialog (right product/order id), no
  cross-wiring between rows.
- Tap delete, then tap elsewhere on the row (not Confirm/Cancel) while the confirm dialog is
  still open — confirm the dialog doesn't dismiss into an unintended state.
- Toggle the role/permission mid-session (log out, log back in as a different role) and confirm
  the delete icon's visibility updates without needing an app restart.

---

## 4. Suggested order of attack

1. **N4** — the actual new failure-notification behavior this branch adds (the conflict-wording
   fix); the buttons themselves (H1/H2) are the smaller, lower-risk half of this branch.
2. **H1, H2** — confirm the buttons work at all.
3. **N1, N2** — confirm the pre-existing guards still produce clear messages through the new
   trigger path (they were never reachable from UI before this branch, so this is the first time
   they've ever been hit via a real tap rather than a direct function call).
4. **H3** — permission gating.
5. **N3** — the reopen-then-delete escape hatch.
6. **E1–E4** — as time allows.
7. Regression checklist (Section 2) — spot-check, nothing here was touched directly.
8. Monkey testing last.

## 5. Explicitly out of scope for this test plan

- Building mock-HTTP infrastructure to make `Gateway._send`'s conflict/failure branches unit-
  testable — real work, belongs with the `_send` retry-classification fix if that ever happens,
  not improvised here (see spec doc).
- Fixing or testing the terminal non-conflict failure black hole (N5) — pre-existing, flagged,
  not addressed by this branch.
- Staff delete UI — same gap, same fix shape, not part of this branch (see spec doc).
- Orphaned stock batches / product photo cleanup on product delete — `InventoryStore.deleteProduct`
  doesn't touch either; not changed or tested here.

## 6. Sign-off checklist

- [ ] Section 1.1 unit tests actually passing under `qmltestrunner` — **nothing in this branch
      has been run against a real toolchain yet.**
- [ ] N4 (conflict-case delete) confirmed on-device — the one scenario that actually proves the
      `action`-threading change works outside a unit test's direct function call.
- [ ] H1, H2, H3 happy paths confirmed on-device.
- [ ] N1, N2, N3 confirmed on-device.
- [ ] E1–E4 confirmed, or explicitly skipped with a reason noted (E2 in particular may be
      structurally unreachable — confirm rather than assume).
- [ ] Regression checklist spot-checked.
- [ ] Monkey testing found nothing alarming.
