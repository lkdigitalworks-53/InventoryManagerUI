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

**Current status (updated 2026-07-29):** all working-tier stores call the gateway, and
`Gateway.mode` now defaults to `"gateway"` (flipped 2026-07-29, `649046d`) — Cloud Functions +
the locked Firestore rules are deployed and confirmed working. `audit_log` entries are now
actually being written for every `recordMutation`/`recordMutations` call. Whether `runCutover`
(the one-time ledger wipe / stock zero-out) was also run as part of this rollout was not
independently confirmed this session — verify before assuming historical ledger data was reset.
See AGENTS.md §8's "P0 implementation status" for the full picture.

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

---

## Skill 35: Testable Cloud Functions — `lib/` extraction + dependency injection

**Files**: `functions/lib/{gatewayLogic,cutoverLogic,batchMutationLogic}.js`,
`functions/test/{gatewayLogic,cutoverLogic,batchMutationLogic}.test.js`

`functions/index.js`'s exported handlers (`recordMutation`, `runCutover`, `recordMutationsBatch`)
are thin: parse the request, verify the token, call into a `lib/*.js` function, shape the
response. All the actual decision logic — request validation, the transactional read/write, the
audit_log shape — lives in `lib/`, has **zero Firebase SDK dependency of its own**, and is unit
tested with `node --test` against hand-rolled fakes. No emulator, no real Firestore, no network.

```js
// lib/gatewayLogic.js — db and serverTimestamp are PARAMETERS, not module-level admin.* calls
async function applyMutation(db, params) {
    await db.runTransaction(async (txn) => { /* ... */ })
}

// test/gatewayLogic.test.js — a fake satisfying just the .doc()/.runTransaction() shape used
function makeFakeDb(existingAuditPaths) {
    const writes = []
    return { writes, doc(path) { return { path } }, async runTransaction(fn) { /* ... */ } }
}
```

**Why this matters beyond style**: this pattern is what makes P0's compliance logic (which is
exactly the code you most need to trust) actually verifiable in a plain CI runner or a sandbox
with no Google Cloud network access — see the 2026-07-11 checkpoint, where this caught two real
bugs (a collapsed error-code distinction in `runCutover`, and a test fixture using an
unregistered entity) before either shipped.

**When adding a new entity or Cloud Function to the gateway**: put the decision logic in `lib/`
first, write its test first (watch it fail on the missing module — this is the actual Iron Law,
not a suggestion), then wire `index.js` to call it. Don't add logic directly to an `exports.*`
handler if it can be expressed as a pure/injected function instead — untestable-by-construction
compliance code is a standing liability, not a shortcut.

**Batch-mutation cap (`batchMutationLogic.js`)**: `MAX_BATCH_SIZE = 200` — not from the spec (P0's
`recordMutation` contract is singular only; batch was added 2026-07-11 for
`OrdersStore.approveAllPending`). Each item is 2 writes (working doc + audit_log), so 200 items =
400 writes/transaction, safely under Firestore's ~500-write transaction ceiling. A caller needing
more must split into multiple `recordMutations` calls client-side — atomicity holds within each
chunk, not across chunks. This is a documented trade-off; don't raise the cap without re-deriving
the arithmetic against Firestore's actual limit.

## Skill 36: Async write sequencing — single-flight, locking, CAS, and atomic deltas

**Files**: `qml/model/{OutboxStore,Gateway,LockManager,OrdersStore,InventoryStore,StaffStore,
SupplierStore,StockBatchStore}.qml`, `functions/lib/{gatewayLogic,lockLogic}.js`, `firestore.rules`,
full design: `docs/superpowers/specs/2026-07-29-async-write-sequencing-design.md`, review:
`docs/superpowers/specs/2026-08-06-async-write-sequencing-code-review.md`

Four related but distinct correctness mechanisms, easy to conflate — know which one actually
fixes which bug before reaching for any of them:

**1. Single-flight-per-record (`OutboxStore`)** — fixes a device racing its OWN sequential writes.
`enqueue()` coalesces a second call for the same `entity+entityId` into an existing NOT-in-flight
item (keeps earliest `before`/`action`, takes latest `after`); if the existing item IS in flight,
the new call is held separately rather than mutating a payload already on the wire. Client-only,
no server involvement, no deploy risk.

**2. Pessimistic locking (`LockManager` + `acquireLock`/`releaseLock`)** — fixes wasted work: lets
a second device find out a record's being edited BEFORE doing any work, not after. A lock is just
another Firestore document (`locks/{entity}_{entityId}`), acquired/released via the same
transaction primitive as everything else — no custom mutex machinery. TTL (90s) + client renewal
heartbeat (30s) means an abandoned/crashed session self-heals via expiry; there is no cleanup job
and there shouldn't need to be one. Gates the EDIT entry point only (entering edit mode / opening
directly into it) — never a plain view, reads are always unrestricted.

