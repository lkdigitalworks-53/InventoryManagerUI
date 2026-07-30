# Workspace Name Editing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let only a workspace owner rename the workspace from Profile settings, reliably persist both canonical and mirror values, and receive success only after every required write succeeds.

**Architecture:** A new pure helper computes normalized profile/workspace changes and rejects invalid or unauthorized renames without knowing about QML singletons or Firestore. `AuthService` owns asynchronous orchestration, issuing only the needed `FirebaseService.patch` calls and emitting exactly one terminal success or failure signal after every request settles. The dialog owns temporary editing state and makes one service call through its existing Save button.

**Tech Stack:** Felgo/Qt Quick QML, Qt Quick Test, `.pragma library` JavaScript, Firebase Firestore REST via `FirebaseService`.

## Global Constraints

- Workspace renames are owner-only: the exact role check is `AuthStore.role === "owner"`; do not change `firestore.rules`.
- Keep workspace editing inside `ProfileSettingsDialog` and its existing Save/Cancel lifecycle; do not create a separate dialog or inline persistence action.
- Canonical name writes must patch only `tenants/{tenantId}.name` (plus `updatedAt`); never fetch and overwrite the tenant document.
- The `users/{uid}.tenantName` mirror must be written with the same logical save and local state changes only after all required remote writes succeed.
- Do not emit `profileUpdated` for validation errors, failed writes, or a partially completed remote save.
- Keep new tests under `tests/`, outside `qml/`, and run them with `qmltestrunner -platform offscreen` when the Felgo toolchain is available.

---

## File structure

| File | Responsibility |
| --- | --- |
| `qml/helper/ProfileSettingsMath.js` | Pure normalization, authorization, and minimal-patch calculation for a Profile settings draft. |
| `tests/tst_ProfileSettingsMath.qml` | Headless behavior tests for the pure helper. |
| `qml/model/AuthService.qml` | Executes the helper's change set, coordinates Firestore callbacks, and emits terminal save signals. |
| `qml/model/AuthStore.qml` | Applies successful profile fields exactly, including empty contact values and `tenantName`, then persists the local session. |
| `qml/model/FirebaseService.qml` | Sends true field-selective Firestore REST PATCH requests using `updateMask.fieldPaths`. |
| `qml/pages/ProfileSettingsDialog.qml` | Owner-only edit affordance, temporary draft reset, and one dialog-wide save request. |

## Task 1: Define and test the pure profile-settings change set

**Files:**

- Create: `qml/helper/ProfileSettingsMath.js`
- Create: `tests/tst_ProfileSettingsMath.qml`
- Modify: none (`.pragma library` helpers resolve by directory import and need no `qmldir` entry)

**Interfaces:**

- Consumes: plain `current` and `draft` objects with `phone`, `address`, `city`, `country`, `postalCode`, and `tenantName` strings; `role` string.
- Produces: `ProfileSettingsMath.buildChangeSet(current, draft, role)` returning `{ error, hasChanges, workspaceChanged, workspaceName, userPatch, tenantPatch, profileState }`.
- `error` is `""` for a valid draft, `"Workspace name is required"` for a whitespace-only changed workspace name, and `"Only the workspace owner can rename it"` for a non-owner rename attempt.
- `userPatch` contains only changed user fields, adding `tenantName` only when the workspace changes. `tenantPatch` is `{ name: normalizedName }` only when the workspace changes, otherwise `null`.

- [ ] **Step 1: Write the failing Qt Quick Test suite**

Create `tests/tst_ProfileSettingsMath.qml` with these imports and tests. These values make every normalization, permission, and no-op contract explicit.

```qml
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
```

- [ ] **Step 2: Run the new test to verify it fails**

Run:

```powershell
$env:QT_FORCE_STDERR_LOGGING='1'
$env:QT_LOGGING_TO_CONSOLE='1'
$env:PATH='C:\Felgo\Felgo\mingw_64\bin;' + $env:PATH
& 'C:\Felgo\Felgo\mingw_64\bin\qmltestrunner.exe' -platform offscreen -input tests/tst_ProfileSettingsMath.qml
```

Expected: FAIL because `qml/helper/ProfileSettingsMath.js` does not yet exist.

