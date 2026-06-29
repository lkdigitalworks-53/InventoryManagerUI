# Staff-role access restrictions

**Date:** 2026-06-16
**Status:** Approved design — ready for implementation planning
**Area:** `qml/model/AuthStore.qml`, `qml/model/StaffStore.qml`, `qml/Main.qml`,
`qml/pages/SalesPage.qml`, `qml/pages/InventoryPage.qml`, `qml/pages/OrdersPage.qml`,
`qml/pages/DashboardPage.qml`, `qml/pages/ProfilePage.qml`

## Problem

The `staff` role currently has too much visibility. A staff member must NOT see:

- Financial reports: **Value, Purchased, Revenue, Profit** views in Analysis.
- **Supplier** identity, product **cost price**, and **purchase/restock transactions**.
- **Other staff's** sale transactions.
- Tenant-wide **revenue** figures (Dashboard KPI, Profile stat tile).
- The product **detail/edit dialog** on the Inventory page (it exposes supplier, cost, batch
  history).

A staff member MAY see:

- **Current stock** report.
- **Their own** sale transactions and **their own** sold items (Sold view, scoped to them).
- Product **name, category, selling price, current stock** in the inventory list.
- Create/complete **their own** orders.

## Goals

- Add role flags + a current-user→staff identity resolver so every restriction reads from one
  source of truth.
- Open the Analysis tab to staff but render a restricted page (Current + own-Sold only).
- Scope Orders, the Sold view, the Dashboard, and the Profile stats to the staff member's own
  identity where "their own" applies.
- Block the product detail dialog for staff entirely.

## Non-goals

- **Server-side enforcement is out of scope.** See "Enforcement boundary" below.
- No change to owner/admin/manager behavior anywhere (every new gate is a no-op for non-staff).
- No new dialog layouts (the product detail dialog is *blocked* for staff, not rebuilt).
- No change to how orders are created (staffId is still set on the order as today).

## Enforcement boundary (explicit)

All enforcement in this feature is **client-side QML** (visibility bindings + list filtering +
role flags). This matches every existing RBAC gate in the app (client-direct Firestore REST).

**A technical staff user can still read cost price, supplier names, other staff's sales, and
revenue directly from Firestore** until the separately-planned **P0 compliance gateway + Firestore
security rules** land (`docs/superpowers/specs/2026-06-06-P0-compliance-gateway-design.md`). This
feature deliberately does not implement field-level redaction or rules. The restrictions here are a
UI-trust boundary, not a security boundary.

## Decisions captured during brainstorming

| Question | Decision |
|---|---|
| How to identify "their own" sales | Auto-link login → staff via `appUid` (resolve `uid → staffId`) |
| Which Analysis views for staff | **Current + Sold only** |
| Staff tapping a product | **Block the detail dialog entirely** |
| Dashboard revenue KPI for staff | **Replace** with a staff metric ("My sales today" count) |
| Orders tab for staff | **Scope to their own** orders |
| Profile Revenue stat tile | Hidden for staff; Orders tile scoped to their own |
| Enforcement depth | UI-layer, with the server gap documented (above) |

## Architecture

Approach **A** — centralized RBAC flags on `AuthStore` + a resolved `currentStaffId`. Pages stay
prop-driven (the existing convention: tab pages never import `AuthStore`; Main.qml binds flags
down — see SKILLS.md Skills 16–17). Overlay pages that already read `AuthStore` directly
(ProfilePage) keep doing so, gating inline as they already do.

### `AuthStore.qml` — new readonly flags

```qml
readonly property bool isStaffRole:          role === "staff"
readonly property bool canViewFinancials:    role !== "staff"  // Value/Purchased/Revenue/Profit, cost, revenue KPIs
readonly property bool canViewSuppliers:     role !== "staff"  // supplier names anywhere
readonly property bool canViewAllSales:      role !== "staff"  // others' sales; staff see only their own
readonly property bool canOpenProductDetail: role !== "staff"  // the product detail/edit dialog
```

