import QtQuick
import QtTest
import "../qml/helper/MemberPolicy.js" as P

// MemberPolicy mirrors firestore.rules (canAssignRole + canManageTarget) and functions/index.js
// canAssignRole. The 4x4 tables below are the same matrix test/firestore.rules.test.js proves in the
// emulator ("D-1 hierarchy matrix"): if one changes, change all three.
TestCase {
    name: "MemberPolicy"

    readonly property var roles: ["owner", "admin", "manager", "staff"]

    // rows = actor, columns = owner, admin, manager, staff
    readonly property var assignTable: ({
        owner:   [false, true,  true,  true],
        admin:   [false, false, true,  true],
        manager: [false, false, false, false],
        staff:   [false, false, false, false]
    })
    readonly property var manageTable: ({
        owner:   [false, true,  true,  true],
        admin:   [false, false, true,  true],
        manager: [false, false, false, false],
        staff:   [false, false, false, false]
    })

    function test_canAssignRole_matrix() {
        for (var a = 0; a < roles.length; ++a)
            for (var t = 0; t < roles.length; ++t)
                compare(P.canAssignRole(roles[a], roles[t]), assignTable[roles[a]][t], roles[a] + " assigns " + roles[t])
    }

    function test_canManageMember_matrix() {
        for (var a = 0; a < roles.length; ++a)
            for (var t = 0; t < roles.length; ++t)
                compare(P.canManageMember(roles[a], roles[t]), manageTable[roles[a]][t], roles[a] + " manages " + roles[t])
    }

    function test_admin_cannot_manage_peer_admin_or_owner() {
        compare(P.canManageMember("admin", "admin"), false)
        compare(P.canManageMember("admin", "owner"), false)
    }

    function test_owner_manages_admin_but_never_owner() {
        compare(P.canManageMember("owner", "admin"), true)
        compare(P.canManageMember("owner", "owner"), false)
    }

    function test_unknown_actor_or_target_fails_closed() {
        var junk = ["", "viewer", "Owner", "ADMIN", undefined, null, 7, {}]
        for (var i = 0; i < junk.length; ++i) {
            compare(P.canManageMember(junk[i], "staff"), false, "actor " + junk[i])
            compare(P.canAssignRole(junk[i], "staff"), false, "actor " + junk[i])
            compare(P.canManageMember("owner", junk[i]), false, "target " + junk[i])
            compare(P.canManageMember("admin", junk[i]), false, "target " + junk[i])
            compare(P.canAssignRole("owner", junk[i]), false, "assign " + junk[i])
        }
    }

    function test_manage_and_assign_agree_except_for_owner_target_semantics() {
        // For every actor/target pair the two answers match today (owner target is false in both).
        for (var a = 0; a < roles.length; ++a)
            for (var t = 0; t < roles.length; ++t)
                compare(P.canManageMember(roles[a], roles[t]), P.canAssignRole(roles[a], roles[t]))
    }
}
