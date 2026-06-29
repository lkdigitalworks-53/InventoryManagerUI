# Staff-Role Access Restrictions Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Restrict the `staff` role so it cannot see financial reports (Value/Purchased/Revenue/Profit), supplier/cost/purchase data, or other staff's sales — while still seeing Current stock, its own sales/sold items, and being able to create its own orders.

**Architecture:** Centralized RBAC. New readonly flags on `AuthStore` + a `uid→staffId` resolver (`StaffStore.findByAppUid`) exposed as `AuthStore.currentStaffId`. Tab pages stay prop-driven (Main.qml binds flags down — the existing convention); the overlay `ProfilePage` reads `AuthStore` inline as it already does. Staff Sold-scoping reuses the page's existing `_staffFilter` machinery by forcing it to the staff member's own name and making it non-removable. Enforcement is client-side QML only; the server gap is documented (P0 gateway out of scope).

**Tech Stack:** Felgo / Qt 6 QML, `pragma Singleton` stores, `qmltestrunner.exe` (QtTest) for pure-logic tests.

---

## Background the implementer needs

This is a Felgo/QML business-management app. RBAC today lives in `qml/model/AuthStore.qml` as
`readonly property bool can*` flags derived from `role` (`"owner"|"admin"|"manager"|"staff"`).
**Tab pages never import `AuthStore`** — `Main.qml` binds flags down as props (see SKILLS.md
Skills 16–17). Overlay pages reached outside the tab Navigation (e.g. `ProfilePage`) DO read
`AuthStore` directly and gate inline; follow whichever pattern the file you're editing already uses.

**Key facts (verified in source):**

- **`AuthStore`** (`qml/model/AuthStore.qml`) exposes `role`, `uid`, and existing flags
  (`canManageInventory`, `canViewSales`, etc.) at lines 31–37. It does NOT currently know the
  current user's own `staffId`.
- **Staff records** carry `appUid` (the Firebase Auth uid), stamped by
  `StaffStore.setAppUid(staffId, appUid)` (`qml/model/StaffStore.qml:199`) when staff credentials
  are provisioned. On Firebase fetch, `appUid` survives (`_fetchFromFirebase` keeps all fields,
  line 224). **BUT `StaffStore._clone()` (lines 62–69) drops `appUid`** — so a local `updateStaff`
  silently loses it. Task 1 fixes `_clone()` to preserve it.
- **Orders** carry `staffId` (set from a dropdown in NewOrderDialog). Completed orders are sales.
- **SalesPage** (`qml/pages/SalesPage.qml`, the "Analysis" page) reads NO `AuthStore`; it is fully
  prop-driven. View modes: `_MODE_VALUE=0, _MODE_PURCHASED=1, _MODE_CURRENT=2, _MODE_REVENUE=3,
  _MODE_SOLD=4, _MODE_PROFIT=5` (lines 31–37). The view-mode `SegmentedPill` is at lines 226–235.
  It already has a `_staffFilter` (a staff **name**, default `"All"`) honored by every computation
  path (`_passesCrossFilters` line ~2012, `_breakdownByDimension` line ~1275, the Revenue gating
  line ~1141). Forcing `_staffFilter` to the staff's own name scopes every Sold computation for free.
- **InventoryPage** (`qml/pages/InventoryPage.qml`): product rows are `ProductCard`s; tapping a row
  fires `onClicked: card.viewClicked()` (line 218) → `root.viewProductClicked(productId)` (line 151)
  → Main.qml opens the read-only detail dialog. FAB/Restock/Edit/Delete are already
  `canManageInventory`-gated. The read-only detail dialog (`EditProductDialog`) is the ONLY
  staff-reachable surface that shows supplier name, cost price, and batch/purchase history.
- **OrdersPage** (`qml/pages/OrdersPage.qml`): list comes from `_filteredOrders()` (line 334,
  iterates `OrdersStore.orders`); status count chips (lines 144–149) mix
  `OrdersStore.orders.length`, `OrdersStore.pendingOrderCount`/`completedOrderCount`, and
  `_countByStatus()` (line 308).
- **DashboardPage** (`qml/pages/DashboardPage.qml`): 2×2 KPI grid (lines 261–303); "Today's sales"
  revenue card at 270–276; helpers `_todayRevenue()` (52), `_todayOrderCount()` (70) iterate
  `OrdersStore.orders`.
- **ProfilePage** (`qml/pages/ProfilePage.qml`): hero `Row` of three `StatTile`s — Orders
  (`SalesStore.totalOrders`, line 154), Revenue (`SalesStore.formatCurrency(SalesStore.totalRevenue)`,
  line 158), Team (line 162). Reads `AuthStore` inline already (lines 198, 256).

**Enforcement boundary:** client-side QML only. A technical staff user can still read restricted
fields from Firestore until the P0 compliance gateway + rules land. This is intentional and stated
in the spec; do NOT add Firestore rules here.

**Build & test commands (Git Bash):**
- Build: `C:/Felgo/Tools/CMake_64/bin/cmake.exe --build --preset felgo-mingw-debug` (fallback
  `cmake --build --preset felgo-mingw-debug`). Expected final: `ninja: no work to do.` / exit 0.