`canManageInventory` (owner/admin) is unchanged and already gates the FAB, Restock, Edit, Delete.

`canViewSales` (owner/admin/manager) currently has exactly one consumer — the Analysis tab
`visible` binding in `Main.qml` — which this feature changes to `isAuthenticated` (§1 below). That
leaves `canViewSales` with no callers. **Keep the flag** (it's a harmless, semantically meaningful
RBAC flag that a future surface may reuse); do not delete it as part of this feature. Removing it
would be unrelated cleanup outside this scope.

### Identity resolver — `uid → staffId`

`StaffStore.qml` gains:

```qml
// Find the staffId whose record was linked to this Firebase Auth uid
// (appUid is stamped by AuthService when staff credentials are provisioned).
// Returns "" when no staff record matches (e.g. an owner not in the roster).
function findByAppUid(uid) {
    if (!uid) return ""
    var arr = staff || []
    for (var i = 0; i < arr.length; ++i)
        if (arr[i].appUid === uid) return arr[i].staffId || ""
    return ""
}
```

`AuthStore.qml` exposes the current user's own staff id, recomputed reactively when the roster
loads or the uid changes:

```qml
// "" for non-staff / unlinked users. Staff filters only ever apply when
// canViewAllSales is false, and a real staff user always has a linked record.
readonly property string currentStaffId: StaffStore.findByAppUid(uid)
```

> Reactivity note: `findByAppUid` reads `StaffStore.staff`; bind through `StaffStore.revision` (or
> reference `staff` directly) so `currentStaffId` re-resolves after the roster syncs from Firebase.
> If `AuthStore` referencing `StaffStore` introduces a singleton init-order cycle, fall back to
> computing `currentStaffId` in `AuthService` after `loadTenantMembers()` and storing it as a plain
> property on `AuthStore`. Implementation picks whichever loads cleanly; the public contract
> (`AuthStore.currentStaffId`) is the same either way.

## Component-by-component changes

### 1. Analysis page (`SalesPage.qml` + `Main.qml` wiring)

`Main.qml` currently gates the whole Analysis tab with `visible: AuthStore.canViewSales`
(owner/admin/manager). Change the tab to `visible: AuthStore.isAuthenticated` and push restriction
into the page via new props:

```qml
SalesPage {
    canViewFinancials: AuthStore.canViewFinancials
    canViewSuppliers:  AuthStore.canViewSuppliers
    canViewAllSales:   AuthStore.canViewAllSales
    currentStaffId:    AuthStore.currentStaffId
    ...
}
```

In `SalesPage.qml` (add the four props, default permissive = `true`/`""` so non-staff and tests are
unaffected):

- **View-mode pill** — build the model conditionally. When `!canViewFinancials`, the pill lists
  only **Current** and **Sold**; selecting them maps to `_MODE_CURRENT` / `_MODE_SOLD`. Default
  `_viewMode` to `_MODE_CURRENT` for staff on load.
- **Mode guard** — in `_rebuildBreakdown()` (or an `onCanViewFinancialsChanged`/`Component.onCompleted`
  hook), clamp `_viewMode` to an allowed mode when `!canViewFinancials` so a stale/out-of-range
  value can never render a financial view.
- **Sold scoping** — when `!canViewAllSales`, force a non-removable staff predicate
  (`order.staffId === currentStaffId`) into every Sold computation: hero total, main breakdown,
  by-category breakdown, and the export. Reuse the existing staff-filter path in
  `_breakdownByDimension` / `_passesCrossFilters` — the difference is it's forced on and not shown
  as a removable filter chip.
- **Supplier breakdown** — hide the "by supplier" `BreakdownBarCard` when `!canViewSuppliers`. Staff
  Sold view = hero + main breakdown + by-category only.
