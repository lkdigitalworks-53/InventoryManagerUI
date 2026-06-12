# Staff Add / Invite / Show User ID — Design Spec

**Date:** 2026-06-12
**Stream:** D, part 1 of 2 (the self-contained UX/wiring half; Google-login Android hang is part 2, a separate spec)
**Bug addressed:** #6 — "staff adding is completely removed"; invite always fails ("how does anyone get a UID?"); no way to see your own User ID.
**Platform:** Felgo + Qt 6.8.3, QML (+ possibly a small C++ clipboard helper). Mobile target; desktop should also work.

---

## 1. Problem & Goal

Three interlocking issues, all confirmed in code — this is a **reachability + surfacing** problem,
not missing backend logic (`AuthService.provisionStaffCredentials()` and
`inviteMemberToCurrentTenant()` already exist and work):

1. **Add-staff form unreachable for owner/admin.** `StaffPage`'s FAB does
   `if (canInviteMembers) inviteMemberClicked() else addStaffClicked()`. So an owner/admin only
   ever reaches invite-by-UID; the working `AddStaffDialog` (create teammate + optional login
   credentials) is never reachable for them — hence "staff adding is completely removed."
2. **Invite-by-UID is a dead end.** `InviteMemberDialog` requires the target user's UID, but nothing
   in the app surfaces a UID, so the owner can never obtain one → invite always fails.
3. **No way to see your own User ID.** `AuthStore.uid` exists but is shown nowhere.

**Goal:** owner/admin can reach BOTH "Add staff member" and "Invite existing user"; any user can read
and copy their own User ID from Profile to be invited; the invite dialog explains where the UID comes
from. End-to-end: invitee copies their UID from Profile → sends it to owner → owner pastes into the
invite dialog → invite succeeds.

**Non-goals:** changing `AuthService` invite/provision logic; auto-discovering UIDs by email
(would need a backend lookup endpoint — out of scope); the Google-login hang (#7, separate spec).

---

## 2. The three fixes

### 2a. FAB choice sheet (StaffPage)

A new `StaffActionSheet` (BottomSheet) with two `ListCard` rows, matching the app's sheet idiom
(`ExportSheet`/`PhotoSourceSheet`):
- **"Add staff member"** — "Create a login for a new teammate" → emits `addStaffSelected()`.
- **"Invite existing user"** — "Add someone who already has an account" → emits `inviteSelected()`.

`StaffPage` FAB behavior:
- `canInviteMembers` (owner/admin) → emit a new `staffActionsRequested()` → Main opens the sheet.
- otherwise (can add staff but not invite) → `addStaffClicked()` directly (no point in a one-option
  sheet).

### 2b. User ID row in Profile (truncated + copy)

In `ProfilePage.qml`'s Account area, add a "User ID" row showing a **truncated** UID (e.g.
`aB3x…9Kp` — first/last few chars) with a copy affordance. Tapping copies the **full**
`AuthStore.uid` and shows a "User ID copied" toast. This is what makes invite-by-UID usable.

### 2c. Invite dialog hint

`InviteMemberDialog` keeps the UID field but gains a one-line helper:
"Ask them for their User ID — they'll find it on their Profile screen." Turns the former dead end
into a guided step.

---

## 3. Clipboard mechanism

QML has **no built-in clipboard-write** API. Resolution order (settled in the plan):
1. Prefer a Felgo-provided clipboard API if one exists (verify `NativeUtils`/Felgo clipboard in the
   install).
2. Otherwise add a minimal C++ helper `Clipboard` (`QGuiApplication::clipboard()->setText(...)`),
   registered as a context property exactly like `NativeFile`/`XlsxService`.

Either way QML calls a single `copy(text)` entry point, so the QML side is identical regardless of
backend. Plan verifies the chosen path works on Android (the real test).

---

## 4. Data flow

```
StaffPage FAB (owner/admin)  → staffActionsRequested()  → Main: staffActionSheet.open()
                                  ├─ addStaffSelected()   → addStaffDlg.open()      (existing)
                                  └─ inviteSelected()     → inviteMemberDlg.open()  (existing)
StaffPage FAB (non-manager)  → addStaffClicked()         → addStaffDlg.open()       (unchanged)

ProfilePage "User ID" row    → tap copy → Clipboard.copy(AuthStore.uid) → Toast "User ID copied"
InviteMemberDialog           → + hint: "Ask them for their User ID (Profile screen)"
```

The sheet is a thin router; both branches reuse dialogs already hosted in `Main.qml`. New signal
paths: `staffActionsRequested` (StaffPage→Main) and the sheet's `addStaffSelected`/`inviteSelected`.
No `AuthService` change.

---

## 5. Files touched

**Created:**
- `qml/pages/StaffActionSheet.qml` — two-option choice sheet (BottomSheet).
- *(conditional)* `src/Clipboard.h`, `src/Clipboard.cpp` — only if Felgo lacks clipboard-write.

**Modified:**
- `qml/pages/StaffPage.qml` — FAB emits `staffActionsRequested()` when `canInviteMembers`, else
  `addStaffClicked()`; declare the new signal.
- `qml/Main.qml` — host `StaffActionSheet` at App root; wire `onStaffActionsRequested` →
  `staffActionSheet.open()`, and the sheet's two signals → `addStaffDlg`/`inviteMemberDlg`; register
  `Clipboard` if the C++ helper is used.
- `qml/pages/ProfilePage.qml` — add the "User ID" row (truncated UID + copy + toast).
- `qml/pages/InviteMemberDialog.qml` — add the UID-source hint line.
- *(conditional)* `main.cpp`, `CMakeLists.txt` — register the `Clipboard` helper if needed.

**Verified, not modified:** `AuthService` (invite/provision already correct); `AuthStore.uid`
(already present).

---

## 6. Verification

1. **qmllint** on all changed QML — no new hard `Error:` lines.
2. **Desktop run:** as owner, FAB → choice sheet → "Add staff member" opens AddStaffDialog;
   "Invite existing user" opens InviteMemberDialog. Profile shows a truncated UID; tap copy → "User
   ID copied" toast AND the clipboard actually holds the full UID (paste elsewhere to confirm).
   Invite dialog shows the hint.
3. **Android device:** same flow on device — choice sheet reachable for owner; Profile UID copy works
   (the real test of the clipboard backend on Android); both dialogs open; a full invite round-trip
   (copy UID on one account, paste/invite from an owner account) succeeds.

---

## 7. Build sequence (preview — full plan via writing-plans)

1. Resolve clipboard backend (Felgo API vs `Clipboard` C++ helper); add + register if C++.
2. `StaffActionSheet.qml` (two ListCard options + two signals).
3. `StaffPage` FAB → `staffActionsRequested()` for owner/admin; declare signal.
4. `Main.qml` — host the sheet, wire all signals.
5. `ProfilePage` "User ID" row (truncated + copy + toast).
6. `InviteMemberDialog` hint line.
7. Desktop pass, then Android device pass (§6).
