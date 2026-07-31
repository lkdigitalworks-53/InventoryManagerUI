.pragma library

// Pure normalization, authorization, and minimal-patch calculation for a
// Profile settings draft. No QML imports, no singletons, no dp()/sp() —
// everything needed is passed in. Keeps AuthService's coordinated save free
// of business-rule logic so it can be unit tested headlessly
// (tests/tst_ProfileSettingsMath.qml).

function _value(source, key) {
    return source && source[key] !== undefined && source[key] !== null
            ? String(source[key]) : ""
}

function _trim(value) {
    return value === undefined || value === null ? "" : String(value).trim()
}

function buildChangeSet(current, draft, role) {
    var fields = ["phone", "address", "city", "country", "postalCode"]
    var currentName = _trim(current ? current.tenantName : "")
    var requestedName = _trim(draft ? draft.tenantName : "")
    var workspaceChanged = requestedName !== currentName

    if (workspaceChanged && requestedName.length === 0)
        return { error: "Workspace name is required", hasChanges: false }
    if (workspaceChanged && role !== "owner")
        return { error: "Only the workspace owner can rename it", hasChanges: false }

    var userPatch = {}
    var profileState = {}
    for (var i = 0; i < fields.length; ++i) {
        var field = fields[i]
        var value = _trim(draft ? draft[field] : "")
        profileState[field] = value
        if (value !== _value(current, field))
            userPatch[field] = value
    }
    profileState.tenantName = workspaceChanged ? requestedName : currentName
    if (workspaceChanged)
        userPatch.tenantName = requestedName

    return {
        error: "",
        hasChanges: Object.keys(userPatch).length > 0,
        workspaceChanged: workspaceChanged,
        workspaceName: profileState.tenantName,
        userPatch: userPatch,
        tenantPatch: workspaceChanged ? { name: requestedName } : null,
        profileState: profileState
    }
}
