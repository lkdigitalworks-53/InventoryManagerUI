# AGENTS.md

## Overview

This file defines specialized agents and their roles for the **BusinessManagement** App_UI project — a cross-platform inventory and business management app built with Felgo QML for Android and iOS.

Each agent is scoped to a specific domain, enabling efficient parallel development and agentic workflows.

---

## Current Feature Status

| Feature | Status |
|---|---|
| Multi-tenant Firebase Auth (email + Google) | ✅ Done |
| 4-role RBAC (owner / admin / manager / staff) | ✅ Done |
| Tenant workspace creation & member invitation | ✅ Done |
| Orders CRUD + delete + auto-approve | ✅ Done |
| Inventory CRUD + delete | ✅ Done |
| Staff CRUD + delete + credential provisioning | ✅ Done |
| Sales analytics from live completed orders | ✅ Done |
| Staff activities from real data | ✅ Done |
| Profile Settings dialog | ✅ Done |
| Member management dialog | ✅ Done |
| Empty-state UI for Sales page | ✅ Done |
| Success toast for key operations | ✅ Done |
| India compliance roadmap (design) | 📋 Approved — see below |

---

## India Compliance Architecture (Approved 2026-06-06)

Full design: `docs/superpowers/specs/2026-06-06-india-compliance-roadmap-design.md`.

The app is legally part of its customers' "books of account" / "electronic records" under Indian
law (Companies Act §2(13), CGST Rule 56, IT §44AA, DPDP Act) **even though it excludes billing**.
A master roadmap decomposes compliance into sub-projects P0–P7.

**Scoping decisions:** target = all segments (build to strictest common denominator → MCA-grade
immutable logging is P0); backend = add Firebase Cloud Functions gateway; sequencing =
foundation-first; manufacturing/BoM (56(12)) + digital signature (56(15)) deferred.

### The architectural spine — two-tier data model + Cloud Functions gateway

The current **client-direct Firestore REST** model cannot satisfy MCA Rule 11(g) (any member can
edit/delete; client forges identity & time). The fix:

- **Ledger tier (immutable, server-owned):** `audit_log` (new), `transactions`, `stock_batches`,
  `stock_movements` (new), plus mutation snapshots. Firestore rules = **read-only to clients**;
  the *only* writer is a Cloud Function (Admin SDK). **Append-only — no update, no delete.**
- **Working tier (client-writable, as today):** live `inventory`, `orders`, `staff`, `suppliers`
  the UI edits. Every mutation calls the gateway, which writes the doc **and** appends a ledger
  entry in one transaction.

`TransactionStore` / `StockBatchStore` become **read models** over the ledger tier (not writers).

### Roadmap priority (each is its own spec → plan)

- **P0** Gateway + immutable `audit_log` (MCA 11(g), CGST 56(8)) — foundation, builds the gateway.
- **P1** Stock-movement taxonomy: loss/theft/destroyed/write_off/free_sample/gift + opening/closing
  balance register (CGST 56(2)).
- **P2** Tax-identity fields: HSN (4/6/8-digit) on products; GSTIN on supplier/customer/tenant
  (client-only, run parallel to P0).
- **P3** Legal docs & acceptance: ToS, Privacy Policy, DPA + versioned accept-record.
- **P4** DPDP privacy core: consent capture/logs, privacy notice, grievance channel, 18+ gate,
  data-residency decision (Firestore is `asia-southeast1`/Singapore — documented, allowed today).
- **P5** PII erasure & retention: terminated-staff deletion, Auth-account cascade (closes the
  `AuthService.cleanupStaffAuthDocs` TODO), backup-aware delete, 6/8-yr archival.
- **P6** Breach detection & 72h notification (depends on P0).
- **P7** Warehouse/storage mapping: address, license no., item↔location, in-transit (CGST 56(5)).

**Required existing-code change:** `TransactionStore.renameParty()` mutates past entries — under
append-only that is illegal. P0 **removes it** (dead code, zero callers); the live supplier rename
already goes through `SupplierStore.updateSupplier` by stable `supplierId`, so no feature is lost.

**Sub-project specs:** P0 design is in `docs/superpowers/specs/2026-06-06-P0-compliance-gateway-design.md`
(gateway + immutable `audit_log`; transport = HTTPS-callable via existing XHR; optimistic UI + a
persisted outbox/retry; P0 scope = inventory + stock only; fresh-start cutover wipes ledger
collections and zeroes product stock).

---

## Core Building Blocks

### 1. Build & Infrastructure Agent

**Purpose**: Manages CMake configuration, Felgo build pipeline, and deployment packaging.  
**Scope**: Project root (`CMakeLists.txt`, `main.cpp`)

