import QtQuick
import QtTest
import "../qml/desktop"

TestCase {
    id: testCase
    name: "Sidebar"

    Sidebar {
        id: sidebar
        width: 216
        height: 400
    }

    SignalSpy {
        id: selectedSpy
        target: sidebar
        signalName: "sectionSelected"
    }

    function init() {
        sidebar.currentSection = "dashboard"
        selectedSpy.clear()
    }

    function test_default_current_section_is_dashboard() {
        compare(sidebar.currentSection, "dashboard")
    }

    function test_all_seven_sections_present() {
        compare(sidebar.items.length, 7)
    }

    function test_selectSection_updates_currentSection() {
        sidebar.selectSection("orders")
        compare(sidebar.currentSection, "orders")
    }

    function test_selectSection_emits_sectionSelected_with_key() {
        sidebar.selectSection("analysis")
        compare(selectedSpy.count, 1)
        compare(selectedSpy.signalArguments[0][0], "analysis")
    }

    function test_selectSection_same_section_does_not_reemit() {
        sidebar.selectSection("dashboard") // already the default from init()
        compare(selectedSpy.count, 0)
    }

    function test_clicking_orders_item_selects_it() {
        var item = findChild(sidebar, "sidebarItem_orders")
        verify(item !== null)
        mouseClick(item)
        compare(sidebar.currentSection, "orders")
        compare(selectedSpy.count, 1)
    }
}
