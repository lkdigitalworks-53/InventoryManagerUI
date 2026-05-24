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
import QtCore

QtObject {
    id: root
    property var items: []

    property Settings _settings: Settings {
        category: "NewDomainStore"
        property string json: ""
    }

    Component.onCompleted: _load()

    function _load() {
        var saved = _settings.json
        if (saved && saved !== "") {
            try { items = JSON.parse(saved) } catch(e) {}
        }
        if (items.length === 0) _fetchFromFirebase()
    }

    function _save() { _settings.json = JSON.stringify(items) }

    function _fetchFromFirebase() {
        FirebaseService.get("newdomain", function(data) {
            if (data) items = FirebaseService.toArray(data)
        })
    }

    function addItem(item) {
        var arr = items.slice()
        arr.push(item)
        items = arr
        _save()
        FirebaseService.put("newdomain/" + item.id, item, null)
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
**Base URL**: `Constants.firebaseDatabaseUrl` → `https://inventorymanager-48392-default-rtdb.asia-southeast1.firebasedatabase.app`

```qml
// GET
FirebaseService.get("orders", function(data) {
    var arr = FirebaseService.toArray(data)
})

// PUT (full overwrite of a node)
FirebaseService.put("orders/" + order.id, order, function(result) {
    console.log("saved", JSON.stringify(result))
})

// PATCH (partial update)
FirebaseService.patch("orders/" + id, { status: "Completed" }, null)

// DELETE
FirebaseService.remove("orders/" + id, null)
```

**`toArray(obj)`**: Converts Firebase `{"-key1": {…}, "-key2": {…}}` to a flat JS array with an `id` field added from each key.

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
3. **Store function** → filters the array, calls `_commit()` or `_pushAllToFirebase()`
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

