import QtQuick
import QtTest
import "../qml/helper/StaffScope.js" as Scope

TestCase {
    name: "StaffScope"

    function test_findByAppUid_match() {
        var roster = [
            { staffId: "STF-001", appUid: "uidA" },
            { staffId: "STF-002", appUid: "uidB" }
        ]
        compare(Scope.findByAppUid(roster, "uidB"), "STF-002")
    }
    function test_findByAppUid_no_match() {
        var roster = [ { staffId: "STF-001", appUid: "uidA" } ]
        compare(Scope.findByAppUid(roster, "nope"), "")
    }
    function test_findByAppUid_empty_uid() {
        compare(Scope.findByAppUid([ { staffId: "STF-001", appUid: "uidA" } ], ""), "")
    }
    function test_findByAppUid_null_roster() {
        compare(Scope.findByAppUid(null, "uidA"), "")
    }
    function test_ownOrders_filters_to_self() {
        var orders = [
            { orderId: "O1", staffId: "STF-001" },
            { orderId: "O2", staffId: "STF-002" },
            { orderId: "O3", staffId: "STF-001" }
        ]
        var mine = Scope.ownOrders(orders, "STF-001")
        compare(mine.length, 2)
        compare(mine[0].orderId, "O1")
        compare(mine[1].orderId, "O3")
    }
    function test_ownOrders_empty_staffId_returns_none() {
        var orders = [ { orderId: "O1", staffId: "STF-001" } ]
        compare(Scope.ownOrders(orders, "").length, 0)
    }
    function test_ownOrders_null_orders() {
        compare(Scope.ownOrders(null, "STF-001").length, 0)
    }
}