- [ ] **Step 3: Implement the pure helper**

Create `qml/helper/ProfileSettingsMath.js` as a `.pragma library`. Copy the current/draft values into new objects; do not mutate either caller object. Use the following implementation shape:

```javascript
.pragma library

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
```

- [ ] **Step 4: Run the helper test and verify it passes**

Run the same `qmltestrunner` command from Step 2.

Expected: all five `ProfileSettingsMath` tests PASS.

- [ ] **Step 5: Commit the helper and its tests**

```powershell
git add qml/helper/ProfileSettingsMath.js tests/tst_ProfileSettingsMath.qml
git commit -m "test: cover profile settings change set"
```

## Task 2: Coordinate persistence in AuthService

**Files:**

- Modify: `qml/model/AuthService.qml:31` (signals) and `qml/model/AuthService.qml:922-981` (replace the independent profile/tenant save functions)
- Modify: `qml/model/AuthStore.qml:153-161` (apply successful values without falsey-value loss and fix the malformed `tenantName` property expression)
- Modify: `qml/model/FirebaseService.qml:409-411` (make `patch()` use Firestore update masks instead of aliasing `put()`)
- Modify: `qml/model/AuthService.qml:3` (add `import "../helper/ProfileSettingsMath.js" as ProfileSettingsMath`)
- Test: `tests/tst_ProfileSettingsMath.qml`

**Interfaces:**

- Consumes: `AuthService.saveProfileSettings(phone, address, city, country, postalCode, workspaceName)` from the Profile dialog.
- Produces: existing `profileUpdated()` only on an all-success or no-change save; new `profileUpdateFailed(string reason)` exactly once after all required remote writes have settled unsuccessfully.
- Uses: `ProfileSettingsMath.buildChangeSet(current, draft, AuthStore.role)`, field-selective `FirebaseService.patch(path, data, callback)`, and `AuthStore.updateProfile(profileState)`.

- [ ] **Step 1: Extend the failing helper suite with explicit empty-field preservation**

Append this test to `tests/tst_ProfileSettingsMath.qml` before implementation, so the data used by the service can intentionally clear optional contact fields instead of silently keeping stale local values:

```qml
function test_empty_optional_contact_value_is_a_real_patch() {
    var draft = Object.assign({}, current, { address: "" })
    var r = ProfileSettingsMath.buildChangeSet(current, draft, "owner")
    compare(r.error, "")
    compare(r.userPatch.address, "")
    compare(r.profileState.address, "")
}
```

- [ ] **Step 2: Run the focused helper test to verify the behavior is not yet implemented**

Run:

```powershell
$env:QT_FORCE_STDERR_LOGGING='1'
$env:QT_LOGGING_TO_CONSOLE='1'
$env:PATH='C:\Felgo\Felgo\mingw_64\bin;' + $env:PATH
& 'C:\Felgo\Felgo\mingw_64\bin\qmltestrunner.exe' -platform offscreen -input tests/tst_ProfileSettingsMath.qml
```

Expected: FAIL if the implementation from Task 1 incorrectly drops empty optional values; otherwise PASS and proceed to the service change.

- [ ] **Step 3: Make FirebaseService.patch field-selective**

Replace the current `patch()` alias with an explicit document-only PATCH that
adds one Firestore `updateMask.fieldPaths` query parameter per supplied key.
Do not alter `put()`: stores that deliberately create/replace full documents
continue to use it.

```qml
function patch(path, data, callback) {
    var p = _splitPath(path)
    if (!p.normalizedPath || p.isCollection) {
        if (callback) callback(false)
        return
    }

    var keys = Object.keys(data || {})
    if (keys.length === 0) {
        if (callback) callback(true)
        return
    }

    var url = _docUrl(p.normalizedPath)
    for (var i = 0; i < keys.length; ++i)
        url += (i === 0 ? "?" : "&")
               + "updateMask.fieldPaths=" + encodeURIComponent(keys[i])

    _request("PATCH", url, _encodeDoc(data), function(ok) {
        if (!ok)
            console.warn("[Firestore] PATCH failed", path)
        if (callback) callback(ok)
    })
}
```

