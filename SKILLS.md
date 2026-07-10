# SKILLS.md

## Overview

This file documents reusable component patterns, signal conventions, and domain-specific knowledge for the **BusinessManagement** App_UI Felgo QML project. Use these skills as reference when building or modifying features.

---

## Skill 1: Using CardKPI

**File**: `qml/helper/CardKPI.qml`  
**Purpose**: Displays a metric card with a gradient background, label, and value.

```qml
CardKPI {
    label: "Total Revenue"
    value: viewHelper.formatCurrency(salesStore.totalRevenue)
    gradient: Gradient {
        GradientStop { position: 0.0; color: Constants.primaryBlue }
        GradientStop { position: 1.0; color: "#1565C0" }
    }
}
```

**Common Properties**:
- `label`: string — displayed above the value
- `value`: string — the main metric value (format with `viewHelper.formatCurrency` or `viewHelper.formatNumber`)
- `gradient`: Gradient — background gradient; use color tokens from `Constants`
- `compact`: bool — set from parent to switch to compact layout

---

## Skill 2: Using StatusBadge

**File**: `qml/helper/StatusBadge.qml`  
**Purpose**: Renders a color-coded pill badge for order/item status.

```qml
StatusBadge {
    status: "Pending"     // "Pending" | "Approved" | "Completed" | "Cancelled"
}
```

**Status → Color Mapping** (defined internally):
- `"Pending"` → amber/orange
- `"Approved"` → blue
- `"Completed"` → green
- `"Cancelled"` → red

---

## Skill 3: Using OrderRow

**File**: `qml/helper/OrderRow.qml`  
**Purpose**: Renders one row in the orders list — responsive between compact and full layout.

```qml
OrderRow {
    order: modelData            // single order object from OrdersStore.orders
    compact: root.width < 520   // responsive mode
    onApprove:  logic.updateOrder(order.id, "Approved")
    onComplete: dataModel.tryCompleteOrder(order.id)
    onEdit:     orderDetailDlg.open(order)
}
```

---

## Skill 4: Using SegmentedNav

**File**: `qml/helper/SegmentedNav.qml`  
**Purpose**: Renders a row of segmented tab buttons — useful for sub-navigation within a page.

```qml
SegmentedNav {
    id: nav
    tabs: ["All", "Pending", "Completed"]
    onTabSelected: function(index) {
        filterIndex = index
    }
}
```

**Properties**:
- `tabs`: `var` (array of strings)
- `currentIndex`: int — bind to local filter state
- Signal `tabSelected(int index)`

---

## Skill 5: Using InlineDatePicker

**File**: `qml/helper/InlineDatePicker.qml`  
**Purpose**: An inline date selection control that works on mobile and desktop.

```qml
InlineDatePicker {
    id: datePicker
    label: "Order Date"
    onDateSelected: function(dateStr) {
        orderDate = dateStr   // ISO string "YYYY-MM-DD"
    }
}
```

---

## Skill 6: Emitting Logic Signals

**Pattern**: Pages and dialogs **never** call store functions directly. All actions go through `Logic.qml` signals. DataModel listens and delegates.

```qml
// CORRECT: emit a Logic signal
logic.addOrder(orderId, customerName, product, qty, total, date, status)

// WRONG: call store directly from a page
OrdersStore.addOrder(...)
```

**Signal call reference**:
```qml
// Orders
logic.addOrder(id, customer, product, qty, total, date, status)
logic.updateOrder(orderId, newStatus)
logic.completeOrder(orderId)
logic.approveAllPending()

// Inventory
logic.addProduct(id, name, category, qty, reorderLevel, unitCost, unitPrice)
logic.restockProduct(productId, qty)

// Sales
logic.recordSale(orderId, productName, qty, revenue, date, customer)

// Staff
logic.addStaff(id, name, role, email, phone, department, startDate, salary, status)

// Lifecycle
logic.loadData()
logic.refreshData()
logic.syncAllStores()
```

---

## Skill 7: Singleton Store Access

All stores are registered as QML singletons via `qml/model/qmldir`. Access them by ID directly — **no import statement needed** when you already import `"../model"` or `"model"`.

```qml
import "../model"

// These IDs are globally available within any file that imports "../model":
OrdersStore.orders          // var (array)
InventoryStore.products     // var (array)
SalesStore.totalRevenue     // real
StaffStore.staff            // var (array)
FirebaseService.get(path, callback)
```

**DataModel is NOT a singleton** — it is instantiated as `id: dataModel` in `Main.qml` and accessed via QML dynamic scoping from child pages.

---

## Skill 8: Accessing DataModel from Pages

`DataModel` is instantiated in `Main.qml` as `id: dataModel`. Pages nested under `NavigationStack → AppPage` can access it via QML dynamic scoping without any import.

```qml
// In any page file:
ListView {
    model: dataModel.ordersModel    // ListModel maintained by DataModel
}

// Trigger cross-store action:
Button {
    onClicked: dataModel.tryCompleteOrder(orderId)
}
```

---

## Skill 9: Accessing ViewHelper from Pages

`ViewHelper` is instantiated in `Main.qml` as `id: viewHelper`. Access directly:

```qml
Text {
    text: viewHelper.formatCurrency(1234.5)    // → "$1,234.50"
    text: viewHelper.formatNumber(9500)         // → "9,500"
}
```

---

## Skill 10: Adding a New Tab/Page

1. Create a new page file: `qml/pages/MyNewPage.qml`
2. Add a `NavigationItem` to `Main.qml`:

```qml
NavigationItem {
    title: "My Tab"
    iconType: IconType.star   // see Felgo IconType for all icons

    NavigationStack {
        AppPage {
            title: "My Tab"
            MyNewPage {}
        }
    }
}
```

3. Add signals to `Logic.qml` if the page introduces new user actions.
4. Add signal handlers in `DataModel.qml` under the `Connections` block.

---

## Skill 11: Adding a New Store

1. Create `qml/model/NewDomainStore.qml`:

