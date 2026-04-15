# SKILLS.md

## Overview
This file defines the skills, tools, and knowledge domains required for effective development and agentic workflows on the InventoryManagerUI project. Skills are organized by domain and mapped to the agents defined in AGENTS.md.

---

## Core Build Skills

### CMake & Build System
**Required for**: Build & Infrastructure Agent, Deployment & Publishing Agent   
**Knowledge Areas**:
- CMake 3.16+ syntax and commands
- Target configuration (qt_add_executable, qt_add_qml_module)
- Mobile-specific build configurations (Android, iOS)
- Felgo CMake extensions (`felgo_configure_executable`, `deploy_resources`)     
- Qt6 CMake integration
- Platform detection and conditional compilation

**Key Commands**:
```bash
cmake -S . -B build -G "Ninja"
cmake --build build
cmake --build build --target clean
```

**Critical Files to Understand**:
- `CMakeLists.txt` (root project - Felgo-based)
- `App_UI/CMakeLists.txt` (BusinessManagement - Qt6-based)
- `android/CMakeLists.txt` configuration patterns if exists
 - Note: The root `CMakeLists.txt` can set Android Gradle SDK versions via a target property, for example:
     `set_target_properties(appInventoryManagerUI PROPERTIES QT_ANDROID_TARGET_SDK_VERSION 35 QT_ANDROID_COMPILE_SDK_VERSION 35)`

**Tools & Dependencies**:
- CMake 3.16+
- Ninja (build tool)
- Qt 6.5 / 6.8
- Felgo SDK

---

## QML & Frontend Skills

### QML Language & Syntax
**Required for**: Felgo Plugin & Architecture Agent, Business Management UI Agent, Core Data Model Agent
**Knowledge Areas**:
- QML type system (Item, Rectangle, Text, etc.)
- Property binding and reactive programming
- Signals and slots architecture
- QML import system
- Component composition and reusability
- Qt Quick Controls 2 (buttons, dialogs, layouts)
- Qt Quick Layouts (ColumnLayout, RowLayout, GridLayout)

**Key Patterns in Project**:
```qml
// Component definition
Rectangle {
    anchors { /* positioning */ }
    property type propName: defaultValue
    signal mySignal(var data)

    MouseArea { onClicked: mySignal(data) }
}

// Data binding
Text { text: dataModel.value }

// Signal connections
Connections {
    target: logic
    function onSignal(data) { /* handle */ }
}
```

### Responsive Design
**Required for**: Business Management UI Agent
**Knowledge Areas**:
- Responsive layouts (compress for mobile, expand for desktop)
- StackLayout for variant switching
- Property-based responsive states
- Margin, padding, and spacing calculations
- Width constraints and bounded sizing

**Project Example**:
```qml
// OrderRow.qml - compact vs full layout
StackLayout {
    currentIndex: compact ? 1 : 0
    // Layout 0: Full 7-column row
    Row { /* full version */ }
    // Layout 1: Compact 2-column row
    Row { /* compact version */ }
}
```

### Felgo-Specific Skills
**Required for**: Felgo Plugin & Architecture Agent
**Knowledge Areas**:
- Felgo App framework (networking, analytics, purchases)
- Navigation system (NavigationStack, NavigationItem)
- Theme management (Felgo.Theme)
- Plugin system architecture
- Felgo lifecycle management
- Hot Reload setup and debugging
- Firebase plugin integration

**Key Felgo Components**:
- `App` (root application container)
- `Navigation` (tab-based navigation)
- `NavigationStack` (page stack navigation)
- `ListPage` (list view pages)
- `AppText`, `AppIcon`, `ScaledImage`
- `Theme` (color, size, spacing)

### Qt Quick Controls & Styling
**Required for**: Business Management UI Agent
**Knowledge Areas**:
- Dialog (modal windows)
- Button, CheckBox, ComboBox
- ScrollView and ListView
- Label styling and text properties
- Control palette and colors
- Custom palettes

---

## Data & State Management Skills

### QML Data Models
**Required for**: Core Data Model Agent
**Knowledge Areas**:
- ListModel and ListElement patterns
- Property binding in models
- Model updates and refresh patterns
- Caching strategies
- Data transformation and filtering
- JSON data handling (`JSON.parse`, `JSON.stringify`)

