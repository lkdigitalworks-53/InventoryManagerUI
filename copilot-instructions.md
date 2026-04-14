# Copilot Instructions for InventoryManagerUI

## Overview
InventoryManagerUI is a cross-platform inventory management app built using Felgo and Qt. It supports Android, iOS, and desktop platforms. The app uses QML for the UI, C++ for backend logic, and Firebase for authentication and database operations.

## Build/Test Commands
### Build
1. Configure the project:
   ```bash
   cmake -S . -B build -G "Ninja"
   ```
2. Build the project:
   ```bash
   cmake --build build
   ```

### Test
- Currently, no explicit test commands are defined. Add tests to the project as needed.

## Architecture
- **UI**: Implemented in QML, organized into logical directories like `pages`, `helper`, and `model`.
- **Backend**: Written in C++, with `main.cpp` as the entry point.
- **Data Management**: Firebase is used for authentication and database operations.
- **Platform-Specific Configurations**: Separate configurations for Android, iOS, and desktop platforms.

## Project-Specific Conventions
- **QML Structure**:
  - `qml/pages`: Contains pages like `DashboardPage.qml`, `OrdersPage.qml`.
  - `qml/helper`: Contains helper components like `Constants.qml`.
  - `qml/model`: Contains data models like `DataModel.qml` and `RestAPI.qml`.
- **Logic**:
  - `qml/logic/Logic.qml` handles signals for actions like login, logout, and data loading.
  - `qml/model/DataModel.qml` manages inventory and order data.
- **Firebase Integration**:
  - Ensure proper configuration (e.g., API keys, project ID).

## Potential Pitfalls
- **Firebase Configuration**:
  - Verify API keys and project ID in `Constants.qml`.
- **Felgo Hot Reload**:
  - Uncomment the relevant lines in `main.cpp` and `CMakeLists.txt` to enable Hot Reload during development.
- **Deployment**:
  - Follow the steps in `CMakeLists.txt` for publishing, such as compiling QML files into the binary.

## Example Prompts
- "How do I build the InventoryManagerUI project?"
- "What are the key files for Firebase integration?"
- "How do I enable Felgo Hot Reload for development?"
- "What are the conventions for adding a new QML page?"

## Notes
- Refer to the Felgo documentation for additional integration steps: https://felgo.com/doc/