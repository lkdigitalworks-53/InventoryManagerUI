# Test plan — staff delete has no row-level button (DELETE-FEATURE-ROADMAP item 2)

**Branch:** `feat/2026-09-21-staff-delete-ui` off `main`.

**What it does:** a trash-icon button now sits in every staff row (owner/admin only), wired to the
already-existing confirm-dialog and delete plumbing. Alongside it: a success toast, a delete-specific
conflict-toast wording, a guard preventing a caller from deleting their own staff record, and a narrow
server-side role check so staff delete can no longer be forced through the gateway by a non-owner/admin.

**Source:** `docs/superpowers/DELETE-FEATURE-ROADMAP.md` item 2 (MEDIUM). Design:
`docs/superpowers/specs/2026-09-21-staff-delete-ui-design.md`.

**Root cause:** identical shape to what products and orders had before `feature/product-order-delete-ui`:
`StaffPage.deleteStaffClicked`, the `Main.qml` confirm dialog, `Logic.deleteStaff`, `DataModel.onDeleteStaff`
(owner/admin guard) and `StaffStore.deleteStaff` were all already wired — no visible element in the row ever
emitted the signal.

**Not covered by this plan / out of scope (decided with Taher, not silently dropped):** no general server-side
authorization matrix (every entity/action other than staff/delete and `provisionMember` still trusts the
client's own role check — new `KNOWN-ISSUES.md` entry); `AuthService.cleanupStaffAuthDocs` stays fire-and-forget
(already tracked under the P5 compliance work); no server-side self-delete guard (the client guard is sufficient
today, no other client exists).

---

## 1. Unit / functional test coverage

`tests/tst_DataModel_deleteGuards.qml` (existing file, extended with 4 cases): the pre-existing owner/admin
guard for `onDeleteStaff` (no prior coverage), and the new self-delete guard — a matching `appUid`, a different
staff record than the caller's own, and a caller with no linked staff record at all (guards the empty-string
edge: `AuthStore.currentStaffId === ""` must not match a staff record whose own `appUid` is also `""`).

`tests/tst_StaffStore_delete.qml` (new file, 10 cases): `deleteStaff` (removes locally, queues a `delete`
mutation, a no-op on an unknown id, removes only the matching id) and `_onMutationConflicted` (ignores a
non-staff entity, update-conflict wording and replacement, delete-conflict wording and restoration, pushes an
unknown record, and a rejected delete with no `current` still removes a locally-present stale copy).

`functions/test/index.handlers.test.js` (existing file, extended with 5 cases): the new role check refused for
a `manager` role, succeeds for `admin` and for `owner`, and two negative-scope cases proving the check does not
leak onto a staff *update* or an *order* delete by the same non-owner/admin role.

## 2. End-to-end test coverage

None added. The button's actual render, tap and event-bubbling behaviour needs a real `StaffPage` instance,
which pulls in `GlassHeader` → `Constants.qml` → `import Felgo` — not available in the `QML Tests` CI job (plain
Qt only). Covered instead by `test/felgo-dependent/tst_StaffPage_deleteButton.qml` (5 cases, on-device only) and
the On-Device section below.

## 3. Regression test coverage

Tests that exist because of the defect or its adjacent findings, so a wrong fix would fail them:

- `test_deleteStaff_succeeds_for_admin_role` / `test_deleteStaff_refused_for_role_without_permission`: the
  pre-existing owner/admin guard must survive untouched.
- `test_deleteStaff_succeeds_for_a_different_staff_record_than_the_callers_own` and
  `test_deleteStaff_self_guard_does_not_fire_for_a_caller_with_no_linked_staff_record`: the new self-delete
  guard must not block an ordinary delete of someone else's record.
- The two negative-scope functions tests: the server-side role check must not widen beyond staff/delete.
- `test_update_conflict_replaces_the_record_and_shows_the_update_worded_toast`: the pre-existing (non-delete)
  conflict wording must still fire for an ordinary update conflict, unchanged by the new `action` param.

## 4. Firestore rules test coverage

