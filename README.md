# BusinessManagement – Felgo QML App

A cross-platform inventory and business management application built with **Felgo SDK** and **QML**, targeting Android and iOS (with desktop support during development).

---

## Features

| Module | Capabilities |
|--------|-------------|
| **Orders** | Create, view, approve, and track customer orders; stock-checked order completion; batch approval |
| **Inventory** | Product catalog, stock level tracking, low-stock alerts, restock workflows |
| **Sales** | Revenue analytics, order volume charts, top-selling products, cumulative sales metrics |
| **Staff** | Team member management, department distribution, activity feed, leave tracking |

Data is synced to **Cloud Firestore** via a REST API layer (`FirebaseService.qml`), with one
Firestore database per environment (dev/test/prd — see "Environments" below).

---

## Tech Stack

- **Framework**: Felgo SDK (Qt-based cross-platform)
- **Language**: QML + JavaScript
- **Database**: Cloud Firestore (REST, one database per env — dev/test/prd)
- **Build**: CMake 3.16+, Ninja
- **Targets**: Android (min SDK 28, target SDK 34), iOS, Desktop

---

## Project Structure

```
App_UI/
├── CMakeLists.txt          # Felgo build configuration
├── main.cpp                # Felgo application bootstrap
├── assets/                 # Static assets (images, fonts)
├── src/
│   └── main.cpp            # (legacy Qt bootstrap – superseded)
└── qml/
    ├── Main.qml            # Felgo App root: theme → logic → dataModel → navigation
    ├── model/              # Data layer (singletons + orchestrator)
    │   ├── qmldir
    │   ├── DataModel.qml   # Orchestrator, cross-store coordination
    │   ├── OrdersStore.qml
    │   ├── InventoryStore.qml
    │   ├── SalesStore.qml
    │   ├── StaffStore.qml
    │   └── FirebaseService.qml
    ├── logic/              # Signal bus and view utilities
    │   ├── Logic.qml       # Pure signal relay (action dispatcher)
    │   └── ViewHelper.qml  # Formatting helpers
    ├── helper/             # Reusable UI components and constants
    │   ├── qmldir
    │   ├── Constants.qml   # Singleton: colors, breakpoints, URLs
    │   ├── CustomeTheme.qml
    │   ├── CardKPI.qml
    │   ├── StatusBadge.qml
    │   ├── OrderRow.qml
    │   ├── SegmentedNav.qml
    │   ├── InlineDatePicker.qml
    │   └── PlaceholderPage.qml
    └── pages/              # Feature pages and dialogs
        ├── OrdersPage.qml
        ├── InventoryPage.qml
        ├── SalesPage.qml
        ├── StaffPage.qml
        ├── NewOrderDialog.qml
        ├── OrderDetailDialog.qml
        ├── AddProductDialog.qml
        ├── AddStaffDialog.qml
        └── RestockDialog.qml
```

---

## Architecture

The app follows a layered architecture aligned with the **InventoryManagerUI** Felgo pattern:

```
App (Main.qml)
├── CustomeTheme          – global style/color tokens
├── Logic                 – signal bus (pure dispatcher, no logic)
├── DataModel             – state orchestrator, wired to Logic
│   ├── OrdersStore       – order CRUD + Firebase sync
│   ├── InventoryStore    – product CRUD + stock management
│   ├── SalesStore        – aggregated sales metrics
│   └── StaffStore        – staff CRUD
├── ViewHelper            – formatting utilities (currency, numbers)
└── Navigation            – Felgo tabbed navigation
    ├── NavigationItem: Orders   → NavigationStack → OrdersPage
    ├── NavigationItem: Inventory → NavigationStack → InventoryPage
    ├── NavigationItem: Sales     → NavigationStack → SalesPage
    └── NavigationItem: Staff     → NavigationStack → StaffPage
```

### Data Flow

```
User action on Page
  → emits signal via Logic (e.g. logic.addOrder(...))
    → DataModel Connections handler receives signal
      → delegates to appropriate Store
        → Store updates local state + persists to Settings + pushes to Firebase
          → UI binding updates reactively
```

---

## Building

### Prerequisites