- Unit test: `QT_FORCE_STDERR_LOGGING=1 QT_LOGGING_TO_CONSOLE=1 PATH="/c/Felgo/Felgo/mingw_64/bin:$PATH" "C:/Felgo/Felgo/mingw_64/bin/qmltestrunner.exe" -platform offscreen -input tests/tst_StaffScope.qml`
- New `.qml`/`.js` under `qml/` are auto-globbed (CONFIGURE_DEPENDS); `tests/` is outside `qml/` and
  not packaged. There is no CMake test target — the runner executes the `.qml` directly.

> Note on `/graphify`: the project's knowledge graph covers only the C++/`functions/` layer (zero
> QML files), so it could not inform this work — the plan was derived by reading the QML source.

---

## File Structure

- **Modify `qml/model/StaffStore.qml`** — add `findByAppUid(uid)`; fix `_clone()` to preserve `appUid`.
- **Modify `qml/model/AuthStore.qml`** — add the four new flags + `isStaffRole` + `currentStaffId`.
- **New `tests/tst_StaffScope.qml`** — pure tests for `findByAppUid` and a staff-scoping predicate helper.
- **Modify `qml/Main.qml`** — Analysis tab visibility → `isAuthenticated`; bind new props to SalesPage,
  InventoryPage, OrdersPage, DashboardPage.
- **Modify `qml/pages/SalesPage.qml`** — new props; conditional view-mode pill; forced own-`_staffFilter`;
  hide supplier chart; mode guard; recent-tx guard.
- **Modify `qml/pages/InventoryPage.qml`** — `canOpenProductDetail` prop; gate the row tap.
- **Modify `qml/pages/OrdersPage.qml`** — own-orders scoping for list + status chips.
- **Modify `qml/pages/DashboardPage.qml`** — staff KPI swap.
- **Modify `qml/pages/ProfilePage.qml`** — hide Revenue tile; scope Orders tile.
- **Possibly modify `qml/pages/AnalysisFilterSheet.qml`** — hide supplier/staff rows for staff (Task 9).

---

## Task 1: Identity resolver + `appUid` preservation (TDD)

**Files:**
- Modify: `qml/model/StaffStore.qml`
- Test: `tests/tst_StaffScope.qml` (create)

The resolver and the staff-scoping predicate are the only pure logic; build them test-first.

- [ ] **Step 1: Write the failing test**

Create `tests/tst_StaffScope.qml`:

```qml
import QtQuick
import QtTest
import "../qml/helper/StaffScope.js" as Scope

TestCase {
    name: "StaffScope"

    // findByAppUid is duplicated as a pure function in StaffScope.js so it is
    // unit-testable without instantiating the StaffStore singleton (which needs
    // FirebaseService). StaffStore.findByAppUid delegates to this.
    function test_findByAppUid_match() {
        var roster = [
            { staffId: "STF-001", appUid: "uidA" },
            { staffId: "STF-002", appUid: "uidB" }
        ]
        compare(Scope.findByAppUid(roster, "uidB"), "STF-002")
    }
    function test_findByAppUid_no_match() {
        var roster = [ { staffId: "STF-001", appUid: "uidA" } ]
        compare(Scope.findByAppUid(roster, "nope"), "")
    }
    function test_findByAppUid_empty_uid() {
        compare(Scope.findByAppUid([ { staffId: "STF-001", appUid: "uidA" } ], ""), "")
    }
    function test_findByAppUid_null_roster() {
        compare(Scope.findByAppUid(null, "uidA"), "")
    }

    // ownOrders: when scoping is active, keep only orders whose staffId matches.
    function test_ownOrders_filters_to_self() {
        var orders = [
            { orderId: "O1", staffId: "STF-001" },
            { orderId: "O2", staffId: "STF-002" },
            { orderId: "O3", staffId: "STF-001" }
        ]
        var mine = Scope.ownOrders(orders, "STF-001")
        compare(mine.length, 2)
        compare(mine[0].orderId, "O1")
        compare(mine[1].orderId, "O3")
    }
    function test_ownOrders_empty_staffId_returns_none() {
        // Fail-closed: an unlinked staff (no staffId) sees nothing, not everything.
        var orders = [ { orderId: "O1", staffId: "STF-001" } ]
        compare(Scope.ownOrders(orders, "").length, 0)
    }
    function test_ownOrders_null_orders() {
        compare(Scope.ownOrders(null, "STF-001").length, 0)
    }
}
```

- [ ] **Step 2: Run the test to verify it FAILS**

Run:
```bash
QT_FORCE_STDERR_LOGGING=1 QT_LOGGING_TO_CONSOLE=1 PATH="/c/Felgo/Felgo/mingw_64/bin:$PATH" "C:/Felgo/Felgo/mingw_64/bin/qmltestrunner.exe" -platform offscreen -input tests/tst_StaffScope.qml
```
Expected: FAIL — `StaffScope.js` does not exist.

- [ ] **Step 3: Create the pure helper**

