import QtQuick
import QtTest

// DECISIVE EXPERIMENT for "Orders filters have no effect — list shows everything".
//
// OrdersPage uses literally:  Repeater { model: _filteredOrders() }
// where _filteredOrders() reads root._statusFilter / dateRange (the latter via a
// nested _dateWindow() call) and returns a NEW JS array each time.
//
// Question under test: when a filter property changes, does a Repeater whose
// `model` is bound to a function returning a fresh JS array actually rebuild its
// delegates? We instantiate a real Repeater and count `repeater.count`, which is
// the faithful reproduction (an earlier version tested a derived int — not the
// same as Repeater.model array semantics).
TestCase {
    id: tc
    name: "RepeaterModelReactivity"
    visible: true
    width: 200; height: 200

    property string statusFilter: "all"
    property string dateRange: "all"
    property var items: [
        { status: "pending" }, { status: "completed" }, { status: "completed" }
    ]

    // Mirror of OrdersPage helpers: dateRange read inside a nested call.
    function dateWindow() { return tc.dateRange === "all" ? null : tc.dateRange }
    function filteredOrders() {
        var f = tc.statusFilter
        var win = dateWindow()
        return tc.items.filter(function(o) {
            if (f !== "all" && o.status !== f) return false
            if (win === "none") return false
            return true
        })
    }

    Item {
        anchors.fill: parent
        Repeater {
            id: rep
            model: tc.filteredOrders()      // exact OrdersPage construct
            Item {}
        }
    }

    function test_repeater_rebuilds_on_status_change() {
        compare(rep.count, 3, "all → 3 delegates")
        tc.statusFilter = "pending"
        compare(rep.count, 1, "status filter MUST rebuild Repeater to 1 delegate")
        tc.statusFilter = "completed"
        compare(rep.count, 2, "switches to completed set")
        tc.statusFilter = "all"
        compare(rep.count, 3, "back to all")
    }

    function test_repeater_rebuilds_on_nested_daterange_change() {
        tc.statusFilter = "all"
        compare(rep.count, 3, "all time → 3 delegates")
        tc.dateRange = "none"
        compare(rep.count, 0,
                "dateRange (read inside nested dateWindow()) MUST rebuild Repeater")
        tc.dateRange = "all"
        compare(rep.count, 3, "back to all")
    }
}
