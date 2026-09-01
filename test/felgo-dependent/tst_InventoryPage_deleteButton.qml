import QtQuick
import QtTest
import "../qml/pages"
import "../qml/model"

// Coverage for the actual button added this branch: ProductCard's trash
// icon inside InventoryPage.qml, wired to card.deleteClicked() ->
// root.deleteProductClicked(productId).
//
// FLAGGED, READ BEFORE TRUSTING THIS FILE: every other test in this suite
// (51 pre-existing files, all model/store/logic layer) exercises a
// singleton or a plain QML type directly. This is the first test in the
// project that instantiates a full Page and simulates a tap on it.
// InventoryPage carries real dependencies (InventoryStore singleton,
// AvatarBadge/StockProgressBar/StatusPill/ListCard components, a
// ScrollView/Flickable layout chain) that a bare TestCase may or may not
// satisfy cleanly without the app's normal Felgo bootstrap -- I have no
// way to compile-check this without a Qt toolchain, so treat this file as
// the first one to run (and the most likely to need adjustment) once
// qmltestrunner is available. If it fails outright rather than reporting
// a real assertion failure, that's a setup problem with THIS file, not
// evidence the button itself is broken -- the button's own logic (does
// tapping it call deleteProductClicked with the right id) is a direct
// copy of the already-shipped Restock button's Rectangle+MouseArea idiom.
//
// NOT RUN IN THIS SANDBOX.
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
