import QtQuick
import QtTest
import "../qml/model"
import "../qml/components"

// StaffStore.deleteStaff and _onMutationConflicted had zero test coverage
// before this file. Written against the same structure as
// tst_InventoryStore_mutationConflicted.qml, DELETE-FEATURE-ROADMAP item 2
// (2026-09-21): _onMutationConflicted gained the `action` param this branch
// (it was left with the old pre-action-param wording during the
// products/orders fix — see KNOWN-ISSUES.md — because it was unreachable
// from the UI until this branch added the row-level delete button).
//
// NOT RUN IN THIS SANDBOX — no Qt/qmltestrunner toolchain available.
TestCase {
    name: "StaffStore_delete"

    SignalSpy { id: toastSpy; target: Toast; signalName: "showRequested" }

    function init() {
        StaffStore.staff = []
        StaffStore.removedNames = ({})
        Gateway.mode = "gateway" // queues into OutboxStore rather than a live send/direct write
        OutboxStore.clear()
        toastSpy.clear()
    }

    function _staffMember(overrides) {
        return Object.assign({ staffId: "S-1", name: "Alex", email: "alex@example.com",
                 phone: "", role: "staff", department: "Sales", joinDate: "2026-01-01",
                 status: "active", salary: 0, appUid: "" }, overrides || {})
    }

    // ── deleteStaff ──────────────────────────────────────────────────────────

    function test_deleteStaff_removes_the_record_locally() {
        StaffStore.staff = [_staffMember()]
        StaffStore.deleteStaff("S-1")
        compare(StaffStore.staff.length, 0)
    }

    function test_deleteStaff_queues_a_delete_mutation() {
        StaffStore.staff = [_staffMember()]
        StaffStore.deleteStaff("S-1")
        const queued = OutboxStore.items.filter(function(i) { return i.entity === "staff" && i.entityId === "S-1" })
        compare(queued.length, 1)
        compare(queued[0].action, "delete")
    }

    function test_deleteStaff_on_an_unknown_id_is_a_no_op() {
        StaffStore.staff = [_staffMember()]
        StaffStore.deleteStaff("does-not-exist")
        compare(StaffStore.staff.length, 1, "the only real record must be untouched")
        const queued = OutboxStore.items.filter(function(i) { return i.entity === "staff" })
        compare(queued.length, 0, "nothing should be queued for a record that was never found")
    }

    function test_deleteStaff_only_removes_the_matching_id() {
        StaffStore.staff = [_staffMember(), _staffMember({ staffId: "S-2" })]
        StaffStore.deleteStaff("S-1")
        compare(StaffStore.staff.length, 1)
        compare(StaffStore.staff[0].staffId, "S-2")
    }

    // ── _onMutationConflicted ────────────────────────────────────────────────

    function test_ignores_a_non_staff_entity() {
        StaffStore.staff = [_staffMember()]
        StaffStore._onMutationConflicted("order", "S-1", { staffId: "S-1", name: "Renamed" }, "update")
        compare(StaffStore.staff[0].name, "Alex", "untouched")
        compare(toastSpy.count, 0, "no toast for an entity this handler doesn't own")
    }

    function test_update_conflict_replaces_the_record_and_shows_the_update_worded_toast() {
        StaffStore.staff = [_staffMember()]
        StaffStore._onMutationConflicted("staff", "S-1", _staffMember({ name: "Renamed Elsewhere" }), "update")

        compare(StaffStore.staff.length, 1)
        compare(StaffStore.staff[0].name, "Renamed Elsewhere")
        compare(toastSpy.count, 1)
        compare(toastSpy.signalArguments[0][0],
                "This staff record was updated elsewhere — your change didn't save. Refreshed to the latest version.")
    }

    function test_delete_conflict_restores_the_record_and_shows_the_delete_worded_toast() {
        // Optimistically removed by deleteStaff() before the mutation was
        // sent; the server rejected the delete because someone else's edit
        // landed first, so `current` is that edit and the record must
        // reappear — same reasoning as InventoryStore's twin.
        StaffStore.staff = [] // already spliced out by deleteStaff()'s optimistic apply
        StaffStore._onMutationConflicted("staff", "S-1", _staffMember({ name: "Alex" }), "delete")

        compare(StaffStore.staff.length, 1, "record must be restored, not stay deleted")
        compare(StaffStore.staff[0].staffId, "S-1")
        compare(toastSpy.count, 1)
        compare(toastSpy.signalArguments[0][0],
                "Couldn't delete — this staff record was updated elsewhere. It's been restored with the latest version.")
    }

    function test_pushes_current_when_the_record_is_not_locally_known() {
        StaffStore.staff = []
        StaffStore._onMutationConflicted("staff", "S-9", _staffMember({ staffId: "S-9" }), "update")
        compare(StaffStore.staff.length, 1)
        compare(StaffStore.staff[0].staffId, "S-9")
    }

    function test_a_rejected_delete_with_no_current_removes_the_record_if_still_present() {
        // current === null (server confirms the record is genuinely gone) —
        // nothing to restore, so any locally-present copy is spliced out too.
        StaffStore.staff = [_staffMember()]
        StaffStore._onMutationConflicted("staff", "S-1", null, "delete")
        compare(StaffStore.staff.length, 0)
        compare(toastSpy.count, 1)
        compare(toastSpy.signalArguments[0][0],
                "Couldn't delete — this staff record was updated elsewhere. It's been restored with the latest version.")
    }
}