```qml
pragma Singleton
import QtQuick

QtObject {
    id: root
    property var items: []

    // Bounded-for-now collection -- auto-pages to exhaustion (Skill 32) so it
    // doesn't hit Firestore's List-Documents response-size truncation once it
    // grows. Full local data, same app behavior as a plain fetch-everything
    // store, just pagination-safe fetch mechanics.
    readonly property int _pageSize: 50
    property bool hasMore: true
    property bool loadingMore: false
    property var _cursor: null

    Component.onCompleted: _resetAndFetch()

    function _resetAndFetch() {
        items = []
        hasMore = true
        _cursor = null
        _fetchFromFirebase()
    }

    function _fetchFromFirebase() {
        if (loadingMore) return
        loadingMore = true
        // orderBy defaults to Firestore's __name__ (always present on every
        // doc) unless you've confirmed some OTHER field is present on
        // literally every existing document -- see Skill 32's gotcha.
        FirebaseService.query("newdomain", { limit: _pageSize, startAfter: _cursor }, function(ok, result) {
            loadingMore = false
            if (!ok || !result) {
                console.warn("[NewDomainStore] Firestore sync failed", FirebaseService.lastStatusCode, FirebaseService.lastError)
                return
            }
            items = items.concat(result.items)
            hasMore = result.hasMore
            _cursor = result.nextCursor
            if (hasMore) _fetchFromFirebase()
        })
    }

    function syncFromFirebase() { _resetAndFetch() }

    function addItem(item) {
        var arr = items.slice()
        arr.push(item)
        items = arr
        // Single-doc PUT -- never rebuild the whole collection into one
        // write (Firestore hard-caps a single :commit at 500 writes; see
        // Skill 12's putMany() for the rare genuinely-multi-doc case).
        FirebaseService.put("newdomain/" + item.id, item, function(ok) {
            if (!ok) console.warn("[NewDomainStore] Firestore write failed for", item.id)
        })
    }
}
```

2. Register in `qml/model/qmldir`:

```
singleton NewDomainStore 1.0 NewDomainStore.qml
```

3. Add signals in `qml/logic/Logic.qml`:

```qml
signal addNewDomainItem(var item)
signal newDomainItemAdded(var item)
```

4. Add handler in `qml/model/DataModel.qml`:

```qml
onAddNewDomainItem: function(item) {
    NewDomainStore.addItem(item)
    logic.newDomainItemAdded(item)
}
```

---

## Skill 12: Firebase REST Pattern

**File**: `qml/model/FirebaseService.qml`
**Base URL**: `databaseUrl` — Firestore v1 REST, `https://firestore.googleapis.com/v1/projects/<project-id>/databases/<databaseId>/documents` (env-aware; see Skill 30 for how `databaseId` is resolved. This is **not** Realtime Database — the app migrated off RTDB before the env-config/P0 work, and callbacks are two-argument `(ok, data)`, not the older single-arg `function(data)` shape.)

```qml
// GET a whole collection (small/bounded collections only -- see query() below
// for anything that can grow past a few hundred docs)
FirebaseService.get("orders", function(ok, arr) {
    if (ok) { /* arr is already a decoded JS array */ }
})

// GET a single document
FirebaseService.get("orders/" + id, function(ok, doc) { ... })

// query() -- cursor-paginated read via Firestore's :runQuery structured-query
// endpoint. See Skill 32 for the full pagination pattern and the __name__
// default-ordering gotcha.
FirebaseService.query("orders", { limit: 50, startAfter: cursor }, function(ok, result) {
    // result = { items, nextCursor, hasMore }
})

// PUT (full overwrite of ONE document -- never a whole collection; see Skill 32's
// write-path note)
FirebaseService.put("orders/" + order.id, order, function(ok) {
    if (!ok) console.warn("save failed", FirebaseService.lastStatusCode, FirebaseService.lastError)
})

// putMany() -- the ONLY sanctioned way to write several docs from one user
// action (e.g. approveAllPending). Chunks into <=500-write commits internally
// -- Firestore hard-caps a single :commit at 500 writes.
FirebaseService.putMany("orders", changedDocsById, function(ok, errorInfo) {
    // errorInfo = { failedAtChunk: n } on failure, so the caller can retry
    // just that slice instead of the whole batch.
})

// PATCH (partial update of one document)
FirebaseService.patch("orders/" + id, { status: "Completed" }, null)

// DELETE
FirebaseService.remove("orders/" + id, null)
```

