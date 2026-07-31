import QtQuick
import QtTest
import "../qml/helper/ProfileSettingsMath.js" as ProfileSettingsMath

TestCase {
    name: "ProfileSettingsMath"

    property var current: ({
        phone: "555", address: "10 Main", city: "Pune", country: "India",
        postalCode: "411001", tenantName: "Old Workspace"
    })

    function test_no_changes_creates_no_writes() {
        var r = ProfileSettingsMath.buildChangeSet(current, current, "owner")
        compare(r.error, "")
        compare(r.hasChanges, false)
        compare(Object.keys(r.userPatch).length, 0)
        compare(r.tenantPatch, null)
    }

    function test_owner_workspace_name_is_trimmed_and_mirrored() {
        var draft = Object.assign({}, current, { tenantName: "  New Workspace  " })
        var r = ProfileSettingsMath.buildChangeSet(current, draft, "owner")
        compare(r.error, "")
        compare(r.workspaceChanged, true)
        compare(r.workspaceName, "New Workspace")
        compare(r.tenantPatch.name, "New Workspace")
        compare(r.userPatch.tenantName, "New Workspace")
        compare(r.profileState.tenantName, "New Workspace")
    }

    function test_blank_changed_workspace_name_is_rejected() {
        var draft = Object.assign({}, current, { tenantName: "   " })
        var r = ProfileSettingsMath.buildChangeSet(current, draft, "owner")
        compare(r.error, "Workspace name is required")
        compare(r.hasChanges, false)
    }

    function test_non_owner_cannot_request_a_workspace_rename() {
        var draft = Object.assign({}, current, { tenantName: "New Workspace" })
        var r = ProfileSettingsMath.buildChangeSet(current, draft, "admin")
        compare(r.error, "Only the workspace owner can rename it")
        compare(r.hasChanges, false)
    }

    function test_contact_only_change_uses_only_the_user_patch() {
        var draft = Object.assign({}, current, { city: "Mumbai" })
        var r = ProfileSettingsMath.buildChangeSet(current, draft, "manager")
        compare(r.error, "")
        compare(r.hasChanges, true)
        compare(r.workspaceChanged, false)
        compare(r.userPatch.city, "Mumbai")
        compare(r.tenantPatch, null)
    }
}