**Project Pattern**:
```qml
// DataModel.qml - centralized state
Item {
    readonly property bool isBusy: api.busy
    readonly property alias inventoryDataJson: _inventory.inventoryDataJson     

    Connections {
        target: logicConnection
        function onDataLoaded(inventory, orders) {
            _inventory.inventoryDataJson = inventory
            _orders.ordersDataJson = orders
        }
    }
}
```

### REST API & Networking
**Required for**: Core Data Model Agent, Firebase & Authentication Agent        
**Knowledge Areas**:
- HTTP methods (GET, POST, PUT, DELETE)
- JSON payload construction
- Error handling and timeouts
- Request/response parsing
- Authentication tokens (if applicable)
- Felgo HttpRequest API
- Debugging network issues

**Project Implementation**:
```qml
// RestAPI.qml pattern
HttpRequest.get(url)
    .timeout(maxRequestTimeout)
    .then(success)
    .catch(error)
```

### Signal/Slot Architecture
**Required for**: Felgo Plugin & Architecture Agent, Core Data Model Agent      
**Knowledge Areas**:
- Signal definition and emission
- Slot (signal handler) implementation
- Signal connections and disconnections
- Avoiding signal loops
- Proper cleanup in Component.onDestruction

**Project Pattern**:
```qml
// Logic.qml - signal definitions
signal login(string username, string password)
signal addProduct(var productData)

// DataModel.qml - signal handlers
Connections {
    target: logic
    function onLogin(username, password) { /* process */ }
    function onAddProduct(data) { /* process */ }
}
```

---

## Firebase & Backend Skills

### Firebase Authentication
**Required for**: Firebase & Authentication Agent
**Knowledge Areas**:
- Firebase authentication flow (email, social, anonymous)
- Session management
- Token handling
- User profile management
- Authentication state listeners
- Logout/cleanup

**Project Files**:
- `qml/pages/LoginPage.qml` (login UI)
- `qml/helper/Constants.qml` (Firebase config)
- Firebase documentation: https://felgo.com/doc/plugin-firebase/

### Firebase Realtime Database
**Required for**: Firebase & Authentication Agent, Core Data Model Agent        
**Knowledge Areas**:
- Database structure design
- CRUD operations (Create, Read, Update, Delete)
- Real-time listeners
- Data validation and permissions
- Offline caching
- Conflict resolution

**Project Example**:
```qml
FirebaseDatabase {
    onReadCompleted: { /* handle result */ }
    onWriteCompleted: { /* handle result */ }
}
```