**`toArray(obj)`**: Normalizes a Firestore-decoded value into a flat JS array (safe to call on an
already-decoded array too — it's a no-op passthrough in that case).

---

## Skill 13: Responsive Layout Pattern

Pages use a `compact` property bound to page width:

```qml
AppPage {
    id: root
    property bool compact: width < Constants.compactBreakpoint  // 520

    // Compact column layout vs. full row layout:
    Flow {
        width: parent.width
        spacing: compact ? 8 : 16

        CardKPI {
            width: compact ? root.width : (root.width - 48) / 4
        }
    }
}
```

---

## Skill 14: PlaceholderPage

**File**: `qml/helper/PlaceholderPage.qml`  
**Purpose**: Shows a label and an icon for pages under construction.

```qml
PlaceholderPage {
    title: "Reports"
    message: "Coming soon"
    iconType: IconType.piechart
}
```

---

## Skill 15: Constants Color Tokens

All color values live in `Constants.qml` (singleton). Use these in components instead of hardcoded hex values:

| Token | Purpose |
|---|---|
| `Constants.primaryBlue` | Primary brand blue |
| `Constants.ordersTab` | Orders tab accent |
| `Constants.inventoryTab` | Inventory tab accent |
| `Constants.salesTab` | Sales tab accent |
| `Constants.staffTab` | Staff tab accent |
| `Constants.pageBg` | Page/scaffold background |
| `Constants.cardBg` | Card background |
| `Constants.borderColor` | Border and divider |
| `Constants.compactBreakpoint` | `520` — responsive breakpoint |
| `Constants.firebaseDatabaseUrl` | Firebase DB root URL |

---

## Skill 16: Auth & Session (AuthStore / AuthService)

**Files**: `qml/model/AuthStore.qml`, `qml/model/AuthService.qml`  
**Both are `pragma Singleton`** — access by name anywhere.

### Reading session state

```qml
AuthStore.isAuthenticated    // bool
AuthStore.uid                // string — Firebase UID
AuthStore.email              // string
AuthStore.displayName        // string
AuthStore.role               // "owner" | "admin" | "manager" | "staff"
AuthStore.tenantId           // string
AuthStore.tenantName         // string
```

### RBAC permission flags (all `readonly bool`)

```qml
AuthStore.canManageInventory  // owner | admin
AuthStore.canManageStaff      // owner | admin
AuthStore.canDeleteOrders     // owner | admin | manager
AuthStore.canApproveAll       // owner | admin | manager
AuthStore.canViewSales        // owner | admin | manager
AuthStore.canViewStaff        // owner | admin | manager
AuthStore.canInviteMembers    // owner | admin
```

### Triggering auth actions

Auth actions are triggered via `logic` signals handled by DataModel, which delegates to AuthService:

```qml
logic.signInWithEmail(email, password)
logic.signUpWithEmail(email, password, displayName)
logic.signInWithGoogleToken(googleIdToken)
logic.signOutRequested()
logic.inviteMember(uid, email, displayName, role)
```

### Listening to auth feedback signals (in Main.qml Connections)

```qml
Connections {
    target: logic
    function onAuthLoginSucceeded()  { /* navigate */ }
    function onAuthFailed(reason)    { authErrorMessage = reason }
    function onAuthSignedOut()       { /* clear UI */ }
}
```

### Gating UI by role

```qml
// Tab visibility
NavigationItem {
    visible: AuthStore.canViewSales
    ...
}

// Button visibility
Button {
    visible: AuthStore.canManageInventory
    onClicked: logic.addProduct(...)
}
```

---

## Skill 17: RBAC-Gated Pages — Property Pattern

Each page that has role-restricted actions exposes `canManage*` boolean properties. The parent (`Main.qml`) binds `AuthStore` flags to them.

```qml
// In the page file:
Item {
    property bool canManageInventory: false  // default off
    property bool canDeleteOrders: false
    signal deleteOrderClicked(string orderId)
    ...
    Button {
        visible: canDeleteOrders
        onClicked: deleteOrderClicked(model.orderId)
    }
}

// In Main.qml:
InventoryPage {
    canManageInventory: AuthStore.canManageInventory
    onDeleteProductClicked: function(pid) { logic.deleteProduct(pid) }
}
```

This keeps pages dumb (no direct AuthStore import) and makes permissions testable.

---

## Skill 18: Delete Operations Pattern

The delete flow for any domain follows:

1. **Logic signal** → `logic.deleteOrder(orderId)` / `logic.deleteProduct(productId)` / `logic.deleteStaff(staffId)`
2. **DataModel handler** → validates RBAC role, calls store `deleteX()`, emits feedback signal
3. **Store function** → filters the array, calls `_commit()` (which pushes the single changed/
   removed doc — see Skill 32's write-path note; never a whole-collection `_pushAllToFirebase()`,
   that pattern was a confirmed bug, removed)
4. **UI** → reactive `model` or `Repeater` binding auto-refreshes

```qml
// Store pattern (OrdersStore example):
function deleteOrder(orderId) {
    var arr = _clone()
    for (var i = 0; i < arr.length; ++i) {
        if (arr[i].orderId === orderId) { arr.splice(i, 1); break }
    }
    _commit(arr)
}

// DataModel (RBAC guard + delegation):
function onDeleteOrder(orderId) {
    if (!_hasAnyRole(["owner", "admin", "manager"])) {
        logic.errorOccurred("auth", "Permission denied")
        return
    }
    OrdersStore.deleteOrder(orderId)
    _syncOrdersModel()
    logic.orderDeleted(orderId)
}
```

---

## Skill 19: Profile Settings

**File**: `qml/pages/ProfileSettingsDialog.qml`  
**Purpose**: View/edit the current user's contact details. Reaches `AuthService.updateUserProfile()`.

```qml
ProfileSettingsDialog {
    id: profileDlg
    onProfileSaved: {
        successMessage = "Profile updated"
        successToastTimer.restart()
    }
}

// Open from anywhere:
Button { onClicked: profileDlg.open() }
```

The dialog auto-populates from `AuthStore` on `onOpened`, and writes back via `AuthService.updateUserProfile(phone, address, city, country, postalCode)`.

---

## Skill 20: Connections in Singletons (Critical Constraint)

**`Connections {}` cannot be used inside a `pragma Singleton` `QtObject` root.** This causes a runtime `Cannot assign to non-existent default property` error, which crashes the entire singleton chain.

**WRONG (crashes)**:
```qml
// SalesStore.qml
pragma Singleton
QtObject {
    Connections {   // ← INVALID in QtObject
        target: OrdersStore
        function onRevisionChanged() { _rebuildData() }
    }
}
```

**CORRECT (property binding watcher)**:
```qml
pragma Singleton
QtObject {
    property int _ordersWatcher: OrdersStore.revision
    on_OrdersWatcherChanged: _rebuildData()
}
```

`Timer {}`, `Rectangle {}`, and other visual/non-visual Item types also cannot be used as children of `QtObject`. Only other `QtObject`-derived non-visual types and plain property/signal/function declarations are valid.

---

## Skill 21: India Compliance — Two-Tier Data Model

**Design**: `docs/superpowers/specs/2026-06-06-india-compliance-roadmap-design.md`
**Agent**: Compliance & Audit Agent (`AGENTS.md` §8)

The app is legally part of customers' "books of account" under Indian law. Compliance data is split
into two tiers — get this wrong and you break MCA Rule 11(g) / CGST 56(8).

| Tier | Collections | Who writes | Client rules |
|---|---|---|---|
| **Ledger (immutable)** | `audit_log`, `transactions`, `stock_batches`, `stock_movements` | **Only** the Cloud Functions gateway (Admin SDK) | `allow read: if isMember; allow write: if false` |
| **Working (mutable)** | `inventory`, `orders`, `staff`, `suppliers` | Client via gateway | read/write per RBAC |

**Rule**: a page/store **never** writes the ledger tier directly. It calls the gateway, which writes
the working doc **and** appends the ledger entry atomically.

```js
// CORRECT — route the mutation through the gateway (P0 onward)
Gateway.recordMutation("inventory", productId, "update", beforeSnapshot, afterSnapshot)

// WRONG — direct client write to a ledger collection (rules reject it; breaks immutability)
FirebaseService.put("audit_log/" + id, entry, null)
```

`TransactionStore` and `StockBatchStore` are **read models** over the ledger — read from them freely,
but they no longer own writes once P0 lands.

---

## Skill 22: Audit Log Entry Shape

Every books-of-account mutation appends one append-only `audit_log` doc. Never edit or delete one.

```js
{
  entryId, tenantId,
  actorUid, actorRole,            // derived SERVER-side from the verified token — never client-supplied
  action: "create" | "update" | "delete",
  entity: "inventory" | "order" | "staff" | "supplier"
        | "stock_movement" | "consent" | "tos_accept",
  entityId,
  before: {…} | null,             // full V(n-1)
  after:  {…} | null,             // full V(n)
  serverTimestamp,                // NTP-backed, set in the Cloud Function — AUTHORITATIVE
  clientTimestamp,                // forensic compare only
  requestId                       // idempotency
}
```

**Invariants**: no `enable_audit_trail` flag anywhere; `serverTimestamp` wins over `clientTimestamp`;
relabels (e.g. supplier rename) propagate by stable id (`SupplierStore.updateSupplier`), never by
editing historical rows. Note: `TransactionStore.renameParty()` violated this and is **removed in
P0** (dead code, zero callers).

---

## Skill 23: Stock-Movement Taxonomy (CGST 56(2))

Non-sales stock changes need distinct immutable tags — a bare decrement is non-compliant. Use the
`stock_movements` ledger with this `kind` enum:

```
receipt | sale | loss | theft | destroyed | write_off | free_sample | gift | adjustment
```

Each row: `{ id, productId, kind, qty, reason, valueAtCost, batchRef?, serverTimestamp, actorUid }`.
The opening-balance / receipts / supplies / closing-balance register is a **derived read model**
over these rows.

---

## Skill 24: Tax-Identity Fields (HSN / GSTIN)

- **Product `hsnCode`** — string, validated as **4, 6, or 8 digits** (variable-length per turnover
  tier). Empty is allowed for sub-₹1.5cr merchants — validate format only when non-empty.
- **`gstin`** on supplier / order-customer / tenant — 15-char GSTIN with checksum validation.

These are **client-only** (P2) — no gateway needed — so they can ship in parallel with the P0
backend work. Add the field to the store's `_clone()` / normalizer and the relevant dialog
(`AddProductDialog`, `EditProductDialog`, supplier/tenant forms).

---

## Skill 25: Analysis Page — view modes & breakdown charts

**File**: `qml/pages/SalesPage.qml` (the "Analysis" page) + `qml/components/BreakdownBarCard.qml`

The Analysis page has six view modes selected by a `SegmentedPill`:

```
_MODE_VALUE=0  _MODE_PURCHASED=1  _MODE_CURRENT=2  _MODE_REVENUE=3  _MODE_SOLD=4  _MODE_PROFIT=5
```

Each view renders three charts, all via the shared `BreakdownBarCard`:
1. **Main breakdown** (`_breakdown`) — time series (Revenue/Sold/Purchased), top-N (Value/Profit), or stock-health (Current).
2. **By category** (`_breakdownByCategory`).
3. **By supplier** (`_breakdownBySupplier`).

`_rebuildBreakdown()` recomputes all three on any period/view/filter/store-revision change. For
Value/Current the category & supplier maps come from existing `InventoryStore` aggregators
(`valueByCategory`, etc.). For **Profit and Revenue** they come from the event-log aggregator
`InventoryStore.realisedProfitByDimension(field, scope)` / `realisedTotals(scope)` /
`realisedBucketWalk(...)` — one source of truth, scope-aware so the sections honour the active filters
(Skill 29). For Sold/Purchased (unit metrics) they come from `_breakdownByDimension(metric, dim,
ignorePeriod)` → `BreakdownMath.breakdown(...)` (Skill 26). The money metrics inside
`_breakdownByDimension` (revenue/tax/discount) also route through `realisedProfitByDimension`.

**Reconciliation invariant:** the *category* breakdown always sums to the hero `_periodTotal` under
the same filters. The *supplier* breakdown can undercount for pre-FIFO / unresolved-inventory sales
(no supplier lineage) — surfaced via the card's "No supplier data for this period" empty-state.
Category is the safe reconciling axis.

### Using BreakdownBarCard

```qml
import "../components"

BreakdownBarCard {
    title: root._breakdownTitles().category   // per-view title
    model: root._breakdownByCategory          // [{ label, value, fullLabel }]
    currency: root._isCurrency                // ₹ prefix on axis + tips
    barTop: Constants.brand3
    barBottom: Constants.brand2
    chartHeight: dp(180)        // default
    showValueTips: false        // per-bar value caption
    emptyText: ""               // centered message when model is empty
}
```

Pure presentation — it computes its own max and renders gradient bars + a y-axis (max / max÷2 / 0).
It is a plain component (no qmldir entry); `import "../components"` makes it available.

---

## Skill 26: BreakdownMath.js — pure analytics grouping

**File**: `qml/helper/BreakdownMath.js` (`.pragma library` — stateless, no QML/singleton deps)

Groups a metric by a dimension into a `{ key -> number }` map. All inputs are injected, which is
what makes it unit-testable headlessly (Skill 27).

```qml
import "../helper/BreakdownMath.js" as BreakdownMath

var win = BreakdownMath.intersect(
            BreakdownMath.periodWindow(_period, new Date()),  // period [from,to)
            _dateWindow())                                    // date-filter [from,to) or null
var byCat = BreakdownMath.breakdown({
    metric: "revenue",          // "revenue" | "sold" | "purchased"
    dim: "category",            // "category" | "supplier"
    orders: OrdersStore.orders, // revenue source
    entries: TransactionStore.entries, // sold/purchased source
    window: win,                // null = unbounded
    channel: "", staffId: "", category: "", supplierId: "",  // "" = no filter
    productCategory: { productId: category, ... },   // lookup maps (injected)
    supplierName:    { supplierId: name, ... }
})
```

- `periodWindow(idx, now)` — Day(0, today) / Week(1, Mon–Sun) / Month(2) / Year(3) → `{from,to}`.
- `intersect(a, b)` — `[from,to)` intersection; `null` = unbounded; both `null` → `null`.
- Category keys fall back to `"(uncategorised)"`; supplier keys: `""` → `"Unknown"`, unknown id → `"(removed)"`.

On the page, wrap the result with `_topNFromMap(map, 8)` to get chart-ready `[{label, value, fullLabel}]`.
The page method `_breakdownByDimension(metric, dim, ignorePeriod)` builds the opts bundle from live
filter state; pass `ignorePeriod=true` for the export (filter-scoped totals, not single-period).

---

## Skill 27: QML unit tests (qmltestrunner)

**Files**: `tests/tst_*.qml` (e.g. `tests/tst_BreakdownMath.qml`)

Test **pure logic** — the `.pragma library` JS helpers. Page-level QML can't load headlessly (needs
the full Felgo `App` context), so keep testable math in a pure library and test that.

