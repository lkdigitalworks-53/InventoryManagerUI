# AGENTS.md

## Overview
This file defines specialized agents and their roles for the InventoryManagerUI project. Each agent is designed to handle specific domains and modules, enabling efficient development through agentic workflows.

---

## Core Building Blocks

### 1. Build & Infrastructure Agent
**Purpose**: Manages CMake configuration, compilation, and build optimization.
**Scope**: Entire project (root + App_UI)
**Responsibilities**:
- Configure CMake: `cmake -S . -B build -G "Ninja"`
- Build projects: `cmake --build build`
- Manage build artifacts and caching
- Platform-specific build configurations (Android, iOS, Desktop)
- Development vs. publishing build modes
- Dependency verification (CMake, Ninja, Qt, Felgo)
 - Ensure Android Gradle properties are numeric and avoid using `.toInteger()` in Gradle files; prefer setting `QT_ANDROID_TARGET_SDK_VERSION` / `QT_ANDROID_COMPILE_SDK_VERSION` via CMake `set_target_properties()` for the `appInventoryManagerUI` target.

**Key Files**:
- `CMakeLists.txt` (root)
- `App_UI/CMakeLists.txt`
- `android/CMakeLists.txt` (if exists)

**Example Prompts**:
- "Build the InventoryManagerUI project"
- "Switch to publishing build mode"
- "Fix build errors for Android"

---

### 2. Felgo Plugin & Architecture Agent
**Purpose**: Manages the Felgo-based application structure, plugin system, and navigation.
**Scope**: Root `qml/` directory
**Responsibilities**:
- Maintain Felgo App architecture (Navigation, NavigationItem, NavigationStack)
- Manage page navigation and plugin system
- Configure Firebase plugins
- Handle cross-platform lifecycle (Android lifecycle management)
- Manage theming with CustomeTheme
- Hot Reload setup and configuration

**Key Files**:
- `qml/Main.qml` (root application)
- `qml/pages/` (all pages: Dashboard, Orders, Inventory, Profile, etc.)
- `qml/logic/Logic.qml` (signal definitions)
- `qml/helper/CustomeTheme.qml`
- `main.cpp` (Felgo initialization)

**Architecture Pattern**:
```
Navigation (root)
├── NavigationItem (Dashboard)
│   └── NavigationStack
│       └── Page
├── NavigationItem (Profile)
└── ...
```

**Example Prompts**:
- "Add a new page to the navigation"
- "Enable Felgo Hot Reload for development"
- "Debug page navigation issues"

---

### 3. Firebase & Authentication Agent
**Purpose**: Handles Firebase integration, authentication, and real-time database operations.
**Scope**: Firebase configuration and API integration
**Responsibilities**:
- Verify Firebase credentials (API keys, project ID)
- Configure authentication (login, logout, session management)
- Manage real-time database operations (read, write, listen)
- Debug network requests and API failures
- Handle Firebase permission and security rules
- Cloud Functions integration (local: `http://127.0.0.1:5001/...`)

**Key Files**:
- `qml/helper/Constants.qml` (API endpoints, Firebase config)
- `qml/model/RestAPI.qml` (network requests)
- `qml/pages/FirebaseLoginPage.qml` / `FirebasePage.qml` (if used)
- `qml/pages/LoginPage.qml`
- `android/build.gradle` (Firebase Android config, if applicable)

**Firebase Project**:
- Project ID: `inventorymanager-48392`
- Local Cloud Function URL: `http://127.0.0.1:5001/inventorymanager-48392/us-central1/`

**Example Prompts**:
- "Verify Firebase API keys are correct"
- "Debug authentication failures"
- "Set up Firebase Cloud Functions"
- "Test database read/write operations"

---

### 4. Core Data Model Agent
**Purpose**: Manages data models, state, and REST API interactions.
**Scope**: `qml/model/` and related logic
**Responsibilities**:
- Maintain DataModel.qml (centralized state management)
- Implement REST API calls (RestAPI.qml)
- Manage inventory, orders, and product data
- Handle API response processing
- Implement data caching with Storage
- Error handling and network state management

**Key Files**:
- `qml/model/DataModel.qml` (main data state)
- `qml/model/RestAPI.qml` (HTTP requests)
- `qml/logic/Logic.qml` (action signals)
- `qml/logic/ViewHelper.qml` (view utilities)

**Data Structures**:
- Inventory: `_inventory.inventoryDataJson`
- Orders: `_orders.ordersDataJson`
- Auth: `_.userLoggedIn`

**Example Prompts**:
- "Add a new data model for products"
- "Debug API response parsing"
- "Implement data caching for inventory"

---

### 5. Business Management UI Agent (App_UI)
**Purpose**: Manages the business management frontend (Qt6-based, shared module).
**Scope**: `App_UI/` directory
**Responsibilities**:
- Develop and maintain Order Management UI
- Create responsive layouts (compact/full variants)
- Implement SegmentedNav for tab-like navigation
- Build dialogs (NewOrderDialog, OrderDetailDialog)
- Create data presentation components (OrderRow, CardKPI, StatusBadge)
- Handle responsive design for desktop and mobile
- Manage Orders store (OrdersStore.qml)

