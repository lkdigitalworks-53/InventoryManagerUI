
cmake_minimum_required(VERSION 3.21)
project(BusinessManagement VERSION 0.1 LANGUAGES CXX)

find_package(Qt6 6.5 REQUIRED COMPONENTS Quick Qml QuickControls2)
qt_standard_project_setup(REQUIRES 6.8)

qt_add_executable(appBusinessManagement
    src/main.cpp
)

qt_add_qml_module(appBusinessManagement
    URI BusinessApp
    VERSION 1.0
    QML_FILES
        qml/Main.qml
        qml/SegmentedNav.qml
        qml/OrdersPage.qml
        qml/CardKPI.qml
        qml/OrderRow.qml
        qml/StatusBadge.qml
        qml/PlaceholderPage.qml
        qml/NewOrderDialog.qml
        qml/OrdersStore.qml
        qml/OrderDetailDialog.qml
        qml/InlineDatePicker.qml
)

set_target_properties(appBusinessManagement PROPERTIES
    MACOSX_BUNDLE TRUE
    WIN32_EXECUTABLE TRUE
)

target_link_libraries(appBusinessManagement PRIVATE Qt6::Quick Qt6::Qml Qt6::QuickControls2)

if(ANDROID)
    message(STATUS "Android build: skipping install() (packaging handled by androiddeployqt)")
else()
    include(GNUInstallDirs)
    install(TARGETS appBusinessManagement
            BUNDLE  DESTINATION .
            RUNTIME DESTINATION ${CMAKE_INSTALL_BINDIR}
            LIBRARY DESTINATION ${CMAKE_INSTALL_LIBDIR}
            ARCHIVE DESTINATION ${CMAKE_INSTALL_LIBDIR})
    qt_generate_deploy_qml_app_script(
        TARGET appBusinessManagement
        OUTPUT_SCRIPT deploy_qml_script
        NO_UNSUPPORTED_PLATFORM_ERROR)
    install(SCRIPT ${deploy_qml_script})
endif()