Not applicable: no rules change. (`firestore.rules`'s existing `members/{uid}` delete rules — the ones this
session's trace read to find the self-delete lockout risk — are untouched.)

## What was genuinely run

- **QML, `tests/`:** no Qt toolchain in the sandbox (standing instruction) — CI is the verdict. Result: pending, filled in once CI runs on the pushed branch.
- **Functions, real execution in this session:** `npm test` in `functions/` (dependencies installed from the
  network-allowlisted npm registry — no emulator, no network mocking needed, these are real Node tests against
  the actual exported handler). **200/200 passing**, up from a 195/195 baseline confirmed before any edit.
  Confirmed genuinely TDD, not just green-only: reverting `functions/index.js`'s fix and re-running produced
  **199 pass, 1 fail** — exactly the new refused-role test, and only that one — then restoring the fix returned
  it to 200/200.
- **Not runnable anywhere automated:** `StaffPage.qml`'s rendered button (Felgo dependency).

---

## On-Device Test Plan

**Prerequisite status:** the automated coverage above covers every guard and the conflict wording. This section
is the only coverage for the actual button render, tap behaviour, and the toasts as seen in a real app.

### Happy Path

1. Sign in as owner or admin, open Staff. Every row shows a trash icon.
2. Tap it, confirm in the dialog: the row disappears, a "Staff member removed" toast appears, and (if login
   provisioning is live and the member had one) their login access is revoked per the dialog's own copy.
3. Delete a different staff member than yourself: succeeds normally.

### Negative Cases

4. Sign in as manager or staff: no trash icon on any row (`canManageStaff` false).
5. As owner/admin, try to delete your own staff record (requires provisioning live and your own account linked
   to a staff row): rejected with "You can't delete your own staff record — ask another owner or admin"; the
   record is untouched.
6. Force the server to reject with `role-not-allowed` (e.g. call the gateway directly with a manager token,
   or verify via a temporarily lowered client role while the account's real Firestore role stays manager):
   confirms the client can no longer bypass the check by skipping its own role gate.
7. Delete the same staff record from two devices at once: the second device's delete is rejected as a conflict
   and shows "Couldn't delete — this staff record was updated elsewhere. It's been restored with the latest
   version.", and the record reappears.

### Edge Cases

8. Delete a staff record that has open orders referencing it (`staffId` on an order): the order keeps showing
   the staff member's name in history (already handled elsewhere — Sales Analysis and exports show "(removed)"
   / blank, confirm no crash or blank row here specifically).
9. Delete a staff member with `status: "on leave"` or `"inactive"`: the button is visible and works regardless
   of status (deliberate, matches orders/products — no per-row status gating).
10. Tap the delete button on a row and confirm it does not also open the staff detail dialog (`viewStaffClicked`
    must not fire).
11. Narrow width / large font: the trash icon doesn't overlap the status pill or elide the name.
12. Delete the last remaining staff member: the empty state ("No team members yet") appears correctly.

### Affected Areas

| File | Automated coverage | Where to look on-device |
|---|---|---|
| `qml/pages/StaffPage.qml` (button) | none (Felgo) | cases 1, 4, 9, 10, 11, 12 |
| `qml/model/DataModel.qml` `onDeleteStaff` | `tst_DataModel_deleteGuards.qml` | cases 4, 5 |
| `qml/model/StaffStore.qml` `deleteStaff`, `_onMutationConflicted` | `tst_StaffStore_delete.qml` | cases 2, 7 |
| `qml/Main.qml` `onStaffDeleted` toast | none (Felgo `App` root) | case 2 |
| `functions/index.js` role check | `index.handlers.test.js` (run for real, 200/200) | case 6 |

### Regression Tests (manual counterpart)

13. Deleting a product or an order still works exactly as before (unrelated to this branch's changes).
14. An ordinary staff *update* conflict (not a delete) still shows "This staff record was updated elsewhere —
    your change didn't save. Refreshed to the latest version." — the wording this session's `action` param must
    not have altered.
15. Staff creation and editing (`AddStaffDialog`, `StaffDetailDialog`) are unaffected.
