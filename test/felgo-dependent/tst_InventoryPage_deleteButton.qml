import QtQuick
import QtTest
import "../../qml/pages"
import "../../qml/model"

// Coverage for the actual button added this branch: ProductCard's trash
// icon inside InventoryPage.qml, wired to card.deleteClicked() ->
// root.deleteProductClicked(productId).
//
// RELOCATED 2026-09-01, was tests/tst_InventoryPage_deleteButton.qml.
// Original placement failed CI outright: InventoryPage.qml -> GlassHeader
// -> Constants.qml (line 4) -> `import Felgo` -- and this repo's
// .github/workflows/checks.yml "QML Tests" job installs plain Qt 6.8 only,
// no Felgo. Every real Page transitively needs Constants, so no full-Page
// test can ever compile under that job -- not a bug in this file or in
// InventoryPage.qml, a hard architectural wall. Moved here (a directory no
// workflow job points qmltestrunner at, confirmed against
// .github/workflows/checks.yml at move time) rather than deleted, since
// the button logic itself is still worth this exact coverage on a machine
// that actually has Felgo (Taher's dev machine, Qt Creator with the Felgo
// SDK) -- run manually there, or fold into an on-device checklist; see
// docs/superpowers/test-plans/2026-08-30-product-order-delete-ui-test-plan.md.
//
// Everything below is unchanged from the original file -- same content,
// different location and this corrected header.
TestCase {
    id: testCase
    name: "InventoryPage_deleteButton"
    when: windowShown
    width: 420
    height: 800

    property var page: null

    function _product() {
        return { productId: "SKU-1", name: "Widget", sku: "W1", category: "",
                 unit: "pc", price: 100, sellingPrice: 100, stock: 10, minStock: 2,
                 photoUrl: "" }
    }

    function init() {
        InventoryStore.products = [_product()]
        page = createTemporaryObject(pageComponent, testCase, { width: 420, height: 800 })
        verify(page !== null, "InventoryPage must instantiate")
        waitForRendering(page)
    }

    Component {
        id: pageComponent
        InventoryPage { canManageInventory: true; canOpenProductDetail: true }
    }

    function test_delete_button_is_visible_when_canManageInventory_is_true() {
        var btn = findChild(page, "deleteBtn")
        verify(btn !== null, "delete button must exist in the rendered card")
        verify(btn.visible, "must be visible for a role that can manage inventory")
    }

    function test_delete_button_is_hidden_when_canManageInventory_is_false() {
        page.destroy()
        page = createTemporaryObject(pageComponent, testCase,
            { width: 420, height: 800, canManageInventory: false })
        waitForRendering(page)
        var btn = findChild(page, "deleteBtn")
        verify(btn !== null)
        compare(btn.visible, false, "same gate as Restock -- canManage false hides it")
    }

    function test_tapping_delete_emits_deleteProductClicked_with_the_right_id() {
        var spy = Qt.createQmlObject(
            'import QtTest 1.0; SignalSpy {}', testCase, "spy")
        spy.target = page
        spy.signalName = "deleteProductClicked"

        var btn = findChild(page, "deleteBtn")
        verify(btn !== null)
        mouseClick(btn)

        compare(spy.count, 1)
        compare(spy.signalArguments[0][0], "SKU-1")
        spy.destroy()
    }

    function test_tapping_delete_does_not_also_trigger_viewProductClicked() {
        // The whole card's onClicked also fires viewClicked -- the delete
        // button's MouseArea must accept the event so it doesn't bubble.
        var viewSpy = Qt.createQmlObject('import QtTest 1.0; SignalSpy {}', testCase, "viewSpy")
        viewSpy.target = page
        viewSpy.signalName = "viewProductClicked"

        var btn = findChild(page, "deleteBtn")
        mouseClick(btn)

        compare(viewSpy.count, 0, "the tap must not bubble through to the card's own onClicked")
        viewSpy.destroy()
    }
}