```qml
import QtQuick
import QtTest
import "../qml/helper/BreakdownMath.js" as BM

TestCase {
    name: "BreakdownMath"
    function test_revenue_category_sum_equals_supplier_sum() {
        var byCat = BM.breakdown({ metric:"revenue", dim:"category", /* ...fixtures... */ })
        var bySup = BM.breakdown({ metric:"revenue", dim:"supplier", /* ...fixtures... */ })
        compare(_sum(byCat), _sum(bySup))   // reconciliation invariant
    }
}
```

Run headlessly (set the two `QT_*` vars — the runner is silent without them on this box):

```bash
QT_FORCE_STDERR_LOGGING=1 QT_LOGGING_TO_CONSOLE=1 \
  PATH="/c/Felgo/Felgo/mingw_64/bin:$PATH" \
  "C:/Felgo/Felgo/mingw_64/bin/qmltestrunner.exe" -platform offscreen -input tests/tst_BreakdownMath.qml
```

`tests/` lives OUTSIDE `qml/` so it is not packaged into the app, and there is no CMake test target —
the runner executes the `.qml` directly. `Object.assign` is available in the engine (Qt 6.8).

---

## Skill 28: Order adjustments, KPI derivation & multi-sheet export

**Files**: `qml/helper/OrderMath.js`, `qml/model/DataModel.qml`, `qml/model/SalesStore.qml`,
`qml/model/InventoryStore.qml`, `qml/pages/SalesPage.qml`, `src/XlsxService.cpp`,
`qml/model/OrderChannelStore.qml`, `qml/model/CategoryStore.qml`

