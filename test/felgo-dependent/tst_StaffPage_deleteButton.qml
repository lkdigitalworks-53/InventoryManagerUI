import QtQuick
import QtTest
import "../../qml/pages"
import "../../qml/model"

// Coverage for the actual button added this branch (DELETE-FEATURE-ROADMAP
// item 2): the trash icon in StaffPage.qml's row, wired to
// root.deleteStaffClicked(staffId) (already-existing plumbing this branch
// didn't touch except adding the DataModel self-delete guard, both covered
// in tests/tst_DataModel_deleteGuards.qml).
//
// Same root cause as tst_OrdersPage_deleteButton.qml / tst_InventoryPage_
// deleteButton.qml in this directory: StaffPage.qml -> GlassHeader ->
// Constants.qml -> `import Felgo`, and the "QML Tests" CI job installs
// plain Qt only, no Felgo. Not runnable under that job for any full Page —
// run manually on a machine with Felgo (Taher's dev box, Qt Creator +
// Felgo SDK). See docs/superpowers/test-plans/2026-09-21-staff-delete-ui-
// test-plan.md for the on-device steps.
TestCase {
    id: testCase
    name: "StaffPage_deleteButton"
    when: windowShown
    width: 420
    height: 800

    property var page: null

    function _staff() {
        return { staffId: "S-001", name: "Alex Doe", email: "alex@example.com",
                 phone: "", role: "staff", department: "Sales", joinDate: "2026-01-01",
                 status: "active", salary: 0, appUid: "" }
    }

    function init() {
        StaffStore.staff = [_staff()]
        page = createTemporaryObject(pageComponent, testCase, { width: 420, height: 800 })
        verify(page !== null, "StaffPage must instantiate")
        waitForRendering(page)
    }

    Component {
        id: pageComponent
        StaffPage { canManageStaff: true }
    }

    function test_delete_button_is_visible_when_canManageStaff_is_true() {
        var btn = findChild(page, "deleteStaffBtn")
        verify(btn !== null, "delete button must exist in the rendered row")
        verify(btn.visible)
    }

    function test_delete_button_is_hidden_when_canManageStaff_is_false() {
        page.destroy()
        page = createTemporaryObject(pageComponent, testCase,
            { width: 420, height: 800, canManageStaff: false })
        waitForRendering(page)
        var btn = findChild(page, "deleteStaffBtn")
        verify(btn !== null)
        compare(btn.visible, false)
    }

    function test_delete_button_stays_visible_regardless_of_staff_status() {
        // Same deliberate choice as orders/products: no per-row status
        // gating. DataModel's own guards (role, self-delete) produce the
        // specific message on tap rather than this row re-deriving them.
        page.destroy()
        StaffStore.staff = [{ staffId: "S-001", name: "Alex Doe", email: "", phone: "",
                               role: "staff", department: "Sales", joinDate: "2026-01-01",
                               status: "on leave", salary: 0, appUid: "" }]
        page = createTemporaryObject(pageComponent, testCase, { width: 420, height: 800 })
        waitForRendering(page)
        var btn = findChild(page, "deleteStaffBtn")
        verify(btn !== null)
        verify(btn.visible, "visible regardless of status -- DataModel's guard explains any block on tap")
    }

    function test_tapping_delete_emits_deleteStaffClicked_with_the_right_id() {
        var spy = Qt.createQmlObject('import QtTest 1.0; SignalSpy {}', testCase, "spy")
        spy.target = page
        spy.signalName = "deleteStaffClicked"

        var btn = findChild(page, "deleteStaffBtn")
        verify(btn !== null)
        mouseClick(btn)

        compare(spy.count, 1)
        compare(spy.signalArguments[0][0], "S-001")
        spy.destroy()
    }

    function test_tapping_delete_does_not_also_trigger_viewStaffClicked() {
        var viewSpy = Qt.createQmlObject('import QtTest 1.0; SignalSpy {}', testCase, "viewSpy")
        viewSpy.target = page
        viewSpy.signalName = "viewStaffClicked"

        var btn = findChild(page, "deleteStaffBtn")
        mouseClick(btn)

        compare(viewSpy.count, 0, "the tap must not bubble through to the row's own onClicked")
        viewSpy.destroy()
    }
}
