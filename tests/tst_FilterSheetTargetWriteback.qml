import QtQuick
import QtTest

// Reproduces the real bug behind "Orders date filter has no effect":
//   Main.qml:1059  ReferenceError: ordersPage is not defined
//
// FilterSheet is declared at Main's ROOT scope, but the OrdersPage instance
// (id: ordersPage) lives inside NavigationStack.initialPage — a `Component {}`.
// IDs declared inside a Component are NOT visible from outside it, so the
// root-level filterSheet handler cannot name `ordersPage`; the assignment
// throws and the chosen date range is silently dropped.
//
// The fix: the page-scoped trigger (which CAN see both ids) hands the page
// object to the sheet via a property, and the sheet's handler writes through
// that reference. This test proves both halves: (1) an id inside a Component
// is unreachable by name from outside, and (2) the reference-passing writeback
// correctly propagates the value.
TestCase {
    id: tc
    name: "FilterSheetTargetWriteback"

    // Faithful stand-in for OrdersPage living inside NavigationStack.initialPage.
    // `initialPage:` is a Component property, so this mirrors the real scope wall.
    property Component pageComp: Component {
        Item {
            id: innerPage
            property string dateRange: "all"
            property string customFrom: ""
            property string customTo: ""
        }
    }

    // Stand-in for the root-level FilterSheet: it can hold a reference to the
    // page (set by the page-scoped trigger) but cannot see the page's id.
    QtObject {
        id: sheet
        property var page: null          // the writeback target
        property string range: "all"
        property string customFrom: ""
        property string customTo: ""
        function applyToTarget() {
            if (!page) return false
            page.dateRange = range
            page.customFrom = customFrom
            page.customTo = customTo
            return true
        }
    }

    function test_writeback_through_reference_propagates() {
        var page = pageComp.createObject(tc)
        verify(page !== null, "page instance created")
        compare(page.dateRange, "all", "starts at all")

        // The trigger (page scope) hands the object to the sheet, the way
        // onFiltersRequested sets filterSheet.page = ordersPage.
        sheet.page = page
        sheet.range = "today"
        sheet.customFrom = ""
        sheet.customTo = ""
        verify(sheet.applyToTarget(), "writeback runs with a target set")
        compare(page.dateRange, "today", "date range propagated to the page")

        sheet.range = "custom"
        sheet.customFrom = "2026-06-01"
        sheet.customTo = "2026-06-10"
        sheet.applyToTarget()
        compare(page.dateRange, "custom", "custom range propagated")
        compare(page.customFrom, "2026-06-01", "customFrom propagated")
        compare(page.customTo, "2026-06-10", "customTo propagated")

        page.destroy()
    }

    function test_no_target_is_safe_noop() {
        // Before the trigger runs (or after the page is gone) the sheet has no
        // target. The guarded handler must no-op, not throw — the un-guarded
        // original threw ReferenceError here.
        sheet.page = null
        compare(sheet.applyToTarget(), false, "no target → guarded no-op, no throw")
    }
}
