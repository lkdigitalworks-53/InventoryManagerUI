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
set(PRODUCT_VERSION_CODE 1)

# Stage selects the Firestore env (see README "Environments"): dev | test | publish.
# publish -> (default) db; dev/test -> named DBs (require Blaze billing to exist).
set(PRODUCT_STAGE "publish")

# Optionally set a license key (used for local builds and Felgo Cloud Builds)
set(PRODUCT_LICENSE_KEY "B50D34F56EB9FD448BC6039EAE88A03BE35D34EDB0873BA183C3158078BABE2E9E7FAEC350119567DC946DDA409BF995D5F70B287E7219BECFB4871AE091EE6A71041982DF626A76FA6D56C35C9A9645E842C4F48A1FFF63B8951D7504D545D0F1A01D1235FFD595A63C44260126B724EF550CC2E9AE60E4FC018DBCEC36EB3D2D74D76705764AD13DE0CC1699CAF8536F0A0179C9AD5F88A074DF98414280A6B4207AF87EA12FE44CE1639623B4154415E056111697BD946A9A3CD04DC9A11754E726CF71F279E519457910A0F13E41730BD7E09C8BE386ADF0E937EAB060D37E5BD59A7E631FAF8F3EF763AD4A624F1A0ACF54BF9FF2FA875950170AD38EE80313A931605791D8082080C4798F1D61E2FD3B1D3ABA864C4D4F6EC5BA569B58A7B74C29F4D0B3FA53A592B2CBD31A30E0B08D0A5FE6215B11763F625649AE41")

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
    QT_ANDROID_TARGET_SDK_VERSION 34
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