- **Recent transactions** — already shown only in Revenue/Purchased (both unreachable by staff); add
  a defensive `&& canViewFinancials` to its `visible` so it can never render for staff.
- **Filter sheet** — the supplier/staff/channel filter rows in `AnalysisFilterSheet` are
  meaningless for staff; hide supplier (and the staff selector) for staff via the existing
  `showChannelStaff`-style flags, driven by the new props. (Staff only have Current + own-Sold, so
  most filter dimensions don't apply.)

### 2. Inventory page (`InventoryPage.qml` + `Main.qml`)

Add a `canOpenProductDetail` prop (default `true`). When `false` (staff):

- The product row's tap handler does **not** emit `viewProductClicked` (the row becomes
  non-interactive for opening detail — remove the tap ripple/chevron affordance so it doesn't look
  tappable).
- FAB, Restock, Edit, Delete are already `canManageInventory`-gated → already hidden for staff.

`Main.qml` binds `canOpenProductDetail: AuthStore.canOpenProductDetail`. The list still shows name,
category, selling price, current stock (none restricted). Cost price never renders in the list;
supplier and batch/purchase history live **only** inside the now-blocked detail dialog, so blocking
it closes those leaks with no separate redaction.

### 3. Orders tab (`OrdersPage.qml` + `Main.qml`)

Add `canViewAllSales` + `currentStaffId` props (defaults `true` / `""`). `OrdersPage` reads
`OrdersStore.orders` through a `_filteredOrders()` helper (and derives the All/Pending/… status
count chips from `OrdersStore.orders`). When `!canViewAllSales`, narrow **both**:

- `_filteredOrders()` — add a first-pass filter `order.staffId === currentStaffId` before the
  existing status/search filtering, so the list shows only the staff member's own orders.
- The status count chips — compute their counts from the same own-scoped set so the badges match
  the visible list (otherwise "All (42)" would contradict a 3-row list).

`OrdersStore` itself is untouched (still the full tenant set); only the view narrows. Staff still
create and complete their own orders.

### 4. Dashboard (`DashboardPage.qml` + `Main.qml`)

Add `canViewFinancials` + `currentStaffId` props. For staff (`!canViewFinancials`):

- Replace the **"Today's sales"** revenue (₹) KPI with **"My sales today"** — a count of completed
  orders where `staffId === currentStaffId` and the date is today.
- Keep the Low-stock and Orders KPIs (operational, non-financial).
- Keep the Active-staff headcount (not financial; not in the restriction list).

For non-staff, the Dashboard is unchanged.

### 5. Profile page (`ProfilePage.qml`)

ProfilePage already reads `AuthStore` directly and gates rows inline (`role !== "staff"`,
`canInviteMembers`). Follow that pattern in-file (no new props):

- **Revenue stat tile** (line ~157–160) → `visible: AuthStore.canViewFinancials`. Hidden for staff.
- **Orders stat tile** (line ~153–156) → for staff, show a count scoped to
  `AuthStore.currentStaffId` (their completed orders) instead of `SalesStore.totalOrders`; caption
  stays "Orders". Non-staff unchanged.
- **Team tile** — kept (headcount, not financial).
- The centered hero `Row` reflows automatically when the Revenue tile is hidden.

## Data flow

```
AuthStore.role ──► canViewFinancials / canViewSuppliers / canViewAllSales / canOpenProductDetail
AuthStore.uid ──► StaffStore.findByAppUid() ──► AuthStore.currentStaffId
        │                                              │
        ▼ (bound as props in Main.qml)                 ▼ (bound as props)
   SalesPage / InventoryPage / OrdersPage / DashboardPage   ProfilePage (reads AuthStore inline)
        │                                              │
        ▼                                              ▼
  view-mode pill, Sold/Orders filtering,        Revenue tile hidden, Orders tile scoped
  supplier-chart hide, detail-dialog block
```

## Edge cases