**Responsibilities**:
- Configure Felgo build: `cmake -S . -B build -G "Ninja"`
- Compile project: `cmake --build build`
- Toggle between development mode (`deploy_resources`) and publishing mode (QRC compilation)
- Manage `PRODUCT_IDENTIFIER`, `PRODUCT_VERSION_NAME`, `PRODUCT_VERSION_CODE`
- Set Android target/compile SDK versions via `set_target_properties`
- Configure `FELGO_LICENSE_KEY` for local and Cloud builds
- Enable/disable Felgo Hot Reload in `CMakeLists.txt` and `main.cpp`

**Key Files**:
- `CMakeLists.txt`
- `main.cpp`

**Example Prompts**:
- "Switch to publishing build mode"
- "Enable Felgo Hot Reload"
- "Update the Android target SDK to 35"
- "Build the app for Android"

---

### 2. App Architecture & Navigation Agent

**Purpose**: Manages the Felgo App root, layer ordering, and Navigation structure.  
**Scope**: `qml/Main.qml`

**Responsibilities**:
- Maintain the Felgo App object hierarchy: Theme → Logic → DataModel → ViewHelper → Navigation
- Add or remove `NavigationItem` / `NavigationStack` tabs
- Wire top-level dialog instances (`NewOrderDialog`, `AddProductDialog`, etc.)
- Handle app-level signals and connections (e.g. `onOrderCompletionFailed`)
- Manage the `compact` responsive breakpoint property
- Connect `Logic` signals to stock error dialogs

**Architecture Pattern**:
```
App (Main.qml)
├── CustomeTheme
├── Logic              (signal bus)
├── DataModel          (orchestrator, dispatcher: logic)
├── ViewHelper
├── Dialogs            (stockErrorDlg, profileDlg, inviteMemberDlg, memberMgmtDlg, etc.)
├── LoginPage          (z:100, visible when unauthenticated or profile unresolved)
├── TenantSetupPage    (z:101, visible only for new owner onboarding)
└── Navigation
    ├── NavigationItem "Orders"    → NavigationStack → AppPage → OrdersPage
    ├── NavigationItem "Inventory" → NavigationStack → AppPage → InventoryPage
    ├── NavigationItem "Sales"     → visible: AuthStore.canViewSales
    └── NavigationItem "Staff"     → visible: AuthStore.canViewStaff
```

**Key Files**:
- `qml/Main.qml`

**Example Prompts**:
- "Add a new Dashboard tab to the navigation"
- "Change the navigation tab order"
- "Wire a new top-level dialog into Main.qml"

---

### 3. Logic & Signal Bus Agent

**Purpose**: Manages the signal dispatcher and view helper utilities.  
**Scope**: `qml/logic/`

**Responsibilities**:
- Define and maintain signals in `Logic.qml` (all user actions and feedback events)
- Keep signal signatures consistent with how pages emit and DataModel handles them
- Add new domain signals following the UI→DataModel / DataModel→UI split convention
- Maintain `ViewHelper.qml` formatting utilities (`formatCurrency`, `formatNumber`)

**Signal Convention**:
- UI→DataModel commands: `addOrder(...)`, `completeOrder(...)`, `addProduct(...)`, `addStaff(...)`
- DataModel→UI feedback: `orderAdded(...)`, `orderCompletionFailed(...)`, `productAdded(...)`, `staffAdded(...)`
- App lifecycle: `loadData()`, `refreshData()`, `syncAllStores()`

**Key Files**:
- `qml/logic/Logic.qml`
- `qml/logic/ViewHelper.qml`

**Example Prompts**:
- "Add a signal for deleting an order"
- "Add a deleteProduct signal and its feedback signal"
- "Add a formatDate helper function to ViewHelper"

---

### 4. Data Model & Orchestration Agent

**Purpose**: Manages state orchestration, cross-store logic, and the orders model.  
**Scope**: `qml/model/DataModel.qml`

**Responsibilities**:
- Maintain the `Connections` block that handles all `Logic` signals
- Orchestrate cross-store operations (e.g. `tryCompleteOrder`: stock check → deduct → mark complete → record sale)
- Keep `ordersModel` (ListModel) in sync with `OrdersStore.orders`
- Expose public methods: `tryCompleteOrder()`, `syncOrdersModel()`, `updateOrderInModel()`
- Handle `stockErrorMsg` for the stock error dialog in `Main.qml`
- Wire new store delegates when adding a new domain

**Key Files**:
- `qml/model/DataModel.qml`

**Example Prompts**:
- "Add handling for the deleteOrder signal in DataModel"
- "Add a new store integration for a Suppliers domain"
- "Fix the order completion flow to also update sales analytics"

---

### 5. Store & Firebase Agent

**Purpose**: Manages per-domain data stores and Firebase REST integration.  
**Scope**: `qml/model/` (stores + FirebaseService)