- [Felgo SDK](https://felgo.com/download) installed
- CMake 3.16+
- Ninja build system
- Android NDK (for Android builds)

### Development Build (Desktop)

```bash
cmake -S . -B build -G "Ninja"
cmake --build build
```

### Android Build

```bash
cmake -S . -B build-android -G "Ninja" \
  -DCMAKE_TOOLCHAIN_FILE=$ANDROID_NDK/build/cmake/android.toolchain.cmake \
  -DANDROID_ABI=arm64-v8a \
  -DANDROID_PLATFORM=android-28
cmake --build build-android
```

### Publishing Mode

Before publishing to app stores:

1. Set your Felgo license key in `CMakeLists.txt`:
   ```cmake
   set(PRODUCT_LICENSE_KEY "your-key-here")
   ```
2. In `CMakeLists.txt`, comment `deploy_resources(...)` and uncomment `QML_FILES`/`RESOURCES`
3. In `main.cpp`, switch to the `qrc:/` path:
   ```cpp
   felgo.setMainQmlFileName(QStringLiteral("qrc:/qml/Main.qml"));
   ```
4. Set `PRODUCT_STAGE "publish"` in `CMakeLists.txt`

---

## Firebase Configuration

Cloud Firestore is accessed via its v1 REST API (`FirebaseService.qml`), env-aware — see
"Environments" below for the full dev/test/prd resolution chain.

The database URL is built in `FirebaseService.qml` from the resolved `databaseId`:
```qml
readonly property string databaseUrl:
    "https://firestore.googleapis.com/v1/projects/" + projectId + "/databases/" + databaseId + "/documents"
```

Top-level collections (all tenant-scoped under `tenants/{tenantId}/...`):
- `orders/` – order records
- `inventory/` – product records
- `staff/` – staff member records
- `suppliers/` – supplier records
- `transactions/` – immutable ledger event log (see `AGENTS.md`'s Compliance & Audit Agent)
- `stock_batches/` – FIFO stock batches
- `audit_log/` – compliance gateway's append-only mutation ledger, server-written only
  (`Gateway.recordMutation`/`recordMutations`/`recordDelta` → Cloud Functions). All 5 working-tier
  stores route through it, and it's live — `Gateway.mode` is `"gateway"` (flipped 2026-07-29). See
  AGENTS.md §8's "P0 implementation status."
- `locks/` – short-lived pessimistic locks (Component 2 of the async-write-sequencing design,
  below), server-written only. Not part of P0's compliance scope — a concurrency-control aid, not
  ledger data.
- `activity_log/` – staff activity feed
- `config/categories`, `config/orderChannels` – single-document settings, not paginated collections

All six growing collections (`orders`/`inventory`/`staff`/`suppliers`/`transactions`/
`stock_batches`) are read via bounded, cursor-paginated queries — see "Scaling" above and
`SKILLS.md` Skill 32.

---

## Configuration

| CMake Variable | Default | Description |
|----------------|---------|-------------|
| `PRODUCT_IDENTIFIER` | `com.lkdigitalworks.business.management.app` | App bundle ID |
| `PRODUCT_VERSION_NAME` | `1.0.0` | Human-readable version |
| `PRODUCT_VERSION_CODE` | `1` | Numeric version for stores |
| `PRODUCT_STAGE` | `test` | `test` or `publish` |
| `PRODUCT_LICENSE_KEY` | _(empty)_ | Felgo license key |

---

## Development Tips

- **Hot Reload**: Uncomment `FelgoHotReload` lines in `CMakeLists.txt` and `main.cpp` for fast QML iteration without recompiling C++
- **Offline seed data**: Each store contains seed data so the app works without Firebase on first launch
- **Responsive design**: `compact: width < 520` breakpoint adapts layouts for mobile screen widths
- **Breakpoints and colors**: Centralised in `qml/helper/Constants.qml` — change once, applies everywhere

---

## Qt Skills Cheat Sheet

This repository now includes local Copilot agents mapped from the Qt skills repo:

- `.github/agents/qt-qml.agent.md`
- `.github/agents/qt-qml-review.agent.md`
- `.github/agents/qt-qml-docs.agent.md`
- `.github/agents/qt-cpp-review.agent.md`

Use these ready-to-paste prompts in chat.

### QML implementation prompts

```text
Use @qt-qml to update qml/pages/OrdersPage.qml and add a compact-friendly filter row for Pending/Approved/Completed orders. Keep existing project conventions.
```

```text
Use @qt-qml to implement a reusable low-stock warning banner in qml/helper and integrate it in qml/pages/InventoryPage.qml.
```

### Store + DataModel prompts

```text
Use @qt-qml to add delete-order flow across qml/logic/Logic.qml, qml/model/DataModel.qml, and qml/model/OrdersStore.qml, then wire the action in qml/pages/OrdersPage.qml.
```

```text
Use @qt-qml to add supplier support with a new store and DataModel wiring, following the existing singleton + logic-signal pattern.
```

### Review prompts

```text
Use @qt-qml-review to review all changed QML files in this branch and report only high-confidence findings with file and line references.
```

```text
Use @qt-cpp-review to review CMakeLists.txt and main.cpp for Qt/Felgo correctness and integration risks.
```

### Documentation prompts

```text
Use @qt-qml-docs to generate Markdown docs for qml/pages/OrdersPage.qml and qml/pages/NewOrderDialog.qml.
```

```text
Use @qt-qml-docs to document all components listed in qml/pages/DOCS_CHECKLIST.md and update completion checkboxes.
```

---

## Changed-Files Review Template

Use this helper to auto-generate a review prompt based on currently changed QML files:

```powershell
powershell -ExecutionPolicy Bypass -File .vscode/process/review-changed-qml.ps1
```

Outputs:

- Changed QML file list (staged + unstaged)
- A ready-to-paste `@qt-qml-review` prompt

Optional flags:

```powershell
powershell -ExecutionPolicy Bypass -File .vscode/process/review-changed-qml.ps1 -StagedOnly
powershell -ExecutionPolicy Bypass -File .vscode/process/review-changed-qml.ps1 -UnstagedOnly
```

---

## QML Pages Docs Checklist

Documentation checklist for all page/dialog components is tracked in:

- `qml/pages/DOCS_CHECKLIST.md`

Use it during feature completion to keep docs coverage consistent.

---

## Environments (dev / test / prd)

The app selects its Firestore database at **build time** from `PRODUCT_STAGE` in
`CMakeLists.txt`:

| PRODUCT_STAGE | env  | Firestore database |
|---------------|------|--------------------|
| `dev`         | dev  | `dev`              |
| `test`        | test | `test`             |
| `publish`     | prd  | `(default)`        |

Unknown/unset stage falls back to **prd** (`(default)`), so a misconfigured
release never points at an empty dev database. The resolution chain is
`PRODUCT_STAGE` → `PRODUCT_STAGE_DEF` (CMake compile def) → `APP_STAGE` (QML
context property, set in `main.cpp`) → `EnvConfig.js` → `FirebaseService.databaseId`.
On non-production builds a `DEV`/`TEST` badge shows in Profile settings.

### One-time backend setup (per non-default database)

> **Requires the Blaze (pay-as-you-go) billing plan.** The free Spark plan allows
> only the single `(default)` database; creating named databases returns HTTP 403
> "This API method requires billing to be enabled". Until Blaze is on, build with
> `PRODUCT_STAGE "publish"` (uses `(default)`).
>
> **Region: `asia-south1` (Mumbai), consistently across the whole project.**
> Confirmed via `gcloud firestore databases list --project=inventorymanager-48392`
> that `(default)` is genuinely in `asia-south1` — not `asia-southeast1` as an
> earlier version of this doc and `AGENTS.md` assumed. Cloud Functions
> (`recordMutation`, `provisionMember`, `runCutover`, `computeAnalysis`,
> `recordMutationsBatch`) are not yet deployed and have been reconfigured to
> also target `asia-south1`, so DB, Functions, and every named environment
> database live in the same region — data never leaves India, and no
> cross-region latency between Functions and
> Firestore. (A non-default database's region does *not* have to match
> `(default)`'s per Firestore's own rules — we're choosing to match here for
> residency/latency consistency, not because it's required.)
>
> Note: `android/google-services.json`'s `firebase_url` field
> (`...asia-southeast1.firebasedatabase.app`) is the **Realtime Database**
> URL, an unrelated Firebase product this app doesn't use. It was the likely
> source of the earlier asia-southeast1 confusion — ignore it when reasoning
> about Firestore's region.
>
> **Database ids are 4–63 chars** (`[a-z0-9-]`), so `dev` (3 chars) is rejected —
> we use `dev1`. `test` is fine. The `PRODUCT_STAGE`→env→databaseId mapping in
> `qml/helper/EnvConfig.js` (and its mirror in `functions/index.js`) already maps
> the `dev` env to database id `dev1` — if you change the id again, update both.

```bash
firebase firestore:databases:create test --location=asia-south1
firebase firestore:databases:create dev1 --location=asia-south1   # 'dev' is too short
```

Then apply the same security rules (`FIRESTORE_RULES.md`) to each database
(Firebase console → Firestore → select database → Rules, or
`firebase deploy --only firestore:rules` targeting each database).

Auth users, Storage, and Cloud Functions are **shared** across environments —
only the Firestore database differs. `test`/`dev1` start empty (MVP fresh-data).

All 5 Cloud Functions (`recordMutation`, `provisionMember`, `runCutover`, `computeAnalysis`,
`recordMutationsBatch`) resolve their Firestore database **per request** from a client-declared
`env` field (`scopedDb(env)` in `functions/index.js`), mirroring this exact resolution chain — see
`SKILLS.md` Skill 33. This closes a real, confirmed gap: before this fix, every Cloud Function
always read/wrote the `(default)` (prd) database regardless of which env the calling client was
built for.

---

## Scaling: pagination & server-side analytics

Two problems, fixed separately (full design: `docs/superpowers/specs/
2026-07-06-scale-reads-writes-analytics-design.md`):

- **Reads** — every growing collection (`inventory`, `orders`, `staff`, `suppliers`,
  `transactions`, `stock_batches`) now pages in bounded chunks via `FirebaseService.query()`
  (Firestore's `:runQuery`, cursor-based) instead of one unbounded `get()`, which silently
  truncated once a collection crossed Firestore's internal response-size threshold. All six
  currently auto-page to exhaustion (full local data, same app behavior — several of them are read
  by correctness-critical logic today, like FIFO stock consumption and Dashboard KPIs, that assumes
  the complete set; see the spec §3.1 for why a "recent window" isn't safe for those yet). See
  `SKILLS.md` Skill 32.
- **Writes** — `OrdersStore`, `StaffStore.addStaff`, and `ActivityLog` used to rebuild their entire
  collection into one bulk Firestore commit on every single-record mutation, which hard-fails past
  Firestore's 500-write-per-commit cap. Fixed to single-doc writes. See `SKILLS.md` Skill 12.
  **Superseded 2026-07-11**: every store's mutations (`Inventory`/`StockBatch`/`Orders`/`Staff`/
  `Supplier`) now route through the compliance gateway (`Gateway.recordMutation`/`recordMutations`
  — see AGENTS.md §8, `SKILLS.md` Skill 35) instead of calling `FirebaseService` directly.
  `approveAllPending`'s bulk update specifically now uses `Gateway.recordMutations` (one atomic
  transaction, capped at 200 items) — the old `FirebaseService.putMany()` call there is gone.
  Functionally live as of 2026-07-29 (`Gateway.mode` is `"gateway"`), and this is the current code
  path, not the one described just above. As of the async-write-sequencing design (below),
  `InventoryStore.deductStock`/`StockBatchStore`'s FIFO functions route through
  `Gateway.recordDelta` instead — an atomic server-side delta, not a client-computed absolute value
  — for the same reason `approveAllPending` needed a batch endpoint: naive per-write races.
- **Analytics** — a new `computeAnalysis` Cloud Function runs Revenue/Profit/Sold/Purchased
  aggregation server-side (ported `RealisedMath`/`BreakdownMath`, parity-tested against the QML
  originals via shared fixtures), so this no longer needs the full transaction ledger resident on
  the phone. `AnalysisService.qml` is the client for it. **Not yet wired into `SalesPage.qml`** —
  that page currently calls the local `InventoryStore.realisedProfitByDimension`/etc. adapters
  synchronously at 15+ call sites, and `AnalysisService.compute` is necessarily async, so the
  cutover is a real rewrite of that page's data flow, deferred as its own future project (spec §9.1).
  See `SKILLS.md` Skill 34.

---

## Concurrency & Conflict Resolution

Full design: `docs/superpowers/specs/2026-07-29-async-write-sequencing-design.md`. Four pieces,
addressing three separate bugs found while investigating one reported symptom (an order silently
reverting from "completed" to "pending"):

- **Client single-flight-per-record** (`OutboxStore`/`Gateway.qml`) — a device's own outbox no
  longer fires overlapping writes at itself for the same record; a second write arriving while the
  first is still in flight coalesces into a held follow-up instead of racing it.
- **Pessimistic record locking** (`locks/` collection, `Gateway.acquireLock`/`releaseLock` Cloud
  Functions, `LockManager.qml`) — proactive cross-device conflict avoidance: opening an editable
  dialog (product, staff, order) acquires a lock first, so a second device finds out immediately
  rather than doing real edit work only to be rejected at save time. TTL + client renewal, no
  cleanup job — an abandoned session just expires.
- **Server-side compare-and-swap** (`applyMutation` in `gatewayLogic.js`) — a backstop, not the
  primary mechanism now that locking exists: rejects a mutation whose `before` doesn't match the
  record's actual current state, instead of blindly overwriting.
- **Atomic server-side deltas** (`applyDelta`, `Gateway.recordDelta`) — quantity fields
  (`inventory.stock`, `stock_batch.qtyRemaining`/`qtyReceived`) are adjusted by a server-computed
  delta inside the Firestore transaction, not a client-computed absolute value — two legitimate
  concurrent stock movements on the same product both apply correctly instead of one clobbering
  the other. Supports either rejecting (`floors`) or clamping (`clamps`) at a boundary, per caller.

**Known, deliberately unfinished piece:** `DataModel._tryAdjustOrder` (order returns/exchanges)
was NOT given the same async-await treatment `_tryCompleteOrder` got, and `OrderDetailDialog`'s
order-level lock doesn't span into the subsequent `ConfirmReturnSheet` confirmation step — both
flagged as real follow-up work in the design doc, not solved in this pass.

---