Lessons baked in after the device-bug pass — follow these to avoid re-introducing fixed defects:

- **Revenue = net, everywhere.** Subtotal − discount, **tax excluded**. `SalesStore` KPIs
  (`totalRevenue`/`totalOrders`/`activeCustomers`) are **derived** from `OrdersStore` via
  `_rebuildDerivedData` (sum `OrderMath.allocate(o).totals.net` over completed orders) — never an
  independently-persisted running tally. Currency formatters use `maximumFractionDigits: 1` so a
  fractional discount (₹4.5) reconciles with the total instead of rounding to ₹5.

- **Reopening a completed order must reverse it.** `DataModel.onUpdateOrder` calls
  `_reverseCompletedOrder` (restore batches + product.stock, append a negating `return` event,
  reason `"reopened"`) BEFORE persisting and clears `consumption[]`. Reversal reads lineage, so it
  must run before any updateOrder that strips it. Re-completing is then a clean fresh deduction.

- **`price_adjust` event spreading.** An order-wide discount edit has `productId:""`; a per-line
  modify has a real productId but empty `consumption[]`. For the supplier/category/product axes use
  `OrderMath.spreadOrderDelta(order, total, dim, categoryOf)` (order-wide) and
  `OrderMath.spreadLineDeltaBySupplier(order, productId, total)` (per-line) so the delta nets across
  REAL keys, not a bogus "(unspecified)"/"Unknown" row. `dim` accepts `"supplier"` AND `"supplierId"`
  (callers pass the field name — a mismatch silently falls through to the product branch).

- **Added units on a completed-order adjust** are booked as a SEPARATE sale event carrying the
  product's CURRENT tax (`taxable`/`taxPercent` from inventory); the original completion event is
  immutable. A single order line stores one tax rate, so a mixed-rate line is correct in the event
  ledger/reports but the order-line summary shows the original rate (known display limitation).

- **Multi-sheet Analysis export.** `XlsxService.writeAnalysisWorkbook(sheets, name)` writes ONE
  workbook with one sheet per report view; `SalesPage.buildAnalysisWorkbook()` builds the payload by
  briefly switching `_viewMode`/`_profitMode` and reusing `buildAnalysisExport()` per view. Sheet
  names are sanitized + de-duped server-side (≤31 chars, no `:\/?*[]`).

- **Config stores** (`OrderChannelStore`, `CategoryStore`) persist to Firestore under
  `config/{orderChannels|categories}` (tenant-scoped) AND cache to QSettings, with exactly one pinned
  default (`setDefault`; `setLastUsed` is a back-compat alias). Re-synced on `onTenantContextReady`.
  Picker dropdowns bind `model:` directly — never reassign `.model` imperatively (freezes the binding).