Create `qml/helper/StaffScope.js`:

```javascript
.pragma library

// Pure staff-scoping helpers. No QML/singleton deps so they're unit-testable.
// StaffStore.findByAppUid and the page-level own-scoping delegate here.

// Resolve a Firebase Auth uid to its staffId via the roster's appUid field.
// Returns "" when roster is empty/null, uid is empty, or no record matches.
function findByAppUid(roster, uid) {
    if (!uid || !roster) return ""
    for (var i = 0; i < roster.length; ++i)
        if (roster[i].appUid === uid) return roster[i].staffId || ""
    return ""
}

// Keep only orders belonging to staffId. Fail-closed: an empty staffId yields
// an empty list (an unlinked staff sees nothing, never everything).
function ownOrders(orders, staffId) {
    if (!orders || !staffId) return []
    var out = []
    for (var i = 0; i < orders.length; ++i)
        if ((orders[i].staffId || "") === staffId) out.push(orders[i])
    return out
}
```

- [ ] **Step 4: Run the test to verify it PASSES**

Run the Step 2 command. Expected: all 7 `test_*` cases PASS (plus init/cleanup).

- [ ] **Step 5: Wire `StaffStore` to the helper + fix `_clone()`**

In `qml/model/StaffStore.qml`:

First, add the import at the top (after `import QtQuick`):
```qml
import "../helper/StaffScope.js" as StaffScope
```

Add the resolver method (place it next to `getById`, after line 170):
```qml
    // Resolve a Firebase Auth uid to its staffId (delegates to the pure helper).
    function findByAppUid(appUid) {
        return StaffScope.findByAppUid(staff || [], appUid)
    }
```

Fix `_clone()` (lines 62–69) to preserve `appUid` so a local `updateStaff` can't strip the
resolver's key. Replace the pushed object with:
```qml
            a.push({ staffId: s.staffId, name: s.name, role: s.role, department: s.department,
                      email: s.email, phone: s.phone, joinDate: s.joinDate, status: s.status,
                      salary: s.salary, appUid: s.appUid });
```

- [ ] **Step 6: Build**

Run: `C:/Felgo/Tools/CMake_64/bin/cmake.exe --build --preset felgo-mingw-debug`
Expected: green, exit 0.

- [ ] **Step 7: Commit**

```bash
git add qml/helper/StaffScope.js tests/tst_StaffScope.qml qml/model/StaffStore.qml
git commit -m "feat(staff-rbac): uid->staffId resolver + own-orders scoping helper, preserve appUid"
```

---

## Task 2: AuthStore RBAC flags + currentStaffId

**Files:**
- Modify: `qml/model/AuthStore.qml`

- [ ] **Step 1: Add the new flags**

In `qml/model/AuthStore.qml`, after the existing flags block (after line 37,
`readonly property bool canInviteMembers: ...`), add:

```qml
    // ── Staff-role restriction flags ─────────────────────────────────────
    // Every flag is permissive (true) for non-staff, so owner/admin/manager
    // behavior is unchanged. Client-side UI gating only (server enforcement is
    // the separately-planned P0 gateway).
    readonly property bool isStaffRole:          role === "staff"
    readonly property bool canViewFinancials:    role !== "staff"  // Value/Purchased/Revenue/Profit, cost, revenue
    readonly property bool canViewSuppliers:     role !== "staff"  // supplier names anywhere
    readonly property bool canViewAllSales:      role !== "staff"  // others' sales; staff see only their own
    readonly property bool canOpenProductDetail: role !== "staff"  // the product detail/edit dialog
```

- [ ] **Step 2: Add `currentStaffId`**

Add immediately after the flags from Step 1:

```qml
    // The logged-in user's own staffId, resolved from the staff roster by
    // appUid. "" for non-staff / unlinked users. Referencing StaffStore.staff
    // directly makes this re-resolve when the roster array is reassigned
    // (StaffStore has no `revision` property — verified).
    readonly property string currentStaffId: {
        var _s = StaffStore.staff   // reactivity tie — re-resolve on roster change
        return StaffStore.findByAppUid(uid)
    }
```

VERIFIED: `StaffStore` does NOT have a `revision` property, so the binding ties to
`StaffStore.staff` directly (it is reassigned wholesale on every roster change, so the binding
re-evaluates correctly).

- [ ] **Step 3: Build**

Run: `C:/Felgo/Tools/CMake_64/bin/cmake.exe --build --preset felgo-mingw-debug`
Expected: green, exit 0. Watch for a singleton init-order warning (`AuthStore` referencing
`StaffStore`). If `currentStaffId` logs a binding-loop or undefined-singleton error at startup,
apply the spec's documented fallback: remove the derived binding and instead have
`AuthService.setTenantContext`/`loadTenantMembers` compute `StaffStore.findByAppUid(AuthStore.uid)`
and assign it to a plain `property string currentStaffId: ""` on AuthStore. The public contract
(`AuthStore.currentStaffId`) is unchanged either way. Report which path you used.

- [ ] **Step 4: Commit**