This changes the request from a potentially replacement-style PATCH to the
documented masked update required to preserve tenant metadata.

- [ ] **Step 4: Add terminal failure signaling and replace the racing save calls**

Near the existing `profileUpdated()` signal in `AuthService.qml`, add:

```qml
signal profileUpdateFailed(string reason)
```

Import the Task 1 helper, then replace `updateUserProfile(...)` and `updateTenantName(...)` with `saveProfileSettings(...)`. It must build this exact data shape and wait for every callback:

```qml
function saveProfileSettings(phone, address, city, country, postalCode, workspaceName) {
    if (busy) return
    if (!AuthStore.isAuthenticated || !AuthStore.uid) {
        profileUpdateFailed("Not authenticated")
        return
    }

    var current = {
        phone: AuthStore.phone, address: AuthStore.address, city: AuthStore.city,
        country: AuthStore.country, postalCode: AuthStore.postalCode,
        tenantName: AuthStore.tenantName
    }
    var draft = {
        phone: phone, address: address, city: city, country: country,
        postalCode: postalCode, tenantName: workspaceName
    }
    var changeSet = ProfileSettingsMath.buildChangeSet(current, draft, AuthStore.role)
    if (changeSet.error.length > 0) {
        profileUpdateFailed(changeSet.error)
        return
    }
    if (!changeSet.hasChanges) {
        profileUpdated()
        return
    }

    var pending = (Object.keys(changeSet.userPatch).length > 0 ? 1 : 0)
                  + (changeSet.tenantPatch !== null ? 1 : 0)
    var failureReason = ""
    busy = true
    function settled(ok, reason) {
        if (!ok && failureReason.length === 0)
            failureReason = reason
        pending -= 1
        if (pending > 0) return
        busy = false
        if (failureReason.length > 0) {
            profileUpdateFailed(failureReason)
            return
        }
        AuthStore.updateProfile(changeSet.profileState)
        profileUpdated()
    }

    if (Object.keys(changeSet.userPatch).length > 0) {
        var userPatch = Object.assign({}, changeSet.userPatch,
                                      { lastUpdatedAt: new Date().toISOString() })
        FirebaseService.patch("users/" + AuthStore.uid, userPatch, function(ok) {
            settled(ok, "Failed to update profile")
        })
    }
    if (changeSet.tenantPatch !== null) {
        var tenantPatch = Object.assign({}, changeSet.tenantPatch,
                                        { updatedAt: new Date().toISOString() })
        FirebaseService.patch("tenants/" + AuthStore.tenantId, tenantPatch, function(ok) {
            settled(ok, "Failed to update workspace name")
        })
    }
}
```

Before issuing a tenant patch, add an explicit `AuthStore.tenantId` guard that emits `profileUpdateFailed("Workspace context is unavailable")` and returns. Do not call `FirebaseService.get`, `FirebaseService.put`, or the removed `updateTenantName` path from this flow.

- [ ] **Step 5: Make AuthStore apply successful fields exactly**

Replace `AuthStore.updateProfile(profileData)`'s `||` assignments and malformed `profileData. tenantName` access with presence checks. This lets a successfully persisted optional contact value become `""` locally and applies the workspace mirror reliably:

```qml
function updateProfile(profileData) {
    if (profileData.phone !== undefined) phone = profileData.phone
    if (profileData.address !== undefined) address = profileData.address
    if (profileData.city !== undefined) city = profileData.city
    if (profileData.country !== undefined) country = profileData.country
    if (profileData.postalCode !== undefined) postalCode = profileData.postalCode
    if (profileData.tenantName !== undefined) tenantName = profileData.tenantName
    saveSession()
}
```

- [ ] **Step 6: Run tests and lint the service/store files**

Run:

```powershell
$env:QT_FORCE_STDERR_LOGGING='1'
$env:QT_LOGGING_TO_CONSOLE='1'
$env:PATH='C:\Felgo\Felgo\mingw_64\bin;' + $env:PATH
& 'C:\Felgo\Felgo\mingw_64\bin\qmltestrunner.exe' -platform offscreen -input tests/tst_ProfileSettingsMath.qml
& 'C:\Felgo\Felgo\mingw_64\bin\qmllint.exe' -I qml qml/model/AuthService.qml qml/model/AuthStore.qml qml/model/FirebaseService.qml
```

