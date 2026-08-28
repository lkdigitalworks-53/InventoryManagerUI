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
| Analysis page — 6 view modes (Value/Purchased/Current/Revenue/Sold/Profit) | ✅ Done |
| Analysis — by-category & by-supplier breakdown charts on every view | ✅ Done & device-verified |
| Analysis filters (date / supplier / channel / staff / category) + xlsx export | ✅ Done |
| Staff activities from real data | ✅ Done |
| Profile Settings dialog | ✅ Done — owner-only workspace rename, coordinated multi-doc save (2026-07-31, Skill 36) |
| Member management dialog | ✅ Done |
| Empty-state UI for Analysis page | ✅ Done |
| Success toast for key operations | ✅ Done |
| QML unit-test harness (qmltestrunner, first suite landed) | ✅ Done |
| Editable per-line price in New Order dialog | ✅ Done |
| Swipe left/right between Analysis report views | ✅ Done |
| Add Product advanced section open by default | ✅ Done |
| Mandatory always-visible staff app-login fields | ✅ Done |
| dev/test/prd Firestore environments (build-time via PRODUCT_STAGE) | ✅ Done |
| Cloud Functions env-awareness (all 4 functions resolve db per request) | ✅ Done — pending real deploy/emulator verification |
| Paginated reads, all 6 growing stores (fixes silent truncation past Firestore's internal page-size threshold) | ✅ Done — pending qmltestrunner run |
| Write-path fix (no more collection-wide bulk overwrite on a single mutation) | ✅ Done |
| `computeAnalysis` Cloud Function (server-side Revenue/Profit/Sold/Purchased aggregation) | ✅ Built, tested (Node-side) — not yet wired into SalesPage.qml, not yet deployed |
| SalesPage.qml cutover to server-side analysis | 📋 Deferred — separate future project, not a thin swap (see `docs/superpowers/specs/2026-07-06-scale-reads-writes-analytics-design.md` §9.1) |
| India compliance roadmap (design) | 📋 Approved — P0 substantially implemented, see below |

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
  data-residency decision (Firestore `(default)` is `asia-south1`/Mumbai, confirmed via
  `gcloud firestore databases list` — corrected 2026-07-10 from an earlier, wrong assumption
  of `asia-southeast1`/Singapore; Cloud Functions reconfigured to also target `asia-south1` for
  consistency. Data + compute are now fully within India — see the compliance roadmap spec's
  §5 correction note; the original DPDP §7 cross-border analysis no longer applies as written
  and should be re-reviewed with whoever advised on it).
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

### P0 implementation status (updated 2026-07-29)

**Code-complete, tested, LIVE.** All five working-tier stores (`InventoryStore`,
`StockBatchStore`, `OrdersStore`, `StaffStore`, `SupplierStore`) now route every mutation through
`Gateway.recordMutation` / `Gateway.recordMutations` (batch — new this session, see Skill 35 below)
— zero direct `FirebaseService.put/patch/remove/putMany` calls remain in any of them. Status:

- **`Gateway.mode` now defaults to `"gateway"`** (flipped 2026-07-29, commit `649046d`). Cloud
  Functions and the locked Firestore rules are deployed and confirmed working (per Taher) —
  `recordMutation` calls now actually go through the gateway and write a real `audit_log` entry
  atomically with the working-tier doc. Whether the one-time `runCutover` (irreversible — wipes
  the ledger, zeroes stock) was run as part of this same rollout has **not** been independently
  confirmed in a session — don't assume historical ledger/stock data was reset without checking.
- CF-side gateway logic (`recordMutation`, `runCutover`, and the new batch endpoint
  `recordMutationsBatch`) was extracted into `functions/lib/{gatewayLogic,cutoverLogic,
  batchMutationLogic}.js` and has real, verified test coverage (48 tests, `node --test` — no
  emulator needed; see Skill 35).
- `tests/tst_Gateway.qml`, `tests/tst_OutboxStore.qml`, and root `test/firestore.rules.test.js`
  exist but were **written, not run** — this sandbox had no Qt toolchain and no network access to
  Firebase's emulator distribution. They need a local `qmltestrunner` pass and
  `firebase emulators:exec --only firestore "node --test test/"` respectively before being trusted.
- Full trail: `docs/superpowers/specs/2026-07-11-p0-gateway-orders-staff-suppliers-CHECKPOINT.md`
  and `docs/superpowers/plans/2026-07-11-p0-gateway-fast-follow.md`.

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
- Select the Firestore environment via `PRODUCT_STAGE` (`dev`|`test`|`publish`):
  CMake emits `PRODUCT_STAGE_DEF` → `main.cpp` sets the `APP_STAGE` context
  property → `EnvConfig.js` maps it (`publish`→`(default)`, `dev`/`test`→named
  DBs) → `FirebaseService.databaseId`. Unknown/unset stage fails safe to `prd`.

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
- Maintain `OrdersStore`, `InventoryStore`, `SalesStore`, `StaffStore`, `SupplierStore`,
  `TransactionStore`, `StockBatchStore`, `ActivityLog`
- Maintain Firebase REST sync (`_fetchFromFirebase`, `syncFromFirebase`) — all six growing
  collections page in bounded chunks via `FirebaseService.query()` (SKILLS Skill 32), not one
  unbounded `get()`
- Handle field normalization between Firestore schema and local schema
- Add new store files for new domains following the singleton pattern (SKILLS Skill 11)
- Register new stores in `qml/model/qmldir`
- Keep `FirebaseService` REST helpers (`get`, `query`, `put`, `putMany`, `patch`, `remove`, `toArray`)
  up to date
- `patch()` sends a real field-masked Firestore update (`updateMask.fieldPaths` per key) — it does
  **not** alias `put()` anymore (fixed 2026-07-31, see SKILLS Skill 36). Use `patch()` for a
  partial update to a document with fields the caller doesn't own or know about; use `put()` only
  when the caller intends to write/replace the whole document.
- `FirebaseService.databaseUrl`/`databaseId` are environment-aware (resolved from
  `PRODUCT_STAGE` via `EnvConfig.js`); never hard-code `databases/(default)` — it
  bypasses dev/test/prd routing. All REST calls already build URLs from these.
- **Never write a whole collection in one bulk `:commit`** on a single-record mutation — Firestore
  hard-caps a single commit at 500 writes (this was a real, confirmed bug in `OrdersStore`,
  `StaffStore.addStaff`, and `ActivityLog` — fixed; see SKILLS Skill 12's `putMany()`). Single-doc
  `put()` per changed record; `putMany()` only for a genuinely multi-doc action (e.g.
  `approveAllPending`).
- Any new `Settings { category: "..." }` block (device-local `QSettings` persistence — all six
  stores: `AuthStore`, `OutboxStore`, `OrdersStore`, `PartyStore`, `CategoryStore`,
  `OrderChannelStore`, all fixed as of 2026-08-18) needs an explicit `location:
  SettingsPath.settingsLocationOverride(Application.organization,
  StandardPaths.writableLocation(StandardPaths.TempLocation))` — note `location` (a `url`), not
  `fileName` (a `string`, which belongs to the older deprecated `Qt.labs.settings` Settings type,
  not this app's `QtCore` one — the first version of this fix used the wrong name and broke 14 test
  files at compile time; see SKILLS Skill 41). Without it, `qmltestrunner` never satisfies the
  org-identifier `Settings` needs to resolve a real file, and every property write against it
  silently no-ops under test.

**Store Pattern** (see SKILLS Skill 11 for the full paginated version):
```qml
pragma Singleton
import QtQuick

QtObject {
    property var items: []
    property bool hasMore: true
    property bool loadingMore: false
    property var _cursor: null
    Component.onCompleted: _resetAndFetch()
    function _resetAndFetch() { items = []; hasMore = true; _cursor = null; _fetchFromFirebase() }
    function _fetchFromFirebase() { /* FirebaseService.query("path", {limit, startAfter}, cb) */ }
    function addItem(item) { /* single-doc FirebaseService.put("path/" + item.id, item, cb) -- never a bulk collection overwrite */ }
}
```

**Key Files**:
- `qml/model/OrdersStore.qml`
- `qml/model/InventoryStore.qml`
- `qml/model/SalesStore.qml` — KPIs are **derived** from OrdersStore (net revenue, completed-only); no persisted tally (see SKILLS Skill 28)
- `qml/model/StaffStore.qml`
- `qml/model/SupplierStore.qml`, `qml/model/StockBatchStore.qml`, `qml/model/TransactionStore.qml`
- `qml/model/OrderChannelStore.qml`, `qml/model/CategoryStore.qml` — Firestore-backed `config/*` singleton documents (not paginated collections — a single doc has no List-Documents truncation risk)
- `qml/model/ActivityLog.qml` — Firestore-backed (`activity_log`), re-synced on login
- `qml/model/AuthService.qml`
- `qml/model/AuthStore.qml`
- `qml/model/FirebaseService.qml`
- `qml/helper/PagingHelper.js` — pure cursor-pagination bookkeeping (SKILLS Skill 32)
- `qml/model/qmldir`

**Example Prompts**:
- "Add a Suppliers store for vendor management"
- "Add a deleteOrder function to OrdersStore"
- "Audit every store for the bulk-overwrite write-path bug before adding a new mutation"

---

### 6. Pages & Dialogs Agent

**Purpose**: Develops and maintains all feature pages and dialogs.  
**Scope**: `qml/pages/`

**Responsibilities**:
- Maintain all four feature pages (Orders, Inventory, Analysis [`SalesPage.qml`, header reads "Analysis"], Staff)
- Build and update all dialogs (New Order, Order Detail, Add Product, Add Staff, Restock, ProfileSettings, InviteMember, MemberManagement, AnalysisFilterSheet)
- The Analysis page has six view modes — Value, Purchased, Current, Revenue, Sold, Profit — each showing a hero total + main breakdown + a **by-category** and **by-supplier** chart (all three render via the shared `BreakdownBarCard` component). The grouping math lives in `qml/helper/BreakdownMath.js` (pure, unit-tested); the page's `_breakdownByDimension()` wrapper feeds it live filter/period state. See SKILLS.md Skill 25.
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
- `qml/pages/SalesPage.qml` (the "Analysis" page)
- `qml/pages/AnalysisFilterSheet.qml`
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
- "Add a new breakdown dimension (e.g. by channel) to the Analysis page"

---

### 7. Shared Components Agent

**Purpose**: Manages reusable UI components, theming, constants, and pure helper libraries.  
**Scope**: `qml/helper/` and `qml/components/`

**Responsibilities**:
- Maintain `Constants.qml` (singleton: colors, breakpoints, Firebase URL)
- Maintain `CustomeTheme.qml` (Felgo theme color tokens)
- Develop and maintain reusable components in `qml/helper/` (`CardKPI`, `StatusBadge`, `OrderRow`, `SegmentedNav`, `InlineDatePicker`, `PlaceholderPage`) and `qml/components/` (`BreakdownBarCard`, `Icon`, `ListCard`, `SegmentedPill`, `ChipScroller`, `BottomSheet`, etc.)
- Maintain pure JS helper libraries in `qml/helper/` (`.pragma library`): `BreakdownMath.js` — stateless analytics grouping math (sold/purchased unit metrics by category|supplier); `RealisedMath.js` — the single source of truth for REALISED money aggregation over the immutable event log (`byDimension`/`totals`/`bucketWalk`/`nameMerge`; scope-filtered, stamped-fields-only, reconciliation invariant Σ byDimension == totals == Σ bucketWalk — see SKILLS Skill 29); `OrderMath.js` — per-order allocation + `eventProfit`/`refundPerUnit`; `ImportMath.js` — import helpers (`renameSku`). All are QML/singleton-free so they are unit-testable headlessly.
- Register new **singleton** helpers in `qml/helper/qmldir` (plain components and `.pragma library` JS files need NO qmldir entry — they resolve via the directory import `import "../helper"` / `import "../helper/Foo.js" as Foo`).
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
- `qml/helper/BreakdownMath.js`
- `qml/helper/qmldir`
- `qml/components/BreakdownBarCard.qml` (reusable vertical-bar chart for the Analysis page)

**Example Prompts**:
- "Add a new ToastNotification component for success/error feedback"
- "Update CardKPI to support a trend indicator"
- "Add a new color to CustomeTheme for danger/warning states"
- "Create a SearchBar reusable component"
- "Add a new metric to BreakdownMath.js and a test for it"

---

### 8. Compliance & Audit Agent

**Purpose**: Owns the India compliance roadmap (P0–P7) — the immutable ledger tier, the Cloud
Functions gateway, tax-identity fields, DPDP privacy, and retention. **Adjacent, not part of P0
itself**: the gateway's concurrency-control layer (single-flight, locking, CAS, atomic deltas —
`docs/superpowers/specs/2026-07-29-async-write-sequencing-design.md`, its 2026-08-06 review at
`docs/superpowers/specs/2026-08-06-async-write-sequencing-code-review.md`, its 2026-08-08 round-2
closure of the remaining findings at `docs/superpowers/specs/2026-08-08-review-round2-design.md`,
README's "Concurrency & Conflict Resolution", SKILLS Skill 36) lives in the same `functions/` files
but is a correctness concern, not a compliance one — don't conflate the two when reasoning about
this directory. Also adjacent, found 2026-08-10 while on-device testing the round-2 branch:
`OrdersStore.applyAdjustment` built its CAS `before` snapshot via a shallow `Object.assign`, then
mutated a nested field (`adjustments`) in place — the mutation leaked back into `before`, so the
server's CAS check rejected a completely ordinary price edit as a false conflict (see SKILLS Skill
37, `docs/superpowers/specs/2026-08-10-before-snapshot-aliasing-CHECKPOINT.md`). A full-codebase
sweep found this was the only instance of the pattern; fixed narrowly rather than rewritten broadly.
Found immediately after, testing the same fix (2026-08-11): `OrdersStore.applyAdjustment`'s
completed-order total also trusts `TransactionStore.totalsForOrder` unconditionally, which is wrong
if `TransactionStore` hasn't finished its post-cold-start paginated re-sync yet — the newest
transactions (timestamp-prefixed IDs, ascending `__name__` pagination) load last, so a just-
completed order's own sale can still be missing when a prompt return tries to net against it.
`DataModel._tryAdjustOrder` now refuses completed-order adjustments while `TransactionStore.
hasMore` is true, and `TransactionStore` now retries a failed sync page with backoff instead of
leaving `hasMore` stuck forever (see SKILLS Skill 38, `docs/superpowers/specs/
2026-08-11-ledger-sync-race-CHECKPOINT.md`). Scoped to the one caller that actually reads this
ledger — order completion and everything else here don't depend on it.
Found by Taher himself immediately after, still testing the same guard (2026-08-12): the guard
above didn't reliably fire because `TransactionStore.hasMore` could read `false` while `entries` was
genuinely still incomplete — `Component.onCompleted` and `onTenantContextReady` both call
`_resetAndFetch()` on a cold start, and since both are async, the second call could wipe `entries`/
`_cursor` out from under the first, still-in-flight fetch. Fixed with `if (loadingMore) return` at
the top of `_resetAndFetch()`, applied to every paginated store (not just `TransactionStore`) — see
SKILLS Skill 39 for the full sweep of all 21 `qml/model/*.qml` singletons, including which ones
don't need this guard and why, and a documented (not yet implemented) residual edge case around
account-switch timing.
Worth knowing regardless: the 2026-08-06 review added a `locks/**` lockdown to
`firestore.rules` (a new `isServerOnlyCollection` tier, distinct from the ledger tier below — locks
needs read AND write denied, not just write) — if touching `firestore.rules` for compliance work,
be aware this tier exists and follow the same pattern for any other collection that should never be
client-reachable. Also worth knowing: `functions/lib/batchMutationLogic.js`'s `applyMutationsBatch`
(the live path for every bulk import) now has a CAS check as of 2026-08-08 — if adding a new bulk
write path anywhere, check whether it should route through this rather than a bespoke batch write
that would reintroduce the same gap.
Found 2026-08-17, closing out the gap-list's QSettings item: `OutboxStore`'s `Settings` block never
actually persisted to a real file under `qmltestrunner` (org-identifier resolution failure — see
SKILLS Skill 41) — meaning this store's entire reason to exist, durability across a relaunch, was
silently untested by every run there has ever been. Fixed with an explicit `location` override
(not `fileName` — see SKILLS Skill 41 for that correction) that only activates when the org
identifier is unset (never true for a real launch); `tst_OutboxStore.qml`
gained the actual regression test that proves it (fails without the fix, not just documents intent).
**Scope**: Cloud Functions (`functions/` — exists, see Key Files below), `FIRESTORE_RULES.md` +
`firestore.rules`, ledger stores (`TransactionStore`, `StockBatchStore`; `AuditLogStore` /
`StockMovementStore` are still future P1 work, not yet created), all five working-tier stores
(`InventoryStore`, `StockBatchStore`, `OrdersStore`, `StaffStore`, `SupplierStore` — all migrated
to the gateway as of 2026-07-11), and the compliance design spec.

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

**Environment follow-up: done, including the 3 endpoints added 2026-07-29.** All 8 Cloud
Functions (`recordMutation`, `recordDelta`, `acquireLock`, `releaseLock`, `provisionMember`,
`runCutover`, `computeAnalysis`, `recordMutationsBatch`) resolve their Firestore
database **per request** via `scopedDb(env)` in `functions/index.js` — see SKILLS Skill 33.
`Gateway.qml`, `LockManager.qml`, and `AnalysisService.qml` inject `env: FirebaseService.environment`
into every request body. This was confirmed as a real, already-live gap (not hypothetical) before being
fixed — `admin.firestore()` was previously called once at module load with no `databaseId`, so
every Cloud Function always targeted `(default)` (prd) regardless of the calling client's actual
env.

**Key Files**:
- `docs/superpowers/specs/2026-06-06-india-compliance-roadmap-design.md` (master design)
- `docs/superpowers/specs/2026-07-06-scale-reads-writes-analytics-design.md` (pagination,
  write-path fix, env-awareness fix, `computeAnalysis` — builds on the P0 gateway)
- `docs/superpowers/specs/2026-07-11-p0-gateway-orders-staff-suppliers-CHECKPOINT.md` +
  `docs/superpowers/plans/2026-07-11-p0-gateway-fast-follow.md` (the fast-follow session: Orders/
  Staff/Suppliers migration, batch-mutation capability, test-gap closure — full trail of what was
  found, decided, and done)
- `functions/` — Cloud Functions project: `index.js` (thin request/response handlers), `lib/`
  (`gatewayLogic.js`, `cutoverLogic.js`, `batchMutationLogic.js` — pure, dependency-injected core
  logic; see Skill 35) plus `breakdownMath.js`/`realisedMath.js`/`orderMath.js` (ported pure math),
  `test/` (48 tests, `npm test` = `node --test`, no emulator needed), `package.json`
- `test/firestore.rules.test.js` + root `package.json` — Firestore rules tests
  (`@firebase/rules-unit-testing`; needs the emulator, `firebase emulators:exec --only firestore
  "node --test test/"`)
- `tests/tst_Gateway.qml`, `tests/tst_OutboxStore.qml` — QML tests for the client-side gateway
  bridge and outbox queue (`qmltestrunner -input tests -platform offscreen`). **Every XHR call site
  in `Gateway.qml` (`_send`, `_sendBatch`, `_sendDelta`, `runCutover`, `provisionMember`) works
  around [QTBUG-49896](https://bugreports.qt.io/browse/QTBUG-49896) via
  `_captureBeforeStatusIsLost()`** — QML's `XMLHttpRequest` can lose `xhr.status` (reset to 0) at
  the readyState 3->4 transition for non-2xx responses. Unresolved upstream, no fix version. If you
  add a new XHR call anywhere in this file, it needs the same snapshot-and-fallback pattern, or its
  error/conflict path will silently never fire in practice — see Skill 45 for the full story.
- `FIRESTORE_RULES.md`
- `qml/model/TransactionStore.qml`, `qml/model/StockBatchStore.qml`

**Example Prompts**:
- "Add the HSN code field to products with 4/6/8-digit validation"
- "Lock the Firestore rules for ledger collections to read-only"
- "Deploy the Cloud Functions changes and verify computeAnalysis against a real tenant"

---

### 9. Testing & QA Agent

**Purpose**: Owns the QML test harness and unit coverage for pure logic.
**Scope**: `tests/`, `functions/test/`, `test/e2e/`, `docs/superpowers/test-plans/`

**Responsibilities**:
- Write every new test plan (automated coverage map, or an on-device manual checklist) into
  `docs/superpowers/test-plans/` directly — not `specs/` or `plans/` — and add it to that folder's
  `README.md` index (consolidated there 2026-08-22, see SKILLS Skill 47). Follow the existing
  naming convention (`YYYY-MM-DD-<branch-or-feature>-test-plan.md`, or `YYYY-MM-DD-on-device-
  test-plan-<feature>.md` for manual-only) and note in the index whether it supersedes or chains
  with an existing plan for the same feature area.
- Write Qt Quick Test (`TestCase`) suites for **pure, headless-testable logic** — primarily the
  `.pragma library` JS helpers (e.g. `qml/helper/BreakdownMath.js`). Page-level QML that needs the
  full Felgo `App` context (`dp()`/`sp()`/`Theme`/`GlassHeader`) cannot load under the runner — keep
  the testable math in a pure library and test that.
- Run the suite headlessly:
  ```bash
  QT_FORCE_STDERR_LOGGING=1 QT_LOGGING_TO_CONSOLE=1 \
    PATH="/c/Felgo/Felgo/mingw_64/bin:$PATH" \
    "C:/Felgo/Felgo/mingw_64/bin/qmltestrunner.exe" -platform offscreen -input tests/tst_<Name>.qml
  ```
  (On this box `qmltestrunner.exe` is silent without the two `QT_*` env vars — set them to see PASS/FAIL lines.)
- Keep `tests/` OUTSIDE `qml/` so test files are NOT globbed into the app package. There is no CMake
  test target — the runner executes the `.qml` directly.
- Assert real numeric behavior, and for analytics assert the reconciliation invariant (a breakdown's
  bars sum to the hero total under the same period/filters).

**Key Files**:
- `tests/tst_BreakdownMath.qml` (sold/purchased grouping math)
- `tests/tst_RealisedMath.qml` (realised money aggregator — `byDimension`/`totals`/`bucketWalk`/`nameMerge`; asserts the Σ byDimension == totals == Σ bucketWalk reconciliation invariant under each active filter)
- `tests/tst_OrderMath.qml` (allocation, `eventProfit`, `refundPerUnit`)
- `tests/tst_ImportMath.qml` (import SKU rename suffix)
- `tests/tst_PagingHelper.qml` (cursor-merge/hasMore logic, SKILLS Skill 32 — verified via a Node port
  of the same cases in this session, not yet run under a real `qmltestrunner`)
- `tests/tst_RealisedMathParityFixtures.qml`, `tests/tst_BreakdownMathParityFixtures.qml` — **paired**
  with `functions/test/{realisedMath,breakdownMath}.test.js` (SKILLS Skill 34). Same literal fixture
  data in both; proves the Node-ported math (`functions/lib/`) agrees with the QML original. If you
  change a scenario in one file of a pair, change it in the other too.
- `tests/tst_OrdersStore_applyAdjustment.qml` (2026-08-10, SKILLS Skill 37) — regression coverage
  for the `applyAdjustment` before/after snapshot aliasing bug: asserts `before`/`after` end up as
  independent array references (not the same shared array a `.push()` would leave them as), covers
  both the first-adjustment and second-adjustment-appended-to-existing-history cases, plus a
  functional sanity check that local order state still updates correctly.
- `tests/tst_DataModel_adjustOrderSyncGuard.qml`, `tests/tst_TransactionStore_syncRetry.qml`
  (2026-08-11, SKILLS Skill 38) — regression coverage for the ledger-sync race: the first asserts
  `DataModel._tryAdjustOrder` refuses a completed-order adjustment while `TransactionStore.hasMore`
  is true (with no side effects — no ledger entry written, no order mutation enqueued), proceeds
  normally once synced, and doesn't weaken the pre-existing pending-order-can't-be-adjusted check;
  the second covers `TransactionStore`'s new retry backoff math in isolation (first-attempt delay,
  exponential growth, the 30s cap, single-shot timer) — NOT the actual network failure/retry
  round-trip, which needs on-device verification (kill the network mid-sync, confirm it keeps
  retrying with growing delays instead of leaving `hasMore` stuck). `DataModel.qml` has no
  `pragma Singleton` (unlike the stores), so its test instantiates it directly as a child item
  rather than referencing it by name — first test coverage for this file.
- `tests/tst_TransactionStore_resetGuard.qml` (2026-08-12, SKILLS Skill 39) — regression coverage
  for the concurrent-reset race Taher found and fixed on-device: asserts `_resetAndFetch()` is a
  no-op (doesn't wipe `entries`/`_cursor`) while `loadingMore` is already true, and still resets
  normally when nothing is in flight. The "nothing in flight" case deliberately lets a real
  `_fetchFromFirebase()` call run (same no-real-network safety pattern as `tst_Gateway.qml` — empty
  `AuthStore.idToken`), so it also stops any retry timer that call schedules in `cleanup()` to avoid
  bleeding into other test files.
- `tests/tst_SettingsPath.qml` (new file), `tests/tst_AuthStore.qml` (new file — first-ever
  coverage for `AuthStore`, deliberately scoped to session persistence only, not the role/permission
  surface), and two new cases in `tests/tst_OutboxStore.qml` (2026-08-17, SKILLS Skill 41) — the
  QSettings org-identifier fix and its regression coverage. The `tst_OutboxStore.qml` durability case
  is the one that actually *proves* the fix rather than documenting intent: it fails
  (`pendingCount` comes back `0`) without the fix, because the write never reached a real file.
- `tests/tst_InventoryStore_cloneSymmetry.qml`, `tests/tst_InventoryStore_upsertMany.qml`,
  `tests/tst_StockSnapshotMath.qml` (2026-08-22, SKILLS Skill 46, review of `pr_taher_bug_fixes`) —
  first-ever direct unit coverage for `InventoryStore`'s create/clone symmetry and bulk-import SKU
  handling (previously zero tests touched `_upsertManySync`/`generateSku`/`addProduct`'s payload at
  all), plus new coverage for `SalesPage.qml`'s stock-snapshot export via a newly-extracted pure
  helper, `qml/helper/StockSnapshotMath.js` (same pattern as `ImportMath.js`/`OrderMath.js`). Verified
  clean (498 passed, 0 failed) in a throwaway scratch copy with a Qt-6.4.2 compat shim — see Skill 46
  for why this Cloud sandbox's real `qmltestrunner` run always shows 14 unrelated pre-existing
  compile failures (`Settings is not a type` under Qt 6.4.2 vs CI's 6.8) that aren't a real signal.
- 26 suites total (14 pre-existing + 3 from the 2026-08-08 session + 1 from 2026-08-10 + 2 from
  2026-08-11 + 1 from 2026-08-12 + 2 from 2026-08-17 + 3 from 2026-08-22). Historical baseline before
  those 9 new suites (pre-2026-08-22 count; the 3 newest aren't included in this older tally):
  **140 cases pass, 0 fail** — none of the 9 newest suites have been run under a real `qmltestrunner`
  yet (this repo's Cloud sessions don't have the Windows/Felgo toolchain; the 3 from 2026-08-08 have
  Node-side twins that do pass, 7/7, via `cd functions && npm test` — the other 6 have no Node-side
  twin, since the logic under test lives directly in QML singletons/components and isn't
  Node-portable the way the pure `functions/lib/` math is).
- **New, separate test surface: `functions/test/`** (`node:test`, run via `cd functions && npm
  test`) — covers the Node-ported `functions/lib/` math. Not part of the `qmltestrunner` suite; a
  different runtime, kept in parity via the paired fixture files above, not by sharing one file
  (QML has no established pattern here for reading an external JSON file synchronously in a test).
- **New, separate test surface: `test/e2e/`** (`qmltestrunner -input test/e2e`, run in CI's
  `e2e-tests` job against the real Firebase Local Emulator Suite — Firestore + Auth + Functions,
  started via `firebase emulators:start`, seeded via `node test/e2e/seed.js`) — real code path
  (Store/DataModel → `Gateway` → the *emulated* Cloud Functions → the *emulated* Firestore), not
  a mock. Verifies via a raw REST GET against the Firestore emulator, independent of the client's
  own optimistic local state. Distinct from `tests/` in three ways worth knowing before adding a
  third scenario here:
  - **Every Cloud Function URL Gateway calls has to be pointed at the emulator explicitly** —
    `Gateway.functionUrl` (`recordMutation`), `Gateway.deltaFunctionUrl` (`recordDelta`, added
    2026-08-16 for the Orders scenario — `StockBatchStore.consumeFifo`/`InventoryStore.deductStock`
    go through this, not `recordMutation`), restored in `cleanup()`. `Gateway.batchFunctionUrl`
    isn't wired yet — nothing in `test/e2e/` exercises a deferred-write batch path so far.
  - **The Cloud Functions Emulator cold-starts each function on its own first real invocation** —
    `initTestCase()` in each file pays that cost with a dedicated warm-up POST (bypassing
    Gateway/OutboxStore) before any real test runs, sized for a one-time cold start rather than
    inflating every test's own timeout. `tst_OrdersE2E.qml`'s `recordDelta` warm-up deliberately
    expects HTTP 404 (a delta against a nonexistent entityId — confirmed against
    `functions/lib/gatewayLogic.js`'s `applyDelta()`), not 200 — a real function needs a real doc
    to move.
  - **Referencing `AuthService` for the first time triggers its `Component.onCompleted`, which
    unconditionally wipes `AuthStore`** — every file's `initTestCase()` forces that construction
    (`AuthService.ensureFreshToken()`, a harmless no-op call) before its own `init()` sets
    `AuthStore.idToken` for real, or the wipe silently lands after and every write goes out with
    an empty token. Root-caused 2026-08-14 after it cost several rounds of "doc never appeared,
    no visible reason" — see `docs/superpowers/specs/2026-08-16-e2e-testing-phase1-CHECKPOINT.md`
    for the full trace if it resurfaces somewhere this note doesn't cover.
  - Shared plumbing (`loadFixture`/`pollEmulatorDoc`/`postDirect`) lives in
    `test/e2e/E2EHelpers.js` (`.pragma library`, extracted 2026-08-16 when a second scenario
    needed it) — every function takes the calling `TestCase` instance explicitly and calls
    `tc.tryVerify`/`tc.fail`/`tc.compare` through it, since pragma-library scripts don't share the
    QML component scope a bare `tryVerify(...)` resolves against inside a `TestCase` file itself.
  - `DataModel.qml` orchestration (as opposed to a single Store) is reached the same way
    `tests/tst_DataModel_adjustOrderSyncGuard.qml` already established — instantiated directly as
    a child item, since it has no `pragma Singleton`.
  - Two scenarios so far: `tst_InventoryE2E.qml` (Phase 1 — CRUD, one Store) and
    `tst_OrdersE2E.qml` (create → complete → FIFO stock deduction, crosses `OrdersStore` →
    `DataModel` → `StockBatchStore`/`InventoryStore` → `TransactionStore`). Not yet covered here:
    the `stock_batch.qtyRemaining` doc directly, the generated transaction doc, and anything
    UI/dialog-level — that last one is Phase 2, gated on an unresolved Felgo headless-rendering
    question (do `dp()`/`sp()`/`Constants` resolve outside an `App{}` root), tracked separately
    from this test surface.

**Example Prompts**:
- "Add tests for the new breakdown metric"
- "Write a TestCase covering the week/month period windows"
- "Add a parity fixture pair for a new RealisedMath scenario, in both functions/test/fixtures/ and
  the matching tst_RealisedMathParityFixtures.qml"
- "Add an E2E scenario for [workflow] against the Firebase emulator, following the pattern in
  test/e2e/tst_OrdersE2E.qml"

---

## Agent Usage Patterns

### Adding a New Domain (e.g. Suppliers)

1. **Store & Firebase Agent** → Create `qml/model/SuppliersStore.qml`, register in `qmldir`
2. **Logic & Signal Bus Agent** → Add `addSupplier(...)`, `supplierAdded(...)` signals to `Logic.qml`
3. **Data Model Agent** → Add `onAddSupplier` handler in `DataModel.qml`
4. **Pages & Dialogs Agent** → Create `qml/pages/SuppliersPage.qml` and dialog(s)
5. **App Architecture Agent** → Add `NavigationItem` for Suppliers in `Main.qml`, wire dialog

### Adding / Changing Analysis Breakdowns

1. **Shared Components Agent** → Add/extend the grouping math in the pure libs: `RealisedMath.js` for REALISED money (revenue/profit/totals), `BreakdownMath.js` for sold/purchased units. Never aggregate realised money from live orders — use the event log (SKILLS Skill 29).
2. **Testing & QA Agent** → Add a `TestCase` asserting the new math reconciles (Σ byDimension == totals == Σ bucketWalk under the same scope).
3. **Pages & Dialogs Agent** → Wire it in `SalesPage.qml` via `InventoryStore.realisedProfitByDimension(field, scope)` / `_breakdownByDimension()` + a `BreakdownBarCard`; extend `buildAnalysisExport()` if the export should mirror it. Build the scope with `_realisedScope(periodScoped)`.

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