**Responsibilities**:
- Maintain `OrdersStore`, `InventoryStore`, `SalesStore`, `StaffStore`
- Keep local persistence via `QtCore.Settings` working correctly
- Maintain Firebase REST sync (`_fetchFromFirebase`, `_pushAllToFirebase`, `syncFromFirebase`)
- Handle field normalization between Firebase schema and local schema
- Add new store files for new domains following the singleton pattern
- Register new stores in `qml/model/qmldir`
- Keep `FirebaseService` REST helpers (`get`, `put`, `patch`, `remove`, `toArray`) up to date

**Store Pattern**:
```qml
pragma Singleton
import QtQuick
import QtCore   // for Settings (OrdersStore, InventoryStore, SalesStore)

QtObject {
    property var data: []
    property Settings _settings: Settings { category: "StoreName"; property string json: "" }
    Component.onCompleted: _load()
    function _load() { /* local Settings → Firebase fallback */ }
    function _save() { /* persist to Settings */ }
    function _fetchFromFirebase() { FirebaseService.get("path", callback) }
    function _commit(arr) { data = arr; _save(); _pushAllToFirebase() }
}
```

**Key Files**:
- `qml/model/OrdersStore.qml`
- `qml/model/InventoryStore.qml`
- `qml/model/SalesStore.qml`
- `qml/model/StaffStore.qml`
- `qml/model/AuthService.qml`
- `qml/model/AuthStore.qml`
- `qml/model/FirebaseService.qml`
- `qml/model/qmldir`

**Example Prompts**:
- "Add a Suppliers store for vendor management"
- "Fix the Firebase sync for orders to handle pagination"
- "Add a deleteOrder function to OrdersStore"

---

### 6. Pages & Dialogs Agent

**Purpose**: Develops and maintains all feature pages and dialogs.  
**Scope**: `qml/pages/`

**Responsibilities**:
- Maintain all four feature pages (Orders, Inventory, Sales, Staff)
- Build and update all dialogs (New Order, Order Detail, Add Product, Add Staff, Restock, ProfileSettings, InviteMember, MemberManagement)
- Implement responsive layouts using `compact: width < 520`
- Expose `canManage*` / `canDelete*` boolean properties on pages; never import AuthStore directly inside pages — bind from Main.qml
- Wire delete signals: `onDeleteOrderClicked`, `onDeleteProductClicked`, `onDeleteStaffClicked` → `logic.deleteX(id)`
- Wire dialog signals back to `logic` signals: e.g. `onOrderCreated: logic.addOrder(...)`
- Maintain KPI card layouts, table rows, search fields, and action buttons

**Responsive Design**:
- `compact = true` when `width < 520` — 2-line compact card/row layouts
- `compact = false` — full table/multi-column layouts

**Key Files**:
- `qml/pages/OrdersPage.qml`
- `qml/pages/InventoryPage.qml`
- `qml/pages/SalesPage.qml`
- `qml/pages/StaffPage.qml`
- `qml/pages/LoginPage.qml`
- `qml/pages/TenantSetupPage.qml`
- `qml/pages/NewOrderDialog.qml`
- `qml/pages/OrderDetailDialog.qml`
- `qml/pages/AddProductDialog.qml`
- `qml/pages/AddStaffDialog.qml`
- `qml/pages/RestockDialog.qml`
- `qml/pages/ProfileSettingsDialog.qml`
- `qml/pages/InviteMemberDialog.qml`
- `qml/pages/MemberManagementDialog.qml`

**Example Prompts**:
- "Add a delete button to order rows in OrdersPage"
- "Create a new SupplierPage for vendor management"
- "Fix the date picker in AddStaffDialog for mobile"
- "Add a filter dropdown to InventoryPage"

---

### 7. Shared Components Agent

**Purpose**: Manages reusable UI components, theming, and constants.  
**Scope**: `qml/helper/`

**Responsibilities**:
- Maintain `Constants.qml` (singleton: colors, breakpoints, Firebase URL)
- Maintain `CustomeTheme.qml` (Felgo theme color tokens)
- Develop and maintain reusable components: `CardKPI`, `StatusBadge`, `OrderRow`, `SegmentedNav`, `InlineDatePicker`, `PlaceholderPage`
- Register new singleton helpers in `qml/helper/qmldir`
- Ensure components import only what they need (`"../model"` for store access)

**Key Files**:
- `qml/helper/Constants.qml`
- `qml/helper/CustomeTheme.qml`
- `qml/helper/CardKPI.qml`
- `qml/helper/StatusBadge.qml`
- `qml/helper/OrderRow.qml`
- `qml/helper/SegmentedNav.qml`
- `qml/helper/InlineDatePicker.qml`
- `qml/helper/PlaceholderPage.qml`
- `qml/helper/qmldir`

