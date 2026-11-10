# Test plan: order CAS base (edit/complete/delete after a console edit) + subtle refresh button

Branch `fix/2026-11-10-pr186-order-cas-base` (based on PR #186's head). Design: `specs/2026-11-10-order-cas-base-design.md`, `specs/2026-11-04-l4b-refresh-row-design.md` (addendum 2026-11-10). Nothing was built or run on a device; QML tests ran in CI only.

## 1. Unit tests (what each file covers)
| File | Cases | Run? | Covers |
|---|---|---|---|
| `.github/scripts/__tests__/orderCasBase.test.js` | 25 (CB-1..CB-24) | RUN | Real `OrdersStore` function bodies in a vm against the REAL server `_deepEqual`. CB-1 the report (hand-changed quantity, name, extra key: edit and completion `before` equal the stored doc); CB-1b control: the rebuilt copy differs (the test can fail); CB-2 four edits in a row; CB-3 two edits before the ack; CB-4 the `before` is a copy; CB-5 conflict then retry succeeds; CB-6 deleted elsewhere; CB-7/8 delete logs only on ack, refused delete logs nothing and the retry works; CB-9 ack handler ignores other entity/action/id; CB-10 parked discard; CB-11 unknown id; CB-12 paged load snapshots before defaults; CB-13/14/15 refresh commit / refused / failed / half-run buffer; CB-16 clear and reset; CB-17 remote result; CB-18 adjustment; CB-19/20 outside write drops bases, internal keeps; CB-21 failed batch; CB-22 no base falls back; CB-23 monkey (300 seeds: a conflict never repeats without a new hand edit; no Activity entry without a delete); CB-24 wiring (no `Object.assign` before, one log site, signals connected, one raw `orders =`). |
| `.github/scripts/__tests__/refreshActionWiring.test.js` | 41 (3 + 38 mutants) | RUN | Replaces `refreshRowWiring.test.js`. Five pages wire `RefreshAction` identically and first in the header actions; the old row is gone; the button reads only its props; only `_tap()` arms the caption; it stays while busy and hides 3.5 s after; non-modal; no ticking timer; Main/DataModel glue unchanged. |
| `refreshBehavior.test.js`, `refreshWiring.test.js`, `refreshCaption.test.js` | adapted | RUN | `_setOrders` in the sandbox; the commit rule accepts `_setOrders(all)`; "refresh button" wording. |
| `tests/tst_ActivityLog_deleteEntries.qml` | order delete now acked; +1 refused-delete case | CI only | Real stores and Gateway signals. |
| `tests/tst_RefreshCaption.qml` | wording | CI only | Helper contract in the Qt JS engine. |

Suites run here after the change: scripts 1049/1049, `functions` 1290/1290.

## 2. Functional / rules / e2e
- Functional: the vm scenarios above (real bodies, real server compare, fake edges).
- Rules / e2e: unchanged (no server or rules change).
- Not testable without Qt/Felgo: the button, the popup, the header fit. Pinned by the wiring test, checked on a device.

## 3. On-device test plan
Prerequisite: sandbox tenant, a few pending orders with 2+ lines, Firebase console open on `tenants/{t}/orders/{id}`.

### Happy path
1. H1 (the report). Console: change `quantity` of a line in `products`. App: tap the header refresh button; the order shows. Open it, set status completed, save. It completes; stock is deducted by the NEW quantity; no "updated elsewhere" toast. Console: totals now match the lines.
2. H2. Console: change only `customer`. Refresh, edit notes, save: saved, name kept.
3. H3. Console: add an unknown field. Refresh, edit and save: saved; the field is gone afterwards (expected).
4. H4. Same console edit, refresh, delete a pending order: it goes. Activity shows "Order deleted" only AFTER the sync finishes.
5. H5. Refresh button on each of Inventory, Orders, Staff, Dashboard, Sales: icon is the first header action, muted. Tap: caption under it says "Refreshing…", then "Updated just now", gone about 3.5 s later. Page layout has no extra row.

### Negative
6. N1. Real race: open the app, change the order in the console WITHOUT refreshing, edit in the app: one "updated elsewhere" toast, order refreshed. Edit again: saves.
7. N2. Same race, delete: "Couldn't delete" toast, order back, NO "Order deleted" entry in Activity.
8. N3. Offline: delete an order. It disappears; Activity has no entry. Go online: the entry appears once.
9. N4. Offline tap on the refresh button: the offline toast and the caption "Offline · Updated N min ago", then it fades.
10. N5. Tap with unsent changes queued: the "Sending your changes first" toast, caption "Waiting to refresh…", then "Updated just now".
11. N6. Put the app in the background and back: the lists refresh and NO caption appears.

### Edge cases
12. E1. Hand-edit `total` only, then save any change in the app: total is recomputed from the lines (documented side effect).
13. E2. Two quick edits of one order, then the second ack: no conflict.
14. E3. Complete a hand-edited order, then make a return/exchange adjustment: both save.
15. E4. Large system font and a narrow phone: the Orders header (four icons) still shows the title; the caption does not leave the screen.
16. E5. Tap the button twice quickly: the second tap is ignored while busy (spinner); no second run.
17. E6. Screen reader: the button reads "Updated … Tap to refresh." (or the busy text) and activates.

### Affected areas
Orders list/detail/completion, bulk Approve, import (new orders get a base), adjustments, Activity feed, all five page headers, refresh coordinator (L4a/L4b), Dashboard KPIs after refresh.

### Regression
18. Add an order, complete it, edit it, delete it (normal path): no conflicts, one Activity entry per delete.
19. Product edit/delete after a console edit still behaves as before (products untouched).
20. Existing L4a: resume/reconnect refresh still quiet.
21. Monkey: for 2 minutes, rapidly edit, refresh, delete and re-add orders while editing the same order in the console now and then. Expected: at most one conflict toast per console edit, never a repeat, never a stuck order, Activity matches the deletes that really happened.