**Key Files**:
- `App_UI/qml/Main.qml` (ApplicationWindow, header, navigation)
- `App_UI/qml/OrdersPage.qml` (orders list and management)
- `App_UI/qml/OrdersStore.qml` (order data store)
- `App_UI/qml/OrderRow.qml` (responsive order row component)
- `App_UI/qml/SegmentedNav.qml` (navigation tabs)
- `App_UI/qml/CardKPI.qml` (metric cards)
- `App_UI/qml/NewOrderDialog.qml`, `OrderDetailDialog.qml` (dialogs)
- `App_UI/src/main.cpp`

**Module Info**:
- Module URI: `BusinessApp`
- Version: 1.0
- Imported as: `import BusinessApp 1.0`

**Responsive Design**:
- Compact mode: `width < 480`
- Full mode: wider layouts
- Dynamic margin and padding calculations

**Example Prompts**:
- "Add a new column to the orders table"
- "Create a responsive card component"
- "Fix the order dialog layout"
- "Implement order filtering"

---

### 6. C++ Integration Agent
**Purpose**: Manages C++ backend code and Felgo/Qt integration.
**Scope**: `main.cpp`, `src/`, and C++ class definitions
**Responsibilities**:
- Manage application lifecycle (FelgoApplication)
- Expose C++ models to QML if needed
- Handle native platform APIs
- Optimize performance-critical code
- Manage QML hot reload configuration
- Handle application initialization

**Key Files**:
- `main.cpp` (root Felgo app)
- `App_UI/src/main.cpp` (BusinessApp Qt app)
- `productinfotablemodel.hpp`, `.cpp` (if used)

**Example Prompts**:
- "Add a C++ model for database operations"
- "Expose a C++ function to QML"
- "Fix initialization issues"

---

### 7. Platform-Specific Agent
**Purpose**: Handles platform-specific configurations and deployment.
**Scope**: Platform directories and configuration files
**Responsibilities**:
- Manage Android build configuration (`android/`)
- Handle iOS deployment (`ios/`)
- Configure macOS app bundle (`macx/`)
 - Ensure `android/AndroidManifest.xml` includes a `<uses-sdk android:minSdkVersion="28" android:targetSdkVersion="35"/>` entry and avoid `.toInteger()` calls in `android/build.gradle` that can break the Gradle build.
- Set Windows-specific resources (`win/app_icon.rc`)
- Platform-specific QML code paths
- Handle platform lifecycle events

**Key Files**:
- `android/AndroidManifest.xml`
- `android/build.gradle`
- `ios/Project-Info.plist`
- `ios/Launch Screen.storyboard`
- `macx/` (macOS bundle resources)
- `win/app_icon.rc` (Windows icon)

**Example Prompts**:
- "Configure Android permissions"
- "Build for iOS"
- "Set app icon for all platforms"

---

### 8. Deployment & Publishing Agent
**Purpose**: Manages the publishing pipeline and production builds.
**Scope**: Build configuration, QML compilation, packaging
**Responsibilities**:
- Switch to publishing build mode
- Compile QML into binary (resource bundling)
- Configure license keys
- Manage version numbers (PRODUCT_VERSION_NAME, PRODUCT_VERSION_CODE)
- Generate deployment packages
- Handle signing and code protection
- Test on target platforms

**Key Configuration**:
- Product ID: `com.yourcompany.wizardEVAP.InventoryManagerUI`
- Version: `1.0.0` (version name), `1` (version code)
- Stage: `test` or `publish`

**Build Mode Differences**:
- **Development**: `deploy_resources()` - fast iteration, QML files not compiled
- **Publishing**: Compiled QML, protected source code, load from `qrc:/`

**Example Prompts**:
- "Switch to publishing build mode"
- "Package for Android App Store"
- "Generate iOS build for App Store"

---

## Agent Usage Patterns

### For New Feature Development
1. **QML Development Agent** → Create new page/dialog
2. **Core Data Model Agent** → Connect to DataModel
3. **Felgo Plugin & Architecture Agent** → Add navigation route
4. **Business Management UI Agent** → If visual component, style it

### For Bug Fixes
1. **Build & Infrastructure Agent** → Rebuild
2. **Identify affected agent** → Apply fix
3. **Firebase & Authentication Agent** → If network-related
4. **Platform-Specific Agent** → If platform-specific issue

### For Deployment
1. **Deployment & Publishing Agent** → Configure publishing mode
2. **Build & Infrastructure Agent** → Build for target platform
3. **Platform-Specific Agent** → Platform-specific packaging
4. **Testing**: Verify on actual devices

---

## Example Prompts for Agent Mode
- "Build and run the InventoryManagerUI project"
- "Add a new page for product management"
- "Debug Firebase authentication in the login flow"
- "Create a responsive card component for inventory metrics"
- "Package the app for Android release"
- "Add a new data model for warehouse locations"
- "Fix the orders page layout for mobile devices"
- "Configure iOS deployment with proper certificates"