**Example Prompts**:
- "Add a new ToastNotification component for success/error feedback"
- "Update CardKPI to support a trend indicator"
- "Add a new color to CustomeTheme for danger/warning states"
- "Create a SearchBar reusable component"

---

### 8. Compliance & Audit Agent

**Purpose**: Owns the India compliance roadmap (P0–P7) — the immutable ledger tier, the Cloud
Functions gateway, tax-identity fields, DPDP privacy, and retention.
**Scope**: Cloud Functions (`functions/`, to be created), `FIRESTORE_RULES.md`, ledger stores
(`TransactionStore`, `StockBatchStore`, new `AuditLogStore` / `StockMovementStore`), and the
compliance design spec.

**Responsibilities**:
- Maintain the **two-tier model**: ledger tier stays append-only and server-written; working tier
  routes every mutation through the gateway's `recordMutation(entity, entityId, action, before,
  after)` callable.
- Keep ledger Firestore rules `allow write: if false` — only the Admin SDK (Cloud Function) writes.
- Never edit historical ledger rows. Relabels (e.g. supplier rename) propagate by stable id, not by
  rewriting past rows.
- Add tax-identity fields: product `hsnCode` (4/6/8-digit validated), `gstin` (15-char checksum) on
  supplier/customer/tenant.
- Implement the stock-movement taxonomy enum (`receipt|sale|loss|theft|destroyed|write_off|
  free_sample|gift|adjustment`) and the opening/closing-balance register read model.
- Build DPDP consent logs, privacy notice, grievance channel, 18+ gate; PII erasure with
  Auth-account cascade and 6/8-yr archival; breach detection.

**Invariants (do not violate)**:
- The audit trail cannot be disabled or made configurable — no `enable_audit_trail` flag anywhere.
- `serverTimestamp` (NTP-backed, set in the Cloud Function) is authoritative; `clientTimestamp` is
  forensic-only.
- `actorUid`/`actorRole` are derived server-side from the verified token, never trusted from the
  client payload.

**Key Files**:
- `docs/superpowers/specs/2026-06-06-india-compliance-roadmap-design.md` (master design)
- `functions/` (Cloud Functions — to be created in P0)
- `FIRESTORE_RULES.md`
- `qml/model/TransactionStore.qml`, `qml/model/StockBatchStore.qml`

**Example Prompts**:
- "Spec out P0 — the compliance gateway and immutable audit_log"
- "Add the HSN code field to products with 4/6/8-digit validation"
- "Implement the P0 gateway and route InventoryStore writes through it"
- "Lock the Firestore rules for ledger collections to read-only"

---

## Agent Usage Patterns

### Adding a New Domain (e.g. Suppliers)

1. **Store & Firebase Agent** → Create `qml/model/SuppliersStore.qml`, register in `qmldir`
2. **Logic & Signal Bus Agent** → Add `addSupplier(...)`, `supplierAdded(...)` signals to `Logic.qml`
3. **Data Model Agent** → Add `onAddSupplier` handler in `DataModel.qml`
4. **Pages & Dialogs Agent** → Create `qml/pages/SuppliersPage.qml` and dialog(s)
5. **App Architecture Agent** → Add `NavigationItem` for Suppliers in `Main.qml`, wire dialog

### Fixing a Data Bug

1. **Store & Firebase Agent** → Check store logic and Firebase sync
2. **Data Model Agent** → Check DataModel orchestration
3. **Logic Agent** → Verify signal signatures match

### Adding a UI Feature

1. **Shared Components Agent** → Build reusable component if needed
2. **Pages & Dialogs Agent** → Integrate into the relevant page
3. **Logic Agent** → Add signals if new user actions are introduced
4. **Data Model Agent** → Wire handlers

### Publishing to Stores

1. **Build Agent** → Switch to publishing mode (comment `deploy_resources`, uncomment `QML_FILES`)
2. **Build Agent** → Set `PRODUCT_LICENSE_KEY` and `PRODUCT_STAGE "publish"`
3. **Build Agent** → Update `main.cpp` to use `qrc:/qml/Main.qml`
4. **Build Agent** → Build for target platform and run packaging

### Adding a Compliance Feature (any data that touches books of account / PII)

1. **Compliance & Audit Agent** → Confirm which roadmap sub-project (P0–P7) it belongs to; read the
   master spec.
2. **Store & Firebase Agent** → Route the mutation through the gateway `recordMutation(...)`; never
   write the ledger tier directly from the client.
3. **Compliance & Audit Agent** → Ensure an `audit_log` entry is appended (before/after, actorUid,
   serverTimestamp) and that ledger rules stay `allow write: if false`.
4. **Pages & Dialogs Agent** → Surface required fields (HSN, GSTIN, movement reason, consent) and
   any privacy notice.
5. Never edit historical ledger rows — relabels propagate by stable id, not by rewriting past rows.
