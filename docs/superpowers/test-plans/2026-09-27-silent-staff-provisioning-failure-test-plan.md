# Test plan — Team Members shows only Owner after adding a new staff member with a role

**Branch:** `fix/2026-09-27-silent-staff-provisioning-failure` off `main`.

**Reported by Taher:** "in the team members page after adding new member as staff or any roles, if we
press the team members view button, newly added member is not visible. Even after refresh nothing shows
up. Only owner is visible."

**What it does:** `AuthService.provisionStaffCredentials` (fired asynchronously from `Main.qml`'s
`onStaffAdded`, always AFTER `AddStaffDialog` has already closed) now emits `memberOperationFailed`
instead of `authFailed` on every one of its failure branches, and `Main.qml`'s `onMemberOperationFailed`
now falls back to the existing `successMessage` → `Toast` bridge whenever neither `inviteMemberDlg` nor
`memberMgmtDlg` is open to show the error inline.

**Root cause:** `authFailed` is only ever surfaced by `Main.qml`'s `AuthService` `Connections` block into
`inviteMemberDlg.errorMessage` or `forgotPasswordDlg`'s equivalent. `provisionStaffCredentials` is never
called while either of those is open — it runs in the background after `AddStaffDialog` has already
closed (`_pendingStaffLogin` is a deferred continuation waiting on `StaffStore.onStaffAdded`). So every
failure inside it — auth/permission/tenant guards, invalid email/password, and the real network failure
branch — was calling a signal nothing on screen was listening for. The staff roster entry
(`StaffStore.addStaff`) had already saved successfully by that point, so the add *looked* like it worked;
the person just never got a `tenants/{tenantId}/members/{uid}` document, which is what the Team Members
dialog (`AuthService.tenantMembers`, via `loadTenantMembers()`) actually reads. Refreshing that dialog
correctly found nothing new, because there was nothing new to find.