Expected: all six helper tests PASS and `qmllint` reports no errors. If the local machine lacks Felgo, record that limitation and run the static `rg` checks in Task 4 instead of claiming the suite passed.

- [ ] **Step 7: Commit the coordinated persistence change**

```powershell
git add qml/model/AuthService.qml qml/model/AuthStore.qml qml/model/FirebaseService.qml qml/helper/ProfileSettingsMath.js tests/tst_ProfileSettingsMath.qml
git commit -m "fix(profile): persist workspace name with profile save"
```

## Task 3: Improve the profile dialog's owner-only edit flow

**Files:**

- Modify: `qml/pages/ProfileSettingsDialog.qml:13-56` (dialog state, Save action, service signals)
- Modify: `qml/pages/ProfileSettingsDialog.qml:117-166` (workspace field and edit affordance)
- Test: `tests/tst_ProfileSettingsMath.qml` (regression suite from Tasks 1-2)

**Interfaces:**

- Consumes: `AuthService.saveProfileSettings(...)`, `profileUpdated()`, and `profileUpdateFailed(reason)`.
- Produces: existing `profileSaved()` only after `profileUpdated()`; does not close itself on `profileUpdateFailed`.
- State: `workspaceOriginalName` stores the name loaded on open; `workspaceEditMode` controls whether the owner can type.

- [ ] **Step 1: Add dialog state and reset it on every open**

Below `property string errorMessage`, add:

```qml
property string workspaceOriginalName: ""
property bool workspaceEditMode: false
```

In `onOpened`, assign the canonical name to both the field and original snapshot, then reset edit mode:

```qml
workspaceOriginalName = AuthStore.tenantName
workspaceName.text = workspaceOriginalName
workspaceEditMode = false
```

Use `AuthStore.tenantName` rather than `"(none)"` as the editable value. Leave the existing display fallback to the `TextField` placeholder when a workspace context is genuinely absent.

- [ ] **Step 2: Route the primary action through the coordinated service and surface failures**

Replace the two independent calls in `onPrimaryClicked` with this single request:

```qml
AuthService.saveProfileSettings(
    phoneField.text.trim(), addressField.text.trim(), cityField.text.trim(),
    countryField.text.trim(), postalField.text.trim(), workspaceName.text
)
```

Keep the existing success connection unchanged. Add a second handler in the same `Connections` object:

```qml
function onProfileUpdateFailed(reason) {
    root.errorMessage = reason
}
```

Clear `errorMessage` before a new Save request and on every `workspaceName.onTextEdited` event, so a corrected value does not continue to show the prior validation failure. Do not close the sheet in the failure handler.

- [ ] **Step 3: Implement the owner-only edit affordance**

Make the field interactive only when the current user is the owner and `workspaceEditMode` is true:

```qml
readonly property bool canRenameWorkspace: AuthStore.role === "owner"
enabled: root.canRenameWorkspace && root.workspaceEditMode
placeholderText: "Workspace name"
```

Use `root.canRenameWorkspace` for the edit button's `visible` state and for the disabled/read-only border styling. When locked, preserve the subtle account-card appearance. When active, use the normal card background, a one-pixel `Constants.brand` border, and a compact non-pill radius such as `dp(Constants.radiusSm)` so the editable state is visibly distinct.

On pencil tap, unlock and focus the field. On the active close icon, restore only the temporary workspace draft and relock; no network call is allowed:

```qml
onClicked: {
    if (root.workspaceEditMode) {
        workspaceName.text = root.workspaceOriginalName
        root.workspaceEditMode = false
        return
    }
    root.workspaceEditMode = true
    Qt.callLater(function() { workspaceName.forceActiveFocus() })
}
```

Use `name: root.workspaceEditMode ? "close" : "edit"` for the existing `Icon`. Remove the stale `onAccepted` TODO and do not submit on Enter; dialog Save remains the sole persistence action.

- [ ] **Step 4: Run focused automated checks and QML lint**

Run:

