import QtQuick
import QtTest
import "../qml/desktop/DesktopNav.js" as DesktopNav

TestCase {
    name: "DesktopNav"

    function test_navigationIndexForSection_dashboard() {
        compare(DesktopNav.navigationIndexForSection("dashboard"), 0)
    }
    function test_navigationIndexForSection_orders() {
        compare(DesktopNav.navigationIndexForSection("orders"), 1)
    }
    function test_navigationIndexForSection_inventory() {
        compare(DesktopNav.navigationIndexForSection("inventory"), 2)
    }
    function test_navigationIndexForSection_analysis() {
        compare(DesktopNav.navigationIndexForSection("analysis"), 3)
    }
    function test_navigationIndexForSection_overlay_section_returns_negative_one() {
        compare(DesktopNav.navigationIndexForSection("staff"), -1)
    }
    function test_navigationIndexForSection_unknown_section_returns_negative_one() {
        compare(DesktopNav.navigationIndexForSection("bogus"), -1)
    }
    function test_overlayIdForSection_staff() {
        compare(DesktopNav.overlayIdForSection("staff"), "staffPageOverlay")
    }
    function test_overlayIdForSection_activity() {
        compare(DesktopNav.overlayIdForSection("activity"), "activityPageOverlay")
    }
    function test_overlayIdForSection_settings() {
        compare(DesktopNav.overlayIdForSection("settings"), "profilePage")
    }
    function test_overlayIdForSection_stack_section_returns_empty_string() {
        compare(DesktopNav.overlayIdForSection("dashboard"), "")
    }
}
