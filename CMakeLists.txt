cmake_minimum_required(VERSION 3.16)

project(InventoryManagerUI VERSION 0.1 LANGUAGES CXX)

set(CMAKE_AUTOMOC ON)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

find_package(Felgo REQUIRED)

# Project identifier and version
# More information: https://felgo.com/doc/felgo-publishing/#project-configuration
set(PRODUCT_IDENTIFIER "com.lkdigitalworks.inventory.management.app")
set(PRODUCT_VERSION_NAME "1.0.0")
set(PRODUCT_VERSION_CODE 1)

# Set either "test" or "publish" stage:
set(PRODUCT_STAGE "test")

# Optionally set a license key that is used instead of the license key from
# main.qml file (App::licenseKey for your app or GameWindow::licenseKey for your game)
# Only used for local builds and Felgo Cloud Builds (https://felgo.com/cloud-builds)
# Not used if using Felgo Developer App
set(PRODUCT_LICENSE_KEY "5D1369F7CEE60AF989BF82F0438EAFCCBC5CFB6DF74E512BD24E2EE6B417A99555E0D5FD528584CAC30874367A99D444ABD79672BF88F8ABE2E7176FAC92EBB0DC762D4FAF1AB1C0862C443F3F887F75B866C769C7DE8C6B73731CF2D0706ACD9840443125C4AC731C8F30738D96726F8FA8CD0861EA3B2FDA559A3820C3845E449BE0EE973A4145758765310C28F3198E7DBB0A1E31F7DFA0427C7F5C15048D5A277F64ACBB59B0BDF4EAE117773C6FB71082F7D5FF3924E082B4FDAE69E1217649E149470C6C3D4166D983196A1D9AFEF8262BA801FC5F61A9CB640462ECB60A02FFC029D910BE075801951D5DED021CCC7ADF0C128265A7982B6F36BC73E47FA728F1E3416846DF5B9BAE5CB735121F66FE9787E343ED9EF5D8D2FB838B77876A86F21B5167DBFF204E9B22EC599B64CCD42BAAEF15EEE6407B397494772A")

set(FELGO_PLUGINS
    firebase
)

# Find all QML/JS files for the QML compiler:
file(GLOB_RECURSE QmlFiles RELATIVE ${CMAKE_CURRENT_SOURCE_DIR} qml/*.qml qml/*.js)

# Find all non-QML/JS files in the qml and assets folder to add as resources:
file(GLOB_RECURSE AssetsFiles RELATIVE ${CMAKE_CURRENT_SOURCE_DIR} assets/* qml/*)
list(REMOVE_ITEM AssetsFiles ${QmlFiles})

qt_add_executable(appInventoryManagerUI
    main.cpp
    ${QmlFiles}
    ${AssetsFiles}
)

felgo_configure_executable(appInventoryManagerUI)

# Deploy resources to build folder/package directly
# comment for publishing
deploy_resources("${QmlFiles};${AssetsFiles}")

# Add QML files and resources to QML module to included them via QRC automatically:
qt_add_qml_module(appInventoryManagerUI
    URI InventoryManagerUI
    VERSION 1.0
# uncomment for publishing:
#    QML_FILES ${QmlFiles}
#    RESOURCES ${AssetsFiles}
    NO_RESOURCE_TARGET_PATH
)

# Add or modify the target properties block
set_target_properties(appInventoryManagerUI PROPERTIES
    # Add this line to control the Target SDK Version in Gradle
    QT_ANDROID_TARGET_SDK_VERSION 34
    # Ensure the Compile SDK is also set high for compatibility
    # QT_ANDROID_COMPILE_SDK_VERSION 34
)

# NOTE: for PUBLISHING, perform the following steps:
# 1. comment the deploy_resources line above, to avoid shipping your qml files with the application (instead they get compiled to the app binary)
# 2. uncomment the QML_FILES and RESOURCES above; this compiles your qml files and js files to the app binary and protects your source code
# 3. change the setMainQmlFile() call in main.cpp to the one starting with "qrc:/" - this loads the qml files from the resources
# for more details see the "Deployment Guides" in the Felgo Documentation

# during development, use the deploy_resources because you then get shorter compilation times (the qml files do not need to be compiled to the binary but are just copied)
# also, for quickest deployment on Desktop disable the "Shadow Build" option in Projects/Builds - you can then select "Run Without Deployment" from the Build menu in Qt Creator if you only changed QML files; this speeds up application start, because your app is not copied & re-compiled but just re-interpreted

target_compile_definitions(appInventoryManagerUI
    PRIVATE $<$<OR:$<CONFIG:Debug>,$<CONFIG:RelWithDebInfo>>:QT_QML_DEBUG>)

target_link_libraries(appInventoryManagerUI PRIVATE Felgo)

# uncomment this line to add Felgo Hot Reload and use hot reloading with your custom C++ code
# for the remaining steps see here: https://felgo.com/custom-code-reload-app/
# find_package(FelgoHotReload REQUIRED)
# target_link_libraries(appInventoryManagerUI PRIVATE FelgoHotReload)