```powershell
$env:QT_FORCE_STDERR_LOGGING='1'
$env:QT_LOGGING_TO_CONSOLE='1'
$env:PATH='C:\Felgo\Felgo\mingw_64\bin;' + $env:PATH
& 'C:\Felgo\Felgo\mingw_64\bin\qmltestrunner.exe' -platform offscreen -input tests/tst_ProfileSettingsMath.qml
& 'C:\Felgo\Felgo\mingw_64\bin\qmllint.exe' -I qml qml/pages/ProfileSettingsDialog.qml qml/model/AuthService.qml qml/model/AuthStore.qml qml/model/FirebaseService.qml
```

Expected: all six helper tests PASS and `qmllint` reports no errors.

- [ ] **Step 5: Perform the device/desktop acceptance pass**

Use a test workspace and verify each case before committing:

1. Sign in as owner, open Profile → Edit profile. The pencil is visible, the workspace name is locked, and tapping it unlocks/focuses the field with the active visual treatment.
2. Change the name with leading/trailing spaces, press Save, then inspect Firestore: `tenants/{tenantId}.name` and `users/{uid}.tenantName` equal the trimmed name; unrelated tenant fields remain present.
3. Reopen Profile and confirm the saved name is displayed. Tap active edit close or dialog Cancel after changing it and confirm no Firestore write occurs.
4. Force a Firestore write failure or remove connectivity. Confirm the dialog remains open, input persists, the error is shown, and no success toast appears. Restore connectivity and retry successfully.
5. Sign in as admin, manager, and staff. Confirm the pencil is absent and the workspace field is read-only for each role.

- [ ] **Step 6: Commit the UI flow and verification-ready implementation**

```powershell
git add qml/pages/ProfileSettingsDialog.qml qml/model/AuthService.qml qml/model/AuthStore.qml qml/model/FirebaseService.qml qml/helper/ProfileSettingsMath.js tests/tst_ProfileSettingsMath.qml
git commit -m "feat(profile): improve owner workspace editing"
```

## Task 4: Final regression check and handoff

**Files:**

- Modify: none unless a verification failure requires a narrowly scoped corrective edit.
- Test: `tests/tst_ProfileSettingsMath.qml` plus all pre-existing `tests/tst_*.qml` suites that are runnable in the local Felgo environment.

**Interfaces:**

- Consumes: completed Tasks 1-3.
- Produces: evidence that the feature meets every acceptance criterion in `docs/superpowers/specs/2026-07-30-workspace-name-edit-design.md`.

- [ ] **Step 1: Run the full QML test discovery pass**

Run:

```powershell
$env:QT_FORCE_STDERR_LOGGING='1'
$env:QT_LOGGING_TO_CONSOLE='1'
$env:PATH='C:\Felgo\Felgo\mingw_64\bin;' + $env:PATH
& 'C:\Felgo\Felgo\mingw_64\bin\qmltestrunner.exe' -platform offscreen -input tests
```

Expected: existing runnable suites and `ProfileSettingsMath` pass. If the local toolchain is unavailable, state that QML runtime verification remains pending and do not convert the limitation into a passing claim.

- [ ] **Step 2: Check the completed source for the prohibited old write path**

Run:

```powershell
rg -n "function updateTenantName|function updateUserProfile|FirebaseService\.put\(\"tenants/\" \+ AuthStore\.tenantId" qml/pages/ProfileSettingsDialog.qml qml/model/AuthService.qml
git diff --check HEAD~1..HEAD
git status --short
```

Expected: no matches for `updateTenantName` or `updateUserProfile` in the profile flow, no `get`+whole-document tenant rewrite in the new save flow, no whitespace errors, and no unintended unstaged files.

- [ ] **Step 3: Commit any narrowly scoped verification correction, if one was necessary**

```powershell
git add qml/pages/ProfileSettingsDialog.qml qml/model/AuthService.qml qml/model/AuthStore.qml qml/model/FirebaseService.qml qml/helper/ProfileSettingsMath.js tests/tst_ProfileSettingsMath.qml
git commit -m "fix(profile): address workspace save verification"
```

Only run this commit when Step 1 or Step 2 required an actual correction. Otherwise, do not create an empty commit.
