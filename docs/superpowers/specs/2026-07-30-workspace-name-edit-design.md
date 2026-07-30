# Workspace Name Editing Design

**Date:** 2026-07-30  
**Status:** Approved design; awaiting specification review

## Goal

Make the Profile settings dialog reliably persist a workspace-name change to
Firestore. The name remains editable only by the workspace owner and stays
within the dialog's existing Save/Cancel lifecycle.

## Current failure

`ProfileSettingsDialog` starts `updateTenantName()` and `updateUserProfile()`
independently. The latter emits `profileUpdated`, which closes the dialog even
when the tenant write is still pending or has failed. The tenant update also
reconstructs a tenant document rather than applying a field-level update.

The current UI enables editing for every non-staff role, but Firestore rules
only permit the owner to update `tenants/{tenantId}`.

## Scope

- Owner-only workspace-name editing in Profile settings.
- Coordinated persistence for profile and workspace changes.
- Targeted Firestore updates that preserve unrelated tenant fields.
- Clear pending, success, and error states in the existing dialog.
- A modest visual improvement to the Edit control and edit state.

## Non-goals

- Allowing admins, managers, or staff to rename a workspace.
- Changing deployed Firestore permissions.
- Creating a separate workspace-settings dialog or independent Save/Cancel
  controls for the workspace name.
- Adding a compliance-gateway route for tenant metadata. This touches the
  tenant profile document, not one of the P0 working-tier mutation stores.

## UI behavior

### Visibility and edit state

- The Workspace row always displays the current workspace name.
- Only `AuthStore.role === "owner"` shows the edit control.
- The text field starts locked. Tapping the pencil unlocks it, applies a clear
  editable border/background, changes the button to a close/cancel-edit icon,
  and focuses the text field.
- Tapping the active edit control relocks the field and restores the original
  loaded workspace name; it does not save independently.
- The dialog Cancel action closes without saving. Opening the dialog again
  loads the latest `AuthStore` values, so unsaved edits are discarded.

### Dialog-level save

- Save remains the only persistence action.
- A Save attempt normalizes the workspace name by trimming whitespace.
- A changed workspace name must be non-empty. Invalid input remains visible
  with an inline message and no network request.
- If nothing changed, Save closes the dialog without issuing writes.
- While writes are pending, the existing busy state blocks duplicate Save
  attempts and displays the component's normal busy treatment.

## Persistence design

`AuthService` gains a single profile-settings update entry point used by the
dialog. It receives the contact fields and requested workspace name, computes
what changed against `AuthStore`, and coordinates the necessary writes.

| Change | Firestore write | Local update after success |
| --- | --- | --- |
| Contact fields changed | Patch only the changed `users/{uid}` contact fields | `AuthStore.updateProfile(contactData)` |
| Workspace name changed | Patch `tenants/{tenantId}.name` | `AuthStore.tenantName` and saved session |
| Workspace mirror changed | Patch `users/{uid}.tenantName` | Included in the profile update |

Both documents are updated with `FirebaseService.patch`, never rebuilt and
overwritten. This preserves `ownerId`, plan information, timestamps, and any
future tenant metadata. `AuthStore.updateProfile` must use the correctly
spelled `profileData.tenantName` property when applying the successful mirror
update.

The service creates a single logical completion condition:

1. Validate authenticated user, tenant context, owner role for a rename, and
   non-empty normalized workspace name.
2. Determine whether contact data and/or workspace name changed.
3. Issue only the required write(s). The user profile write includes the
   workspace-name mirror when the workspace changed.
4. Wait for all issued callbacks to report success.
5. Only then update `AuthStore`, emit `profileUpdated`, and allow the dialog
   to close and show its existing success toast.

## Failure handling

- A failed tenant patch or user-profile update is a failed save.
- The dialog remains open with the user's entered values intact.
- `AuthService` provides a concise error reason; the dialog displays it in its
  existing error-message area.
- No `profileUpdated` signal is emitted for a failed or partially completed
  save, so no success toast is shown.
- A partial remote write is possible because client REST writes are not a
  cross-document transaction. A retry writes the intended final values and is
  idempotent for the requested fields. This is preferable to masking a
  failure or overwriting the whole tenant document.

## Files and boundaries

- `qml/pages/ProfileSettingsDialog.qml`: field state, owner-only Edit control,
  validation display, and a single call to the coordinated service API.
- `qml/model/AuthService.qml`: validation and all completion/error
  orchestration for profile settings persistence.
- `qml/model/AuthStore.qml`: retain one canonical in-memory workspace name and
  session persistence; correct the existing `profileData. tenantName`
  expression to `profileData.tenantName` while integrating the service flow.
- `tests/`: add focused headless coverage for logic extracted or exposed in a
  testable form. Manual/device QA validates focus and interactive visual
  states in the Felgo runtime.

## Acceptance criteria

1. An owner can rename a workspace in Profile settings, press Save, and see
   `tenants/{tenantId}.name` persist the normalized value.
2. The owner profile's `tenantName` mirror and `AuthStore.tenantName` match
   the saved canonical name after success.
3. A non-owner cannot unlock or change the workspace-name field.
4. Save does not close or show success until all required writes succeed.
5. A write failure keeps the dialog open, preserves entered data, and shows an
   error without a success toast.
6. Updating a workspace name preserves unrelated fields on the tenant
   document.
7. Cancel or leaving edit mode does not write the workspace name.

## Verification

- Run relevant QML unit tests through `qmltestrunner -platform offscreen` when
  the Felgo toolchain is available.
- Run `qmllint` on changed QML files.
- Manual smoke test as owner: rename, save, reopen, and confirm the name
  survives the reload.
- Manual permission test as admin, manager, and staff: confirm the edit affordance is absent and the name is read-only.
- Simulate/observe a write failure: confirm no close or success toast and that retry succeeds.