```bash
git add qml/model/AuthStore.qml
git commit -m "feat(staff-rbac): add staff restriction flags + currentStaffId to AuthStore"
```

---

## Task 3: Main.qml — open Analysis tab + bind props

**Files:**
- Modify: `qml/Main.qml`

- [ ] **Step 1: Open the Analysis tab to all authenticated users**

In `qml/Main.qml`, the Analysis `NavigationItem` is gated `visible: AuthStore.canViewSales`
(line 493). Change it to:
```qml
            visible: AuthStore.isAuthenticated
```

- [ ] **Step 2: Bind the new props to SalesPage**

In the `SalesPage { ... }` block (starts line 500), add these property bindings (the props are
added to SalesPage in Task 4; binding them now is harmless — QML ignores unknown props only if
declared, so do Task 4 before running the app, but committing the binding here is fine):
```qml
                    SalesPage {
                        anchors.fill: parent
                        compact: app.compact
                        canViewFinancials: AuthStore.canViewFinancials
                        canViewSuppliers:  AuthStore.canViewSuppliers
                        canViewAllSales:   AuthStore.canViewAllSales
                        currentStaffId:    AuthStore.currentStaffId
                        currentStaffName:  AuthStore.displayName
                        onExportRequested: function(payload) {
                            app._pendingAnalysisExport = payload
                            exportSheet.kind = "sales"
                            exportSheet.open()
                        }
                    }
```
(`currentStaffName` is used by SalesPage to force its name-keyed `_staffFilter`; see Task 4.)

- [ ] **Step 3: Bind `canOpenProductDetail` to InventoryPage**

In the `InventoryPage { ... }` block (line 461), add after `canManageInventory:` (line 464):
```qml
                        canOpenProductDetail: AuthStore.canOpenProductDetail
```

- [ ] **Step 4: Bind own-orders props to OrdersPage**

Find the `OrdersPage { ... }` instance in `Main.qml` (search `OrdersPage {`). Add:
```qml
                        canViewAllSales: AuthStore.canViewAllSales
                        currentStaffId:  AuthStore.currentStaffId
```

- [ ] **Step 5: Bind staff props to DashboardPage**

Find the `DashboardPage { ... }` instance in `Main.qml` (search `DashboardPage {`). Add:
```qml
                        canViewFinancials: AuthStore.canViewFinancials
                        currentStaffId:    AuthStore.currentStaffId
```

- [ ] **Step 6: Build**

Run: `C:/Felgo/Tools/CMake_64/bin/cmake.exe --build --preset felgo-mingw-debug`
Expected: green. (Unknown-property warnings for the not-yet-added props are expected until Tasks
4–7 land; they are warnings, not errors. If the build hard-fails, proceed to Task 4 then rebuild.)

- [ ] **Step 7: Commit**

```bash
git add qml/Main.qml
git commit -m "feat(staff-rbac): open Analysis tab to staff, bind restriction props to pages"
```

---

## Task 4: SalesPage — staff-restricted Analysis

**Files:**
- Modify: `qml/pages/SalesPage.qml`

- [ ] **Step 1: Add the new props**

In `qml/pages/SalesPage.qml`, after `property bool compact: false` (line 15), add:
```qml
    // Staff-restriction inputs (bound from Main.qml). Permissive defaults so
    // non-staff and tests are unaffected.
    property bool canViewFinancials: true
    property bool canViewSuppliers: true
    property bool canViewAllSales: true
    property string currentStaffId: ""
    property string currentStaffName: ""
```

- [ ] **Step 2: Make the view-mode pill conditional**

Replace the view-mode `SegmentedPill` (lines 226–235) with:
```qml
            SegmentedPill {
                Layout.fillWidth: true
                Layout.leftMargin: dp(Constants.space4)
                Layout.rightMargin: dp(Constants.space4)
                Layout.topMargin: dp(Constants.space3)
                // Staff see only Current + Sold; everyone else sees all six.
                model: root.canViewFinancials
                       ? [qsTr("Value"), qsTr("Purchased"), qsTr("Current"),
                          qsTr("Revenue"), qsTr("Sold"), qsTr("Profit")]
                       : [qsTr("Current"), qsTr("Sold")]
                // Map the visible segment index back to the real _MODE_* value.
                selected: root.canViewFinancials
                          ? root._viewMode
                          : (root._viewMode === root._MODE_SOLD ? 1 : 0)
                onSegmentSelected: function(idx, label) {
                    if (root.canViewFinancials) root._viewMode = idx
                    else root._viewMode = (idx === 1 ? root._MODE_SOLD : root._MODE_CURRENT)
                }
            }
```

- [ ] **Step 3: Default staff into Current + clamp guard**

