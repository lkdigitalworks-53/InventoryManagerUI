cmake_minimum_required(VERSION 3.16)

project(BusinessManagement VERSION 0.1 LANGUAGES CXX)

set(CMAKE_AUTOMOC ON)
set(CMAKE_AUTOUIC ON)
set(CMAKE_AUTORCC ON)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

find_package(Felgo REQUIRED)
find_package(Qt6 REQUIRED COMPONENTS Network Gui)

# Vendored QXlsx — read/write .xlsx workbooks for the import/export feature.
# We exclude QXlsx's own examples to keep the build focused on the library.
set(QXLSX_PARENTPATH "${CMAKE_CURRENT_SOURCE_DIR}/src/3rdparty/qxlsx-src/QXlsx/" CACHE STRING "")
set(QXLSX_HEADERPATH "${CMAKE_CURRENT_SOURCE_DIR}/src/3rdparty/qxlsx-src/QXlsx/header/" CACHE STRING "")
set(QXLSX_SOURCEPATH "${CMAKE_CURRENT_SOURCE_DIR}/src/3rdparty/qxlsx-src/QXlsx/source/" CACHE STRING "")
add_subdirectory(src/3rdparty/qxlsx-src/QXlsx ${CMAKE_BINARY_DIR}/QXlsx)

# Project identifier and version
set(PRODUCT_IDENTIFIER "com.lkdigitalworks.business.management.app")
set(PRODUCT_VERSION_NAME "1.0.0")
set(PRODUCT_VERSION_CODE 2)

# Stage selects the Firestore env (see README "Environments"): dev | test | publish.
# publish -> (default) db; dev/test -> named DBs (require Blaze billing to exist).
set(PRODUCT_STAGE "publish")

# Optionally set a license key (used for local builds and Felgo Cloud Builds)
set(PRODUCT_LICENSE_KEY "7DE3BC3AD3A76DE396F0C706C3CB0BF4683B3E0DFDA541CA89163CB320232DE3F86B5062338D5EC6739022887374C5F67D7D2608B2E60C244858D28D69BB55949A55CE835EEA6F1B9CCA4CFC5030EBA41123AF6A00DB2A89E6F13061B4C31BC756EC3DB9CB23FA3605E16FF8FE4A5814B8FC94195D2F19D84568E267062B7B0E26B6298502A3F2AB250ED082D7228E2C486F1C5B04D9116774011ADE0F175FB5337E55BA899802D721D9B37943F48D1E53CA15FFDA0BB8F3B52AC658860DD9F53ECC1DEAA17E636ECEB4886B002C92BBAD11C9F1AE2E76C545879DA62CA6849A66C8A9B8E179E188D9B46A4C26719827EEB8FD4ED222FDBC81A6F21268A155BB43FF7CE4DEE3A1AB8A408B8AD9A9EA56F523E6287B16B80C17BC0E354FEEA087E09E85A624960560FF4F7221F0203C3FC1C329865ED4D2CDB50BD99C53C1FB4B")

# Find all QML/JS files for the QML compiler:
# CONFIGURE_DEPENDS re-globs on every build so newly-added files (e.g. new
# model singletons or icon assets) are picked up without a manual reconfigure.
# Without it, CMake caches the file list at configure time and silently omits
# new files from the Android package — the loader then fails with
# "Gateway.qml: No such file or directory" and the app crashes on launch.
file(GLOB_RECURSE QmlFiles CONFIGURE_DEPENDS RELATIVE ${CMAKE_CURRENT_SOURCE_DIR} qml/*.qml qml/*.js)

# Find all non-QML/JS files in the qml and assets folder to add as resources:
file(GLOB_RECURSE AssetsFiles CONFIGURE_DEPENDS RELATIVE ${CMAKE_CURRENT_SOURCE_DIR} assets/* qml/*)
list(REMOVE_ITEM AssetsFiles ${QmlFiles})

qt_add_executable(appBusinessManagement
    main.cpp
    src/OAuthServer.h
    src/OAuthServer.cpp
    src/ImageProcessor.h
    src/ImageProcessor.cpp
    src/XlsxService.h
    src/XlsxService.cpp
    src/NativeFile.h
    src/NativeFile.cpp
    src/Clipboard.h
    src/Clipboard.cpp
    src/PkceGenerator.h
    src/PkceGenerator.cpp
    ${QmlFiles}
    ${AssetsFiles}
)

target_include_directories(appBusinessManagement PRIVATE
    src/3rdparty/qxlsx-src/QXlsx/header
)

# This command configures the application and sets up cross-platform deployment hooks.
felgo_configure_executable(appBusinessManagement)

# Deploy resources to build folder/package directly
# comment for publishing
# deploy_resources("${QmlFiles};${AssetsFiles}")

# Add QML files and resources to QML module to included them via QRC automatically:
qt_add_qml_module(appBusinessManagement
    URI BusinessApp
    VERSION 1.0
# uncomment for publishing:
    QML_FILES ${QmlFiles}
    RESOURCES ${AssetsFiles}
    NO_RESOURCE_TARGET_PATH
)

# Android SDK targeting
# CHANGE 2: Linked properties directly to CMake variables (${PRODUCT_VERSION_CODE}, etc.)
# so that any changes in the main configuration automatically propagate to Android
# build configurations without cache conflicts.
set_target_properties(appBusinessManagement PROPERTIES
    QT_ANDROID_TARGET_SDK_VERSION 35
    QT_ANDROID_VERSION_CODE ${PRODUCT_VERSION_CODE}
    QT_ANDROID_VERSION_NAME "${PRODUCT_VERSION_NAME}"
    QT_ANDROID_PACKAGE_NAME "${PRODUCT_IDENTIFIER}"
)

# User-visible executable name (Windows only). The CMake target id stays
# appBusinessManagement (so target references keep resolving); only the produced
# Windows binary is renamed to Karobar.exe to match the app's display name.
# Scoped to Windows on purpose: a global OUTPUT_NAME would also rename the
# Android shared library (libappBusinessManagement_<abi>.so) and collide with
# the Linux ".run" name Felgo sets itself — both verified working, so leave them.
if(CMAKE_SYSTEM_NAME STREQUAL "Windows")
    set_target_properties(appBusinessManagement PROPERTIES
        OUTPUT_NAME "Karobar"
    )
endif()

# NOTE: for PUBLISHING, perform the following steps:
# 1. comment the deploy_resources line above
# 2. uncomment the QML_FILES and RESOURCES above
# 3. change the setMainQmlFileName() call in main.cpp to the one starting with "qrc:/"

target_compile_definitions(appBusinessManagement
    PRIVATE $<$<OR:$<CONFIG:Debug>,$<CONFIG:RelWithDebInfo>>:QT_QML_DEBUG>
    PRIVATE PRODUCT_STAGE_DEF="${PRODUCT_STAGE}")

target_link_libraries(appBusinessManagement PRIVATE
    Felgo
    Qt6::Network
    Qt6::Gui
    QXlsx::QXlsx
)

# uncomment this line to add Felgo Hot Reload
# find_package(FelgoHotReload REQUIRED)
# target_link_libraries(appBusinessManagement PRIVATE FelgoHotReload)