- **`ActivityLog`** is Firestore-backed (`activity_log`, tenant-scoped) and re-syncs on login so
  non-order activity survives sign-out; `clear()` stays an in-memory-only sign-out wipe.

- **Desktop file import.** The Felgo desktop picker returns a malformed 2-slash `file://C:/…` URL;
  `ImportPreviewDialog._toFileUrl` normalizes any `file:` URL to a valid `file:///C:/…`. Only
  `content://` (Android) is routed through `NativeFile.toReadablePath` — a desktop path through its
  QUrl round-trip mangles the drive letter.

---

## Skill 29: RealisedMath.js — one source of truth for realised money

**File**: `qml/helper/RealisedMath.js` (`.pragma library`, `.import`s `OrderMath.js`). The single home
for REALISED money aggregation over the immutable transaction event log. Pure, headless-testable
(`tests/tst_RealisedMath.qml`).

**The rule it enforces (SITE 5):** the Analysis Revenue hero, the export Totals block, the Revenue
period bins, and every realised by-dimension section all aggregate the **immutable event log** — NEVER
the live order via `OrderMath.allocate`. The live order is mutated by returns/discount edits
(`OrdersStore.applyAdjustment` rewrites `o.products`), so allocating it double-counts. Reading the
ledger (sale + return + price_adjust rows) nets adjusted orders correctly, so Revenue and Profit views
reconcile to the same number.

```qml
import "../helper/RealisedMath.js" as RealisedMath
// scope mirrors _passesCrossFilters: { window:{from,to}|null, channel, staffId, category, supplierId }
var rows = RealisedMath.byDimension("supplierId", entries, scope, lookups) // {key->{revenue,cogs,profit,tax,discount,margin}}
var t    = RealisedMath.totals(entries, scope, lookups)                    // {gross,discount,net,tax,cogs,profit}
var bins = RealisedMath.bucketWalk("net", periodIdx, entries, scope, now, lookups) // "net" | "profit"
var named = RealisedMath.nameMerge(rows, function(id){return nameOf(id)}, "Unknown")
```

- **Invariant (locked):** for any scope, `Σ byDimension(any field) == totals == Σ bucketWalk`. New
  tests must assert it. The `tst_RealisedMath` reconciliation cases exist for exactly this.
- **Stamped-only / fail-closed (SITE 4):** reads `e.net/e.tax/e.discountShare`; a missing `net`
  contributes **0**, never re-allocates the live order.
- **Cent-exact splits (C/D):** multi-batch FIFO uses remainder-to-largest; `gross = round(net+disc)`
  once.
- **price_adjust under a supplier filter** is excluded from BOTH `totals` and `bucketWalk` (no clean
  supplier lineage) so the invariant holds; with no supplier filter it's spread via
  `OrderMath.spreadOrderDelta`/`spreadLineDeltaBySupplier` (SITES 2/3).
- **On the page:** `InventoryStore.realisedProfitByDimension(field, opts)` / `realisedTotals(opts)` /
  `realisedBucketWalk(metric, period, opts)` are thin adapters that inject `entries` + lookups. Build
  `opts` from `SalesPage._realisedScope(periodScoped)` — `true` intersects the selected period (the
  on-screen hero/chart), `false` is the whole filter window (the export sections). `opts` is OPTIONAL
  everywhere; omitting it sums the whole ledger (legacy behaviour).
- **Other extractions:** `OrderMath.refundPerUnit(saleEvent)` (refund returned units at the
  original-sale rate, SITE 6) and `ImportMath.renameSku(sku, addedCount)` (import rename suffix, E).

**Coverage ceiling:** `SalesPage.qml` and the C++ `XlsxService` still can't load under `qmltestrunner`.
The pure libs are fully tested; the page WIRING (which map feeds which `BreakdownBarCard`) and the
xlsx column-writer stay verified by the manual export→unzip→decode→reconcile procedure.

---

## Skill 30: Build-time environments (dev / test / prd)

**Files**: `qml/helper/EnvConfig.js` (`.pragma library`), `qml/model/FirebaseService.qml`,
`CMakeLists.txt`, `main.cpp`, `tests/tst_EnvConfig.qml`

The app talks to an isolated Firestore database per environment, selected at **build time** —
no runtime switcher. Each env is a **named Firestore database in the one project**
(`inventorymanager-48392`, region `asia-south1`, confirmed via `gcloud firestore databases
list` — corrected 2026-07-10 from an earlier wrong `asia-southeast1` assumption); Auth,
Storage, and Cloud Functions are **shared**, and Cloud Functions now target `asia-south1` too
for regional consistency.

**Resolution chain (single source of truth):**

```
PRODUCT_STAGE (CMakeLists.txt)
  → PRODUCT_STAGE_DEF  (target_compile_definitions)
  → APP_STAGE          (engine.rootContext()->setContextProperty in main.cpp)
  → EnvConfig.envForStage(APP_STAGE)  → "prd" | "test" | "dev"
  → EnvConfig.databaseIdForEnv(env)   → "(default)" | "test" | "dev1"
  → FirebaseService.databaseId / .databaseUrl   (every REST call builds off this)
```

| `PRODUCT_STAGE` | env  | database    |
|-----------------|------|-------------|
| `dev`           | dev  | `dev1`      |
| `test`          | test | `test`      |
| `publish`       | prd  | `(default)` |

Note the **env name** (`dev`) and the **Firestore database id** (`dev1`) differ — Firestore
database ids must be >=4 characters, so the 3-char `dev` is invalid and the actual database is
named `dev1`. `databaseIdForEnv` is the only place this divergence lives; never assume env name
== database id.

```qml
// FirebaseService.qml — env resolved once; all get/put/patch/remove switch here.
readonly property string environment: EnvConfig.envForStage(
    (typeof APP_STAGE !== "undefined" && APP_STAGE) ? APP_STAGE : "")
readonly property string databaseId: EnvConfig.databaseIdForEnv(environment)
```

