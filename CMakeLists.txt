cmake_minimum_required(VERSION 3.16)

project(InventoryManagerUI VERSION 0.1 LANGUAGES CXX)

set(CMAKE_AUTOMOC ON)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

find_package(Felgo REQUIRED)

# Project identifier and version
# More information: https://felgo.com/doc/felgo-publishing/#project-configuration
set(PRODUCT_IDENTIFIER "com.lkdigitalworks.inventory.management.app")
set(PRODUCT_VERSION_NAME "1.0.0")
set(PRODUCT_VERSION_CODE 2)

# Set either "test" or "publish" stage:
set(PRODUCT_STAGE "test")

# Optionally set a license key that is used instead of the license key from
# main.qml file (App::licenseKey for your app or GameWindow::licenseKey for your game)
# Only used for local builds and Felgo Cloud Builds (https://felgo.com/cloud-builds)
# Not used if using Felgo Developer App
set(PRODUCT_LICENSE_KEY "3F3506BFF764D512407759CE7C931A6C77E48DA3278D3AF6B2DB7D966F71336AC3B65A1A2071AD04DBDDEADE75498FA8DAB000F286994F014C551A8DCD0A73F94A393BBAF93E96885BD905C1672DE5A3433F21555EF65B2D71C7AD5EB3D61D215C7EFA75FB1F88CCA38B49B429DA14BEFF579766A21876288320A2035BAFE8C7183916C77118B8B6F88591F14D1490B29D274678CD96A687681A2D0FF1C35C0918C5C0D8BC5BD7DBE1E7A64371F1D17E9AEF7715D77BB0A859F515C0DE9A085092043CEE4028E2B9E387B913296F5F53468FA473D5A4E31BFA890038B73E37CD673D0AB5F96DD360724E07ED359F03FC526DDFA79BD1E13FEAA0C753632875C110263AA58AC49AD42E9E70D5048797EBCB08F42AB4F165D70E0C2D52F255BA55E4F55CC7DE591730E18694CAEC0D8E8FD7C5CA2EF07A14023AACAACC004F0A3E")

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