**3. Server-side compare-and-swap (`applyMutation`'s CAS check)** — the actual correctness
backstop for whole-record writes, independent of whether locking "worked": rejects if the record's
current server state doesn't match the mutation's claimed `before`. With locking in place this
should fire rarely — if it fires often, that's a signal locking isn't actually being acquired
somewhere it should be, not a reason to remove the check. **The client half matters just as much as
the server half** (see the 2026-08-06 section below): a server that correctly rejects a stale write
is only a real backstop if the client actually stops retrying it and reconciles — `Gateway.
mutationConflicted(entity, entityId, current)` is that other half, and every store that calls
`recordMutation` needs to be connected to it, not just the one or two that happen to get exercised
in testing.

**4. Atomic server-side deltas (`applyDelta`, `Gateway.recordDelta`)** — a DIFFERENT mutation kind
for quantity fields, not a CAS variant. Reads the current value INSIDE the transaction and computes
`current + delta`, so it's correct regardless of what else touched the doc concurrently — two
legitimate concurrent stock deductions on the same product both apply. `floors` (reject) vs
`clamps` (cap and still succeed) — pick based on the caller's actual business rule
(`InventoryStore.deductStock` rejects for order completion, `completeImportedOrder` clamps because
its whole point is "complete anyway, report the shortfall"). **Don't use CAS/locking for a
quantity field a delta could handle instead** — whole-record CAS on a stock field would spuriously
reject two perfectly-compatible concurrent decrements; that's not a conflict, it's ordinary
concurrent business, and rejecting it is a correctness regression, not caution.

```js
// gatewayLogic.js — the actual bug that motivated #4: computing a new value
// from a possibly-stale LOCAL read is unsafe no matter how carefully it's
// guarded client-side. The fix reads inside the SAME transaction that writes:
async function applyDelta(db, params) {
    return db.runTransaction(async (txn) => {
        const current = (await txn.get(workingRef)).data()
        const next = (current[field] || 0) + params.deltas[field]   // computed HERE, not client-side
        txn.set(workingRef, Object.assign({}, current, { [field]: next }))
    })
}
```

**A subtlety that cost a genuine near-bug**: naive "coalesce a queued mutation into an existing
item" (mechanism #1) is unsafe if it doesn't distinguish QUEUED from IN-FLIGHT — merging into an
item whose payload was already serialized onto an outbound request silently discards whatever the
merge was supposed to add, once that in-flight request's own completion handler removes the
(now-corrupted) entry by its original requestId. `OutboxStore.markInFlight(item)`/`clearInFlight(item)`
take the item object itself (not a requestId) specifically to sidestep a related bug: looking an
item back up by requestId AFTER `markSent` has already deleted it silently leaks the in-flight key
forever.

**Test-tooling note**: `functions/test/gatewayLogic.test.js`'s fake Firestore double
(`makeFakeDbWithData`) tracks real document DATA per path, not just existence — needed once
`applyMutation`/`applyDelta` actually read current state to decide anything. The original
`makeFakeDb` (existence-only, Skill 35's example above) is still fine for logic that never reads
before writing, but silently breaks anything that does (caught this converting 2 pre-existing
`applyMutation` tests when adding the CAS check — they used `makeFakeDb` with a non-null `before`,
which read as a false conflict once the function started actually checking current state).

**Two real bugs found post-implementation (2026-07-30), both worth internalizing as patterns, not
just as one-off fixes:**

1. **Never let "the request failed" and "the server decided no" share a code path.** The original
   `LockManager.acquire`/`Gateway._sendDelta` treated any non-2xx HTTP response as a genuine server
   decision. An undeployed Cloud Function's 404 has no real body — but the code couldn't tell that
   apart from a real `409 someone-else-has-this`, so a lone tester saw "someone else is editing
   this" with nobody else on the system. The fix pattern: a real decision from YOUR OWN code is
   only ever valid JSON matching YOUR OWN response envelope (here, a boolean `ok` field) — anything
   else, regardless of HTTP status number, is infrastructure noise and must never be presented to a
   user as a business outcome. Extract this as a pure `_classify*Response(status, body)` function
   so it's unit-testable without a mock HTTP layer (see `_classifyDeltaResponse`/
   `_classifyAcquireResponse`).

2. **Whole-record CAS is only as safe as your create-vs-reconstruct symmetry.** `OrdersStore`'s
   `_clone()` (used to build `before` for every update) had a field whitelist that DIDN'T match
   `addOrder`'s create payload — `adjustments` got silently added by `_clone()`'s defaulting,
   `updatedAt` got silently dropped since `_clone()`'s whitelist never listed it. Every clone after
   creation reshaped the local cache away from the real Firestore document, so `applyMutation`'s
   CAS check would reject a completely ordinary single-user edit as a false conflict — not a rare
   race, close to guaranteed on the second touch of any record. **The lesson generalizes past
   orders**: any store with a reconstructing `_clone()`-style function (explicit field list with
   defaults) needs that list to be IDENTICAL to what its create function sends — extract one
   `_normalizeX(raw)` function and use it in both places, don't maintain two field lists that have
   to be kept in sync by hand. Stores that instead build `before`/`after` via a plain shallow copy
   of the live array element (`arr.slice()` + `Object.assign`) — `SupplierStore`, `StockBatchStore`
   — are structurally immune to this specific bug, since there's no separate defaulting step that
   can diverge from creation. When auditing a store for this, check which pattern it uses first;
   only the reconstructing kind needs the create/clone symmetry check at all. **Caveat added
   2026-08-10, see Skill 37**: "shallow copy" immunizes against *this* bug (create/clone field-list
   drift) but is not a general safety property — `Object.assign` only copies top-level fields, so a
   shallow-copied `before` still shares any nested array/object by reference with `after`, and stays
   vulnerable to a *different* bug if that nested field is later mutated in place rather than
   reassigned. `OrdersStore.applyAdjustment` was exactly this: shallow-copy-immune to the bug above,
   but not to the one Skill 37 covers.
**2026-08-06: full code review + fix round.** A dedicated review of the whole feature (`docs/
superpowers/specs/2026-08-06-async-write-sequencing-code-review.md`, 8 Critical + 5 Important
findings) found the design was individually correct in every piece but had never actually been
wired end-to-end — several mechanisms above were server-tested but client-inert, or converted for
one caller and silently not another. All 8 Critical findings are now fixed (`fix/
async-write-sequencing-review-fixes` branch). Patterns worth internalizing, not just the specific
bugs:

1. **A mechanism "existing" server-side and being "wired up" client-side are two different claims
   — verify both separately.** Component 3's CAS check (#3 above) was fully implemented and
   unit-tested in `gatewayLogic.js`, but `Gateway._send`/`_sendBatch` never actually handled a 409
   conflict response — it fell into the exact same retry-forever bucket as a plain network
   timeout, defeating the entire point of the backstop. Fixed with a narrow, deliberately-scoped
   `_parseMutationConflict(status, responseText)` (pure, unit-tested) that only special-cases the
   specific `409 + conflict:true` shape — every OTHER failure (400/401/403/5xx/network error) keeps
   going through the existing retry path unchanged, since those might genuinely resolve on retry
   (token refresh, transient infra) where a real conflict never will. Then wired
   `Gateway.mutationConflicted(entity, entityId, current)` into **every** store that calls
   `recordMutation` (`OrdersStore`, `InventoryStore`, `StaffStore`, `SupplierStore`,
   `StockBatchStore`) — each patches its local array for that `entityId` from `current` (removing
   it if `current` is null — deleted elsewhere) and shows a `Toast`, except `StockBatchStore`,
   which patches silently since batch writes are an internal accounting side effect of an action
   the user already got feedback on elsewhere.

2. **"Converted caller X and Y" in a checkpoint is a claim to re-verify, not a fact to inherit.**
   The prior checkpoint asserted `InventoryStore.deductStock`/`restock` were both converted to
   `recordDelta` (#4 above) — only `deductStock` actually was; `restock` (and, found during this
   fix, `creditStockNoBatch`, same bug) were still computing the new stock value from a local
   snapshot and sending it via the old whole-record CAS path. `grep -rn "recordDelta(" qml/` is the
   fast way to independently confirm a delta-conversion claim rather than trusting prose about it.

3. **A "reject on rejection" delta path needs the SAME care about what already ran before it as a
   "reject on rejection" mutation path does.** `StockBatchStore.consumeFifo`/`topUpOldest` run
   synchronously and unconditionally, before the corresponding `deductStock` delta call resolves,
   in both `_tryCompleteOrder` and `_tryAdjustOrder`. On a genuine rejection (the exact scenario
   `floors` exists to produce), the FIFO batches had already been decremented with no rollback.
   Fixed by calling the already-existing `StockBatchStore.restoreFifo` on every already-touched
   batch when the delta fails — no new primitive needed, the returns flow already had one for
   exactly this purpose. **Left open, flagged rather than silently expanded into**: when one line
   item's delta succeeds and a sibling's fails, the successful line's `product.stock` delta stays
   applied even though the whole order reports failure — a partial-completion gap beyond FIFO,
   needing a compensating delta call, out of scope for the FIFO-specific fix.

4. **A sibling function needs the SAME fix as its twin, not just a similar one.** The 2026-07-30
   `_classify*Response` fix (lesson 1 above) was applied to `_classifyDeltaResponse` but
   `LockManager._classifyAcquireResponse` never got the equivalent status-range check — it treated
   every well-formed `{ok:false}` body as `"denied"` regardless of status, so a 400/401/403/500
   (none of which mean "someone else holds this lock") produced a fabricated "someone else is
   editing this" message. When a bug's fix pattern applies to more than one function, grep for
   every function that shares the pattern, not just the one that was reported.

5. **`firestore.rules` needing a lockdown and `firestore.rules` HAVING a lockdown are two different
   git commits — check the actual diff, not just the design doc's intent.** The design doc called
   for `locks/**` to be denied to clients the same way `audit_log`/`transactions`/etc. are — this
   was never actually done; `git log` confirmed the rules file was untouched across the entire
   13-commit branch. Fixed with a new `isServerOnlyCollection` tier, distinct from the existing
   `isLedgerCollection` tier: the ledger tier is readable-but-write-locked (clients display that
   data), `locks` needs BOTH denied since no client ever has a legitimate reason to touch it.
   **Subtlety worth remembering**: Firestore grants access if ANY matching rule allows it — the
   generic wildcard fallback's `allow read` line isn't gated by `isLedgerCollection` at all, so
   adding a name to that list alone would NOT have blocked reads. The fallback's read rule needed
   its own explicit carve-out.

6. **A "fix by consolidating two duplicate functions into one" commit needs the same scrutiny as
   any other fix.** `OrdersStore._normalizeOrder` existed as two drifted-apart copies (the root
   cause of lesson 2's bug above); consolidating them into one was the right instinct, but the
   merge read `inv.consumption` (the just-looked-up inventory/product record, which never has a
   `consumption` field) instead of `lp.consumption` (the order line itself) — silently wiping FIFO
   lineage on every order, and crashing with a TypeError whenever a line's product was deleted from
   inventory (`InventoryStore.getById` returns `null`; `null.consumption` throws). The existing
   `tests/tst_OrdersStore_normalization.qml` (added specifically for the OTHER bug this same commit
   fixed) caught this by accident, via an unseeded `InventoryStore` in its test fixture — not by
   design. Two explicit regression tests were added for both failure modes so it's no longer an
   accident that this is covered.

**Still genuinely open after the 2026-08-06 round** (Important-severity findings, not Critical —
tracked, not silently dropped): none — see 2026-08-08 below. All five were closed, plus the two
new/known gaps also tracked here (StockBatchStore recordDelta conversion, ConfirmReturnSheet
lock-span) and one more discovered mid-round (partial-multi-line-completion, lesson 3 above).

**2026-08-08: round 2 — I1–I4 + 3 known/new gaps, all closed** (`fix/
async-write-sequencing-review-fixes` branch, design doc: `docs/superpowers/specs/
2026-08-08-review-round2-design.md`). Scoped via `/superpowers:brainstorming` — Taher was shown the
real blast radius of the StockBatchStore option (5 call sites, 3 with retry-loop coupling) before
choosing the full rewrite over the smaller mechanical-swap alternative. New patterns worth
internalizing, distinct from the 2026-08-06 lessons above (see there first — several round-2 bugs
are second instances of those same lesson categories, cross-referenced rather than re-derived):

1. **`floors` and `clamps` are not interchangeable "don't go negative" options — they have opposite
   failure semantics, and picking wrong quietly reintroduces the attribution gap you're trying to
   close.** `floors` on `applyDelta` REJECTS the whole delta if it would cross the floor (ok:false,
   zero applied) — the delta either fully lands or doesn't happen at all, no partial state.
   `clamps` caps the result at the boundary and still succeeds — a partial amount can silently
   apply. `StockBatchStore.consumeFifo`'s async rewrite deliberately uses `floors`, not `clamps`,
   specifically because exact-or-nothing per batch is what makes the returned `consumption[]`
   trustworthy — with `clamps`, a successful response could still mean "less than planned was
   actually taken," reintroducing ambiguity about which batch really contributed what.

2. **(Second instance of the 2026-08-06 lesson 2 pattern — "verify caller-conversion claims,
   don't inherit them.")** The round-2 design doc scoped `completeImportedOrder`'s `consumeFifo`
   conversion as "simpler — no failure path." That was true for the failure-handling logic, but
   missed that the function had a synchronous `return {ok, understocked}` contract its
   `ImportPreviewDialog` caller depended on in a tight loop — converting the function to async
   forced restructuring that loop too. **A function's own body being simple doesn't mean its
   conversion is small — check what its RETURN VALUE'S caller does with it before scoping.**

3. **A "hand off ownership" fix needs the actual event ordering traced, not assumed.** First
   instinct for the `ConfirmReturnSheet` lock-span gap was having the sheet re-acquire its own
   lock in `openFor()` — simpler, self-contained. Wrong: `openFor()` runs SYNCHRONOUSLY, inside the
   same call stack as `OrderDetailDialog._save()`'s `adjustRequested` handler, which fires BEFORE
   `dlg.close()` on the next line. A re-acquire there would resolve, then `OrderDetailDialog`'s own
   release (fired moments later by `close()`) would delete the SAME lock document the re-acquire
   just claimed — the two are both async network calls racing on one doc, and there's no ordering
   guarantee release loses. Fixed with an explicit handoff flag instead (`_lockHandoffPending`) so
   the original owner's `onClosed` skips its release rather than relying on a second acquire
   winning a race it might not win. **When two components both touch the same server-side
   resource across an async boundary, trace the actual call-stack ordering before assuming a
   "simpler" independent-acquire design is safe.**

4. **(Second instance of 2026-08-06 lesson 1 — "existing" and "wired up" are different claims.)**
   The Cloud Function endpoint (`functions/index.js`'s `recordMutationsBatch`) was calling
   `applyMutationsBatch` and discarding its return value entirely, always sending `200 {ok:true}`
   regardless of what the transaction did. Adding the CAS check itself (I1) would have been
   silently inert without also fixing this — the transaction would correctly refuse to write, but
   the client would be told it succeeded, which is WORSE than doing nothing (a caller that thinks
   an import landed when it didn't is a worse bug than the original no-CAS-check gap). Grep for
   every place a function's result is called and check whether the CALLER actually branches on it,
   not just whether the function itself returns something meaningful.

5. **A fake DB double built for one query shape breaks silently once the code starts reading a
   DIFFERENT ref.** `batchMutationLogic.test.js`'s `makeFakeDb` only ever modeled `auditRef`
   existence (all `applyMutationsBatch` needed to check before I1). Adding the CAS check meant
   reading `workingRef`s too — the existing 5 tests would have started reporting false conflicts
   (fake working docs "don't exist" by default, but `validItem()`'s fixture `before` claims
   `{status:"pending"}`) had the fake not been extended to model working-doc state and the existing
   tests updated to pass matching state. Same root pattern as the 2026-07-30 `makeFakeDbWithData`
   note above — a fake that's "good enough" for what the code currently reads needs re-auditing
   every time the code starts reading something new, not assumed to still be sufficient.

All 7 remaining findings from the 2026-08-06 review are closed as of this round: I1 (batch CAS,
plus the endpoint wiring gap it surfaced), I2 (bulk-approve locking), I3 (lock entity allowlist),
I4 (dialogs' dead "try again" retry, all 3), StockBatchStore's full async rewrite, the
`ConfirmReturnSheet` lock-span handoff, and the partial-multi-line-completion gap (found mid-round
during the 2026-08-06 fix, fixed at two sites: `_tryCompleteOrder` and `_tryAdjustOrder`'s exchange
path — the second site wasn't in any prior finding list, found while implementing the first).



**Files**: `qml/helper/ProfileSettingsMath.js`, `tests/tst_ProfileSettingsMath.qml`,
`qml/model/AuthService.qml` (`saveProfileSettings`), `qml/model/FirebaseService.qml` (`patch`)

When one user action must write to two documents (here: `users/{uid}` and `tenants/{tenantId}`)
and the UI should only see one success/failure, don't fire two independent requests with two
independent success signals — that's a race. Instead:

1. A pure helper (no QML, no singletons) computes the **full change set** up front: what changed,
   whether the request is even authorized (owner-only workspace rename), and the exact per-document
   patch payloads. It returns `null`/`error` for invalid input instead of letting a bad write reach
   the network.
2. The orchestrating function counts how many writes are actually needed, issues them all, and
   only emits the terminal success/failure signal once every issued write has settled — first
   failure wins, but every callback still runs.
3. The local store (`AuthStore.updateProfile`) applies fields with `!== undefined` presence checks,
   not `value || fallback`. `||` silently keeps the old value when a field is legitimately cleared
   to `""` — a real, non-obvious bug distinct from a `.pragma library` re-export bug.

**`FirebaseService.patch()` was dead code before this**: it aliased straight to `put()`, and
`put()`'s Firestore REST call is a `PATCH` **without** `updateMask.fieldPaths`, which Firestore
treats as "replace the document with exactly these fields" — not a partial update. Grep for
callers before trusting `patch()`'s name; here there were zero, so redefining it to send real
`updateMask.fieldPaths` per key was zero-risk. If a future `patch()` caller exists, confirm it
actually wanted masked semantics before changing it again.

**Verify `Constants.qml` tokens exist before writing them into a design doc or plan.** A prior plan
for this feature specified `Constants.brand` for an active-edit-state border; no such property
exists (only `brand1`..`brand5` and semantic aliases like `primaryBlue: brand1`). Referencing an
undefined singleton property doesn't fail to compile — it silently binds `undefined`, which is a
much harder bug to spot than a QML syntax error. `grep -n "property color" qml/helper/Constants.qml`
before using any `Constants.*` token you haven't seen used elsewhere first.

## Skill 37: Before/after snapshot aliasing — shallow copy vs. in-place mutation

**Files**: `qml/model/OrdersStore.qml` (`applyAdjustment`), `tests/tst_OrdersStore_applyAdjustment.qml`,
full investigation + fix: `docs/superpowers/specs/2026-08-10-before-snapshot-aliasing-CHECKPOINT.md`

Found by Taher's own manual testing (2026-08-10, on `fix/async-write-sequencing-review-fixes`):
add an order, complete it, open it, adjust the price, save — spurious "This order was updated
elsewhere — your change didn't save" toast, even though nothing else touched the order. The price
edit was silently discarded (server rejected the whole write, nothing persisted — see Skill 36 §3
for what the CAS check does and why a rejection there is all-or-nothing, not just the field that
triggered it).

**Root cause**: `Object.assign({}, o)` is a SHALLOW copy — it copies top-level properties only.
Any nested array or object field is copied BY REFERENCE, not by value. `applyAdjustment` took
`before` this way, then did `o.adjustments.push(adjustmentRecord)` — an IN-PLACE mutation of that
same shared array. `before.adjustments` and `o.adjustments` were never two arrays; they were one
array with two names, so the push leaked forward into `before` too. That corrupted `before` is
exactly what fails `applyMutation`'s `_deepEqual(current, before)` check in
`functions/lib/gatewayLogic.js` — the server's real prior state didn't have the new adjustment, the
client's claimed "before" now did, mismatch, reject.

```js
// BUGGY
var before = Object.assign({}, o);   // before.adjustments IS o.adjustments (same array)
o.adjustments.push(adjustmentRecord); // mutates the array both names point to — before is corrupted

// FIXED
var existingAdjustments = Array.isArray(o.adjustments) ? o.adjustments : [];
o.adjustments = existingAdjustments.concat([adjustmentRecord]); // NEW array; before's reference untouched
```

**The fix is `.concat()` over `.push()`, not "stop using shallow copy."** A full-codebase sweep (25
`Object.assign` call sites across every store, `Gateway`, `OutboxStore`, `AuthService`,
`NewOrderDialog`) found this was the ONLY instance of the pattern in the project — every other site
either only reassigns primitive fields after the shallow copy (safe — no shared reference is ever
mutated), or already builds a brand-new object/array and replaces the array slot rather than
mutating in place (`StockBatchStore`, `OutboxStore`, `Gateway`, `NewOrderDialog` — this is the
correct, established convention). Rewriting all of those to a full deep-clone (e.g.
`JSON.parse(JSON.stringify())`, confirmed safe for this codebase's data shapes — no `Date`/
Timestamp/function fields ever live in a store's persisted shape, `new Date()` only appears in
transient calculations) was considered and deliberately rejected: it would have touched 6+ working
files to guard against a bug that, after the sweep, exists nowhere else, which is exactly the
"bundled refactoring while fixing a root cause" anti-pattern `superpowers:systematic-debugging`
warns against.

**The general rule** (this is the actual takeaway, not "avoid `Object.assign`" — it's used safely
in a dozen other places in this file alone): once you've taken a `before` snapshot — shallow copy
OR the reconstructing `_normalizeOrder`/`_clone()` kind, doesn't matter which — every subsequent
change to the live object must be a REASSIGNMENT (`o.field = newValue`, `o.arr = oldArr.concat(x)`,
`o.arr = oldArr.filter(...)`) never an IN-PLACE MUTATION of a nested field (`.push`, `.splice`,
`.sort`, `.reverse`, or `obj.nested.prop = x`) — reassignment produces a new reference the old
snapshot doesn't share; in-place mutation changes the value at an address the snapshot is still
looking at. `grep -rn "[a-zA-Z_][a-zA-Z0-9_]*\.[a-zA-Z_][a-zA-Z0-9_]*\.push(\|...\.splice(" qml/` is
the fast way to re-check this project-wide — it should keep returning nothing outside intentional,
reviewed cases.

**A related, currently-dormant fragility, left alone rather than fixed**: `_normalizeOrder`'s
`adjustments: r.adjustments.slice()` is itself only a shallow ARRAY copy — the individual past
adjustment record OBJECTS inside are still shared by reference across every snapshot taken from
that array. Nothing in this codebase currently mutates a past adjustment record after creation (grep
confirmed), so this isn't live, but it's the same fragility pattern lying dormant one call away. Not
fixed here — no evidence it's needed, and "fix it in case something mutates it later" is scope creep
without a concrete bug behind it. Worth checking first if a future change ever needs to edit a past
adjustment record in place instead of appending a new one.

**Test-tooling note**: `Gateway.recordMutation` in `mode: "gateway"` enqueues into `OutboxStore`
without touching the network as long as `AuthStore.idToken` stays empty (`_send`'s guard closes
before any XHR — see Skill 36 / `tests/tst_Gateway.qml`'s header note). That makes the real,
production `before`/`after` objects directly inspectable via `OutboxStore.items[0].before`/`.after`
in a test — no mock/fake layer needed to catch this class of bug; asserting on object identity
(`before.adjustments !== after.adjustments`) is the most direct regression check available.

## Skill 38: Ledger-sync race — acting on a paginated store before it's complete

**Files**: `qml/model/TransactionStore.qml` (`_fetchFromFirebase`, `_scheduleRetry`), `qml/model/
DataModel.qml` (`_tryAdjustOrder`), `qml/pages/OrderDetailDialog.qml` (`_save`), `tests/
tst_DataModel_adjustOrderSyncGuard.qml`, `tests/tst_TransactionStore_syncRetry.qml`, full
investigation: `docs/superpowers/specs/2026-08-11-ledger-sync-race-CHECKPOINT.md`

Found by Taher immediately after the Skill 37 fix shipped, testing the very branch that fix
unblocked: complete an order, verify it in Firestore, close the app, reopen it, and — promptly —
return an item. The return "succeeded" (product-level history recorded it), but the order's total
in the Orders list didn't reduce, and order-level history looked incomplete. Confirmed by Taher's
own follow-up test: same sequence but with the app left running (no restart) — works perfectly.
Same sequence with a restart, but waiting long enough before returning — also works perfectly. The
one variable that matters is whether `TransactionStore` has finished its post-restart sync.

**Root cause**: `TransactionStore` re-fetches its entire transaction history from Firestore on
every cold start, 50 docs at a time, via `FirebaseService.query("transactions", { limit, startAfter
}, ...)` — no `orderBy` override, so it defaults to ascending `__name__` (document ID). Transaction
IDs are locally generated as `"tx-" + kind + "-" + Date.now() + "-" + rand` (`_nextId`) — an
ever-increasing, timestamp-prefixed string. Ascending-by-ID is therefore ascending-by-creation-time:
the OLDEST transactions load first, page by page, and the NEWEST — including the sale from an order
you just completed — load LAST. On a dev/test database with a lot of accumulated history (this
project has plenty, from every review round's testing), that's several sequential round trips, not
one.

`OrdersStore.applyAdjustment`, for a completed order, trusts `TransactionStore.totalsForOrder(orderId)`
unconditionally:
```js
var led = TransactionStore.totalsForOrder(orderId);
if (led) { o.tax = led.tax; o.total = led.total; }   // led is ALWAYS an object -- this always wins
else { o.tax = t.tax; o.total = t.total; }            // dead code, totalsForOrder never returns null
```
If the return happens before that last page (containing the order's own sale entry) has synced,
`totalsForOrder` sums an incomplete ledger — the return entry is there (it's written locally and
immediately, independent of any fetch), the sale entry isn't, and the resulting total is wrong. I
verified this isn't an arithmetic bug — I Node-ported the actual `OrderMath.allocate`/
`TransactionStore.totalsForOrder`/`forOrder` logic (both files are plain, portable JS — no QML/
singleton deps per their own header comments) and ran it against three realistic scenarios
(simple, tax+discount+multi-line, sequential double-return) — all computed correctly given a
complete ledger. The bug is entirely about *what the ledger contains at the moment it's read*, not
how it's summed.

**The fix has two parts, and both matter — one without the other creates a worse bug:**

1. **Refuse the action, don't silently degrade.** `DataModel._tryAdjustOrder` now refuses to adjust
   a completed order while `TransactionStore.hasMore` is true, with a clear message telling the
   user to wait — checked both in `DataModel` (the authoritative gate — `onAdjustOrder` and
   `adjustOrderForImport` both route through `_tryAdjustOrder`, so one check covers both) and
   proactively in `OrderDetailDialog._save()` (so the user finds out before filling out
   ConfirmReturnSheet's reason/condition/note fields, not after). Scoped deliberately narrow: `grep
   -rn "totalsForOrder(" qml/` turns up exactly one caller (`applyAdjustment`'s completed-order
   branch) — nothing else in the app reads this ledger, so nothing else needed gating. Order
   completion itself is unaffected (`recordSaleFromOrder`'s allocation comes from the order's own
   `products`, never from `TransactionStore.entries`), and blocking the whole app until a
   potentially-large paginated historical fetch completes — which was the instinctive first ask —
   would have been a real regression for any business with meaningful order history. "Block the
   user" only where the actual dependency is.

2. **Fix the failure path the block now depends on.** Before this, a single failed sync page left
   `TransactionStore.hasMore` stuck at `true` FOREVER — `_fetchFromFirebase`'s failure branch just
   logged a warning and returned, no retry, nothing else in the file ever flips `hasMore` back down
   on its own. Once (1) ships, that gap stops being a cosmetic loose end and becomes a real problem:
   one dropped request during a cold-start sync would permanently block every completed-order return
   until the app restarts. Added `_scheduleRetry()` — exponential backoff (3s, 6s, 12s, 24s, capped
   at 30s), single-shot `Timer` created via `Qt.createQmlObject` the same way `Gateway._drainTimer`
   already does it in this codebase (same `LDR-3` lint finding as that existing, shipped code —
   not a new anti-pattern, matching established precedent). Point 1 without point 2 trades a subtle
   wrong-number bug for an occasional hard, unrecoverable lockout — worse, not better.

**The general rule**: a `property bool hasMore` (or equivalent "is this collection fully loaded"
flag) on a paginated store is not just a loading-spinner concern — anything that trusts that
store's data to be *complete* (a sum, a lookup-by-key expected to always hit, an aggregate) needs to
either check that flag or have its own reason to be sure the relevant subset is already loaded.
`grep -rn "\.hasMore\b" qml/model/` is the fast way to find which stores have this shape at all;
right now that's `TransactionStore` and `OrdersStore` — worth the same scrutiny if a similar
"trust an aggregate over the whole collection" pattern shows up reading from `OrdersStore.orders`
somewhere.

**Left alone, not fixed here**: `OrdersStore.orders` has the identical paginated/`hasMore` shape
(same grep). Nothing today aggregates *across* orders the way `totalsForOrder` aggregates across
transactions — `OrdersPage`'s list, counts, and filters all operate per-row on whatever's loaded,
which degrades gracefully (a syncing order list just looks incomplete, it doesn't compute a wrong
number) rather than silently wrong. No evidence of a live bug here; flagging so a future aggregate
built on `OrdersStore.orders` doesn't reintroduce this same class of bug without the same guard.

## Skill 39: Concurrent-reset race — two async resyncs, one paginated store

**Files**: `qml/model/TransactionStore.qml`, `qml/model/InventoryStore.qml`, `qml/model/
OrdersStore.qml`, `qml/model/StaffStore.qml`, `qml/model/StockBatchStore.qml`, `qml/model/
SupplierStore.qml` (all `_resetAndFetch`, Taher's fix, 2026-08-12), `qml/model/ActivityLog.qml`,
`qml/model/CategoryStore.qml`, `qml/model/OrderChannelStore.qml` (`Component.onCompleted`, this
session's follow-up fix), `tests/tst_TransactionStore_resetGuard.qml`. Full narrative:
`docs/superpowers/specs/2026-08-11-ledger-sync-race-CHECKPOINT.md`.

Taher found this himself, on-device, immediately after the Skill 38 guard shipped and still didn't
reliably catch the sync-incomplete window: no "still syncing" message on a prompt post-restart
return, and Orders/Inventory screens showing inconsistent data that self-resolved given enough time.
His diagnosis, in his own words: `TransactionStore.Component.onCompleted` calls `_resetAndFetch()`,
and separately `Main.qml`'s `onTenantContextReady` handler ALSO calls it (via `syncFromFirebase()`)
— both async, both real, on the same cold start. Whichever's page-1 request lands first sets
`loadingMore = true` and starts accumulating pages; the second call still ran to completion anyway
(nothing was gating it), wiping `entries` back to `[]` and resetting `_cursor` out from under the
FIRST, still-in-flight fetch. That first fetch's eventual page-1 response then concatenated onto the
just-wiped array and its `_cursor` got clobbered, corrupting the rest of that pagination chain —
`hasMore` could end up `false` with `entries` still genuinely incomplete, which is exactly why
Skill 38's guard (which only checks `hasMore`) didn't catch it: `hasMore` was lying.

This is a materially different bug from Skill 38, even though the visible symptom (return doesn't
fully take effect after a restart) looked similar. Skill 38 was about *what* the ledger sum trusted;
this is about *whether the sync that populates the ledger can even complete correctly* when two
triggers fire close together. Worth internalizing as two separate lessons because a fix for one
doesn't imply the other is covered — Skill 38's guard, by itself, was necessary but not sufficient.

**Why `Component.onCompleted`'s existing `AuthStore.tenantId.length > 0` check didn't prevent
this**: that guard was written (see `OrdersStore`'s own comment on the same pattern) assuming
`tenantId` is normally still empty at singleton-creation time on a cold start, deferring the actual
first fetch to `onTenantContextReady`. On-device, that assumption didn't hold reliably — `tenantId`
CAN already be populated by the time these singletons are created (session restore timing varies),
so BOTH triggers fire. Static reading of the "normal" case predicted this couldn't happen; the
actual device proved otherwise. Lesson: a guard justified by "this shouldn't normally be true yet"
is a hope, not a guarantee — the two-async-callers problem needs its own guard regardless of how
unlikely the overlap seems from reading the trigger order in isolation.

**The fix**: `_resetAndFetch()` now starts with `if (loadingMore) return` — a second reset call
arriving while a fetch is already in flight is a no-op instead of wiping state out from under it.
Applied to `_resetAndFetch()` itself (not each caller), so it protects against ANY current or future
caller pairing, not just the two known ones — confirmed by finding a third, currently-dead trigger
(`Logic.syncAllStores` / `DataModel.onSyncAllStores`, declared and handled but never actually
emitted anywhere in the app today) that would hit the exact same race the moment something wires it
up to a UI action (e.g. a future pull-to-refresh) — already covered, no separate fix needed if/when
that happens.

**Residual trade-off, not fixed, worth a decision before it's needed**: `if (loadingMore) return`
also silently drops a *legitimate* reset that happens to arrive mid-fetch — e.g. a user switching
accounts while the previous account's very own initial sync is still in flight. The in-flight fetch
would complete with the OLD account's data, and the new account's reset request — the one case
`onTenantContextReady`'s own comment says it exists FOR ("a re-login after switching accounts") —
would just be discarded, leaving the store showing the wrong account's data until some other trigger
resyncs it. Lower probability than the cold-start double-fire (needs a deliberate fast account
switch, not just normal app launch timing) and not something Taher's on-device testing has hit, but
it's a real gap in the current fix, not a hypothetical. A more complete fix is a "pending reset"
flag: if `_resetAndFetch()` is called while `loadingMore` is true, set `_resetPending = true` instead
of silently returning; when the in-flight fetch's callback completes, check the flag and immediately
re-run `_resetAndFetch()` (which will now proceed, since `loadingMore` is false) rather than
continuing that now-stale fetch chain. Not implemented — flagging for a decision on whether the
probability of hitting this in practice justifies the added complexity, rather than deciding
unilaterally either way.

**Full sweep of every `qml/model/*.qml` singleton** (Taher's fix covered six stores; this session
checked the other fifteen for the same shape — a reset-like function clearing accumulator state and
kicking off an async fetch, reachable from more than one trigger):

| Store | Verdict | Why |
|---|---|---|
| `TransactionStore`, `InventoryStore`, `OrdersStore`, `StaffStore`, `StockBatchStore`, `SupplierStore` | **Fixed** (Taher, 2026-08-12) | Multi-page pagination (`entries`/`hasMore`/`_cursor`), dual-triggered (`Component.onCompleted` + `onTenantContextReady`) — exactly the vulnerable shape. |
| `ActivityLog`, `CategoryStore`, `OrderChannelStore` | **Structurally immune to the corruption; fixed a smaller, separate issue** (this session) | Dual-triggered same as above, but each does a single bounded fetch (`ActivityLog`: top-50 query, no cursor; `CategoryStore`/`OrderChannelStore`: single-document `get()`) — no multi-page accumulation to corrupt. A duplicate concurrent call just re-fetches the same correct data; whichever response lands last harmlessly overwrites with an equally-correct result. They DID have a different, minor issue: unlike every dual-triggered store above, none guarded `Component.onCompleted` with the `AuthStore.tenantId.length > 0` check — meaning they fired an unscoped, guaranteed-to-fail Firestore request on every cold start before `onTenantContextReady`'s real sync. Fixed for consistency (same one-line guard the six already had) — not the same bug, but the same missing defense, found while checking the same trigger pair. |
| `SalesStore` | **N/A** | No Firestore fetch at all — `syncFromFirebase()`/`_load()` both just call `_rebuildDerivedData()`, a synchronous, idempotent recompute over `OrdersStore.orders` already in memory. `Component.onCompleted` happens to call `_load()` then `_rebuildDerivedData()` redundantly (harmless double-recompute at startup, not worth touching). |
| `AuthStore` | **N/A** | `loadSession()` is a synchronous local `QSettings` read, no network I/O at all, called from exactly one place (`AuthService.Component.onCompleted`). No async, no second trigger, no race possible. |
| `OutboxStore`, `PartyStore` | **N/A** | Each has exactly one call site for its load function (its own `Component.onCompleted`) — grepped the whole `qml/` tree to confirm neither is in `onTenantContextReady`'s resync list or called from anywhere else. Safe by construction: a race needs two callers, and these only have one. `PartyStore` is additionally device-local (`QSettings`, not Firestore-tenant-scoped) per its own `onSignedOut` handling. |
| `AnalysisService`, `GoogleAuthService`, `LockManager`, `MigrationService`, `StorageService` | **N/A** | No `Component.onCompleted`, no `FirebaseService.query`/`.get()` call anywhere in any of these five files — they don't do startup fetching at all (pure computation, auth-flow helpers, in-memory coordination, or invoked on demand). Nothing for this bug class to attach to. |

**The general rule**: any store with a "reset and (re)fetch from scratch" function reachable from
more than one trigger point needs that function itself to refuse re-entry while a fetch it already
started is still in flight — guard the shared function, not each caller, since callers get added
over time and each one re-deriving "is this safe" independently is how this kind of gap survives a
review. The `if (loadingMore) return` guard is `_resetAndFetch()`-specific (a resettable, multi-page
pagination cycle); a store instead using `FirebaseService.query`/`.get()` for a bounded, single-call,
directly-overwritten fetch (see the `ActivityLog`/`CategoryStore`/`OrderChannelStore` row above)
doesn't need it — a second concurrent call there just re-fetches the same correct answer. Before
adding a NEW dual-triggered store, check which of these two shapes it is before assuming it needs
the guard.

---

## Skill 40: Real-emulator E2E testing — cold starts, singleton construction order, and per-function URLs

**Files**: `test/e2e/tst_InventoryE2E.qml`, `test/e2e/tst_OrdersE2E.qml`, `test/e2e/E2EHelpers.js`,
`test/e2e/seed.js`, `qml/model/Gateway.qml`, `.github/workflows/checks.yml` (`e2e-tests` job). Full
narrative of Phase 1's 13 CI-debugging rounds: the archived
`docs/superpowers/specs/2026-08-16-e2e-testing-phase1-CHECKPOINT.md`. Design boundary (what's in
scope vs. deferred to Phase 2): `docs/superpowers/specs/2026-08-09-e2e-testing-phase1-design.md`.

This suite drives real Store/`DataModel` code against the real Firebase Local Emulator Suite —
Firestore + Auth + Functions — and verifies via a raw REST GET against the Firestore emulator,
independent of the client's own optimistic in-memory state. That's the whole point of it (a mock
would only prove the client agrees with itself), but it means every gap between "looks right
locally" and "the server actually agrees" is a real bug this suite can catch that `tests/`
structurally cannot. Four gaps specifically cost real CI rounds; worth internalizing before adding
a third scenario here rather than rediscovering each one:

**1. The Cloud Functions Emulator lazily cold-starts each function on its own first real
invocation.** Not per test run, per *function* — warming up `recordMutation` does nothing for
`recordDelta`'s first call. `initTestCase()` in each file pays this cost once, deliberately, with a
dedicated raw POST warm-up sized for a one-time cold start (15000ms), before any real test's
5000ms-budget poll can eat it. `tst_OrdersE2E.qml`'s `recordDelta` warm-up targets a nonexistent
`entityId` and asserts HTTP 404, not 200 — confirmed against `functions/lib/gatewayLogic.js`'s
`applyDelta()`, which returns `{ok:false, status:404}` for a missing document. A real function
still needs a real doc to move; 404 there proves the worker responded, which is all a warm-up
needs.

**2. Referencing a QML singleton for the first time triggers its `Component.onCompleted`** — for
`AuthService` specifically, that unconditionally wipes `AuthStore` before checking whether there's
a session to restore. `AuthService` is never referenced directly anywhere in either test file; its
actual first reference in a real run is buried inside `Gateway.drainNow()`
(`if (typeof AuthService !== 'undefined' && AuthService) AuthService.ensureFreshToken()`) — meaning
the FIRST test to call any `Gateway.recordMutation`/`recordDelta` path is also the first thing to
construct `AuthService`, and it does so from *inside* that call, after its own `init()` already set
`AuthStore.idToken` for real. The wipe lands in between, silently no-op-ing every request until an
unrelated later call happens to re-set the token. Both files' `initTestCase()` forces the
construction explicitly (`AuthService.ensureFreshToken()`, a harmless no-op while unauthenticated)
before `init()` ever runs — cheap insurance against a bug that took four CI rounds to root-cause
the first time, and applies to ANY new E2E file that touches `Gateway`, not just these two.

**3. Each Cloud Function `Gateway` calls has its own URL property, and wiring one doesn't wire the
others.** `functionUrl` (`recordMutation`), `deltaFunctionUrl` (`recordDelta`), `batchFunctionUrl`
(`recordMutationsBatch`) are three independent properties. Phase 1 only needed the first. The
Orders scenario needed the second (`StockBatchStore.consumeFifo`/`InventoryStore.deductStock` go
through `recordDelta`, not `recordMutation`) — a scenario exercising a deferred-write batch path
would need the third. Before writing a new scenario, trace which Store methods it actually calls
and check each one's `Gateway.*` call against this list rather than assuming the existing
`functionUrl` override covers it.

**4. QtQuickTest does not preserve a file's declared function order.** `tst_InventoryE2E.qml`'s own
`test_recordMutation_function_accepts_seeded_credentials` was originally written assuming it'd run
first (as a fast-fail credentials probe) — it didn't; actual order was alphabetical. Don't design a
test around "this one runs before the others" without `initTestCase()`/explicit sequencing; use
`initTestCase()` for anything that must happen exactly once before every test, not test declaration
order.

**Sharing code across test files, given #1–#4 mean every new scenario needs the same
fixture-loading/polling/warm-up machinery**: `test/e2e/E2EHelpers.js` (`.pragma library`) holds
`loadFixture`/`pollEmulatorDoc`/`postDirect`, extracted from `tst_InventoryE2E.qml` when
`tst_OrdersE2E.qml` needed the same logic verbatim. Every function takes the calling `TestCase`
instance explicitly (`tc`) and calls `tc.tryVerify`/`tc.fail`/reads `tc.fixture`/`tc.lastConflict`
through it — a `.pragma library` script doesn't share the QML component scope a bare
`tryVerify(...)` call resolves against inside a `TestCase` file itself, so every QtTest primitive
has to arrive as an explicit call on the passed-in object instead of an unqualified reference. New
pattern for this codebase (`BreakdownMath.js`/`OrderMath.js`/`ImportMath.js` are pure math, no
`TestCase` involved) — passed first CI attempt, but flagging the pattern itself as worth watching
if a future E2E file's helpers start failing in a way that looks like a scoping issue.

**Reaching `DataModel` orchestration** (as opposed to a single Store's own method): `DataModel.qml`
has no `pragma Singleton`, so it's instantiated directly as a child item inside the `TestCase`
(`DataModel { id: dm }`) and its functions called directly (`dm._tryCompleteOrder(...)`) — same
pattern `tests/tst_DataModel_adjustOrderSyncGuard.qml` already established, bypassing the
Logic/dispatcher signal bus entirely rather than trying to drive it through `Logic.qml`'s signals.

---

## Skill 41: QSettings org-identifier fix — making a Settings-backed store's persistence actually testable under qmltestrunner

**Files**: `qml/helper/SettingsPath.js` (new), all six `Settings`-backed stores (`AuthStore`,
`OutboxStore`, `OrdersStore`, `PartyStore`, `CategoryStore`, `OrderChannelStore`),
`tests/tst_SettingsPath.qml`, `tests/tst_AuthStore.qml`, `tests/tst_PartyStore.qml`,
`tests/tst_CategoryStore.qml`, `tests/tst_OrderChannelStore.qml` (all new), plus new cases in
`tests/tst_OutboxStore.qml`. Carried forward from the archived
`2026-08-16-e2e-testing-phase1-CHECKPOINT.md`'s gap list as "QSettings org-identifier warnings under
`qmltestrunner`".

**The bug, precisely**: `Settings { category: "..." }` resolves its underlying storage file from
`QCoreApplication`'s organization identifier when no explicit override is set. `qmltestrunner` is a
generic Qt-provided binary — it never runs this app's own `main.cpp`, so
`FelgoApplication::initialize()` (which sets `Application.organization` for a real launch) never
runs either. The identifier stays empty, `Settings` logs a warning, and — this is the part that
actually matters, not just noise — every property write against it no-ops instead of persisting.
For `OutboxStore`, whose entire reason to exist is durability across a relaunch, this meant that
guarantee was silently untested by every `qmltestrunner` run there has ever been.

**Correction, 2026-08-18 — the first version of this fix was itself wrong.** It targeted a property
called `fileName` (string) — that's the OLD, deprecated `Qt.labs.settings` Settings type's property
name. This app imports `QtCore`'s Settings (Qt 6.5+, `import QtCore`), whose equivalent property is
called **`location`** and is typed **`url`**, not `string`. Confirmed by an actual `qmltestrunner`
run on Qt 6.8.3 (results.xml Taher supplied): `qml/model/PartyStore.qml:22,9: Cannot assign to
non-existent property "fileName"` — and because one QML singleton failing to compile breaks the
whole `qml/model` qmldir module for every file that transitively imports any of it, this cascaded
into **14 failing test files** (`tst_ActivityLog`, `tst_Gateway`, `tst_LockManager`, and others that
never touch `PartyStore` directly), not just the six actually-changed store files. This was the
exact assumption flagged in the first version of this entry as "needs checked on a real build,
unverified in this sandbox" — it was wrong, and this sandbox genuinely could not have caught it
(no Qt toolchain here to compile against). Lesson: a plausible, doc-shaped assumption about a QML
type's API surface is still a guess until something actually compiles it — the honest flag doesn't
substitute for the check, it just means the check has to happen on a real build, which it now has.

**The fix, corrected**: a pure helper, `SettingsPath.settingsLocationOverride(orgName, tempDir)` —
returns `""` (identical to leaving `location` unset — per QtCore's own docs: *"If this property is
empty (the default), then QSettings::defaultFormat() will be used"*) when `orgName` is non-empty, an
explicit `StandardPaths.writableLocation(StandardPaths.TempLocation)`-rooted path when it's empty.
Wired into each store's `Settings` block as `location:
SettingsPath.settingsLocationOverride(Application.organization,
StandardPaths.writableLocation(StandardPaths.TempLocation))`. `StandardPaths.writableLocation()`
already returns a `url`; the helper's string concatenation coerces it via `toString()`, producing
another valid URL string, which QML accepts for a `url`-typed property the same way it accepts a
plain string for one. `Application` (the QtQuick singleton, not the older `Qt.application`
global-object property) and `StandardPaths` (QtCore) are both already in scope via each store's
existing `import QtQuick`/`import QtCore` — no new imports needed beyond the helper itself.

**Why untouched for real users, not just "probably fine"**: the override only fires when
`orgName` is falsy. In a real app build, Felgo sets it before `Main.qml` even loads — so
`settingsLocationOverride` returns `""` on every real invocation, unconditionally. There's no
runtime flag or stage check gating this; it's structurally impossible for a real launch to take the
temp-file branch. This is a real behavioral change to production persistence code (the file this
function lives in is loaded by the real app too — it's not a test-only shim in a test-only
location), but the branch that changes anything only executes where `Application.organization` is
empty, which never happens outside `qmltestrunner` or a similarly-init-skipping harness.

**One file, not one per store**: the override path is the same literal filename regardless of which
store calls it — mirrors production, where every `Settings` block using this pattern already shares
ONE default-resolved QSettings file, differentiated only by each block's own `category`. Splitting
it per-store under test would test a file layout that doesn't match production.

**The regression test that actually proves the fix, not just documents it**:
`tst_OutboxStore.qml`'s `test_persists_and_reloads_via_settings_across_a_simulated_relaunch` —
can't literally destroy/reconstruct a `pragma Singleton` within one `qmltestrunner` process, so
"relaunch" is simulated by wiping only the in-memory `items` (`OutboxStore.items = []`) while
leaving the persisted `_settings.itemsJson` untouched, then calling `OutboxStore._load()` directly —
the same function `Component.onCompleted` calls on a real launch. Without the fix, this test would
fail (`pendingCount` comes back `0`, not `1`) because the write never reached a real file in the
first place — this is the concrete, executable difference between "fixed" and "still broken", not
just a warning going away.

**Scope, final state**: all six stores using this pattern are fixed — `AuthStore`, `OutboxStore`
first (Taher's original decision), then `OrdersStore`, `PartyStore`, `CategoryStore`,
`OrderChannelStore` (Taher: "cover all", 2026-08-17) after grepping `qml/model/*.qml` for the same
`Settings {` pattern turned up four more instances the original gap-list item didn't name.
`PartyStore`/`CategoryStore`/`OrderChannelStore` also got comprehensive new test coverage
(`tst_PartyStore.qml` fully complete — no Firestore calls in that store at all;
`tst_CategoryStore.qml`/`tst_OrderChannelStore.qml` complete for every local/synchronous path,
excluding the actual `FirebaseService` network callbacks, which have no mock layer available to QML
singletons anywhere in this codebase). `OrdersStore`'s own broader test-coverage gap (764 lines, 27
functions, 4 already covered elsewhere) is separate, larger, unscoped work — not yet started.

**Correction, 2026-08-18 (second) — the `location` rename (commit `4d8c5aa`) missed one caller.**
That commit renamed `SettingsPath.js`'s exported function and updated all six stores' `Settings`
blocks plus this doc, but not `tests/tst_SettingsPath.qml` — the one file that unit-tests the helper
function directly rather than through a store. All four of its test functions still called
`SettingsPath.settingsFileNameOverride(...)`, which no longer exists post-rename. Found by grepping
the whole tree for the old name (not from a CI log — GitHub's raw job logs and artifact downloads
both redirect to `*.blob.core.windows.net`, outside this sandbox's egress allowlist, so the actual
CI failure text for this run was never directly readable) and confirmed deterministically via the
same `node`-vm harness this skill has used throughout: calling the old name against the renamed
module throws `TypeError: ... is not a function`. Fixed by updating the six call sites in
`tests/tst_SettingsPath.qml` to `settingsLocationOverride`, no other change. Lesson, stated plainly:
a rename's completeness has to be checked with a repo-wide grep for the old name, every time — "I
updated the callers I remembered" is not the same claim as "I updated every caller," and the second
one is the only one that's actually true after a rename.

## Skill 42: Returns/analysis-revenue bug — a rebuild of `order.products` silently dropped `consumption[]` on ANY save, not just edits

**Files**: `qml/pages/OrderDetailDialog.qml` (`_save`), `qml/helper/OrderAdjust.js`
(`reconcileConsumptionOnSave`), `qml/model/OrdersStore.qml` (`updateOrder`, `_normalizeOrder`),
`qml/helper/RealisedMath.js` (`byDimension`, `totals`), `tests/tst_ReconcileConsumptionOnSave.qml`,
`tests/tst_OrderMetadataEditPreservesConsumption.qml`, `test/e2e/tst_ReturnAfterMetadataEditE2E.qml`

Found by Taher 2026-08-19: complete an order with one item, return the item — Order and Inventory
pages show the return correctly, every Sales Analysis tab updates correctly *except* Revenue and
Profit, which stay exactly where they were before the return. Same stale numbers in the exported
XLSX. Static tracing of the entire return pipeline (`ConfirmReturnSheet` -> `_tryAdjustOrder` ->
`TransactionStore.recordReturn` -> `RealisedMath.byDimension`/`totals` -> the `InventoryStore`
wrappers both the hero display and export call) read correct on paper, and a Node.js `vm` harness
replaying the exact repro through the actual math files netted revenue and profit to 0 as expected
- the pure math wasn't the bug. Root cause only surfaced from Taher's device logs (temporary
`console.log` instrumentation, one build/run cycle): for the specific order that failed, its line's
`consumption` array - the FIFO batch lineage stamped at completion - was already `[]` *before* the
return even started.

**Root cause**: `OrderDetailDialog._save()` rebuilds a `prods` array from the dialog's editable
`products` ListModel - a ListModel that never carries `consumption` at all, because it isn't a
user-editable field (nothing in the UI shows or edits FIFO batch lineage). For a **completed** order
whose lines are unchanged (`linesChanged === false` - the branch that runs for ANY metadata-only
edit: customer name, email, phone, status, channel, staff - nothing that touches quantity/price/
discount), `_save()` falls straight through to `logic.updateOrder(orderId, {..., products: prods,
...})`. `OrdersStore.updateOrder` does a full, unconditional `o.products = fields.products` - no
merge, no per-field patch - so any save from this dialog on a completed order silently wiped
`consumption` off every line, even a save triggered by nothing more than fixing a typo in the
customer's name.

The reason this stayed invisible until an actual return: `RealisedMath.byDimension`/`totals` need a
non-empty `consumption[]` to attribute a sale or return event's revenue/profit to any dimension -
the per-row split is driven by `qtyConsumed` fractions of the stamped line total. With
`consumption: []`, the row loop never runs and the event contributes **nothing**, silently, no error.
`TransactionStore.bucketsFor` (backs Sold/Purchased) doesn't touch `consumption` at all - it just
nets `quantity` - which is exactly why those tabs, and the Order/Inventory pages (neither of which
reads `consumption` for their own status display), stayed correct while only Revenue/Profit went
wrong. The bug was dormant on the *original sale* too (completion always writes `consumption`
correctly - this class of bug only fires on a LATER save) - it only became visible on a return,
because a return is the only thing that reads `consumption` back out of the order to reverse it.

**Same bug class, different site than the existing "preserve consumption[] on adjusted lines" fix**
(referenced in `docs/superpowers/KNOWN-ISSUES.md`'s cross-period-netting entry) - that one covers the
`_tryAdjustOrder`/quantity-and-price adjustment path, which derives `consumption` correctly on its
own and was never at risk here. This is the OTHER save path in the same dialog: the plain-metadata-
edit branch, which has no adjustment math at all and simply forwards whatever `prods` it built.

**The fix**: `OrderAdjust.reconcileConsumptionOnSave(newLines, originalLines)` - a small, pure,
`.pragma library` function (matches `diffLines`/`restorePlan`'s existing shape in the same file) that
merges each surviving line's *original* `consumption[]` back in by `productId` (falling back to
`name`, same invariant `diffLines` already uses) before the array is sent to `updateOrder`. Wired
into `OrderDetailDialog._save()` **only** on the plain-`updateOrder` branch - deliberately left the
`adjustRequested`/adjust-path branch untouched, since `_tryAdjustOrder` already derives consumption
correctly there and touching it would have been unnecessary blast radius for a bug that only exists
in the metadata-only-edit branch.

**The general rule**: any place that rebuilds an `order.products`-shaped array from UI/editable state
and then does a *full replace* write (as opposed to a per-field patch) has to explicitly carry
forward every field the UI state doesn't represent - `consumption` here, matching the exact same
class of bug as `InventoryStore._clone()`'s field whitelist (Key structural discoveries, top of this
doc). `grep -rn "products:\s" qml/model/DataModel.qml` is the fast way to audit every call site that
sends a `products` field through `updateOrder`; each one needs to either derive `consumption` itself
(`_tryCompleteOrder`, `_tryAdjustOrder` - do) or explicitly preserve it from the original
(`OrderDetailDialog._save()` - now does, via this fix). A field that isn't shown or edited in a form
is the easiest one to forget when that form's save path does a full-object rebuild - the rebuild
itself is the risk, not the specific field.

**Left alone, not audited here**: `DataModel.adjustOrderForImport` (the import-correction twin of
`_tryAdjustOrder`) wasn't checked for the same pattern - different function, different caller,
outside Taher's reported repro. Worth the same grep if an import-correction path ever shows the same
symptom.

**Addendum, first real CI run (2026-08-21):** the initial version of
`tests/tst_OrderMetadataEditPreservesConsumption.qml`'s negative/characterization test assumed
`OrdersStore._normalizeOrder`'s consumption-coercion (`Array.isArray(p.consumption) ? p.consumption :
[]`) applies to whatever ends up in LOCAL state after `updateOrder`. It doesn't:
`OrdersStore._commit(arr, changedOrder, ...)` does `orders = arr` - the raw cloned array, mutated
directly (`arr[idx] = o`) - and only passes the SEPARATE `_normalizeOrder(o)` result to
`Gateway.recordMutation` for the outbound Firestore write. So local state and the outbound payload
can genuinely diverge: skip `reconcileConsumptionOnSave` and the LOCAL order carries
`consumption: undefined` on a line, while Firestore would get `consumption: []`. This never surfaced
as a crash because every downstream reader (`_tryAdjustOrder`'s
`Array.isArray(line.consumption) ? line.consumption : []` guard) already tolerates `undefined`
defensively - which is itself worth remembering: reading `_normalizeOrder`'s behavior tells you what
gets WRITTEN to Firestore, not what's readable from `OrdersStore.getById()` a moment later. The real
qmltestrunner CI run caught this wrong assumption on the first attempt (499/500 passed, the one
failure was this test, not the fix) - a genuine case of "written to convention, not run in this
sandbox" catching a real gap once it actually ran.

## Skill 43: Dropped-field response contract — a client parser and a server response builder that never got diffed against each other

**Symptom**: `test/e2e/tst_OrdersStoreE2E.qml`'s
`test_two_users_editing_the_same_order_produces_a_real_conflict` failed identically across 8
debugging rounds (full trail: `CHECKPOINT.md`, "E2E testing phase 2 followup") -
`Gateway.mutationConflicted` never fired, `tryVerify`/its later manual-poll replacement always timed
out. Eight rounds ruled out wrong URL, empty/wrong token, parameter-order mismatch, heavy-test
adjacency, date-handling, env/database routing, raw-POST-vs-Gateway-path, request-never-reaching-
the-server, server crash, server hang, and the CAS logic itself - all with real evidence, all correct
eliminations. None of them found the actual bug.

**Root cause**: `functions/lib/gatewayLogic.js`'s `applyMutation` computes a CAS conflict correctly -
`{ ok: false, status: 409, conflict: true, current }` - well covered by
`functions/test/gatewayLogic.test.js`. But `functions/index.js:155` (the actual HTTP handler that
turns that result into a response body) forwarded `current` and reconstructed everything else by
hand, dropping `result.conflict` and substituting an unrelated `error: "conflict"` string. The 409
arrived at the client, parsed as valid JSON, and `Gateway.qml`'s `_parseMutationConflict` - which
checks specifically for `body.conflict !== true` - still returned `isConflict: false` every time,
because the one field it depends on was never actually on the wire. The mutation fell into the
generic retry/backoff path with a permanently-stale `before`, rejected identically forever - which
is exactly the "identical failure every round" symptom that made this look like a transport/timing
problem rather than a data-shape one.

**Why 8 rounds missed it, and why the unit tests didn't catch it either**: `_parseMutationConflict`
had unit coverage (`tests/tst_Gateway.qml`) - but the test's fixture was `{ ok: false, status: 409,
conflict: true, current }`, which is `gatewayLogic.js`'s *internal result object* shape, not the
actual serialized HTTP body `functions/index.js` sends. The two shapes are close enough to look
interchangeable at a glance and different enough that one has the field the parser needs and the
other doesn't. The batch-mutation path (`_parseBatchMutationConflict` / `applyMutationsBatch`'s 409
body) uses a different, internally-consistent shape that happens to line up correctly, which is part
of why grepping either single-mutation file in isolation looked fine - the break only shows up by
holding the client parser and the server response builder side by side, line by line, which none of
the 8 rounds (reasoning about transport/timing/environment) nor the original test-authoring session
(reasoning about `gatewayLogic.js`'s return value, not the HTTP layer's re-serialization of it) did.

**Fixed**: `functions/index.js:155` now forwards `conflict: result.conflict === true` alongside the
existing `error`/`current` fields - additive, no removal, doesn't touch the batch path. Chose
`result.conflict === true` over a hardcoded `true` so this stays correct if `applyMutation` ever
grows a second, non-conflict `ok:false` branch (currently it has exactly one). Fixed the QML unit
test's fixture to match the real wire shape, and added a regression test pinned to the literal
pre-fix body, documenting the actual failure mode rather than an idealized one.

**Real production impact, not just a test artifact**: `mutationConflicted` is connected by five
production stores - `OrdersStore`, `InventoryStore`, `StaffStore`, `SupplierStore`,
`StockBatchStore` - each with its own correctly-written reconciliation handler. Every one of those
handlers has been unreachable in practice since this shipped: a real user hitting a genuine CAS
conflict on any of those five entities would have had their conflicting write silently retried
forever against a permanently-stale snapshot, with no reconciliation and no user-visible signal,
rather than hitting the Component 3 backstop that was specifically built to catch this. Not
confirmed to have caused a real support ticket, but the code path existed with zero live coverage
until this fix.

**General principle**: when a value crosses a serialization boundary (an internal result object -> a
hand-built HTTP response body -> a client-side parser reading specific field names), a passing unit
test on either side of that boundary proves nothing about the boundary itself unless one side's
fixture is actually derived from - or diffed against - the other side's real output. Two files that
each look internally consistent can still disagree with each other. When a bug reproduces
identically across many attempts with a fully-parseable, correctly-arriving response, treat "the two
ends might be using different field names for the same concept" as a first-class hypothesis, not a
last resort after transport/timing theories are exhausted.

**Correction (2026-08-24, eleventh round)**: this bug is real and the fix is real, but it was NOT
the cause of `tst_OrdersStoreE2E.qml`'s conflict-test failure. A fresh CI run against the fix commit
failed identically. The tell was in evidence already on record: the client-side failure log reads
`recordMutation failed 0`, not `recordMutation failed 409` -- `xhr.status` is literally `0`, meaning
no response ever arrived at all, which makes a dropped-field-inside-a-parsed-body theory impossible
regardless of how well it explains everything else. See Skill 44.

## Skill 44: A fix that explains every symptom except the one status code is still the wrong fix

**What happened**: Skill 43's diagnosis fit almost everything about
`test_two_users_editing_the_same_order_produces_a_real_conflict`'s failure -- server completes
normally, CAS correctly rejects, `mutationConflicted` never fires, identical failure every retry.
The one piece of evidence it never squared against itself was already sitting in `CHECKPOINT.md`
from four rounds earlier: `xhr.status` on every failing attempt is `0`, not `409`, with an empty
`responseText`. A theory built on "the 409 arrives but is misparsed" cannot be reconciled with
"no response arrives at all" -- those are mutually exclusive, not two framings of the same fact. The
fix got implemented, tested (with a unit test that, correctly, tests the parser logic in isolation
and says nothing about whether a real 409 ever reaches it), and pushed, before that contradiction got
checked.

**The general lesson**: a diagnosis that produces a clean narrative explaining most of the symptoms
is not the same as a diagnosis that's been checked against literally all of them, especially the
most specific, most mechanical piece of evidence available (an exact status code, an exact byte
count, an exact error string) -- those are cheap to check and disproportionately likely to falsify a
theory that otherwise "reads" correctly. Before implementing a fix for a bug with an existing
diagnostic trail, re-derive the trail's own most concrete data points and confirm the new theory is
compatible with each one, not just consistent with the trail's prose summary of itself. This is the
same failure class the whole `test/e2e` debugging trail already teaches (Skills 40/42/43) from a
different angle: prose summaries compress away the detail that falsifies a plausible-looking theory,
and the fix is always to go back to the primary evidence, not the summary of it -- including your
own summary, written two paragraphs ago in the same document.

## Skill 45: QTBUG-49896 — QML's XMLHttpRequest can lose `status` (reset to 0) at the readyState 3->4 transition

**What happened**: `test_two_users_editing_the_same_order_produces_a_real_conflict` failed
identically across 13 rounds. Rounds 1-11 exhausted server-side theories (transport, timing, dropped
response fields, serialization) with real evidence, including two working repros (Skill 43/44's
writeup) that proved the server sends a completely clean 409. Round 12 added `xhr.statusText` and
header logging — still no answer on its own, but it captured something new: a partial header
(`x-powered-by: Express?`, cut off immediately after) that proved a response really had started
arriving, rather than nothing at all. That reopened the question productively instead of settling for
"transport failure, cause unknown."

**Root cause**: [QTBUG-49896](https://bugreports.qt.io/browse/QTBUG-49896) — QML's
`XMLHttpRequest` implementation can lose `xhr.status` (reset to `0`) during the readyState 3->4
(LOADING -> DONE) transition, for certain {HTTP method, response status} combinations. Unresolved,
no fix version. The original reporter's own minimal repro used a **409** response and observed
`status: 409` correctly at readyState 2 and 3, `status: 0` at readyState 4 — the exact status code
and exact transition this codebase's CAS-conflict path hits. A real, longstanding Qt engine bug, not
anything in this codebase.

**How it was found**: a targeted web search once the evidence was specific enough to search for —
"the client receives real response headers but ends up with status 0 specifically for a 409" is a
search-able signature; "recordMutation intermittently fails" is not. The lesson isn't "search
earlier" in general (most of rounds 1-11's server-side elimination was necessary and correctly done
via code reading and real repros, not guessable via search) — it's that once evidence narrows to
something with a *specific, unusual shape* (an exact status code, an exact protocol-level symptom),
that shape is often exactly what an external tool's bug tracker would also describe, and is worth
searching verbatim rather than continuing to reason from this codebase's logs alone.

**Fixed**: not a server change (the server was already proven clean) — a client-side workaround.
`_captureBeforeStatusIsLost(xhr, snapshot)` in `qml/model/Gateway.qml` snapshots status/responseText/
headers at HEADERS_RECEIVED/LOADING, before DONE's potential loss, and every one of the file's five
XHR call sites falls back to that snapshot via an `effStatus`/`effResponseText` pair. All five call
sites had the identical vulnerable pattern — this bug isn't specific to conflict responses or to
`recordMutation`; it can hit any non-2xx response from any of them.

**Discipline point**: every failure log now prints the raw (possibly-lost) status *and* the effective
(recovered) one side by side, specifically so the next real run can confirm or refute this rather than
taking it on faith. Thirteen rounds in, a plausible-sounding root cause with strong circumstantial
support (Skill 44's own lesson) still isn't the same as a confirmed one until a real run says so.

## Skill 46: Testing a real firebase-functions v2 HTTPS handler without a live emulator

**Problem**: `functions/index.js`'s exported HTTPS handlers (`recordMutation`, `recordDelta`,
`recordMutationsBatch`, etc.) had zero direct test coverage — only `functions/lib/*.js`'s pure logic
was tested. That untested seam is exactly where Skill 43's bug lived: a value computed correctly one
function down, silently dropped when the HTTP response got built by hand. No live Firebase emulator
is available in this environment (or in most quick local iteration) to test against.

**Approach that works**: `functions.onRequest(opts, handler)`'s exported result is directly callable
as `(req, res) => {...}` — confirmed by actually invoking it through the real
`@google-cloud/functions-framework` CLI (Skill 45's investigation). This means the real handler can
be tested directly, with two things mocked:

1. **`firebase-admin` / `firebase-admin/firestore`, and any local `./lib/*.js` dependency you want
   to stub** — inject fakes into Node's `require.cache` (keyed by each dependency's *resolved
   absolute path*, via `require.resolve(...)`) *before* requiring `index.js`. Since `index.js` calls
   `admin.initializeApp()` at module load time, the mock must be in place first. This works
   identically across Node versions (unlike `node:test`'s newer `mock.module()`), and needs no
   changes to `index.js` itself.
2. **`req`/`res`** — use `node-mocks-http` rather than hand-rolling a mock response object.
   firebase-functions v2's wrapper does more than a thin passthrough (it runs `cors` middleware and
   waits on the response stream's real `'finish'` event before resolving) — a hand-rolled mock either
   needs to be a real `EventEmitter` emitting `'finish'`, or hits confusing hangs. `node-mocks-http`
   already handles this correctly; not worth re-deriving.

**What to mock vs. what to keep real**: mock the *data-touching* functions from `lib/gatewayLogic.js`/
`lib/batchMutationLogic.js` (`applyMutation`, `applyDelta`, `applyMutationsBatch`) so tests can inject
canned results including the exact conflict shape (`{ conflict: true, current: {...} }`) — but keep
the *pure* functions from those same modules real (`parseBearerToken`, `validateMutationRequest`,
etc.), since those already have their own dedicated test files and re-mocking them would just
duplicate that coverage while hiding real validation bugs. The goal is testing `index.js`'s own logic
(auth, `deriveContext`, and — the one that matters — translating a `lib/` result into an HTTP
response), not re-testing `lib/`'s own correctness.

**One thing not worth chasing**: an OPTIONS-preflight test hung indefinitely — `cors` middleware
intercepts and completes OPTIONS requests itself, and `node-mocks-http`'s mock doesn't reliably
propagate that middleware's own completion path to a resolved promise. Since OPTIONS handling here is
unmodified `cors` package behavior, not this codebase's own logic, it wasn't worth fighting that
mock/middleware interaction for — dropped, with a comment explaining why, rather than either silently
omitted or endlessly debugged.

## Skill 47: Reviewing `pr_taher_bug_fixes` — a `_clone()`/create-payload drift, a SKU-clobber, and an export column shift

**Files**: `qml/model/InventoryStore.qml` (`_newProductDoc()` new, `_idSuffixNumber()` new,
`generateSku()`, `_upsertManySync()`), `qml/helper/StockSnapshotMath.js` (new),
`qml/pages/SalesPage.qml`, `qml/pages/OrderDetailDialog.qml`,
`tests/tst_InventoryStore_cloneSymmetry.qml` (new), `tests/tst_InventoryStore_upsertMany.qml`
(new), `tests/tst_StockSnapshotMath.qml` (new).

**Context**: Taher had already pushed 8 commits to `pr_taher_bug_fixes` (branched off `main` @
`bc0a8fb`) fixing real bugs in bulk-import SKU generation, the inventory search field, an order-
history display, and an analysis export. The PR's CI showed QML/Functions/Firestore-Rules Tests
green but **E2E Tests failing**; none of the eight commits added a single test. This session's job
was to find why E2E failed and cover the untested surface — not to re-litigate the eight fixes
themselves, most of which were correct.

**Bug 1 (the actual CI failure) — `_clone()`/create-payload drift, same failure class as Skill 20-
ish's OrdersStore incident** (see `tests/tst_OrdersStore_normalization.qml`'s own header comment for
that precedent). One of the eight commits added `supplierId` to `InventoryStore._clone()`'s field
whitelist — correctly, it's needed so the bulk-import/overwrite path can carry it — but never added
it to `addProduct()`'s create payload. `functions/lib/gatewayLogic.js`'s CAS check (`_deepEqual`)
bails out on `aKeys.length !== bKeys.length` before comparing a single value, so: create a product
via `addProduct()` (doc has no `supplierId` key) → any later edit reads it back through `_clone()`
first (`updateProduct`/`deleteProduct` both start with `var arr = _clone()`) → that clone now carries
`supplierId: ""`, a key the real Firestore doc doesn't have → key-count mismatch → false 409
conflict. `test/e2e/tst_InventoryE2E.qml`'s `test_updateProduct_persists_to_emulator` and
`test_deleteProduct_removes_from_emulator` both create-then-touch-again, which is exactly this.
Confirmed against the actual GitHub Checks API (`gh`/`curl` weren't available; used
`api.github.com/repos/.../commits/{sha}/check-runs` directly with a session PAT) rather than
guessed — QML/Functions/Firestore-Rules all green, only E2E red, matching this theory exactly (a
CAS/emulator-only failure mode, invisible to the offline QML unit suite).

**Fix**: extracted `addProduct`'s doc-building into `_newProductDoc()` — a pure function (no async
args; `id`/`supplierId` are already-resolved values by the time `addProduct` calls it) — and added
`supplierId` there. Deliberately **not** the full `_normalizeOrder`-style unification OrdersStore
uses (one canonical shape function called by every path, including bulk-import) — `_normalizeRecord`
(bulk-import's own doc-builder) still independently duplicates this shape and has to be checked by
hand against `_newProductDoc`/`_clone()` if any of the three changes. Flagged to Taher as a
trade-off (smaller/faster fix now vs. the structurally-safer unification as a follow-up), not
decided unilaterally. `tests/tst_InventoryStore_cloneSymmetry.qml` locks the fields-match invariant
down directly (`Object.keys(_newProductDoc(...))` vs `Object.keys(_clone()[0])`) instead of by
inspection, mirroring `tst_OrdersStore_normalization.qml`'s approach for the same bug class.

**Bug 2 — SKU clobber on overwrite**: `_upsertManySync`'s "overwrite" branch (existing product,
matched by `productId`) generated a brand-new SKU whenever the imported row's `sku` column was
blank — but a blank `sku` on an *overwrite* row just means the CSV round-trip didn't carry that
column, not that the product's real SKU should be replaced; `updateProduct`'s merge only skips
`undefined` fields, so the synthetic SKU silently overwrote the real one every time. New-row/rename
are correct to generate fresh (nothing to preserve there). Fixed to prefer
`arr[existingIdx].sku`, only falling back to `generateSku()` if the stored product itself also has
none (legacy-data edge case). `tests/tst_InventoryStore_upsertMany.qml` covers this plus the
original generate-unique-SKU-per-batch fix directly (calling `_upsertManySync`/`generateSku` with
stub `pullProductId`/`resolveSupplierForRecord` functions — both already plain synchronous
functions by design, so no Gateway/network mocking needed for the overwrite-only scenarios).

**Bug 3 — `SalesPage.qml`'s stock-snapshot export column shift**: one of the eight commits added a
leading "Product ID" column plus three trailing ones (Cost Price/Selling Price/Tax%) to
`snapHeaders` without updating every `snapRows.push(...)` to match — the non-supplier-view data row
kept its old field count against the new header, shifting every value one column left (Name lands
under "Product ID", ..., Status ends up blank), and both views' Total rows were short several
trailing columns. `src/XlsxService.cpp`'s `renderAnalysisSections()` loops
`col < headers.size() && col < line.size()`, so this never crashes or fails anything — it just
silently writes a wrong spreadsheet. Nothing caught it because nothing tested it: `SalesPage.qml` is
a UI page, not unit-tested under this project's existing convention (`tests/` only covers
`.pragma library` helpers — see the Testing & QA Agent section of `AGENTS.md`). Fix: extracted the
row/column shaping (not the `qsTr()` headers, not the `TransactionStore`/`SupplierStore` lookups —
just the pure array-building) into `qml/helper/StockSnapshotMath.js`, following the exact
`ImportMath.js`/`OrderMath.js` pattern this codebase already uses for testable pure logic, rather
than either leaving it untestable in-page or over-extracting the whole export function (which would
have dragged in translation-context and singleton-mocking complexity for no real benefit — the bug
was purely in the array shaping, not the lookups). `tests/tst_StockSnapshotMath.qml` asserts
row/header column-count parity for both `showSup` branches plus the total row, and specifically
locks down "the non-supplier row leads with `productId`" as its own case.

**Sandbox environment note, worth knowing before trusting a "tests pass" claim from a Cloud
session on this repo**: this Cloud sandbox's `apt`-installable Qt is **6.4.2**; CI runs **6.8**.
Concretely, `Settings` moved from `Qt.labs.settings` to `QtCore` partway through Qt 6's life —
`import QtCore; Settings { ... }` (what every store in this app actually uses) fails to compile
under 6.4.2 with `Settings is not a type`, and since one failed-to-compile singleton breaks the
whole `qml/model` qmldir for every file that transitively imports it, this shows up as **14 files
failing at `compile()`** with zero relation to whatever the actual diff touches (confirmed
identical on `main` — not something this PR or this session caused). A real `qmltestrunner -input
tests` run in this sandbox will always show that exact 14-file signature as a floor; anything
beyond those 14 is a real signal. To verify new/changed test files anyway without waiting for CI,
this session did the verification in a **throwaway scratch copy only** (`Qt.labs.settings` compat
shim swapped in, `location:` properties stripped — neither change touched the real working tree),
confirmed **498 passed, 0 failed** across the whole suite there, then discarded the scratch copy.
Don't "fix" the real `AuthStore.qml`/etc. for this — they're already correct for Qt 6.8; the gap is
this sandbox's Qt version, not the code.

## Skill 48: Consolidating scattered test plans into `docs/superpowers/test-plans/`, and the `pr_taher_bug_fixes` test plan

**Files**: `docs/superpowers/test-plans/` (new folder, 9 files moved into it via `git mv` + 1 new
one), `docs/superpowers/test-plans/README.md` (new — the combined index), plus every file that
referenced a moved path by name (`docs/superpowers/plans/2026-07-10-product-tax-export-size-
field.md`, `.../2026-07-11-product-adjustment-reason.md`, and four files under `specs/` —
`2026-08-11-ledger-sync-race-CHECKPOINT.md`, `2026-07-10-product-tax-export-size-field-
CHECKPOINT.md`, `2026-07-10-product-tax-export-size-field-design.md`,
`2026-08-08-review-round2-design.md`, `2026-07-29-async-write-sequencing-design.md`). Also 2 new
test cases in `tests/tst_InventoryStore_upsertMany.qml` (found missing while writing the test
plan below — see the last paragraph).

**The mess, found by grep**: before this session, "test plan" documents existed in three
different places — `docs/superpowers/` root (3 on-device manual checklists), `docs/superpowers/
specs/` (6 automated-coverage plans, interleaved with unrelated design docs and session
checkpoints), and 2 more `docs/superpowers/plans/` design docs that have a test-plan *section*
inline rather than being standalone plans (those two were left where they are — a design doc
with an embedded test-plan section isn't the same artifact as a standalone plan file, and moving
it would separate the plan from the design decisions it's testing). Nothing indicated which of
the 9 standalone files was current for a given feature versus superseded by a later one for the
same feature — e.g. `2026-07-14-test-plan.md` says outright, in its own addendum, "don't treat
this document as complete on its own anymore," but you'd only find that by opening it.

**The fix**: one new folder, `docs/superpowers/test-plans/`, holding all 9 standalone plans
(moved with `git mv`, preserving blame/history) plus a `README.md` that indexes every one of them
newest-first with its branch/feature, a one-line description of what kind of coverage it actually
represents (automated-and-run / automated-but-unverified-in-that-session / on-device-only), and an
explicit "chains" section calling out the two multi-part sequences (`2026-07-14` →
`2026-07-17-part2` for order-import-stock; `2026-07-29` → `2026-08-08-in-detail` →
`2026-08-08-review-round2` for async-write-sequencing) so a reader doesn't stop at the first file
in a chain and miss that it's out of date. Every file elsewhere in the repo that referenced one of
the 9 by its old path was grepped for and updated — checked afterward with the same grep pattern
returning zero hits, not just assumed clean after one pass.

**The new `pr_taher_bug_fixes` test plan** (`2026-08-22-pr_taher_bug_fixes-test-plan.md`, the first
plan seeded directly into the new folder) follows the same three-tier structure
`2026-08-08-review-round2-test-plan.md` established: what's genuinely been run (25 new cases, via
the Skill 42 scratch-copy workaround — 531/531 passing), what a real Qt 6.8 + Firebase emulator CI
run will confirm that this sandbox structurally cannot (the actual E2E tests that failed pre-fix),
and what has zero automated coverage with a static trace instead (`InventoryPage.qml`'s two UI-page
changes, `OrderDetailDialog.qml`'s dialog text, and `XlsxService.cpp`'s order-channel column — this
last one re-checked specifically for the same "inserted column, index shift not fully propagated"
bug class as Bug 3, and found to have been done correctly and completely, unlike the SalesPage bug).

**Writing this plan surfaced a real, cheap-to-close gap in the prior session's own tests**: the
`rename` and `skip` branches of `_upsertManySync`'s conflict-policy dispatch had no direct test at
all, even though `rename` is exactly what `e571ed3` (one of the three bugs Skill 42 fixed) touches.
Closed immediately rather than just noted — `tests/tst_InventoryStore_upsertMany.qml` gained
`test_rename_policy_with_blank_sku_generates_a_fresh_unique_sku`,
`test_rename_policy_with_provided_sku_gets_a_renamed_suffix_not_a_fresh_one` (asserts the rename
path calls `ImportMath.renameSku`, not `generateSku`, for a row that already has a sku — a
distinction the code gets right but nothing previously pinned down), and
`test_skip_policy_leaves_the_existing_product_untouched`. Caught a real mistake writing the second
of these: an `str_replace` edit dropped the `TestCase {}` block's own closing brace, and the
scratch-copy run (which this session runs before ever claiming "done," not after) caught it
immediately as a compile error rather than a silent no-op test file — the fix was one line, but the
catch is the point: static review of a diff doesn't substitute for actually running it, even for a
change that "obviously" just adds test functions.

## Skill 49: Standard test plan structure (Taher's convention) — UT / Regression / E2E, then an on-device plan with 5 fixed sections

**Files**: `docs/superpowers/test-plans/2026-08-22-pr_taher_bug_fixes-test-plan.md` (restructured
to this format), memory edit #9 (records the convention for future sessions).

**The convention, stated once so it doesn't have to be re-derived each time**: every test plan
going forward opens with three sections listing what's already covered by a test that's genuinely
been *run* — Unit Tests, Regression Tests, and E2E — each as its own section, not folded together.
Unit and regression are a real distinction worth keeping separate even when the same test file
holds both kinds: a unit test checks a piece of logic is correct on its own terms (would exist even
if nothing had ever broken); a regression test exists *because* something broke, and pins down the
specific defect. The same file can have both — `tst_InventoryStore_upsertMany.qml` has 6 unit cases
and 3 regression cases — and conflating them loses the "why does this test exist" information a
reviewer actually wants. After those three sections, a separate **On-Device Test Plan** follows
with five fixed sections regardless of feature: Happy Path, Negative, Edge Cases, Affected Areas,
Regression Tests. "Affected Areas" is where a file-by-file coverage table belongs (what used to be
called a "gap list" in earlier plans in this folder) — every file the change touches, whether it
has automated coverage, and where to look on-device if it doesn't. The on-device "Regression Tests"
section is the manual-click-through counterpart to the automated regression section above it, not
a duplicate of it — same bugs, phrased as "how would you notice if this came back" rather than as
assertions.

**A miscounted claim, found and fixed while doing this restructure**: the `pr_taher_bug_fixes`
test plan had been asserting "31 new cases" since it was first written, repeated verbatim into this
folder's `README.md` and into Skill 47's own write-up. Actually counting each file's
`function test_...` declarations (`grep -oE "function test_[a-zA-Z0-9_]+" tests/tst_*.qml`) instead
of trusting the carried-forward number: 4 + 9 + 12 = **25**, not 31. All three places corrected in
the same pass as the restructure — a wrong number copied three times isn't three independent
confirmations of it, it's one mistake with three symptoms. Recounting a real artifact (test
functions in a file) is cheap; re-asserting a remembered number is not the same as checking it.

## Skill 50: Converting a sync id-minter to async without touching its bulk-import loop's actual shape

**What happened**: `docs/superpowers/E2E-TESTING-ROADMAP.md` left `StockBatchStore._nextBatchId()`'s
async conversion "blocked on a decision, not effort" — the doc's own estimate was that Option A
(full parity with Staff/Supplier's real Firestore counter) forces "a real change to a working,
sensitive bulk-import feature, unrelated to anything else in this effort," and leaned toward Option B
(retry-on-conflict, no `addBatch()` contract change) for that reason. Taher's instruction named
Option A explicitly.

**What reading the code first found**: `InventoryStore.upsertMany` already solves this exact shape of
problem — reserve N ids in one round-trip before a synchronous loop runs — twice over, for products
and for suppliers, via `FirebaseService.mintCounterBatch` plus a pre-scan and a `pullXId()` closure.
`SupplierStore` already has the exact sync/async split this needed: `addSupplier()` (async, mints its
own id, one-at-a-time UI use) vs. `addSupplierWithId()`/`addSupplierWithIdMany()` (sync, given a
pre-reserved id, bulk-import use). Converting `StockBatchStore.addBatch()` to async and adding
`addBatchWithId()` for the bulk path isn't novel restructuring of the loop — it's adding a *third*
reservation of a shape the file already has twice, using a split the codebase already has a working
precedent for. That's a materially smaller risk than "unrelated restructuring of a sensitive loop."

**The actual lesson**: a roadmap/backlog entry's own risk estimate is itself a claim worth re-checking
against the current code before treating it as settled, not just before implementing the option it
didn't recommend. The entry wasn't wrong given what was known when it was written; it was written
before anyone had traced exactly how much of the target shape (reserve-then-loop, sync/async split)
the file already had. "The doc says this is risky" and "reading the code says this is risky" turned
out to be different findings — worth stating that difference honestly rather than either silently
overriding the doc's framing or silently deferring to it without re-checking.

**Fixed**: `StockBatchStore.nextBatchId(callback)` mints off a real, **year-scoped**
(`counters/stockBatches-<year>`) Firestore counter — year-scoped specifically because `BAT-<year>-NNN`
resets every year by existing design, and a single global counter (like `counters/suppliers`) would
silently break that contract. `addBatch()` is now async; `addBatchWithId()` (sync, pre-reserved id)
handles the bulk-import path. `upsertMany`'s pre-scan gained `neededBatchIds`, computed by a newly
extracted pure helper (`_scanUpsertManyNeeds`) specifically so the one genuinely new,
correctness-critical piece — does the reserved range size match what the loop actually consumes? — is
unit-testable without a live emulator, rather than buried where only an E2E run could ever catch an
off-by-one. See `docs/superpowers/specs/2026-08-27-async-stock-batch-id-minting-design.md` for the
full design.

## Skill 51: A sync-to-async conversion didn't create a bug — it surfaced one a coincidence was hiding

**What happened**: first real CI run after Skill 50's change failed 2 tests.
`InventoryStore_upsertMany::test_scan_sums_batch_ids_across_multiple_qualifying_rows` (Actual 3,
Expected 2) was simply my own new test's expected value being wrong — I'd miscounted, forgetting a
zero-stock new row still needs a product id (only the *batch* id is stock-gated). Fixed the test.

The other, `DataModel_adjustOrderSyncGuard::test_proceeds_normally_once_transaction_history_is_synced`
(Actual 3, Expected 4, missing exactly the `stock_batch` mutation), was worth tracing all the way
through rather than patching the count. Full trace: test → `DataModel._tryAdjustOrder` →
`StockBatchStore.restoreFifo("B1", "SKU-1", 1)` → `getById("B1")`. This test's `init()` never seeded
`StockBatchStore.batches` — `getById` has *always* returned `null` here, so `restoreFifo` has always
fallen through to `topUpOldest`'s synthetic-batch-creation fallback, never the normal existing-batch
`recordDelta` path the test's own header comment describes and clearly intends
(`StockBatchStore.restoreFifo -> Gateway.recordDelta("stock_batch", B1, ...)` — naming a direct delta
on an existing batch, not a synthesized one). This was invisible before Skill 50's change only because
`topUpOldest`→`addBatch` used to be fully synchronous (local-array scan) — either code path produced
exactly one `stock_batch` mutation before the test's assertion ran, so the missing fixture never
mattered. Once `addBatch` mints its id over a real network round-trip, the fallback path's mutation
is still in flight when the assertion runs (this is a bare unit test, no Firestore backend) — the
coincidence that made two different code paths look identical stopped holding, and only then did the
gap show up.

**The actual lesson**: when a fix changes timing (sync → async) and a previously-passing test starts
failing on a *count*, the reflex to bump the expected count or add a `tryVerify` wait is a symptom
patch — it doesn't ask *which code path produced the count before*, only whether the new number can be
made to match. Tracing backward through the exact call stack (not just to the failing assertion, but
through every function it called) found that the test was never exercising the path its own comments
say it exercises. The fix is the same size as a symptom patch (one added fixture value) but is a
different fix: it makes the test exercise its actually-documented scenario, and doing so happens to
sidestep the async gap entirely (`recordDelta` on a known id never mints anything, so it stays
synchronous regardless of Skill 50). A stray `tryVerify` would have "fixed" the assertion while leaving
the test silently testing the wrong path (and pointlessly waiting on a mint call that will never
resolve without a real backend, in a file that has none).

**Fixed**: seeded `StockBatchStore.batches` in `tst_DataModel_adjustOrderSyncGuard.qml`'s `init()`
with a batch matching the fixture's own consumption record (`B1`, `SKU-1`, `qtyConsumed: 2`), so
`restoreFifo` takes the path the test already claimed to cover.

## Skill 52: Extending Skill 46's handler-test harness to endpoints with no `lib/` module to mock

**Problem**: `docs/superpowers/E2E-TESTING-ROADMAP.md`'s "explicitly scoped out" backlog item —
handler-level tests for `acquireLock`/`releaseLock`/`provisionMember`/`runCutover`/`computeAnalysis`,
the 5 of 8 `functions/index.js` endpoints `index.handlers.test.js` (Skill 46) deliberately left
uncovered. Two different shapes hid inside one backlog line:

1. **`acquireLock`/`releaseLock`/`runCutover`** delegate their actual Firestore work to a `lib/`
   module (`lockLogic.js`, `cutoverLogic.js`) that already has its own full, passing pure-logic test
   file — exactly Skill 46's `GatewayLogic`/`BatchMutationLogic` shape. Extended the same
   `require.cache`-injection harness to mock `LockLogic.acquireLock`/`releaseLock` and
   `CutoverLogic.deleteCollection`/`zeroInventoryStock` (the Firestore-writing exports), while keeping
   `validateAcquireRequest`/`validateReleaseRequest`/`validateCutoverRequest`/`buildCutoverMarker` real
   — same "mock the seam that's actually untested, not the logic something else already proves" rule
   Skill 46 established.
2. **`provisionMember`/`computeAnalysis`** are a genuinely different shape: their logic (`canAssignRole`,
   `findOrCreateAuthUser`, the provisioning transaction, `readAllPaged`'s pagination, the product/
   supplier/order lookup-map builders) lives directly in `index.js`, in no `lib/` file, with zero
   coverage anywhere before this arc — there's no lower layer to delegate correctness to. These needed
   the harness's Firestore mock itself extended: `db.doc().set()`, `db.runTransaction()` (txn.get/set/
   delete delegating to the same synchronous doc store), and `db.collection().orderBy().limit()
   .startAfter().get()` with real cursor semantics keyed on doc id (matching `readAllPaged`'s own
   `startAfter(lastDoc)` usage) — enough to exercise that logic for real, not stub it out.

**Reused rather than re-derived**: `computeAnalysis`'s revenue/profit path (`RealisedMath.totals`) was
tested with the SAME fixture (`sale_plus_return_nets_down`) `realisedMath.test.js` already trusts,
asserting the endpoint's response matches that fixture's already-proven `expected.totals` — proves
*this endpoint's wiring* (Firestore doc → `readAllPaged` → `RealisedMath`) without re-deriving
`RealisedMath`'s own math a second time in a different file.

**A pagination bug class this harness makes newly testable**: `ANALYSIS_PAGE_SIZE` is 500, and every
other computeAnalysis test fixture fits in a single page — none of them would ever touch the
`startAfter` cursor branch at all. Added one dedicated test seeding 501 synthetic transaction docs,
asserting both that the total count across pages is exactly 501 (no doc dropped or double-counted at
the page boundary) and that `collection().get()` was actually called 2+ times (proving the second page
was fetched, not silently short-circuited). This is the one test in the new file whose absence would
have let a real off-by-one at the pagination boundary ship silently.

**One `require.cache` pattern that does NOT work, and why**: tried swapping
`require.cache[firestorePath].exports.getFirestore` mid-test (after `installMocks()` already ran) to
simulate `provisionMember`'s `db.runTransaction()` failing. Failed with the response still `200`, not
the expected `500`. Root cause: `index.js` does `const { getFirestore } = require("firebase-admin/
firestore")` — a plain destructure — at MODULE LOAD time. That copies the *function reference* into
`index.js`'s own local `const` once; it is not a live binding to `module.exports`, so any later
mutation of `require.cache[...].exports` has zero effect on the reference `index.js` already holds.
This is the same load-order constraint Skill 46 already worked around for `GatewayLogic`/
`BatchMutationLogic` (install the mock into `require.cache` *before* `index.js`'s first `require()`)
— the difference here is a fix attempted *after* that first require, which is exactly the case that
constraint rules out. Fixed properly: added a `mockState.runTransactionError` flag read *inside* the
one `runTransaction` closure `index.js` actually holds a reference to (read live, at call time, from
the shared mutable `mockState` object — the same mechanism every other error-injection flag in this
harness already uses), rather than trying to swap the module out from under an already-bound
reference.

**Two honest, not-fixed findings surfaced by chasing coverage numbers rather than trusting them**:
`index.js`'s `canAssignRole()` has an `else return false` branch (line ~506) that is unreachable via
its only call site — `provisionMember` already rejects any caller whose role isn't `owner`/`admin`
before `canAssignRole` is ever invoked, so it's only ever called with one of those two actor roles.
Not exported, so not directly unit-testable either. Likely-dead defensive code, not a bug — flagged in
the roadmap rather than deleted speculatively or force-tested via an artificial export. Similarly,
`send()`'s `catch` block (the `JSON.stringify`-failure safety net documented in its own header comment
as "not currently proven to be the cause of" a *different*, already-closed investigation) has no
reachable trigger through any current handler's real response-construction code — every response body
in this file is built from plain, non-circular fields by hand. Both are pre-existing, not introduced by
this arc's changes, and both apply equally to the 3 endpoints Skill 46 already covered, not just the 5
this arc added.

## Skill 53: Closing a coverage asymmetry that was an authoring artifact, not a scope decision

**Problem**: `docs/superpowers/E2E-TESTING-ROADMAP.md` flagged, but didn't fix, an asymmetry in
`functions/test/index.handlers.test.js`: `recordMutation` had a full auth/error matrix (401
missing-token, 401 invalid-token, 403 no-tenant-context, 400 invalid-body, 500 write-failed) but
`recordDelta` only had 3 tests and `recordMutationsBatch` only 3, missing most of that matrix, and
none of the three had a 405 method-not-allowed test. All three endpoints share the exact same
`OPTIONS` → method-check → token-parse → `verifyIdToken` → validate → `deriveContext` → lib-call →
response-translation shape, so there was no structural reason for one to be covered better than the
other two.

**Root cause**: not a deliberate scope decision. The file's own header comment says its purpose is
catching Skill 43's bug class (a `lib/` result silently mis-forwarded into the HTTP response) —
Skill 43's actual bug lived specifically in `recordMutation`'s conflict-forwarding, so that's the
endpoint that got the full investigative pass. `recordDelta`/`recordMutationsBatch` each got just
enough to prove the same response-forwarding pattern once (their own conflict-shape regression
test) plus a happy path, not because anyone decided they needed less coverage, but because the file
grew across several separate sessions each focused on whatever bug or feature motivated that
session, never a single symmetric coverage pass across all three.

**Fix**: added the missing cells — `recordMutation` gained a 405 test (the one thing it was
missing); `recordDelta` gained 401 invalid-token, 403, 400, 405, and 500 tests; `recordMutationsBatch`
gained 401 missing-token, 401 invalid-token, 403, 405, and 500 tests. 11 new tests total, all
mirroring `recordMutation`'s existing test bodies verbatim in structure (same `mockState.
verifyIdToken` override for 401, same `mockState.docs = {}` for 403, same `mockReq({ method: "GET"
})` for 405, same `require.cache`-swap-then-restore pattern for the 500 write-failed case — applied
to `GatewayLogic.applyDelta` and `BatchMutationLogic.applyMutationsBatch` respectively instead of
`GatewayLogic.applyMutation`). No harness changes needed — `testSupport/handlerHarness.js` already
exposed everything required, confirming the roadmap's own "no new mocking needed" note.

**Result**: `functions/` suite 163 → 174 tests, 0 failures. `index.js` line coverage 95.32% →
99.32%. The two lines still uncovered (`send()`'s `JSON.stringify`-failure catch, `canAssignRole`'s
unreachable `else` branch) are the same two pre-existing, already-documented findings from Skill 52
— confirmed still true, not rediscovered as new gaps, and deliberately not touched here: there is no
legitimate code path that reaches either one, so a test forcing them would be exercising test-only
scaffolding, not real behavior.

**Lesson, generalized**: a file's own justification comment ("this file exists to catch bug class
X") is worth re-reading with a skeptical eye once the file has grown past its original single
motivating bug — it can explain *why* coverage is asymmetric across the things the file nominally
covers equally, without anyone having decided that asymmetry was correct. Worth checking any test
file that grew incrementally across several unrelated sessions for the same pattern: does its
current coverage match its stated scope, or just its history?

## Skill 54: Verifying sandbox execution capability instead of asserting it — real `qmltestrunner` works here, the Firebase emulator specifically doesn't (and exactly why)

**Problem**: stated to Taher, mid-session, that this Cloud sandbox "can't run qmltestrunner" and
"can't run the Firebase emulator" as a blanket justification for scoping a task to Cloud-Functions-
only work. Both claims were assumptions carried over from general priors about the sandbox
(restricted network egress, no Qt toolchain by default), not something actually checked against
*this* sandbox's real capabilities. Taher pushed back: sandbox execution limits — real or assumed —
shouldn't gate what code gets written, since CI and his own machine are the actual verification
layer regardless. That pushback is what prompted actually checking instead of continuing to assert.

**What checking found — qmltestrunner**: `apt-cache policy qt6-declarative-dev` shows a real,
installable `6.4.2+dfsg-4build3` candidate from `archive.ubuntu.com` (already on this sandbox's
network allowlist). Installed it plus every `qml6-module-*` package the actual test suite's imports
needed — this took several rounds of install-run-read-the-next-missing-module, not one shot:

```
qt6-declarative-dev qml6-module-qttest qml6-module-qtquick qml6-module-qtqml \
qml6-module-qtquick-controls qml6-module-qtqml-workerscript qml6-module-qt-labs-platform \
qml6-module-qt-labs-qmlmodels qml6-module-qt-labs-folderlistmodel qml6-module-qtquick-layouts \
qml6-module-qtquick-dialogs qml6-module-qtquick-shapes qml6-module-qtqml-models \
qml6-module-qtquick-window
```

Run headless with `QT_QPA_PLATFORM=offscreen /usr/lib/qt6/bin/qmltestrunner -input tests -platform
offscreen` (note: the binary is at `/usr/lib/qt6/bin/qmltestrunner`, not on `PATH` by default).
Result: **315 passed, 22 failed** — every failure is `Type AuthStore unavailable`, all from the
same root cause Skill 47 already documented (`AuthStore.qml` does `import QtCore; Settings { ... }`,
and `Settings` didn't move into the `QtCore` QML module until a later Qt 6 minor than this
sandbox's apt-installable 6.4.2 — CI runs 6.8, where it's fine). One failed-to-compile singleton
breaks the whole `qml/model` qmldir for every file that transitively imports it, so this shows up as
a fixed-size floor unrelated to whatever a given session's diff touches — confirmed by running on
an unmodified `main` checkout too, same 22. (Skill 47's version of this note said 14 files, from
2026-08-22 — the suite has grown since; same root cause, bigger blast radius, not a new problem.)

**What checking found — Firebase emulator**: `npm install -g firebase-tools` succeeds (npm registry
is allowlisted) and `firebase emulators:start` runs — gets past config parsing, port-checking, all
of it — right up to `firestore: downloading cloud-firestore-emulator-v1.22.0.jar...`, which fails
with `Error: download failed, status 403: Host not in allowlist: storage.googleapis.com`. Precise,
not vague: it's specifically the emulator JAR download that's blocked, nothing upstream of it. If
this sandbox's network allowlist ever adds `storage.googleapis.com`, the emulator itself may well
start — untested past that point, since it wasn't reachable to test further.

**Fix (to the two prior sessions' documentation, not to any code)**: `AGENTS.md`'s Testing & QA
Agent section had two separate wrong "Skill 46" cross-references (should've been Skill 47 both
times — Skill 46 is the unrelated Firebase-functions-handler-testing skill) — both corrected in
place rather than left wrong, with a forward-pointer to this skill for the current package list and
count. Also added `scripts/setup-sandbox-qmltestrunner.sh` — the package list above as a runnable
script, so the next Cloud session doesn't repeat the several rounds of trial and error it took to
find it.

**Lesson, generalized, and the actual point of writing this down**: "the sandbox can't do X" is a
claim like any other technical claim — it needs a check, not a recollection. The check here (`apt-
cache policy`, an actual install-and-run attempt, reading the exact 403 message instead of stopping
at "it failed") took a handful of tool calls and turned a vague, overly broad limitation into two
precise, different findings: one capability that was simply never tried before (qmltestrunner — now
usable directly, no scratch-copy trick needed) and one that's genuinely blocked, with the exact
missing allowlist entry named. Vague unverified limitations are worse than either outcome on its
own: they make a real block ("Firebase emulator needs `storage.googleapis.com` allowlisted") sound
the same as a solvable one ("nobody had checked whether `apt` has Qt"), and Taher can't act on
either without knowing which is which.

## Skill 55: A PR flagged as "likely conflicts" for 6 days turned out to have exactly one conflicting
line, and it wasn't in the code

PR #49 (`review/post-pr45-qml-audit`) sat since 2026-08-26 flagged in the roadmap as `mergeable:
false` / `dirty`, with a coordination note guessing it overlapped Skill 52/53's handler-test work on
the same function. Guess wasn't checked before this session — it was checked now, on explicit
instruction to resolve it. `git merge --no-commit --no-ff` against current `main` surfaced exactly
one conflict: `CHECKPOINT.md`, which conflicts on every branch older than a session or two by design
(it's rewritten every session). `functions/index.js`, the new `lib/httpResponse.js`, and its test
file all merged clean — the extraction touched the same function Skill 52/53 later added tests for,
but at the call-site/wiring level, not the same lines, so no actual collision.

**Verification before completion, not instead of it**: ran the full `functions/` suite after
resolving (178/178, up from 174 on `main` — the 4 new `httpResponse.test.js` tests), checked
coverage before claiming the extraction improved anything (`index.js` 99.32% → 99.88%, the two
try/catch lines move out of `index.js` entirely and land at 100% coverage in their new home,
confirmed by direct measurement not by trusting the PR body's description of its own tests).

**Generalized point**: "mergeable: false" from the GitHub API doesn't say what conflicts, only that
something does — a stale checkpoint doc and a genuine logic collision produce the identical API
response. A 6-day-old dirty flag on a small, well-scoped, well-tested PR was worth 90 seconds of
`git merge --no-commit` to actually look at, rather than continuing to defer it on the strength of a
plausible-sounding guess from a different session that never checked either.

## Skill 56: PR CI status comment — researching QML coverage tooling first surfaced why "just add
% coverage gates" wasn't the ask that got acted on

Taher first asked about generating test-coverage reports (unit/PR-diff/overall) across all three
test suites. Research (web search, not assumption) found the three layers are not equally tractable:
Node's built-in `--experimental-test-coverage` and the Firestore emulator's native
`ruleCoverage` endpoint are mature, free, and near-zero CI-time cost; QML/JS coverage has no mature
free tool for Qt6 — Coco is commercial, `qoverage` (Qt6-native, `qmldom`-based) is pre-alpha. Recommendation
given to Taher: don't gate CI on a pre-alpha instrumenter's numbers — a wrong number is worse than
no number, since it gets treated as ground truth in merge decisions. Deferred rather than
implemented, on Taher's call — a case of surfacing the tooling gap and recommending against
building on it rather than proceeding just because a tool technically exists.

**What got implemented instead, same session**: a `pr-comment` job in `checks.yml` that posts (and
upserts, not duplicates) a single PR comment summarizing all four test jobs — success counts on
green, per-job failing-test name+reason+logs-link on red. Deliberately thin I/O glue
(`post-ci-comment.js`) around three pure, independently-unit-tested modules:
- `parse-junit.js` — dependency-free JUnit XML parser. Scoped narrowly to the two generators this
  repo actually produces (`qmltestrunner -o results.xml,junitxml` and
  `node --test --test-reporter=junit`), not a general XML parser.
- `resolve-job-url.js` — matches a job's display name against the GitHub "list jobs for run" API
  response to get its direct log-page URL, so every row/failure links straight to that job's logs
  instead of just the overall run.
- `build-summary.js` — pure markdown-builder function, network/filesystem-free, so comment format
  changes can be verified with plain assertions.

**Real bug caught by the test suite, not by inspection**: the first `extractAttr` regex for pulling
`name="..."` had no word boundary, so it matched inside `classname="..."` and returned the
classname's value as the test's name. A test titled "unnamed testcase falls back to placeholder
name" failed with `actual: 'c'` instead of the expected placeholder — caught immediately by running
`node --test` locally (pure Node, no Qt/Firebase toolchain needed, so this one didn't have to wait
on CI to catch). Fixed with a `\b` boundary: `classname=` and `name=` share the substring `name=`,
but `\b` correctly refuses to match at the `s`/`n` boundary inside `classname` (both word chars) while
still matching after a space or `<testcase `.

**Design decisions worth remembering if this needs extending**:
- Uses the built-in `GITHUB_TOKEN` scoped via job-level `permissions:` (`pull-requests: write`,
  `actions: read`), not Taher's PAT — works on forked-PR CI runs (a PAT wouldn't/shouldn't be
  exposed there) and follows least-privilege, matching the existing per-job `permissions:` pattern
  already in `checks.yml`.
- Upsert via a marker comment (`<!-- ci-status-comment:checks.yml -->`) — finds and `PATCH`es the
  existing comment on re-push instead of accumulating a new comment per push.
- `continue-on-error: true` on the artifact-download step and defensive `null`-parsed handling for
  any job with no `results.xml` — a job that crashed before its own upload step (npm ci failure, Qt
  install failure) is a real, reportable state ("produced no test results"), not a reason to crash
  the comment job and lose the report entirely.
- Runs the comment script's own unit tests (`node --test .github/scripts/__tests__/*.test.js`) as a
  CI step *before* trusting the script to post — a bug in the parser/builder should fail loudly, not
  silently post a garbled comment.