- **Fail-safe = prd:** unknown/empty stage → `envForStage` returns `"prd"` → `(default)` db, so a
  misconfigured/unflagged build never silently hits an empty dev database.
- **Never hard-code `databases/(default)`** anywhere — it bypasses routing. The only acceptable
  `(default)` literal is the `databaseIdForEnv` ternary in `EnvConfig.js`.
- **Pure + headless-tested:** `EnvConfig.js` has no QML deps; `tests/tst_EnvConfig.qml` asserts the
  stage→env→databaseId mapping incl. the fail-safe.
- **Env badge:** `ProfileSettingsDialog` shows a `DEV`/`TEST` pill bound to
  `FirebaseService.environment`, hidden on `prd`.
- **Cloud Functions are env-aware too (done):** all 4 functions (`recordMutation`, `provisionMember`,
  `runCutover`, `computeAnalysis`) resolve their Firestore database **per request** via
  `scopedDb(env)` in `functions/index.js`, mirroring this exact resolution chain (fail-safe to prd
  on unknown/missing `env`). The client sends `env: FirebaseService.environment` in every request
  body — `Gateway.qml` injects it for its 3 endpoints, `AnalysisService.qml` for `computeAnalysis`.
  See Skill 33 for the Cloud Functions side of this pattern.

---

## Skill 31: New Order editable price + Analysis swipe navigation

Two small page interactions added alongside the env work:

- **Editable per-line price in `NewOrderDialog`** — mirrors the `OrderDetailDialog` price field
  (blur/accept commit, plain number while focused, formatted currency otherwise). The helper
  `_setLinePrice(idx, value)` does an immutable `selectedProducts` replace (same shape as
  `_setLineDiscount`), so `_totalsCache` and the `orderCreated` payload pick up the new price with
  no signal/store change. Rejects empty/NaN/negative by keeping the old price.
- **Swipe between Analysis views** — `SalesPage._stepViewMode(dir)` (`dir = -1` swipe-left/prev,
  `+1` swipe-right/next) steps within `_allowedViewModes()` (staff: Current↔Sold; others: all six)
  and clamps at both ends (no wrap). Driven by a `DragHandler { yAxis.enabled: false }` over the
  `AppScrollView` so vertical scroll and control taps pass through; horizontal threshold `dp(60)`.
  Touch-gesture behaviour differs Android vs desktop — device-verify (see the
  `scrollview_touch_freedrag` note).

---

## Skill 32: Paginated reads — `FirebaseService.query()` + `PagingHelper.js`

**Files**: `qml/model/FirebaseService.qml` (`query()`), `qml/helper/PagingHelper.js`,
`tests/tst_PagingHelper.qml`

A plain `FirebaseService.get("collection", ...)` fetches the whole collection in one request.
Firestore's List-Documents endpoint paginates **internally** once a collection crosses an internal
response-size threshold, and `get()` follows `nextPageToken` to still return everything — but for a
collection that's genuinely growing (not just occasionally large), fetching it all in one shot on
every launch doesn't scale. `query()` fetches bounded pages instead:

```qml
FirebaseService.query("inventory", { limit: 50, startAfter: cursor }, function(ok, result) {
    // result = { items, nextCursor, hasMore }
    if (!ok || !result) { /* handle failure, keep already-loaded items on screen */ return }
    items = items.concat(result.items)
    hasMore = result.hasMore
    cursor = result.nextCursor
    if (hasMore) /* auto-page-to-exhaustion, or wait for explicit loadMore() */
})
```

**`opts`**: `{ orderBy, direction ("ASCENDING"|"DESCENDING", default ASCENDING), limit (default 50),
startAfter (opaque cursor from a previous page, omit for the first page) }`.

**The `orderBy` default-field gotcha (important, easy to get wrong):** `query()` defaults to
ordering by Firestore's `__name__` (the document's resource name — always present on every
document, immune to schema drift) when `opts.orderBy` is omitted. **Don't order by an app-level
timestamp/date field unless you've confirmed it's present on literally every existing document.**
Firestore's `orderBy` silently **excludes** documents missing the ordered field from query results
— ordering by a sometimes-missing field reintroduces a truncation-shaped bug, just via a different
mechanism than the original unpaginated-`get()` bug. **The tell:** a defensive `field || ""` /
`field || fallback` fallback already present in a store's existing normalization code is strong
evidence some documents lack that field. This was caught for `SupplierStore.createdAt`,
`OrdersStore.date`, `TransactionStore.timestamp`, and `StockBatchStore.receivedDate` — all four
default to `__name__` instead of the "obvious" timestamp field.

**Auto-page-to-exhaustion vs. explicit `loadMore()`:** all six existing stores
(`InventoryStore`/`StaffStore`/`SupplierStore`/`OrdersStore`/`TransactionStore`/`StockBatchStore`)
currently auto-page to exhaustion — full local data, same app behavior as a plain fetch-everything
store, just pagination-safe fetch mechanics (see `docs/superpowers/specs/
2026-07-06-scale-reads-writes-analytics-design.md` §3.1 for why: several of these stores are read
directly by correctness-critical logic — FIFO consumption, Dashboard KPIs, import dedup, the live
Analysis page — that assumes the complete local set today; a "recent window" would silently
miscompute those, not just under-display a list). A genuine windowed/on-demand-`loadMore()` UI is
possible for any of these but isn't built yet — that's deferred, unscheduled future work (same spec,
§9 Phase 3).

**`PagingHelper.js`** (`.pragma library`, pure, no QML deps — same convention as `BreakdownMath.js`):
`mergePage(existingItems, newItems, limit) -> {items, hasMore}` and `cursorFrom(items, orderByField)
-> value|null`. `query()` uses these internally (over-fetches `limit+1` and trims, so `hasMore` is
exact at the page boundary — never guessed from "got a full page back").