Add a `Component.onCompleted` and a guard. SalesPage already has an `on_ViewModeChanged` handler
(search `on_ViewModeChanged`); add a sibling handler and the completed hook near the other
top-level handlers (after the property block, before the visual tree). If `Component.onCompleted`
already exists, ADD these lines to it rather than duplicating it:
```qml
    Component.onCompleted: {
        if (!canViewFinancials && _viewMode !== _MODE_CURRENT && _viewMode !== _MODE_SOLD)
            _viewMode = _MODE_CURRENT
    }
    onCanViewFinancialsChanged: {
        if (!canViewFinancials && _viewMode !== _MODE_CURRENT && _viewMode !== _MODE_SOLD)
            _viewMode = _MODE_CURRENT
    }
```
NOTE: SalesPage already has a `Component.onCompleted: _rebuildBreakdown()` (search for it). If so,
MERGE — make it:
```qml
    Component.onCompleted: {
        if (!canViewFinancials && _viewMode !== _MODE_CURRENT && _viewMode !== _MODE_SOLD)
            _viewMode = _MODE_CURRENT
        _rebuildBreakdown()
    }
```

- [ ] **Step 4: Force own-sales scoping via `_staffFilter`**

Staff Sold/Revenue computations already honor `_staffFilter` (a staff NAME). Force it to the staff
member's own name and keep it forced. Add a handler that re-applies it whenever the roster/identity
could change. Place near the other `on*Changed` handlers:
```qml
    // Staff are hard-scoped to their own sales: force the existing name-keyed
    // staff filter to themselves and keep it pinned (the removable filter chip
    // and filter sheet are hidden for staff in their respective edits).
    function _enforceStaffScope() {
        if (!canViewAllSales && currentStaffName.length > 0 && _staffFilter !== currentStaffName)
            _staffFilter = currentStaffName
    }
    onCanViewAllSalesChanged: _enforceStaffScope()
    onCurrentStaffNameChanged: _enforceStaffScope()
```
Then call `_enforceStaffScope()` at the START of `_rebuildBreakdown()` (first line of the function
body, before any computation) so it's pinned on every rebuild:
```qml
    function _rebuildBreakdown() {
        _enforceStaffScope()
        // ... existing body ...
```

- [ ] **Step 5: Hide the by-supplier chart for staff**

In the by-supplier `BreakdownBarCard` (lines 540–556), change its `visible` to also require
supplier visibility:
```qml
                visible: root.canViewSuppliers
                         && (root._viewMode === root._MODE_CURRENT
                             || (root._breakdownBySupplier || []).length > 0
                             || root._supplierBreakdownApplies())
```

- [ ] **Step 6: Guard the active-filter chip strip + recent transactions**

The removable active-filter chip strip must not let staff clear their forced own-scope. Find
`_activeFilterChips()` (search it) and the chip strip's `visible`. Simplest correct guard: hide the
staff dimension chip for staff. In `_activeFilterChips()`, the staff push is:
```qml
        if (_staffFilter !== "All")
            out.push({ dimension: "staff", label: qsTr("Staff: %1").arg(_staffFilter) })
```
Wrap it so staff don't get a removable self-chip:
```qml
        if (_staffFilter !== "All" && canViewAllSales)
            out.push({ dimension: "staff", label: qsTr("Staff: %1").arg(_staffFilter) })
```
Recent transactions already render only in Revenue/Purchased (unreachable by staff). Find that
section's `visible` (search `Recent transactions` / `_scopedTransactions`) and add a defensive
`&& root.canViewFinancials` to it.

- [ ] **Step 7: Build**

Run: `C:/Felgo/Tools/CMake_64/bin/cmake.exe --build --preset felgo-mingw-debug`
Expected: green, exit 0. The unknown-property warnings from Task 3 Step 2 should now be gone.

- [ ] **Step 8: Commit**

```bash
git add qml/pages/SalesPage.qml
git commit -m "feat(staff-rbac): restrict Analysis to Current + own-Sold for staff"
```

---

## Task 5: InventoryPage — block product detail for staff

**Files:**
- Modify: `qml/pages/InventoryPage.qml`

- [ ] **Step 1: Add the prop**

In `qml/pages/InventoryPage.qml`, near the existing `property bool canManageInventory` declaration
(search it), add:
```qml
    property bool canOpenProductDetail: true
```

- [ ] **Step 2: Gate the row tap**

The `ProductCard` delegate (line 147) fires `onViewClicked: root.viewProductClicked(...)` (line
151). Gate it so staff can't open the detail:
```qml
                        onViewClicked:    if (root.canOpenProductDetail) root.viewProductClicked(modelData.productId)
```

- [ ] **Step 3: Remove the tappable affordance for staff**

The `ProductCard` is a `QQC.AbstractButton` with `onClicked: card.viewClicked()` (line 218). Pass
the flag into the card and neutralize the press visuals + click when blocked. Add a property to the
`ProductCard component` (near `property bool canManage: true`, line 209):
```qml
        property bool canOpenDetail: true
```
Bind it at the delegate (after `canManage: root.canManageInventory`, line 150):
```qml
                        canOpenDetail: root.canOpenProductDetail
```
Change the card's `onClicked` (line 218) to:
```qml
        onClicked: if (card.canOpenDetail) card.viewClicked()
```
And make the pressed-state background inert when not openable — in the card `background` Rectangle
(line 220–224), change the color line:
```qml
            color: (card.canOpenDetail && card.pressed) ? Constants.subtleBg : Constants.cardBg
```

- [ ] **Step 4: Build**

