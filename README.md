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

All data is persisted locally via `QtCore.Settings` and synced to **Firebase Realtime Database** via a REST API layer.

---

## Tech Stack

- **Framework**: Felgo SDK (Qt-based cross-platform)
- **Language**: QML + JavaScript
- **Database**: Firebase Realtime Database (REST)
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

Firebase Realtime Database is accessed via REST (`FirebaseService.qml`).

The database URL is configured in `qml/helper/Constants.qml`:
```qml
readonly property string firebaseDatabaseUrl: "https://<project-id>-default-rtdb.<region>.firebasedatabase.app"
```

Data paths:
- `orders/` – order records
- `inventory/` – product records
- `sales/` – aggregate sales data
- `staff/` – staff member records

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