**Write side — the matching gotcha:** pagination fixes the READ side. The equivalent write-side
bug (a store rebuilding its *entire* collection into one bulk `:commit` on every single-record
change) is a different, separately-fixed problem — see Skill 12's `putMany()` and the same design
spec's §2.2 audit. Don't assume a store using `query()` correctly also means its writes are safe;
check both independently.

---

## Skill 33: Cloud Functions env-awareness — `scopedDb(env)`

**File**: `functions/index.js`

Every Cloud Function (`recordMutation`, `provisionMember`, `runCutover`, `computeAnalysis`) resolves
its Firestore database **per request**, not from a module-level global:

```js
const DATABASE_ID_FOR_ENV = { dev: "dev1", test: "test", prd: "(default)" };

function scopedDb(env) {
    const databaseId = DATABASE_ID_FOR_ENV[env] || DATABASE_ID_FOR_ENV.prd;  // fail-safe to prd
    return getFirestore(admin.app(), databaseId);
}

exports.someFunction = functions.onRequest({ region: "asia-south1", cors: true }, async (req, res) => {
    const body = req.body || {};
    const db = scopedDb(body.env);              // <-- parse body FIRST, before anything needing db
    const ctx = await deriveContext(db, decoded.uid);  // deriveContext takes db explicitly
    // ...
});
```

**Why this exists:** a Cloud Functions deployment is shared across dev/test/prd (Skill 30 — Auth,
Storage, and Cloud Functions are shared; only the Firestore database differs per env), so a Cloud
Function has no way to know which database to use except being told. Before this, `admin.firestore()`
was called once at module load with no `databaseId`, meaning every Cloud Function always read/wrote
the `(default)` (prd) database regardless of which env the calling client was built for — confirmed
in the actual deployed code, not hypothetical.

**Client side:** every request body includes `env: FirebaseService.environment`. `Gateway.qml`
injects it into all 3 of its outgoing bodies (`_send`/`recordMutation`, `runCutover`,
`provisionMember`) in one place, so no caller (a store, `AuthService.qml`) needs to remember to add
it. `AnalysisService.qml` does the same for `computeAnalysis`.

**Constrained enum, not a free-form string:** `scopedDb` maps exactly 3 known values, never trusts an
arbitrary client-supplied database id — a malformed/malicious `env` value just falls back to prd via
`DATABASE_ID_FOR_ENV[env] || DATABASE_ID_FOR_ENV.prd`, same fail-safe philosophy as `EnvConfig.js`'s
`envForStage`.

**`deleteCollection(db, path)` and `deriveContext(db, uid)`** both take `db` as an explicit first
parameter (not a closure over a shared global) for the same reason — whichever database a given
request is scoped to must flow through consistently to every read/write that request makes.

---

## Skill 34: `computeAnalysis` — ported math + shared-fixture parity

**Files**: `functions/index.js` (`computeAnalysis` export), `functions/lib/{orderMath,realisedMath,
breakdownMath}.js`, `functions/test/{realisedMath,breakdownMath}.test.js`,
`functions/test/fixtures/*.js`, paired QML tests `tests/tst_{RealisedMath,BreakdownMath}
ParityFixtures.qml`

`computeAnalysis` runs Revenue/Profit/Sold/Purchased aggregation server-side instead of requiring the
full transaction ledger resident in QML. It reuses the **same math** as the client — but "reuses"
means *ported*, not literally shared: `qml/helper/{OrderMath,RealisedMath,BreakdownMath}.js` use
QML's `.pragma library` + `.import`, which aren't valid Node/CommonJS syntax. The Node versions in
`functions/lib/` have byte-identical function bodies, only the module boilerplate differs
(`require`/`module.exports` instead of `.pragma library`/`.import`).

**Parity is proven by shared fixtures, not file identity.** Since there are now two copies of the
same logic, drift between them is the risk. `functions/test/fixtures/*.js` holds scenario data
lifted directly from already-verified cases in `tests/tst_RealisedMath.qml`/`tst_BreakdownMath.qml`
(not invented fresh) — run against the Node port via `functions/test/*.test.js` (`node:test`, `cd
functions && npm test`), **and** manually mirrored (same literal data, not loaded from a shared
file — QML has no established pattern in this repo for reading an external JSON file synchronously
in a test) into paired QML test files that assert the same expected values against the QML
original. **If you change a scenario in one fixture file, change it in its pair too** — the paired
files say so in their header comments.

**Request contract** (see `docs/superpowers/specs/2026-07-06-scale-reads-writes-analytics-design.md`
§6.5 for the full spec): `{ env, period, viewMode, dims, scope, periodScoped }` →
`{ totals, byDimension, bucketWalk }`. `env` per Skill 33. Reads the tenant's `transactions`/
`orders`/`inventory`/`suppliers` via a Firestore-`orderBy(__name__)`-paginated internal loop
(`readAllPaged`, ≤500 docs/page — never one unbounded query), then runs the ported math.

**Honest scope note (also in the code):** reads are paginated, but the result is still one
in-memory array by the time `RealisedMath`/`BreakdownMath` run — those functions take a full
`entries` array, same contract as the QML originals; no streaming/incremental rewrite was
attempted. This still fixes the actual failure mode (an unbounded read tripping Firestore's
response-size limits) and moves the memory burden from a phone to a Cloud Function with far more
headroom. A true streaming version is a possible future refinement, not required for this to be
useful today.

**Not yet wired into `SalesPage.qml`.** `AnalysisService.qml` (the client for this endpoint) exists
and works, but `InventoryStore.realisedProfitByDimension`/`realisedTotals`/`realisedBucketWalk` are
still local synchronous `RealisedMath`/`BreakdownMath` calls — cutting `SalesPage.qml` over is **not**
a thin passthrough (those three functions are called synchronously at 15+ sites; `AnalysisService.
compute` is necessarily async), and is deferred as its own separate, undesigned future project. See
the design spec §9.1 before assuming this is a quick swap.

