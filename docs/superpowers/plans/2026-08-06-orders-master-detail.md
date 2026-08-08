# Plan 2 — Orders Master-Detail (Desktop)

Status: In progress
Branch: feature/desktop-ux-design
Spec: docs/superpowers/specs/2026-07-14-desktop-ux-design.md §6.1 (approved 2026-07-16, no changes requested)
Depends on: Plan 1 (desktop-shell-foundation) — merged into this branch, verified by Taher

## 1. Goal

Replace the desktop "Orders" section — currently the raw mobile `OrdersPage` repositioned
inside the shell (a Plan-1 interim bridge, not a defect) — with the master-detail composition
spec §6.1 already describes: a fixed-width scrollable list on the left, a detail pane on the
right showing the selected order, no page navigation on click.

Explicitly NOT in scope: Dashboard, Inventory, Staff, Activity, Settings (still on the interim
mobile-page bridge, waiting their own turn — Taher's call, 2026-08-06). Not rebuilding order
*editing* — that stays on the existing `OrderDetailDialog.qml` bottom sheet (see §2).

## 2. Architecture decisions

**Editing stays on the existing dialog; the new pane is read-only + an "Edit" button.**
`OrderDetailDialog.qml` is a `BottomSheet` with real stakes riding on it — write-lock
acquire/release wired into the async-write-sequencing system, product-line editing, tax
recompute. Rebuilding that inline in a new pane would duplicate compliance-sensitive logic
for a purely cosmetic gain. The detail pane shows the same information read-only and calls
the existing dialog for edits — mirrors the pattern Plan 1 already established for
Staff/Activity/Settings (sidebar triggers existing overlays, doesn't reimplement them).

**Filter/search logic gets one tested source of truth.** `OrdersPage.qml`'s `_scopedOrders`/
`_countByStatus`/`_dateWindow`/`_filteredOrders` are pure functions today, just trapped as
page-private methods. Both the mobile page and the new desktop list pane need identical
behavior here (same bugs already fixed once — see the TZ note in `tst_OrdersDateFilter.qml` —
must not get a second, divergent copy). Extract to `qml/helper/OrdersScope.js`, mirroring the
existing `StaffScope.js` pattern already used in this exact file.

**No new header component.** Reuse existing atoms (`SearchField`, `ChipScroller`,
`IconActionButton`) directly inside `OrdersMasterDetail.qml` rather than extracting
`OrdersPage`'s header into a shared component. `OrdersPage.qml`'s header is small enough
(search + chips + a few icon buttons) that extracting it is speculative abstraction for a
single consumer — if a third surface ever needs it, extract then.

**One shared `navigation` StackView, content swapped per-tab, not the whole shell.** Plan 1's
`DesktopShell` repositions the *same* `navigation` control system-wide; it doesn't own a
content area. Consistent with that: the Orders tab's `AppPage` gets an `if` between
`OrdersPage` (mobile) and `OrdersMasterDetail` (desktop), not a parallel desktop-only
navigation system.

## 3. Files

**New:**
- `qml/helper/OrdersScope.js` — extracted pure filter/search/date-window/status-count functions
- `qml/desktop/OrdersListPane.qml` — left pane: search, status chips, selectable row list
- `qml/desktop/OrdersDetailPane.qml` — right pane: read-only order detail + Edit button
- `qml/desktop/OrdersMasterDetail.qml` — composes the two panes + slim action strip
- `tests/tst_OrdersScope.qml` — unit tests for the extracted module
- `tests/tst_OrdersListPane.qml` — selection/empty-state/signal tests
- `tests/tst_OrdersDetailPane.qml` — rendering/Edit-signal tests

**Modified:**
- `qml/pages/OrdersPage.qml` — delegate to `OrdersScope.js` instead of private copies (behavior-preserving)
- `tests/tst_OrdersDateFilter.qml` — retarget at the real `OrdersScope.js` instead of a hand-duplicated mirror
- `qml/Main.qml` — Orders tab shows `OrdersMasterDetail` on desktop, `OrdersPage` on mobile

## 4. Task 1 — Extract OrdersScope.js

**Files:** `qml/helper/OrdersScope.js` (new), `qml/pages/OrdersPage.qml` (modified),
`tests/tst_OrdersDateFilter.qml` (modified), `tests/tst_OrdersScope.qml` (new)

**Interface:**
```js
.pragma library
// scopedOrders(all, canViewAllSales, staffId) -> array
// countByStatus(scoped, status) -> int
// dateWindow(dateRange, customFrom, customTo, now) -> {from,to} | null   (now defaults to `new Date()`)
// filteredOrders(scoped, searchText, statusFilter, win) -> array, sorted by numeric orderId desc
```
`dateWindow` and the row date-predicate keep the existing local-midnight parse
(`new Date(s + "T00:00:00")`) — that's the TZ fix already locked by the current test, not
something to re-derive.

**TDD steps:**
1. Write `tests/tst_OrdersScope.qml` first, covering: `scopedOrders` (owner sees all vs. staff
   sees own via `StaffScope.ownOrders`), `countByStatus`, `filteredOrders` (search across
   orderId/customer/status, status-filter, combined with a date window), and the same 5 cases
   currently in `tst_OrdersDateFilter.qml` (custom-range inclusive end, unparseable custom range,
   TZ local-midnight parity, "today" inclusion) — now calling `OrdersScope.dateWindow` directly.
2. Create `qml/helper/OrdersScope.js`, porting the four functions verbatim from
   `OrdersPage.qml` lines 333–406, adding the `now` parameter to `dateWindow` (default
   `new Date()`) so it's injectable for tests without changing call sites that don't pass it.
3. Run tests mentally against the ported logic line-by-line (no local Qt toolchain — real
   execution happens in CI/Taher's build); fix until the port is a faithful line-for-line match.
4. Refactor `OrdersPage.qml`: replace the bodies of `_scopedOrders`/`_countByStatus`/
   `_dateWindow`/`_filteredOrders` with one-line delegations to `OrdersScope.*`, passing
   `root.canViewAllSales`, `root.currentStaffId`, `root.dateRange`, `root.customFrom`,
   `root.customTo` as before. Signatures of the page-private functions stay identical — nothing
   else in the file changes.
5. Delete the hand-duplicated `_dateWindow`/`_inWindow` mirror in `tst_OrdersDateFilter.qml`;
   `import "../qml/helper/OrdersScope.js" as OrdersScope` and call `OrdersScope.dateWindow`
   directly in all 5 existing test functions. Same assertions, same names — this is a retarget,
   not a rewrite of intent.

**Done when:** `OrdersScope.js` exists with 4 exported functions; `OrdersPage.qml`'s own
filter functions are one-line delegations; `tst_OrdersDateFilter.qml` tests the real module;
`tst_OrdersScope.qml` covers the parts the old test didn't (search, status-filter, scoping).

## 5. Task 2 — OrdersListPane.qml

**Files:** `qml/desktop/OrdersListPane.qml` (new), `tests/tst_OrdersListPane.qml` (new)

**Interface:**
```qml
// Props (in)
property var orders: []              // OrdersStore.orders, passed in (not read as a singleton — testable standalone)
property bool canViewAllSales: false
property string currentStaffId: ""
property string selectedOrderId: ""  // set externally by OrdersMasterDetail
property string dateRange: "all"
property string customFrom: ""
property string customTo: ""
// Signals (out)
signal orderSelected(string orderId)
```
Width is the caller's job (`OrdersMasterDetail` sets it, per spec §6.1's ~190–220dp column) —
this component doesn't hardcode its own width so it stays testable at any size.

**Visual (reuses, doesn't reinvent):** `SearchField` for search, `ChipScroller` for the 5
status chips (All/Pending/Processing/Completed/Cancelled with live counts — same model shape
as `OrdersPage.qml` lines 152–158), `ListCard` + `AvatarBadge` + `StatusPill` for rows —
same trio `OrdersPage.qml` already uses (lines 249–279), same avatar-palette rotation. Row
click sets nothing locally — it just emits `orderSelected`; the parent owns `selectedOrderId`
and reflects it back in as a prop, so selection state has one owner. Selected row gets a
`Constants.brand1`-tinted 3px left border (spec §4 token) instead of `ListCard`'s default look
— needs a thin wrapper or a `selected` prop on `ListCard` if one doesn't already exist (check
before adding one).

**TDD steps:**
1. Write `tests/tst_OrdersListPane.qml`: empty `orders` → empty-state text visible; a row
   click with matching `orderId` emits `orderSelected` with that id (`SignalSpy`); typing in
   the search field narrows the rendered row count; selecting a status chip does too; setting
   `selectedOrderId` externally is reflected (`findChild` the delegate, check whatever visual
   marker — e.g. `objectName: "selected"` — signals selection so the test doesn't depend on
   color literals).
2. Implement `OrdersListPane.qml` using `OrdersScope.js` for filtering, structurally mirroring
   `OrdersPage.qml`'s header+list (import the same components, same field names) but narrower
   and selection-based instead of navigation-based.
3. Confirm against the test list; iterate until green (CI/Taher's build confirms — no local
   run here).

**Done when:** component renders a filtered, searchable, chip-filterable list; clicking a row
emits `orderSelected`; externally-set `selectedOrderId` visibly marks the matching row.

## 6. Task 3 — OrdersDetailPane.qml

**Files:** `qml/desktop/OrdersDetailPane.qml` (new), `tests/tst_OrdersDetailPane.qml` (new)

**Interface:**
```qml
property string orderId: ""     // empty = nothing selected
property var order: null        // the full record from OrdersStore.getById(orderId), passed in
signal editRequested(string orderId)
```
Passed-in `order` (not a live `OrdersStore` read) for the same testability reason as
`OrdersListPane`'s `orders` prop — this file has zero Firebase/singleton dependency and can
load under `qmltestrunner` on its own.

**Content (per spec §6.1: "same information already shown in the mobile detail dialog, laid
out with more breathing room"):** header (orderId, customer, email/phone, channel, date,
`StatusPill`), a line-items table (name/qty/price/line-total per product from `order.products`),
totals block (subtotal/discount/tax breakdown/total via the existing `formatCurrency`-style
values already computed by `OrdersStore._normalizeOrder`), staff (resolve `order.staffId` to a
display name the same way `OrderDetailDialog.qml` does — check that file's resolution before
duplicating it differently), notes if present, and an "Edit order" button that emits
`editRequested(orderId)` — the caller wires that straight to the existing
`orderDetail.openFor(orderId)`, nothing new to build there. Empty state (no `orderId`) shows a
placeholder ("Select an order to see details") — not a blank pane.

**TDD steps:**
1. Write `tests/tst_OrdersDetailPane.qml`: empty `orderId` → placeholder visible, no crash on
   `order: null`; setting a fixture `order` object renders orderId/customer/total/status
   text somewhere findable; clicking the Edit button emits `editRequested` with the current
   `orderId` (`SignalSpy`).
2. Implement, reusing `StatusPill`/`Constants` tokens throughout, no new color/spacing values
   invented outside the token set.
3. Iterate against the test list.

**Done when:** renders full read-only detail for a passed-in order; empty state doesn't
crash or look broken; Edit button emits the signal with the right id.

## 7. Task 4 — OrdersMasterDetail.qml

**Files:** `qml/desktop/OrdersMasterDetail.qml` (new)

**Interface — deliberately matches `OrdersPage.qml`'s existing contract** so `Main.qml`'s
wiring is a straight swap, not a redesign of the call site:
```qml
property bool canApproveAll: false
property bool canApprovePending: false
property bool canDeleteOrders: false
property bool canViewAllSales: false
property string currentStaffId: ""
property string dateRange: "all"
property string customFrom: ""
property string customTo: ""
signal addOrderClicked()
signal deleteOrderClicked(string orderId)
signal exportRequested()
signal importRequested()
signal filtersRequested()
signal editRequested(string orderId)   // new — OrdersPage's onOrderDetailsClicked equivalent
```

**Composition:** slim top strip (page title + Add/Export/Import/Filter `IconActionButton`s,
wired straight through to the signals above — same actions `OrdersPage`'s header already has,
just relaid-out) above a `RowLayout` of `OrdersListPane` (fixed `Layout.preferredWidth: dp(220)`,
per spec §6.1's 190–220dp) and `OrdersDetailPane` (`Layout.fillWidth: true`). Owns
`selectedOrderId` as its single source of truth: `OrdersListPane.selectedOrderId` bound in,
`OrdersListPane.onOrderSelected` writes it, `OrdersDetailPane.orderId`/`order` bound from it
(`order: selectedOrderId ? OrdersStore.getById(selectedOrderId) : null` — this is the one place
that reads the `OrdersStore` singleton directly; both panes stay prop-driven and testable).
Default-selects the first row of the current filtered list when nothing is selected yet, and
re-picks if the selection scrolls out of the filtered set (deleted, or filtered away by search/
status/date) — without this, a stale `selectedOrderId` shows a blank detail pane after a filter
change, which is worse than always showing something.

**No dedicated test file** — this is a thin composition of two already-tested panes plus
straight signal pass-through; the two panes' own tests cover the real logic. (Consistent with
Plan 1: `DesktopShell.qml` itself wasn't unit-tested either, `Sidebar`/`TopBar` were.)

**Done when:** two panes render side by side; selecting a row updates the detail pane;
Edit calls through; all 5 header actions emit their signals; default-selection and
selection-recovery both work without a blank pane.

## 8. Task 5 — Wire into Main.qml

**Files:** `qml/Main.qml` (modified)

Inside the Orders `NavigationItem` → `NavigationStack` → `AppPage` (lines 476–517), replace the
single `OrdersPage { ... }` with two siblings gated on `app.isDesktopShell`, both `anchors.fill:
parent`, both wired to the exact same root-level dialogs the current single instance uses
(`orderDetail`, `newOrderDlg`, `exportSheet`, `importDlg`, `filterSheet`, `confirmDlg`,
`logic.deleteOrder`):

```qml
OrdersPage {
    id: ordersPage
    visible: !app.isDesktopShell
    anchors.fill: parent
    // ...unchanged from current lines 484–514...
}
OrdersMasterDetail {
    id: ordersMasterDetail
    visible: app.isDesktopShell
    anchors.fill: parent
    canApproveAll: AuthStore.canApproveAll
    canApprovePending: AuthStore.canApprovePending
    canDeleteOrders: AuthStore.canDeleteOrders
    canViewAllSales: AuthStore.canViewAllSales
    currentStaffId:  AuthStore.currentStaffId
    onAddOrderClicked: newOrderDlg.open()
    onEditRequested: function(orderId) { orderDetail.openFor(orderId) }
    onDeleteOrderClicked: function(orderId) {
        confirmDlg.ask({ /* identical body to ordersPage's onDeleteOrderClicked */ })
    }
    onExportRequested: { exportSheet.kind = "orders"; exportSheet.open() }
    onImportRequested: { importDlg.mode = "orders"; importDlg.pickAndStart() }
    onFiltersRequested: {
        filterSheet.targetPage = ordersMasterDetail
        filterSheet.range = ordersMasterDetail.dateRange
        filterSheet.customFrom = ordersMasterDetail.customFrom
        filterSheet.customTo = ordersMasterDetail.customTo
        filterSheet.open()
    }
}
```
`visible: false` rather than a `Loader` swap — cheaper (no re-instantiation on resize across
the 1000dp breakpoint) and matches how `isDesktopShell`-gated visibility already works
elsewhere in this file (line 609's Navigation footer). Both instances stay alive; only one is
visible at a time; `OrdersStore`/`AuthStore` singleton bindings keep both in sync regardless of
which is on screen, so switching mid-resize never shows stale data.

**Manual verification (Taher, on his build — nothing here runs in the sandbox):**
- Resize across 1000dp with Orders open: list/detail view appears, mobile card-list disappears, no crash.
- Click a row → detail pane updates, no navigation/dialog opens.
- Click Edit → existing `OrderDetailDialog` bottom sheet opens, editing/saving still works exactly as before.
- Search and each status chip narrow the list; clearing search restores it.
- Add/Export/Import/Filter buttons open the same dialogs they do on mobile today.
- Staff-role user sees only their own orders in both panes (existing `canViewAllSales` gating).
- Delete an order while it's selected → selection recovers to another row, no blank pane.

## 9. Explicitly deferred (not this plan)

- Global TopBar search actually querying Orders (still an open, separate scope question with
  Taher — parked, not resolved by this plan).
- Dashboard/Inventory/Staff/Activity/Settings desktop-native treatment — Taher's call,
  2026-08-06: wait their turn.
- The spec's own open question (§6.1): list-virtualization/search-vs-scroll behavior at large
  order volumes — revisit once real data volume is known, per the spec's own text.
