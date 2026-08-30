import QtQuick
import QtTest
import "../qml/pages"
import "../qml/model"

// Coverage for the actual button added this branch: the trash icon in
// OrdersPage.qml's order row, wired to root.deleteOrderClicked(orderId)
// (already-existing plumbing this branch didn't touch, per DataModel's
// onDeleteOrder handler covered in tst_DataModel_deleteGuards.qml).
//
// Same caveat as tst_InventoryPage_deleteButton.qml -- first-of-its-kind
// page-level UI test in this suite, not compile-checked (no toolchain
// here). Treat a hard failure here as a test-setup problem to fix, not
// proof the button itself doesn't work -- it's a direct copy of the
// Restock idiom pattern used elsewhere in this same branch.
//
// NOT RUN IN THIS SANDBOX.
TestCase {
    id: testCase
    name: "OrdersPage_deleteButton"
    when: windowShown
    width: 420
    height: 800

    property var page: null

    function _order() {
        return { orderId: "ORD-001", customer: "Test Customer", status: "pending",
                 date: "2026-08-30", items: 1, total: 100 }
    }

    function init() {
        OrdersStore.orders = [_order()]
        page = createTemporaryObject(pageComponent, testCase, { width: 420, height: 800 })
        verify(page !== null, "OrdersPage must instantiate")
        waitForRendering(page)
    }

    Component {
        id: pageComponent
        OrdersPage { canDeleteOrders: true }
    }

    function test_delete_button_is_visible_when_canDeleteOrders_is_true() {
        var btn = findChild(page, "deleteOrderBtn")
        verify(btn !== null, "delete button must exist in the rendered row")
        verify(btn.visible)
    }

    function test_delete_button_is_hidden_when_canDeleteOrders_is_false() {
        page.destroy()
        page = createTemporaryObject(pageComponent, testCase,
            { width: 420, height: 800, canDeleteOrders: false })
        waitForRendering(page)
        var btn = findChild(page, "deleteOrderBtn")
        verify(btn !== null)
        compare(btn.visible, false)
    }

    function test_delete_button_stays_visible_for_a_completed_order() {
        // Deliberate design choice (see spec doc): no per-row status gating.
        // DataModel's own guard produces the "reopen it first" message on
        // tap rather than this row re-deriving that rule to hide the icon.
        page.destroy()
        OrdersStore.orders = [{ orderId: "ORD-001", customer: "Test", status: "completed",
                                 date: "2026-08-30", items: 1, total: 100 }]
        page = createTemporaryObject(pageComponent, testCase, { width: 420, height: 800 })
        waitForRendering(page)
        var btn = findChild(page, "deleteOrderBtn")
        verify(btn !== null)
        verify(btn.visible, "visible regardless of status -- DataModel's guard explains the block on tap")
    }

    function test_tapping_delete_emits_deleteOrderClicked_with_the_right_id() {
        var spy = Qt.createQmlObject('import QtTest 1.0; SignalSpy {}', testCase, "spy")
        spy.target = page
        spy.signalName = "deleteOrderClicked"

        var btn = findChild(page, "deleteOrderBtn")
        verify(btn !== null)
        mouseClick(btn)

        compare(spy.count, 1)
        compare(spy.signalArguments[0][0], "ORD-001")
        spy.destroy()
    }

    function test_tapping_delete_does_not_also_trigger_orderDetailsClicked() {
        var detailSpy = Qt.createQmlObject('import QtTest 1.0; SignalSpy {}', testCase, "detailSpy")
        detailSpy.target = page
        detailSpy.signalName = "orderDetailsClicked"

        var btn = findChild(page, "deleteOrderBtn")
        mouseClick(btn)

        compare(detailSpy.count, 0, "the tap must not bubble through to the row's own onClicked")
        detailSpy.destroy()
    }
}