Run: `C:/Felgo/Tools/CMake_64/bin/cmake.exe --build --preset felgo-mingw-debug`
Expected: green, exit 0.

- [ ] **Step 5: Commit**

```bash
git add qml/pages/InventoryPage.qml
git commit -m "feat(staff-rbac): block product detail dialog for staff in InventoryPage"
```

---

## Task 6: OrdersPage — scope to own orders

**Files:**
- Modify: `qml/pages/OrdersPage.qml`

- [ ] **Step 1: Add props + import the scoping helper**

In `qml/pages/OrdersPage.qml`, add the import at the top (after the existing `import "../model"`):
```qml
import "../helper/StaffScope.js" as StaffScope
```
Near the page's other top-level properties, add:
```qml
    property bool canViewAllSales: true
    property string currentStaffId: ""
```

- [ ] **Step 2: Add a single scoped-orders source**

Add a helper that returns the base order set already narrowed for staff, so both the list and the
count chips read from the same set. Place it next to `_filteredOrders()` (line 334):
```qml
    // Base order set, narrowed to the current staff member when they may not
    // view all sales. Everyone else gets the full tenant set.
    function _scopedOrders() {
        var all = OrdersStore.orders || []
        if (canViewAllSales) return all
        return StaffScope.ownOrders(all, currentStaffId)
    }
```

- [ ] **Step 3: Route the list through the scoped set**

In `_filteredOrders()` (line 334), change the first line from:
```qml
        var orders = (OrdersStore.orders || []).slice()
```
to:
```qml
        var orders = _scopedOrders().slice()
```

- [ ] **Step 4: Route the status count chips through the scoped set**

`_countByStatus()` (line 308) iterates `OrdersStore.orders` directly. Change its source to the
scoped set:
```qml
    function _countByStatus(s) {
        var c = 0
        var arr = _scopedOrders()
        for (var i = 0; i < arr.length; ++i)
            if (arr[i].status === s) c++
        return c
    }
```
The chip model (lines 144–149) uses store-level counts for some chips
(`OrdersStore.pendingOrderCount`, `OrdersStore.completedOrderCount`, `OrdersStore.orders.length`)
which are tenant-wide. Replace those with scoped equivalents so badges match the visible list:
```qml
                    { label: "All", count: _scopedOrders().length },
                    { label: "Pending", count: _countByStatus("pending") },
                    { label: "Processing", count: _countByStatus("processing") },
                    { label: "Completed", count: _countByStatus("completed") },
                    { label: "Cancelled", count: _countByStatus("cancelled") }
```
NOTE: verify the exact status string for pending — `OrdersStore.pendingOrderCount` may count a
specific status value. Confirm the status literals (`"pending"`/`"completed"`) match what orders
actually store (search `status:` in NewOrderDialog/DataModel). If the store uses different literals,
use those.

- [ ] **Step 5: Add reactivity tie**

The chip model + list need to recompute when `OrdersStore.orders` changes. They already bind to
`OrdersStore.orders`/store counts; since `_scopedOrders()` reads `OrdersStore.orders` and
`currentStaffId`, ensure the bindings re-evaluate. If the chip `model` doesn't refresh on order
changes, add `OrdersStore.revision` as a tie inside `_scopedOrders()` (first line
`var _r = OrdersStore.revision`). Verify `OrdersStore` has a `revision` property
(`grep -n "revision" qml/model/OrdersStore.qml`); if yes, add the tie.

- [ ] **Step 6: Build + verify reactivity**

Run: `C:/Felgo/Tools/CMake_64/bin/cmake.exe --build --preset felgo-mingw-debug`
Expected: green, exit 0.

- [ ] **Step 7: Commit**

```bash
git add qml/pages/OrdersPage.qml
git commit -m "feat(staff-rbac): scope Orders list + status chips to own orders for staff"
```

---

## Task 7: DashboardPage — staff KPI swap

**Files:**
- Modify: `qml/pages/DashboardPage.qml`

- [ ] **Step 1: Add props + import**

In `qml/pages/DashboardPage.qml`, add the import (after `import "../model"`):
```qml
import "../helper/StaffScope.js" as StaffScope
```
Add props near the page's other properties:
```qml
    property bool canViewFinancials: true
    property string currentStaffId: ""
```

- [ ] **Step 2: Add a "my sales today" count helper**

Place next to `_todayOrderCount()` (line 70):
```qml
    // Count of the current staff member's own completed orders dated today.
    function _myCompletedToday() {
        var mine = StaffScope.ownOrders(OrdersStore.orders || [], currentStaffId)
        var now = new Date()
        var c = 0
        for (var i = 0; i < mine.length; ++i) {
            var o = mine[i]
            if ((o.status || "") !== "completed") continue
            var d = new Date(o.date)
            if (isNaN(d.getTime())) continue
            if (d.getFullYear() === now.getFullYear()
                && d.getMonth() === now.getMonth()
                && d.getDate() === now.getDate()) c++
        }
        return c
    }
```
NOTE: confirm completed-status literal as in Task 6 Step 4.