### Cloud Functions
**Required for**: Firebase & Authentication Agent
**Knowledge Areas**:
- Cloud Function deployment and management
- HTTP triggers
- Request/response handling
- Firebase SDK integration
- Local emulation (http://127.0.0.1:5001/...)
- Debugging and logging

**Project Cloud Function**:
- Endpoint: `http://127.0.0.1:5001/inventorymanager-48392/us-central1/addProduct`

---

## Platform & Deployment Skills

### Android Development
**Required for**: Platform-Specific Agent, Deployment & Publishing Agent        
**Knowledge Areas**:
- AndroidManifest.xml configuration
- Android permissions handling
- Gradle build system (build.gradle)
- App signing and keystore management
- Android lifecycle events in QML
- Google Play Store submission

**Project Files**:
- `android/AndroidManifest.xml`
- `android/build.gradle`
- `android/res/` (resources)
 - Note: Ensure `android/AndroidManifest.xml` contains a `<uses-sdk android:minSdkVersion="28" android:targetSdkVersion="35"/>` entry and prefer numeric Gradle 
properties (avoid `.toInteger()` conversions in `android/build.gradle`).        

### iOS Development
**Required for**: Platform-Specific Agent, Deployment & Publishing Agent        
**Knowledge Areas**:
- iOS app configuration (Info.plist)
- Xcode project management
- iOS entitlements and capabilities
- Code signing and provisioning profiles
- App Store submission
- iOS lifecycle in QML
- Certificate management

**Project Files**:
- `ios/Project-Info.plist`
- `ios/Launch Screen.storyboard`
- `ios/Assets.xcassets/`

### macOS & Desktop
**Required for**: Platform-Specific Agent
**Knowledge Areas**:
- macOS bundle configuration
- App code signing
- Gatekeeper and notarization
- Windows resource compilation (.rc files)
- Desktop app distribution

**Project Files**:
- `macx/` (macOS resources)
- `win/app_icon.rc` (Windows icon)

### Publishing & Distribution
**Required for**: Deployment & Publishing Agent
**Knowledge Areas**:
- App Store / Play Store submission process
- Version management (PRODUCT_VERSION_NAME, PRODUCT_VERSION_CODE)
- License key management
- QML to resource bundling (qrc)
- Release build optimization
- Testing on real devices
- Beta distribution (TestFlight, Google Play Beta)

**Project Configuration**:
```cmake
set(PRODUCT_VERSION_NAME "1.0.0")
set(PRODUCT_VERSION_CODE 1)
set(PRODUCT_STAGE "test")  # or "publish"
```

---

## Debugging & Troubleshooting Skills

### QML Debugging
**Required for**: All agents
**Knowledge Areas**:
- console.log() usage
- Qt Creator debugging
- Component inspection
- Performance profiling
- Memory leak detection
- Animation debugging

### Network Debugging
**Required for**: Firebase & Authentication Agent, Core Data Model Agent        
**Knowledge Areas**:
- HTTP request/response inspection
- Firebase Console monitoring
- Request timeout diagnosis
- Server error handling
- Local emulation testing
- Network proxy usage

### Build Troubleshooting
**Required for**: Build & Infrastructure Agent
**Knowledge Areas**:
- CMake error interpretation
- Compiler error diagnosis
- Linker issues
- Mobile SDK configuration issues
- Plugin loading problems
- Resource compilation errors

---

## Project-Specific Knowledge

### InventoryManagerUI (Root) Architecture
**Required for**: Felgo Plugin & Architecture Agent
- Entry: `main.cpp` with FelgoApplication
- Root QML: `qml/Main.qml` with App root and Navigation
- Pages located in `qml/pages/`
- Models in `qml/model/`
- Logic in `qml/logic/`
- Helpers in `qml/helper/`

### BusinessManagement (App_UI) Architecture
**Required for**: Business Management UI Agent
- Separate Qt6 application (BusinessApp module)
- Entry: `App_UI/src/main.cpp` with QGuiApplication
- Root: `App_UI/qml/Main.qml` with ApplicationWindow
- Feature: Orders management with responsive design
- Components: OrderRow, OrdersPage, OrdersStore, CardKPI, etc.

### Data Flow Pattern
**Required for**: Core Data Model Agent
```
UI (Pages)
  ↓ (signals)
Logic.qml
  ↓ (signal handlers)
DataModel.qml
  ↓ (API calls)
RestAPI.qml
  ↓ (HTTP requests)
Cloud/Firebase
```

---

## Tool Proficiency Matrix

| Tool | Agents | Proficiency Level |
|------|--------|-------------------|
| CMake | Build, Deployment | Expert |
| QML | All Frontend | Expert |
| Qt Creator | All | Advanced |
| Felgo SDK | Architecture, Platform | Advanced |
| Firebase Console | Firebase, Data | Intermediate |
| Git/Version Control | All | Advanced |
| Terminal/PowerShell | Build, Deployment | Advanced |
| Xcode | iOS Platform | Advanced |
| Android Studio | Android Platform | Intermediate |
| Qt Quick Designer | QML Development | Intermediate |

---

## Continuous Learning Resources

- **Felgo Documentation**: https://felgo.com/doc/
- **Qt Documentation**: https://doc.qt.io/
- **Qt Quick Controls 2**: https://doc.qt.io/qt-6/qtquickcontrols2-index.html   
- **Firebase Documentation**: https://firebase.google.com/docs/
- **CMake Documentation**: https://cmake.org/documentation/
- **Android Development**: https://developer.android.com/
- **iOS Development**: https://developer.apple.com/ios/

---

## Example Prompts for Skill Application
- "Update the Orders page layout to use a new card design"
- "Add a new data field to the inventory model"
- "Configure Firebase authentication for email/password"
- "Implement responsive design for tablet screens"
- "Fix the Android build configuration for NDK"
- "Create a REST API endpoint connector for a new service"
- "Debug why the navigation doesn't update after data changes"
- "Package the app for iOS App Store submission"