- **Unlinked staff (`currentStaffId === ""`):** only possible if a staff record has no `appUid`.
  Their own-scoped views (Sold, Orders, "My sales today") would show zero rows — correct
  fail-closed behavior (they see nothing rather than everything). Non-staff always have
  `canViewAllSales === true`, so empty `currentStaffId` never widens visibility.
- **Role change mid-session:** flags are `readonly` bindings on `role`; if `role` updates, every
  gate re-evaluates reactively. No manual refresh needed.
- **Owner/admin/manager:** every new flag is `true` and `currentStaffId` is unused → zero behavior
  change. Verified by the "defaults permissive" prop defaults.
- **Staff defaulting into a financial view:** the `_viewMode` clamp guard prevents a stale value
  from rendering Value/Revenue/Profit.

## Testing

Client QML gating is hard to unit-test headlessly (needs the full App context), so testing is
split:

- **Pure logic (qmltestrunner, per SKILLS.md Skill 27):** if the staff Sold-scoping predicate is
  factored into a pure helper (e.g. extend `BreakdownMath` or a small filter function), add a
  `TestCase` asserting that scoping by `staffId` returns only that staff's rows and that an empty
  `staffId` returns nothing (fail-closed). `findByAppUid` is pure and testable: assert it returns
  the right id for a matching `appUid`, `""` for no match, `""` for empty input.
- **Manual device verification** (the only way to verify the QML visibility wiring): sign in as each
  role and confirm the matrix below.

### Acceptance matrix (manual)

| Surface | staff | manager/admin/owner |
|---|---|---|
| Analysis view modes | Current, Sold (own) only | all 6 |
| Analysis "by supplier" chart | hidden | shown |
| Analysis Sold totals | own sales only | all |
| Inventory product tap → detail | blocked | opens (view; edit if canManage) |
| Inventory FAB/Restock/Edit/Delete | hidden (as today) | per canManageInventory |
| Orders tab list | own orders only | all orders |
| Dashboard top KPI | "My sales today" (count) | "Today's sales" (₹) |
| Profile Revenue tile | hidden | shown |
| Profile Orders tile | own count | tenant total |

## Files touched

- **Modify:** `qml/model/AuthStore.qml` (flags + `currentStaffId`),
  `qml/model/StaffStore.qml` (`findByAppUid`), `qml/Main.qml` (tab visibility + prop bindings),
  `qml/pages/SalesPage.qml` (pill, scoping, supplier-chart, guard),
  `qml/pages/InventoryPage.qml` (`canOpenProductDetail`, tap gate),
  `qml/pages/OrdersPage.qml` (own-orders filter),
  `qml/pages/DashboardPage.qml` (KPI swap), `qml/pages/ProfilePage.qml` (tile gating).
- **Possibly modify:** `qml/pages/AnalysisFilterSheet.qml` (hide supplier/staff rows for staff).
- **Possibly add:** `tests/tst_StaffScope.qml` (pure `findByAppUid` + Sold-scoping predicate tests).

## Build sequence (for the plan)

1. `AuthStore` flags + `StaffStore.findByAppUid` + `AuthStore.currentStaffId` (with a test for the
   resolver). Foundation — no UI change yet.
2. Main.qml: open the Analysis tab to all authenticated users; bind the four props to SalesPage.
3. SalesPage: conditional pill + mode guard + Sold staff-scoping + hide supplier chart + recent-tx
   guard. Verify staff see Current + own-Sold only.
4. InventoryPage: `canOpenProductDetail` gate on the row tap. Verify staff can't open detail.
5. OrdersPage: own-orders filter. Verify staff see only their orders.
6. DashboardPage: "My sales today" KPI swap for staff.
7. ProfilePage: hide Revenue tile, scope Orders tile.
8. AnalysisFilterSheet: hide supplier/staff filter rows for staff.
9. Full manual acceptance-matrix pass across all four roles.