- [ ] **Step 3: Swap the revenue KPI card for staff**

Replace the "Today's sales" `GradientKpiCard` (lines 270–276) with a conditional. Use a `Loader`-free
approach by binding label/value to the role:
```qml
                GradientKpiCard {
                    label: root.canViewFinancials ? "Today's sales" : "My sales today"
                    value: root.canViewFinancials
                           ? OrdersStore.formatCurrency(root._todayRevenue())
                           : String(root._myCompletedToday())
                    trend: root.canViewFinancials ? root._todaySalesTrend() : "today"
                    trendVariant: root.canViewFinancials ? "up" : "muted"
                    spark: root.canViewFinancials ? root._last7DaysRevenue() : []
                    palette: Constants.grad1
                }
```
NOTE: verify `GradientKpiCard` accepts an empty `spark: []` without error (it should — search its
definition in `qml/components/GradientKpiCard.qml` and confirm `spark` defaults to an array). If it
requires non-empty, omit the `spark` line for the staff branch by leaving the binding as
`root.canViewFinancials ? root._last7DaysRevenue() : []` only if `[]` is safe; otherwise bind
`spark: root._last7DaysOrderCounts()` for both (a non-financial spark).

- [ ] **Step 4: Build**

Run: `C:/Felgo/Tools/CMake_64/bin/cmake.exe --build --preset felgo-mingw-debug`
Expected: green, exit 0.

- [ ] **Step 5: Commit**

```bash
git add qml/pages/DashboardPage.qml
git commit -m "feat(staff-rbac): swap revenue KPI for 'My sales today' on staff dashboard"
```

---

## Task 8: ProfilePage — hide Revenue tile, scope Orders tile

**Files:**
- Modify: `qml/pages/ProfilePage.qml`

ProfilePage reads `AuthStore` inline (it's an overlay, not a tab page) — follow that pattern.

- [ ] **Step 1: Import the scoping helper**

Add at the top (after `import "../model"`):
```qml
import "../helper/StaffScope.js" as StaffScope
```

- [ ] **Step 2: Gate the Revenue tile + scope the Orders tile**

The hero stats `Row` has three `StatTile`s (lines 153–164). Replace that block with:
```qml
                        StatTile {
                            title: AuthStore.canViewFinancials
                                   ? String(SalesStore.totalOrders)
                                   : String(StaffScope.ownOrders(OrdersStore.orders || [], AuthStore.currentStaffId).length)
                            caption: "Orders"
                        }
                        StatTile {
                            visible: AuthStore.canViewFinancials
                            title: SalesStore.formatCurrency(SalesStore.totalRevenue)
                            caption: "Revenue"
                        }
                        StatTile {
                            title: String(StaffStore.totalStaff())
                            caption: "Team"
                        }
```
NOTE: a `StatTile` with `visible: false` inside a `Row` still occupies layout space unless its
width collapses. Confirm `StatTile` (the component at line 265) collapses when hidden; QML `Row`
skips invisible children for positioning ONLY if `visible` is false (Row DOES skip invisible items).
So `visible: false` is sufficient — the Row reflows. Verify visually in Step 4.

- [ ] **Step 3: Build**

Run: `C:/Felgo/Tools/CMake_64/bin/cmake.exe --build --preset felgo-mingw-debug`
Expected: green, exit 0.

- [ ] **Step 4: Commit**

```bash
git add qml/pages/ProfilePage.qml
git commit -m "feat(staff-rbac): hide Revenue tile and scope Orders tile for staff on Profile"
```

---

## Task 9: AnalysisFilterSheet — hide supplier/staff rows for staff

**Files:**
- Modify: `qml/pages/SalesPage.qml` (where it configures `analysisFilterSheet` before `.open()`)
- Possibly modify: `qml/pages/AnalysisFilterSheet.qml`

The filter sheet already has a `showChannelStaff` flag and a `showDate` flag driven from SalesPage
(search `analysisFilterSheet.showChannelStaff` ~line 133 and `analysisFilterSheet.showDate`). For
staff, the supplier row and staff row are meaningless (they only have Current + own-Sold).

- [ ] **Step 1: Suppress channel/staff/supplier for staff when opening the sheet**

In `SalesPage.qml`, where the settings IconActionButton's `onClicked` configures the sheet (around
lines 119–144), the existing code sets `analysisFilterSheet.showChannelStaff = ...`. Add staff
suppression by ANDing `root.canViewAllSales` into it, and add supplier suppression. Locate:
```qml
                    analysisFilterSheet.showChannelStaff =
                            !isPotentialProfit && (
                                root._viewMode === root._MODE_REVENUE
                                || root._viewMode === root._MODE_SOLD
                                || root._viewMode === root._MODE_PROFIT)
```
Change the closing to also require `canViewAllSales`:
```qml
                    analysisFilterSheet.showChannelStaff =
                            root.canViewAllSales && !isPotentialProfit && (
                                root._viewMode === root._MODE_REVENUE
                                || root._viewMode === root._MODE_SOLD
                                || root._viewMode === root._MODE_PROFIT)
```

- [ ] **Step 2: Hide the supplier row for staff**

