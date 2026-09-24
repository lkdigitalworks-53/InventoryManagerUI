import QtQuick
import QtTest
import "../qml/model"
import "../qml/components"

// PR #80 on-device finding: after a staff member was deleted, their orders
// showed no name (order detail, exported sheet, Sales Analysis), and a
// newly-added staff member with the same name appeared to "own" the old
// orders. StaffStore now keeps a tombstone { staffId: name } for every
// hard-deleted member (persisted via the `removed_staff` gateway entity) and
// never hands a deleted id to a new hire.
//
// NOT RUN IN THIS SANDBOX — no Qt/qmltestrunner toolchain; CI is the signal.
// (The async FirebaseService.mintCounterValue / query paths have no mock
// layer in this codebase, so the guard and merge are tested through their
// pure pieces: _seedMax, _isBurned, _mergeRemoved.)
TestCase {
    name: "StaffStore_removedNames"

    SignalSpy { id: toastSpy; target: Toast; signalName: "showRequested" }

    function init() {
        StaffStore.staff = []
        StaffStore.removedNames = ({})
        Gateway.mode = "gateway"
        OutboxStore.clear()
        toastSpy.clear()
    }

    function cleanup() {
        StaffStore.staff = []
        StaffStore.removedNames = ({})
        OutboxStore.clear()
    }

    function _member(overrides) {
        return Object.assign({ staffId: "S-1", name: "Ravi", email: "r@example.com",
                 phone: "", role: "staff", department: "Sales", joinDate: "2026-01-01",
                 status: "active", salary: 0, appUid: "" }, overrides || {})
    }

    function _queued(entity) {
        return OutboxStore.items.filter(function(i) { return i.entity === entity })
    }

    // ── name resolution ──────────────────────────────────────────────────────

    function test_live_staff_resolves_to_the_plain_name() {
        StaffStore.staff = [_member()]
        compare(StaffStore.nameOf("S-1"), "Ravi")
        compare(StaffStore.displayName("S-1"), "Ravi")
        verify(!StaffStore.isRemoved("S-1"))
    }

    function test_empty_and_unknown_ids_resolve_to_empty() {
        StaffStore.staff = [_member()]
        compare(StaffStore.nameOf(""), "")
        compare(StaffStore.displayName(""), "")
        compare(StaffStore.nameOf(undefined), "")
        compare(StaffStore.displayName("S-404"), "", "no live record and no tombstone = genuinely unknown")
        verify(!StaffStore.isRemoved("S-404"))
        verify(!StaffStore.isRemoved(""))
    }

    function test_a_tombstoned_id_keeps_its_name_and_is_marked_removed() {
        StaffStore.removedNames = ({ "S-1": "Ravi" })
        compare(StaffStore.nameOf("S-1"), "Ravi")
        compare(StaffStore.displayName("S-1"), "Ravi (removed)")
        verify(StaffStore.isRemoved("S-1"))
    }

    function test_a_tombstone_with_an_empty_name_still_reads_as_removed() {
        StaffStore.removedNames = ({ "S-1": "" })
        compare(StaffStore.nameOf("S-1"), "")
        compare(StaffStore.displayName("S-1"), "(removed)")
        verify(StaffStore.isRemoved("S-1"))
    }

    function test_a_live_record_always_beats_a_stray_tombstone() {
        // e.g. a delete rejected with a conflict leaves the tombstone the
        // client already sent.
        StaffStore.staff = [_member({ name: "Ravi Kumar" })]
        StaffStore.removedNames = ({ "S-1": "Ravi" })
        compare(StaffStore.displayName("S-1"), "Ravi Kumar")
        verify(!StaffStore.isRemoved("S-1"))
    }

    function test_a_removed_member_and_a_same_name_new_hire_never_look_alike() {
        // The reported scenario: delete "Ravi", add another "Ravi".
        StaffStore.staff = [_member({ staffId: "S-2", name: "Ravi" })]
        StaffStore.removedNames = ({ "S-1": "Ravi" })
        compare(StaffStore.displayName("S-1"), "Ravi (removed)")
        compare(StaffStore.displayName("S-2"), "Ravi")
        verify(StaffStore.displayName("S-1") !== StaffStore.displayName("S-2"))
    }

    // ── deleteStaff writes the tombstone ─────────────────────────────────────

    function test_deleteStaff_keeps_the_name_after_the_record_is_gone() {
        StaffStore.staff = [_member()]
        StaffStore.deleteStaff("S-1")
        compare(StaffStore.staff.length, 0)
        compare(StaffStore.nameOf("S-1"), "Ravi")
        compare(StaffStore.displayName("S-1"), "Ravi (removed)")
        verify(StaffStore.isRemoved("S-1"))
    }

    function test_deleteStaff_queues_a_removed_staff_create_with_id_and_name() {
        StaffStore.staff = [_member()]
        StaffStore.deleteStaff("S-1")
        var q = _queued("removed_staff")
        compare(q.length, 1)
        compare(q[0].entityId, "S-1")
        compare(q[0].action, "create")
        compare(q[0].before, null)
        compare(q[0].after.staffId, "S-1")
        compare(q[0].after.name, "Ravi")
        verify(String(q[0].after.removedAt).length > 0)
    }

    function test_the_tombstone_is_queued_before_the_delete() {
        StaffStore.staff = [_member()]
        StaffStore.deleteStaff("S-1")
        var kinds = OutboxStore.items.filter(function(i) {
            return i.entity === "removed_staff" || i.entity === "staff"
        }).map(function(i) { return i.entity })
        compare(kinds, ["removed_staff", "staff"], "an interrupted sync must never leave the delete without its tombstone")
    }

    function test_deleteStaff_still_queues_exactly_one_staff_delete() {
        StaffStore.staff = [_member()]
        StaffStore.deleteStaff("S-1")
        var q = _queued("staff")
        compare(q.length, 1)
        compare(q[0].action, "delete")
    }

    function test_deleting_an_unknown_id_writes_no_tombstone() {
        StaffStore.staff = [_member()]
        StaffStore.deleteStaff("S-404")
        compare(_queued("removed_staff").length, 0)
        compare(Object.keys(StaffStore.removedNames).length, 0)
        compare(StaffStore.staff.length, 1)
    }

    function test_deleting_a_member_with_an_empty_name_still_burns_the_id() {
        StaffStore.staff = [_member({ name: "" })]
        StaffStore.deleteStaff("S-1")
        verify(StaffStore._isBurned("S-1"))
        compare(StaffStore.displayName("S-1"), "(removed)")
    }

    function test_deleting_twice_is_harmless() {
        StaffStore.staff = [_member()]
        StaffStore.deleteStaff("S-1")
        StaffStore.deleteStaff("S-1")
        compare(_queued("removed_staff").length, 1, "second call finds no record, so it queues nothing")
        compare(StaffStore.displayName("S-1"), "Ravi (removed)")
    }

    function test_deleting_one_member_leaves_the_others_untouched() {
        StaffStore.staff = [_member(), _member({ staffId: "S-2", name: "Priya" })]
        StaffStore.deleteStaff("S-1")
        compare(StaffStore.displayName("S-2"), "Priya")
        verify(!StaffStore.isRemoved("S-2"))
    }

    // ── conflict handling ────────────────────────────────────────────────────

    function test_a_rejected_delete_drops_the_local_tombstone() {
        StaffStore.staff = [_member()]
        StaffStore.deleteStaff("S-1")
        StaffStore._onMutationConflicted("staff", "S-1", _member({ name: "Ravi (edited elsewhere)" }), "delete")
        compare(StaffStore.displayName("S-1"), "Ravi (edited elsewhere)")
        verify(!StaffStore._isBurned("S-1"), "a live id must not stay burned")
    }

    function test_a_delete_conflict_with_no_current_keeps_the_tombstone() {
        // Server confirms the record is genuinely gone.
        StaffStore.staff = [_member()]
        StaffStore.deleteStaff("S-1")
        StaffStore._onMutationConflicted("staff", "S-1", null, "delete")
        verify(StaffStore.isRemoved("S-1"))
        compare(StaffStore.displayName("S-1"), "Ravi (removed)")
    }

    function test_an_update_conflict_does_not_touch_tombstones() {
        StaffStore.removedNames = ({ "S-2": "Old Timer" })
        StaffStore.staff = [_member()]
        StaffStore._onMutationConflicted("staff", "S-1", _member({ name: "X" }), "update")
        compare(StaffStore.displayName("S-2"), "Old Timer (removed)")
    }

    function test_a_tombstone_entity_conflict_is_ignored_by_the_staff_handler() {
        // Re-create of an existing tombstone -> server 409 -> Gateway emits
        // mutationConflicted("removed_staff", ...). Must not touch the roster
        // or raise a "staff record was updated elsewhere" toast.
        StaffStore.staff = [_member()]
        StaffStore._onMutationConflicted("removed_staff", "S-1", { staffId: "S-1", name: "Ravi" }, "create")
        compare(StaffStore.staff.length, 1)
        compare(StaffStore.staff[0].name, "Ravi")
        compare(toastSpy.count, 0)
    }

    // ── id minting guard ─────────────────────────────────────────────────────

    function test_seedMax_covers_live_and_removed_ids() {
        StaffStore.staff = [_member({ staffId: "STF-003" }), _member({ staffId: "STF-001" })]
        StaffStore.removedNames = ({ "STF-007": "Gone" })
        compare(StaffStore._seedMax(), 7, "a deleted highest id must still seed the counter")
    }

    function test_seedMax_is_zero_when_empty_and_ignores_malformed_ids() {
        compare(StaffStore._seedMax(), 0)
        StaffStore.staff = [_member({ staffId: "weird" }), _member({ staffId: "STF-" }), _member({ staffId: "" })]
        StaffStore.removedNames = ({ "nope": "x" })
        compare(StaffStore._seedMax(), 0)
    }

    function test_isBurned_only_for_tombstoned_ids() {
        StaffStore.removedNames = ({ "STF-002": "Ravi" })
        verify(StaffStore._isBurned("STF-002"))
        verify(!StaffStore._isBurned("STF-003"))
        verify(!StaffStore._isBurned(""))
    }

    function test_isBurned_is_not_fooled_by_object_prototype_names() {
        verify(!StaffStore._isBurned("constructor"))
        verify(!StaffStore._isBurned("toString"))
        verify(!StaffStore._isBurned("__proto__"))
    }

    // ── merging fetched tombstones ───────────────────────────────────────────

    function test_merge_adds_fetched_tombstones() {
        StaffStore._mergeRemoved([{ staffId: "S-1", name: "Ravi" }, { staffId: "S-2", name: "Priya" }])
        compare(StaffStore.nameOf("S-1"), "Ravi")
        compare(StaffStore.nameOf("S-2"), "Priya")
    }

    function test_merge_never_overwrites_a_local_tombstone() {
        StaffStore.removedNames = ({ "S-1": "Local Name" })
        StaffStore._mergeRemoved([{ staffId: "S-1", name: "Server Name" }])
        compare(StaffStore.nameOf("S-1"), "Local Name")
    }

    function test_merge_ignores_junk_and_handles_null() {
        StaffStore.removedNames = ({ "S-1": "Ravi" })
        StaffStore._mergeRemoved(null)
        StaffStore._mergeRemoved(undefined)
        StaffStore._mergeRemoved([null, {}, { name: "no id" }, { staffId: "" , name: "empty id" }])
        compare(Object.keys(StaffStore.removedNames), ["S-1"])
    }

    function test_merge_defaults_a_missing_name_to_empty() {
        StaffStore._mergeRemoved([{ staffId: "S-5" }])
        compare(StaffStore.nameOf("S-5"), "")
        verify(StaffStore.isRemoved("S-5"))
    }

    function test_merge_keeps_a_pending_local_tombstone_across_a_sync() {
        StaffStore.staff = [_member()]
        StaffStore.deleteStaff("S-1")        // not on the server yet
        StaffStore._mergeRemoved([{ staffId: "S-9", name: "Other" }])
        compare(StaffStore.displayName("S-1"), "Ravi (removed)")
        compare(StaffStore.displayName("S-9"), "Other (removed)")
    }

    // ── lifecycle ────────────────────────────────────────────────────────────

    function test_clear_wipes_tombstones_so_one_tenant_never_sees_anothers() {
        StaffStore.removedNames = ({ "S-1": "Ravi" })
        StaffStore.clear()
        compare(Object.keys(StaffStore.removedNames).length, 0)
        compare(StaffStore.displayName("S-1"), "")
    }

    // ── monkey ───────────────────────────────────────────────────────────────

    function test_monkey_random_deletes_never_lose_a_name_or_mislabel_a_live_member() {
        var seed = 987
        function rnd() { seed = (seed * 1103515245 + 12345) & 0x7fffffff; return seed / 0x7fffffff }
        var roster = []
        for (var i = 1; i <= 30; ++i)
            roster.push(_member({ staffId: "S-" + i, name: (i % 4 === 0) ? "Ravi" : ("Person " + i) }))
        StaffStore.staff = roster
        var deleted = {}
        for (var k = 0; k < 60; ++k) {
            var id = "S-" + (1 + Math.floor(rnd() * 35))   // includes ids that never existed
            StaffStore.deleteStaff(id)
            if (Number(id.split("-")[1]) <= 30) deleted[id] = true
        }
        for (var j = 1; j <= 30; ++j) {
            var sid = "S-" + j
            var expected = (j % 4 === 0) ? "Ravi" : ("Person " + j)
            if (deleted[sid]) {
                compare(StaffStore.displayName(sid), expected + " (removed)", sid)
                verify(StaffStore.isRemoved(sid), sid)
            } else {
                compare(StaffStore.displayName(sid), expected, sid)
                verify(!StaffStore.isRemoved(sid), sid)
            }
        }
        compare(_queued("removed_staff").length, Object.keys(deleted).length,
                "exactly one tombstone per member actually deleted")
    }
}
