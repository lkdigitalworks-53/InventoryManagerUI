import QtQuick
import QtTest
import "../qml/helper/StaffPicker.js" as StaffPicker

// Pure builder behind OrderDetailDialog's "Sold by" combo. The bug it fixes:
// an order whose staff member was deleted (or is on leave) opened with the
// combo on "none" and saving silently wiped the attribution.
//
// NOT RUN IN THIS SANDBOX — no Qt/qmltestrunner toolchain; CI is the signal.
TestCase {
    name: "StaffPicker"

    readonly property var roster: [
        { staffId: "S-1", name: "Alex",  status: "active" },
        { staffId: "S-2", name: "Priya", status: "active" },
        { staffId: "S-3", name: "Sam",   status: "on_leave" },
        { staffId: "S-4", name: "Lee",   status: "suspended" },
        { staffId: "S-5", name: "Kim" }                      // no status = active
    ]

    function _opts(labelFor) {
        return { noneLabel: "NONE", unnamedLabel: "UNNAMED", removedLabel: "REMOVED", labelFor: labelFor }
    }

    // ── happy path ───────────────────────────────────────────────────────────

    function test_only_active_staff_are_offered_and_none_is_first() {
        var r = StaffPicker.build(roster, "", _opts())
        compare(r.ids, ["", "S-1", "S-2", "S-5"])
        compare(r.labels, ["NONE", "Alex", "Priya", "Kim"])
        compare(r.index, 0)
    }

    function test_preferred_active_staff_is_selected() {
        var r = StaffPicker.build(roster, "S-2", _opts())
        compare(r.index, 2)
        compare(r.ids[r.index], "S-2")
        compare(r.ids.length, 4, "no extra row when the preferred id is already offered")
    }

    // ── the regression: attribution must survive a picker rebuild ───────────

    function test_deleted_staff_row_is_appended_with_the_tombstone_label_and_selected() {
        var r = StaffPicker.build(roster, "S-9", _opts(function(id) { return "Ravi (removed)" }))
        compare(r.ids[r.index], "S-9", "saving must keep S-9, not fall back to none")
        compare(r.labels[r.index], "Ravi (removed)")
        compare(r.ids.length, 5)
    }

    function test_on_leave_staff_stays_selected_instead_of_being_wiped() {
        var r = StaffPicker.build(roster, "S-3", _opts(function(id) { return "Sam" }))
        compare(r.ids[r.index], "S-3")
        compare(r.labels[r.index], "Sam")
    }

    function test_suspended_staff_stays_selected() {
        var r = StaffPicker.build(roster, "S-4", _opts(function(id) { return "Lee" }))
        compare(r.ids[r.index], "S-4")
    }

    function test_unknown_id_with_no_tombstone_uses_the_removed_label() {
        var r = StaffPicker.build(roster, "S-9", _opts(function(id) { return "" }))
        compare(r.ids[r.index], "S-9")
        compare(r.labels[r.index], "REMOVED")
    }

    // ── negative / edge ──────────────────────────────────────────────────────

    function test_empty_preferred_selects_none_and_adds_no_row() {
        var r = StaffPicker.build(roster, "", _opts(function() { return "x" }))
        compare(r.index, 0)
        compare(r.ids.length, 4)
    }

    function test_undefined_and_null_preferred_select_none() {
        compare(StaffPicker.build(roster, undefined, _opts()).index, 0)
        compare(StaffPicker.build(roster, null, _opts()).index, 0)
    }

    function test_null_and_empty_roster() {
        var r = StaffPicker.build(null, "", _opts())
        compare(r.ids, [""])
        compare(r.index, 0)
        var r2 = StaffPicker.build([], "S-1", _opts(function() { return "Gone" }))
        compare(r2.ids, ["", "S-1"])
        compare(r2.index, 1)
        compare(r2.labels[1], "Gone")
    }

    function test_no_opts_at_all_does_not_throw() {
        var r = StaffPicker.build(roster, "S-9")
        compare(r.ids[r.index], "S-9")
        compare(r.labels[0], "")
    }

    function test_labelFor_that_is_not_a_function_is_ignored() {
        var r = StaffPicker.build(roster, "S-9", { removedLabel: "REMOVED", labelFor: "nope" })
        compare(r.labels[r.index], "REMOVED")
    }

    function test_unnamed_active_staff_gets_the_unnamed_label() {
        var r = StaffPicker.build([{ staffId: "S-7", name: "", status: "active" }], "", _opts())
        compare(r.labels[1], "UNNAMED")
    }

    function test_legacy_id_field_is_honoured() {
        var r = StaffPicker.build([{ id: "L-1", name: "Legacy", status: "active" }], "L-1", _opts())
        compare(r.ids[r.index], "L-1")
    }

    function test_ids_and_labels_stay_parallel_arrays() {
        var r = StaffPicker.build(roster, "S-9", _opts(function() { return "Z" }))
        compare(r.ids.length, r.labels.length)
    }

    // ── multi-scenario / monkey ──────────────────────────────────────────────

    function test_every_possible_preferred_id_round_trips() {
        var wanted = ["", "S-1", "S-2", "S-3", "S-4", "S-5", "S-9", "STF-404"]
        for (var i = 0; i < wanted.length; ++i) {
            var r = StaffPicker.build(roster, wanted[i], _opts(function(id) { return "n:" + id }))
            compare(r.ids[r.index], wanted[i], "selection must round-trip for '" + wanted[i] + "'")
            verify(r.index >= 0 && r.index < r.ids.length)
        }
    }

    function test_monkey_random_rosters_never_lose_the_current_attribution() {
        var seed = 12345
        function rnd() { seed = (seed * 1103515245 + 12345) & 0x7fffffff; return seed / 0x7fffffff }
        var statuses = ["active", "on_leave", "suspended", undefined, ""]
        for (var round = 0; round < 200; ++round) {
            var n = Math.floor(rnd() * 12)
            var list = []
            for (var k = 0; k < n; ++k)
                list.push({ staffId: "S-" + k, name: rnd() < 0.2 ? "" : "N" + k,
                            status: statuses[Math.floor(rnd() * statuses.length)] })
            var pick = rnd() < 0.15 ? "" : "S-" + Math.floor(rnd() * 16)
            var r = StaffPicker.build(list, pick, _opts(function(id) { return "L:" + id }))
            compare(r.ids[r.index], pick, "round " + round)
            compare(r.ids.length, r.labels.length)
            compare(r.ids[0], "")
        }
    }
}