`AnalysisFilterSheet.qml` shows a Supplier chip row gated on suppliers existing (search
`SupplierStore.suppliers`). Add a public flag to the sheet and gate the supplier section on it.
In `AnalysisFilterSheet.qml`, near the other public props (`showChannelStaff`, `showDate`), add:
```qml
    property bool showSupplier: true
```
Find the Supplier `Text` label and its `FilterChipRow` (search `qsTr("Supplier")`), and add
`&& root.showSupplier` to BOTH their `visible` conditions (they currently read
`visible: (SupplierStore.suppliers || []).length > 0`):
```qml
            visible: root.showSupplier && (SupplierStore.suppliers || []).length > 0
```

- [ ] **Step 3: Set `showSupplier` from SalesPage**

Back in `SalesPage.qml`'s settings `onClicked` (same block as Step 1), add:
```qml
                    analysisFilterSheet.showSupplier = root.canViewSuppliers
```

- [ ] **Step 4: Build**

Run: `C:/Felgo/Tools/CMake_64/bin/cmake.exe --build --preset felgo-mingw-debug`
Expected: green, exit 0.

- [ ] **Step 5: Commit**

```bash
git add qml/pages/SalesPage.qml qml/pages/AnalysisFilterSheet.qml
git commit -m "feat(staff-rbac): hide supplier/staff filter rows for staff in Analysis filter sheet"
```

---

## Task 10: Final verification — tests + acceptance matrix

**Files:** none (verification only)

- [ ] **Step 1: Re-run the unit suite**

Run:
```bash
QT_FORCE_STDERR_LOGGING=1 QT_LOGGING_TO_CONSOLE=1 PATH="/c/Felgo/Felgo/mingw_64/bin:$PATH" "C:/Felgo/Felgo/mingw_64/bin/qmltestrunner.exe" -platform offscreen -input tests/tst_StaffScope.qml
```
Expected: all green (7 test_* + init/cleanup). Also re-run the existing `tests/tst_BreakdownMath.qml`
to confirm no regression.

- [ ] **Step 2: Clean build**

Run: `C:/Felgo/Tools/CMake_64/bin/cmake.exe --build --preset felgo-mingw-debug`
Expected: green, exit 0, no unknown-property warnings for the touched pages.

- [ ] **Step 3: Manual acceptance matrix (launch app, sign in as each role)**

Verify, signing in as **staff** then as **manager/admin/owner**:

| Surface | staff | non-staff |
|---|---|---|
| Analysis view modes | Current, Sold only | all 6 |
| Analysis "by supplier" chart | hidden | shown |
| Analysis Sold totals | own sales only | all |
| Analysis filter sheet | no supplier/staff rows | full |
| Inventory product tap → detail | nothing opens | opens detail |
| Inventory FAB/Restock/Edit/Delete | hidden | per canManageInventory |
| Orders list + status chips | own orders only | all orders |
| Dashboard top KPI | "My sales today" (count) | "Today's sales" (₹) |
| Profile Revenue tile | hidden | shown |
| Profile Orders tile | own count | tenant total |

Confirm no binding-loop / undefined errors in the console when switching roles.

- [ ] **Step 4: Commit any verification fixes**

```bash
git add -A
git commit -m "fix(staff-rbac): address verification findings"
```

---

## Self-review notes (for the implementer)

- **Spec coverage:** Task 1 → resolver + appUid; Task 2 → flags + currentStaffId; Task 3 → tab open
  + bindings; Task 4 → staff Analysis (pill, scoping, supplier-chart, guards); Task 5 → block product
  detail; Task 6 → own Orders; Task 7 → Dashboard KPI; Task 8 → Profile tiles; Task 9 → filter sheet;
  Task 10 → verification. Every spec section maps to a task.
- **Scoping mechanism choice:** staff Sold-scoping forces the existing name-keyed `_staffFilter` to
  the staff member's own name rather than threading a new predicate through every computation. This
  reuses the proven filter path (`_passesCrossFilters`, `_breakdownByDimension`, revenue gating). The
  forced filter is hidden from the removable-chip strip (Task 4 Step 6) and the filter sheet (Task 9)
  so staff can't clear it.
- **Fail-closed:** `ownOrders("")` returns `[]` — an unlinked staff sees nothing, never everything
  (Task 1 test asserts this).
- **Name vs id:** SalesPage scopes by `_staffFilter` (name, via `currentStaffName`); Orders/Dashboard
  scope by `currentStaffId`. Both are bound from AuthStore; the dual key is intentional because the
  SalesPage filter machinery is name-keyed while Orders/Dashboard match `order.staffId` directly.
- **Verification gaps flagged for the implementer:** status-literal confirmation (Tasks 6/7),
  `revision` property existence (Tasks 2/6), `GradientKpiCard` empty-spark tolerance (Task 7),
  singleton init-order for `currentStaffId` (Task 2 Step 3 fallback). Each has an inline NOTE with
  what to check and the fallback.
- **No CMake change:** new `StaffScope.js` and `tst_StaffScope.qml` are auto-globbed / test-only.
