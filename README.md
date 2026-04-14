# InventoryManagerUI

A cross-platform inventory management application built with Felgo and Qt. Supports Android, iOS, and Desktop platforms with Firebase integration for authentication and real-time data synchronization.

## Project Structure

### Root: InventoryManagerUI (Felgo-based)
Main application using Felgo framework for cross-platform development.
- **Entry Point**: `main.cpp`
- **QML Directory**: `qml/`
  - `Main.qml`: Main application entry point with Navigation and plugin system
  - `pages/`: Application pages (Dashboard, Orders, Inventory, Profile)
  - `helper/`: Helper components and constants
  - `model/`: Data models and REST API
  - `logic/`: Application logic and signals
- **Platform Configs**: `android/`, `ios/`, `macx/`, `win/`
- **Assets**: `assets/`
- **Build**: `CMakeLists.txt` (Felgo-based CMake configuration)

### App_UI: BusinessManagement (Qt6-based)
Separate business management UI module using pure Qt6/QML.
- **Project Name**: BusinessManagement
- **Module URI**: BusinessApp (used for imports)
- **Entry Point**: `App_UI/src/main.cpp`
- **QML Files**: `App_UI/qml/`
  - `Main.qml`: Application window with header and navigation
  - `OrdersPage.qml`: Orders management interface
  - `OrdersStore.qml`: Order data storage and management
  - `SegmentedNav.qml`: Segmented navigation component
  - `OrderRow.qml`: Order row renderer with compact/full layout
  - `CardKPI.qml`: Key Performance Indicator cards
  - `StatusBadge.qml`: Status badge component
  - `NewOrderDialog.qml`, `OrderDetailDialog.qml`: Dialog components
  - `InlineDatePicker.qml`: Date picker component
  - `PlaceholderPage.qml`: Placeholder pages
- **Build**: `App_UI/CMakeLists.txt` (Qt6-based CMake configuration)

## Building the Project

### InventoryManagerUI (Root)
```bash
cmake -S . -B build -G "Ninja"
cmake --build build
```

### App_UI (BusinessManagement)
Built as part of the root project or separately:
```bash
cmake -S . -B build -G "Ninja"
cmake --build build
```

## Key Technologies
- **Felgo**: Cross-platform framework based on Qt/QML
- **Qt 6.5/6.8**: GUI framework
- **Qt Quick Controls**: UI components
- **Firebase**: Authentication and real-time database
- **CMake**: Build system
- **QML**: UI markup language

## Architecture Highlights

### Data Flow
1. UI (QML) → Logic.qml (signals)
2. DataModel.qml (data management)
3. RestAPI.qml (network requests)
4. Firebase (persistent storage)

### Navigation
- Root app uses Felgo's Navigation component
- App_UI uses Qt Quick Controls' ApplicationWindow
- Pages are organized in dedicated files

### Components
- **CardKPI**: Displays key performance indicators
- **OrderRow**: Responsive row with compact/full layouts
- **SegmentedNav**: Tab-like navigation
- **Status Badge**: Status indicators

## Firebase Integration
- **Configuration**: `qml/helper/Constants.qml`
- **Project ID**: inventorymanager-48392
- **Features**: Authentication, Realtime Database
- **Local Testing**: Cloud Functions at `http://127.0.0.1:5001/inventorymanager-48392/us-central1/`

## Development Workflow

### For QML Development
1. Edit QML files in respective modules
2. Rebuild: `cmake --build build`
3. Run application
4. (Optional) Enable Felgo Hot Reload for faster iteration

### For Adding Features
1. Pages: Add `.qml` file to `pages/` directory
2. Logic: Define signals in `logic/Logic.qml`
3. Data: Connect in `model/DataModel.qml`
4. UI: Import and use in pages

## Platform-Specific Considerations
- **Android**: Uses native gradle build system, see `android/CMakeLists.txt`
- **iOS**: Requires Xcode, see `ios/CMakeLists.txt`
- **Desktop**: Supports macOS (macx/), Windows (win/)

## Deployment

### Development
- Use `deploy_resources()` for fast iteration (QML files not compiled)
- Load from: `qml/Main.qml`

### Publishing
1. Comment `deploy_resources()` in CMakeLists.txt
2. Uncomment `QML_FILES` and `RESOURCES` sections
3. Change main.cpp to load from `qrc:/`
4. Compile QML into binary for protection

## Testing & Debugging
- Use Qt Creator for debugging
- Console output: `console.log()` in QML
- Network debugging: Firebase Console

## Common Commands
```bash
# Configure
cmake -S . -B build -G "Ninja"

# Build
cmake --build build

# Clean build
rm -rf build && cmake -S . -B build -G "Ninja" && cmake --build build
```