**Traced and ruled out before landing on this root cause** (see session notes / commit body for the full
trace): `FirebaseService.get`'s collection pagination and doc decoding, `MemberManagementDialog`'s role
filter (defaults to "all", doesn't hide anything), `firestore.rules`' `members` `allow read` rule (doesn't
filter per-document — a genuine member can list the whole subcollection, not just their own doc), the
server-side `canAssignRole` gate (owner can assign admin/manager/staff, all three from the bug report), and
`deriveContext`'s env/tenant scoping (matches the client's `env` param on every gateway call). Also ruled
out as *the* bug (real, but pre-existing and intentional, not new): `ProfilePage`'s "Team members" row
opens the `StaffPage` overlay, not `MemberManagementDialog` directly — confirmed intentional by `AGENTS.md`
("Staff lives as a full-screen overlay reached from the Dashboard 'Invite staff' tile and the Profile
page's 'Team members' row"); `StaffPage`'s own header button is what opens the real Team Members dialog,
and it already calls `AuthService.loadTenantMembers()` before opening.

**Not covered by this plan / out of scope (flagged, not silently dropped):**
- *Why* the underlying `Gateway.provisionMember` call fails for Taher specifically (bad/duplicate test
  email, a password Firebase's own policy rejects, a Cloud Function cold-start issue, etc.) — this fix
  makes that reason visible for the first time; the actual reason is a follow-up once it's seen.
  `KNOWN-ISSUES.md` M-1 (`InviteMemberDialog` gives no busy-state/success/close feedback at all) is the
  same general class of gap but a separate, already-tracked, lower-severity item — not touched here to
  keep this branch's diff to the one confirmed root cause.
- The actual XHR request/response handling inside `Gateway.provisionMember` (success and conflict
  branches) — no mock-HTTP layer exists anywhere in this codebase (see `tst_Gateway.qml`'s own scope
  note); only the synchronous no-XHR guards (`provisioningAvailable === false`, empty `idToken`) are
  exercised here, same documented gap.
- No Firestore rules change, no Cloud Function change — this is a client-side signal-routing fix only.

---

## 1. Unit / functional test coverage

`tests/tst_ProvisionStaffCredentialsFailureRouting.qml` (new file, 9 cases) — real (non-mocked) calls
against the actual `AuthService`/`AuthStore`/`Gateway` singletons, `SignalSpy`-verified:
- Each of the 5 synchronous guards (not authenticated, missing permission, missing tenant, invalid email,
  empty email, short password) emits `memberOperationFailed` and NOT `authFailed`, with the exact expected
  message.
- Manager and admin roles (not just staff) reach the same guard-passing path without `authFailed` firing —
  proves the fix isn't accidentally staff-role-specific ("staff or any roles" in the bug report).
- The actual previously-silent line: `Gateway.provisionMember`'s own synchronous `not-signed-in` guard
  (reached via `provisioningAvailable = true` + empty `idToken`, so no real XHR fires) now emits
  `memberOperationFailed("Failed to create staff credentials: you're not signed in.")` instead of
  `authFailed`.
- Regression guard: the pre-Blaze `"provisioning-unavailable"` branch is unchanged — still a soft
  `memberOperationSucceeded`, not a failure. Proves the fix only touched the genuine-failure branch below
  it, not this adjacent one.

`tests/tst_MemberOperationFailedFallback.qml` (new file, 6 cases) — pure-logic model of `Main.qml`'s
`onMemberOperationFailed` handler (mirrors it line-for-line; `Main.qml` itself needs the full Felgo `App`
context and can't load under `qmltestrunner`, same reason `tst_AddStaffSyncClose.qml` models
`AddStaffDialog`'s fix in pure JS instead of the real page):
- Neither dialog open (the actual bug scenario) → falls back to the toast bridge. **This is the case that
  was completely silent before the fix.**
- `inviteMemberDlg` open → shows inline, no duplicate toast (existing, still-correct behavior unchanged).
- `memberMgmtDlg` open → shows inline via `memberErrorMessage`, no duplicate toast (existing, still-correct
  behavior unchanged).
- Both open (edge case, shouldn't normally occur — mutually exclusive sheets) → invite dialog's inline
  error wins, still no duplicate toast.
- Empty/undefined reason → falls back to a generic message, not a blank toast.
- Two failures in sequence → both toast independently, neither is swallowed.

## 2. End-to-end test coverage

None added. Exercising the real `AddStaffDialog` → `Main.qml` → `AuthService` → `Gateway` → Cloud
Function → Firestore chain end-to-end needs a live device/emulator build (Felgo `App` context + a real or
emulated Cloud Function) — out of scope for this sandbox and this session, same as every other
Main.qml/dialog-level fix in this repo's history (see `2026-09-21-staff-delete-ui-test-plan.md`,
`2026-09-16-new-order-double-submit-test-plan.md`). Covered instead by the On-Device Test Plan below.

## 3. Regression test coverage

Tests that exist because of this defect, so a wrong fix would fail them:
- `test_provisioningUnavailable_staysASoftSuccess`: proves the pre-Blaze soft-success branch (a real,
  intentional, different code path one line above the fixed one) still works exactly as before — a
  careless fix that changed the wrong `if` branch would fail this.
- `test_managerRole_reachesGatewayGuard_not_authFailed` / `test_adminRole_reachesGatewayGuard_not_authFailed`:
  proves the fix applies uniformly across all three assignable roles, not just `"staff"` — a fix that
  special-cased on `appRole` would fail one of these.
- `test_inviteDialogOpen_showsInline_noToast` / `test_memberMgmtDialogOpen_showsInline_noToast`: proves the
  fallback doesn't fire (and doesn't double-toast) for the two flows that already worked correctly before
  this session — a fix that unconditionally toasted on every failure would fail these.

## 4. Firestore rules test coverage

Not applicable — no rules change. `firestore.rules`' `members/{uid}` block was read closely while tracing
this bug (see Root cause above) but is untouched.

## What was genuinely run

**QML, `tests/`:** not run in this sandbox — no Qt/`qmltestrunner` toolchain available (standing
instruction; CI's `qml-tests` job is the verdict). Both new files are written to this repo's established
conventions (`TestCase`/`SignalSpy` usage matching `tst_Gateway.qml` and `tst_AuthStore.qml`; the
pure-logic-model technique matching `tst_AddStaffSyncClose.qml`) and manually reviewed for correctness,
but have **not** been confirmed by an actual `qmltestrunner` run. Brace-balance-checked only (mechanical
syntax sanity check, not a substitute for a real test run).

**Functions:** no server-side code touched this session — `functions/` suite unaffected, not re-run.

---

## On-Device Test Plan

**Prerequisite status:** the automated coverage above proves the *signal routing* is correct in isolation.
This section is the only coverage for the actual dialogs, toast rendering, and the real
add-staff-with-login → Team Members flow end-to-end — and the only way to find *why* the underlying
provisioning call was actually failing for Taher, now that the reason will finally be visible.

### Happy Path

1. Sign in as owner. Add a new staff member via **Add Staff**, tick "Create app login", pick role
   **staff**, fill a valid email + password (≥6 chars), save. If provisioning succeeds: a success toast
   appears, and opening **Team Members** (via `StaffPage`'s header button, or Profile → Team members →
   Staff → the same button) shows the new member with role **staff**, alongside Owner.
2. Repeat with role **manager**, then **admin** — each shows up with the correct role.
3. Confirm the roster entry on the **Staff** page also shows the same person (unaffected by this fix,
   should already have worked).

### Negative Cases

4. **The actual repro:** add a staff member with a role and "Create app login" ticked, using whatever
   inputs Taher originally used when this bug was reported (likely candidates: an email already used by
   an earlier test attempt, or a password that satisfies this app's 6-char client check but not Firebase
   Auth's own policy). Confirm a toast now appears with a specific reason (e.g. "Failed to create staff
   credentials: no account exists for that user." or similar from `_provisionErrorMessage`) instead of
   silence. **This toast's exact wording is the actual diagnostic this fix was for** — whatever it says is
   the real next bug to chase, if any.
5. Sign in as **manager** or **staff** (not owner/admin): "Create app login" should not even be reachable
   per existing `canInviteMembers` gating — confirm no regression there (unrelated to this fix, but
   adjacent code path).
6. Turn off network / airplane mode, then add a staff member with login: confirm the roster entry still
   saves (offline-queued) and the credential-provisioning failure (or deferred state) is surfaced sensibly,
   not silently.
7. Re-attempt adding a staff member with an email that already has app login from a PRIOR successful add:
   confirm the toast (if it fails) or success (if `findOrCreateAuthUser`'s existing-user path succeeds)
   makes sense — this exercises the exact "tested the same email repeatedly" scenario suspected during
   diagnosis.

### Edge Cases

8. Add a staff member WITHOUT ticking "Create app login" at all: no provisioning call happens, no toast
   related to this fix should appear, roster entry saves normally (unaffected code path).
9. Trigger a failure while the **Team Members** dialog happens to already be open in the background (e.g.
   add staff from a second window/tab if the platform allows, or add staff, then quickly open Team
   Members before the async provisioning call resolves): confirm the error shows inline in that dialog
   (via `memberErrorMessage`) and does NOT also pop a redundant toast.
10. Trigger a failure while `InviteMemberDialog` happens to be open (unlikely in practice — different
    entry points — but confirm no cross-talk): its own inline error handling should be completely
    unaffected by this change.
11. Rapid-fire adding several staff members with login in quick succession, at least one failing: confirm
    each failure gets its own toast (not just the first or the last), matching
    `test_multipleFailuresInSequence_eachToasts`.

### Affected Areas

| File | Automated coverage | Where to look on-device |
|---|---|---|
| `qml/model/AuthService.qml` `provisionStaffCredentials` | `tst_ProvisionStaffCredentialsFailureRouting.qml` | cases 1, 2, 4, 7 |
| `qml/Main.qml` `onMemberOperationFailed` | `tst_MemberOperationFailedFallback.qml` (model only, Felgo `App` root) | cases 4, 9, 10, 11 |
| `qml/pages/AddStaffDialog.qml` (`createLogin`, `appRole`) | none (Felgo) — unchanged this session | cases 1, 2, 8 |
| `qml/pages/MemberManagementDialog.qml` (Team Members list) | none (Felgo) — unchanged this session | cases 1, 2, 9 |

### Regression Tests (manual counterpart)

12. Adding a staff member WITHOUT login still works exactly as before (case 8 above).
13. Inviting an existing user via **Invite team member** (`InviteMemberDialog`, requires their real UID)
    still works and still shows its own inline error on failure — completely untouched by this fix.
14. Updating an existing member's role, or removing a member, from the Team Members dialog still shows
    its error inline in that dialog (not a toast) — `memberErrorMessage`'s existing binding is unchanged.
15. Every other `successMessage`/`Toast` consumer (password reset, profile update, export, etc.) still
    toasts exactly as before — this fix only added one more `else if` branch, didn't touch the timer or
    the bridge itself.
