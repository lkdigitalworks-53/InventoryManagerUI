# Staff Add / Invite / Show User ID Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let owner/admin reach BOTH "Add staff member" and "Invite existing user" from the Staff FAB, and let any user copy their own User ID from Profile so invite-by-UID actually works.

**Architecture:** A new `StaffActionSheet` (BottomSheet) is a thin router presenting the two existing dialogs (`AddStaffDialog`, `InviteMemberDialog`) — no `AuthService` change. A small C++ `Clipboard` helper (Felgo has no clipboard API) backs a tap-to-copy User ID row added under the name in `ProfilePage`. The invite dialog gains a hint pointing to where the UID is found.

**Tech Stack:** Felgo + Qt 6.8.3, QML + C++. `Clipboard` wraps `QGuiApplication::clipboard()` (Qt6::Gui is already linked). Context-property registration mirrors `NativeFile`/`XlsxService`.

**Spec:** `docs/superpowers/specs/2026-06-12-staff-add-invite-uid-design.md`

---

## Verification model (read first)

No QML unit-test harness. "Tests" are concrete runnable checks:

1. **`qmllint`** on changed QML — no new hard `Error:` lines. Binary:
   `"/c/Felgo/Felgo/mingw_64/bin/qmllint.exe" -I qml <file>` (filter `grep -E '^Error:'`).
   Pre-existing Felgo import / unqualified-access notes are acceptable.
2. **C++ build** — `cmake --build --preset felgo-mingw-debug` compiles + links with `Clipboard`.
3. **Desktop run:** FAB (as owner) → choice sheet → both options open the right dialogs; Profile shows
   a truncated UID; tap → "User ID copied" toast AND the clipboard holds the full UID (paste to confirm);
   invite dialog shows the hint.
4. **Android device (Task 7):** same flow; UID copy works on device (real test of the clipboard backend).

---

## File Structure

**Created:**
- `src/Clipboard.h`, `src/Clipboard.cpp` — `Q_INVOKABLE void copy(const QString&)` over QClipboard.
- `qml/pages/StaffActionSheet.qml` — two-option choice sheet (BottomSheet).

**Modified:**
- `CMakeLists.txt` — add the two `Clipboard` sources to `qt_add_executable`.
- `main.cpp` — register `Clipboard` context property.
- `qml/pages/StaffPage.qml` — FAB emits `staffActionsRequested()` for owner/admin; declare the signal.
- `qml/Main.qml` — host `StaffActionSheet`; wire `onStaffActionsRequested`; sheet signals → dialogs.
- `qml/pages/ProfilePage.qml` — add the copyable "User ID" row under the name.
- `qml/pages/InviteMemberDialog.qml` — add the UID-source hint.

**Verified, not modified:** `AuthService` (invite/provision already work); `AuthStore.uid` (present);
`AddStaffDialog`/`InviteMemberDialog` (already wired in Main.qml).

---

### Task 1: `Clipboard` C++ helper + register

**Files:**
- Create: `src/Clipboard.h`, `src/Clipboard.cpp`
- Modify: `CMakeLists.txt`, `main.cpp`

- [ ] **Step 1: Create `src/Clipboard.h`**

```cpp
#pragma once

#include <QObject>
#include <QString>

// Clipboard — QML-invokable clipboard write. Felgo/QML exposes no clipboard
// API, so this thin wrapper over QGuiApplication::clipboard() backs the
// copy-User-ID action. Registered as the "Clipboard" context property.
class Clipboard final : public QObject
{
    Q_OBJECT
    Q_DISABLE_COPY_MOVE(Clipboard)

public:
    explicit Clipboard(QObject *parent = nullptr);
    ~Clipboard() override = default;

    // Put `text` on the system clipboard. No-op if no clipboard is available.
    Q_INVOKABLE void copy(const QString &text);
};
```

- [ ] **Step 2: Create `src/Clipboard.cpp`**

```cpp
#include "Clipboard.h"

#include <QClipboard>
#include <QGuiApplication>

Clipboard::Clipboard(QObject *parent)
    : QObject(parent)
{
}

void Clipboard::copy(const QString &text)
{
    if (QClipboard *cb = QGuiApplication::clipboard())
        cb->setText(text);
}
```

- [ ] **Step 3: Add the sources to CMakeLists.txt**

In `CMakeLists.txt`, the `qt_add_executable(appBusinessManagement ...)` block lists src files
explicitly and currently ends the src list with:
```
    src/NativeFile.h
    src/NativeFile.cpp
```
Immediately AFTER `src/NativeFile.cpp`, add:
```
    src/Clipboard.h
    src/Clipboard.cpp
```

- [ ] **Step 4: Register the context property in main.cpp**

(a) After `#include "src/NativeFile.h"`, add:
```cpp
#include "src/Clipboard.h"
```

(b) After the NativeFile registration block (the two lines ending with
`setContextProperty(QStringLiteral("NativeFile"), nativeFile);`), add:
```cpp

    // Register the clipboard helper (copy User ID, etc.).
    auto *clipboard = new Clipboard(&app);
    engine.rootContext()->setContextProperty(QStringLiteral("Clipboard"), clipboard);
```

- [ ] **Step 5: Build**

Run: `"C:/Felgo/Tools/CMake_64/bin/cmake.exe" --build --preset felgo-mingw-debug 2>&1 | tail -8`
Expected: compiles + links; `Clipboard.cpp.obj` built, executable linked, no errors.

- [ ] **Step 6: Commit**

```bash
git add src/Clipboard.h src/Clipboard.cpp CMakeLists.txt main.cpp
git commit -m "feat(staff): add Clipboard C++ helper for copy-to-clipboard"
```

---

### Task 2: `StaffActionSheet` choice sheet

**Files:**
- Create: `qml/pages/StaffActionSheet.qml`

- [ ] **Step 1: Create the sheet**

Create `qml/pages/StaffActionSheet.qml`:

```qml
import QtQuick
import QtQuick.Controls as QQC
import QtQuick.Layouts

import "../components"
import "../helper"

// Staff FAB choice sheet — owner/admin pick between creating a new teammate
// (with login credentials) and inviting someone who already has an account.
// Thin router: emits a signal per choice; Main.qml opens the matching dialog.
BottomSheet {
    id: root

    sheetTitle: qsTr("Add to team")
    primaryAction: ""
    secondaryAction: qsTr("Cancel")

    signal addStaffSelected()
    signal inviteSelected()

    ListCard {
        Layout.fillWidth: true
        title: qsTr("Add staff member")
        subtitle: qsTr("Create a login for a new teammate")
        onClicked: { root.addStaffSelected(); root.close() }

        leading: Rectangle {
            width: dp(38); height: dp(38); radius: dp(12)
            color: Qt.rgba(0.39, 0.40, 0.95, 0.10)
            Icon { anchors.centerIn: parent; name: "staff"; size: sp(18); color: Constants.textPrimary }
        }

        Icon {
            name: "chevron"
            color: Constants.textMuted
            size: sp(16)
            Layout.alignment: Qt.AlignVCenter | Qt.AlignRight
        }
    }

    ListCard {
        Layout.fillWidth: true
        title: qsTr("Invite existing user")
        subtitle: qsTr("Add someone who already has an account")
        onClicked: { root.inviteSelected(); root.close() }

        leading: Rectangle {
            width: dp(38); height: dp(38); radius: dp(12)
            color: Qt.rgba(0.39, 0.40, 0.95, 0.10)
            Icon { anchors.centerIn: parent; name: "add"; size: sp(18); color: Constants.textPrimary }
        }

        Icon {
            name: "chevron"
            color: Constants.textMuted
            size: sp(16)
            Layout.alignment: Qt.AlignVCenter | Qt.AlignRight
        }
    }
}
```

(Mirrors `ExportSheet.qml`: a `BottomSheet` whose body is a ColumnLayout, with `ListCard` rows that
emit a signal + `close()`. `ListCard` is a same-dir-resolved component via `import "../components"`.)

- [ ] **Step 2: qmllint**

Run: `"/c/Felgo/Felgo/mingw_64/bin/qmllint.exe" -I qml qml/pages/StaffActionSheet.qml 2>&1 | grep -E '^Error:' || echo CLEAN`
Expected: CLEAN.

- [ ] **Step 3: Commit**

```bash
git add qml/pages/StaffActionSheet.qml
git commit -m "feat(staff): add StaffActionSheet (add-staff vs invite choice)"
```

---

### Task 3: StaffPage FAB → choice sheet for owner/admin

**Files:**
- Modify: `qml/pages/StaffPage.qml`

- [ ] **Step 1: Declare the new signal**

In `qml/pages/StaffPage.qml`, the signals block is:
```qml
    signal addStaffClicked()
    signal inviteMemberClicked()
    signal manageMembersClicked()
```
Add one line after `manageMembersClicked()`:
```qml
    signal staffActionsRequested()
```

- [ ] **Step 2: Repoint the FAB**

The `FloatingActionButton`'s `onClicked` currently reads:
```qml
        onClicked: {
            if (root.canInviteMembers)
                root.inviteMemberClicked()
            else
                root.addStaffClicked()
        }
```
Change it to:
```qml
        onClicked: {
            // Owner/admin can both create staff and invite existing users →
            // offer the choice sheet. Others can only add staff → go direct.
            if (root.canInviteMembers)
                root.staffActionsRequested()
            else
                root.addStaffClicked()
        }
```
(Leave the `inviteMemberClicked` signal declared — it stays wired in Main.qml and is harmless; the
choice sheet now drives the invite path.)

- [ ] **Step 3: qmllint**

Run: `"/c/Felgo/Felgo/mingw_64/bin/qmllint.exe" -I qml qml/pages/StaffPage.qml 2>&1 | grep -E '^Error:' || echo CLEAN`
Expected: CLEAN.

- [ ] **Step 4: Commit**

```bash
git add qml/pages/StaffPage.qml
git commit -m "feat(staff): FAB opens add/invite choice sheet for owner/admin"
```

---

### Task 4: Host the sheet in Main.qml + wire signals

**Files:**
- Modify: `qml/Main.qml`

- [ ] **Step 1: Wire the StaffPage signal to open the sheet**

In `qml/Main.qml`, the `StaffPage { ... }` inside `staffPageOverlay` has handlers including
`onAddStaffClicked: addStaffDlg.open()`. Add a handler next to it:
```qml
            onStaffActionsRequested: staffActionSheet.open()
```
(Place it adjacent to the existing `onAddStaffClicked`/`onInviteMemberClicked` handlers.)

- [ ] **Step 2: Host the StaffActionSheet at the App root**

Add a `StaffActionSheet` instance near the other hoisted dialogs (e.g. just after the
`AddStaffDialog { id: addStaffDlg ... }` block). Per the nested-popup hoist convention, it lives at
App root, not inside the staff overlay:
```qml
    // Staff FAB choice sheet (hoisted to App root). Routes to the two existing
    // staff dialogs; both are already hosted here.
    StaffActionSheet {
        id: staffActionSheet
        onAddStaffSelected: addStaffDlg.open()
        onInviteSelected: {
            inviteMemberDlg.errorMessage = ""
            inviteMemberDlg.open()
        }
    }
```
`StaffActionSheet` resolves via the existing `import "pages"` in Main.qml.

- [ ] **Step 3: qmllint**

Run: `"/c/Felgo/Felgo/mingw_64/bin/qmllint.exe" -I qml qml/Main.qml 2>&1 | grep -E '^Error:' || echo CLEAN`
Expected: CLEAN.

- [ ] **Step 4: Commit**

```bash
git add qml/Main.qml
git commit -m "feat(staff): host StaffActionSheet and route its choices"
```

---

### Task 5: Copyable User ID row in Profile

**Files:**
- Modify: `qml/pages/ProfilePage.qml`

The hero block (a `ColumnLayout`) holds, in order: avatar Item, name Item (`heroName`), sub Item
(`heroSub`), stats Item (`heroStats`). Add a copyable User-ID row as a new `Item` BETWEEN the
`heroSub` Item and the `heroStats` Item — "under the name".

- [ ] **Step 1: Add a truncation helper**

In `qml/pages/ProfilePage.qml`, near the existing `function _formatRole(r)` (around line 322), add:
```qml
    // Short, shareable rendering of a UID: first 6 + ellipsis + last 4. Full
    // value is what gets copied; this is display-only.
    function _shortUid(u) {
        if (!u || u.length === 0) return qsTr("—")
        if (u.length <= 12) return u
        return u.substring(0, 6) + "…" + u.substring(u.length - 4)
    }
```

- [ ] **Step 2: Add the User ID row under the name**

Immediately AFTER the `heroSub` `Item { ... }` block (the one containing `id: heroSub`, which ends
around line 109) and BEFORE the `heroStats` `Item { ... }`, insert:
```qml
                Item {
                    Layout.fillWidth: true
                    Layout.preferredHeight: uidBtn.height
                    visible: AuthStore.uid.length > 0
                    QQC.AbstractButton {
                        id: uidBtn
                        anchors.horizontalCenter: parent.horizontalCenter
                        padding: dp(6)
                        contentItem: Row {
                            spacing: dp(6)
                            Text {
                                anchors.verticalCenter: parent.verticalCenter
                                text: qsTr("ID: %1").arg(root._shortUid(AuthStore.uid))
                                color: Constants.textMuted
                                font.pixelSize: sp(Constants.fsSmall)
                            }
                            Icon {
                                anchors.verticalCenter: parent.verticalCenter
                                name: "clipboard"
                                size: sp(Constants.fsSmall)
                            }
                        }
                        background: Rectangle {
                            radius: dp(Constants.radiusSm)
                            color: uidBtn.pressed ? Constants.subtleBg : "transparent"
                        }
                        onClicked: {
                            Clipboard.copy(AuthStore.uid)
                            Toast.show(qsTr("User ID copied"))
                        }
                    }
                }
```
Notes: `Clipboard` (Task 1) and `Toast` (singleton) resolve via Main's app context / existing imports
in ProfilePage (`Toast` is used app-wide; if ProfilePage lacks an import that resolves `Toast`, it
resolves as a singleton through `import "../components"` which ProfilePage already has — verify the
import is present, add `import "../components"` if missing). `AuthStore` resolves via `import
"../model"` (already present — ProfilePage already references `AuthStore`).

- [ ] **Step 3: qmllint**

Run: `"/c/Felgo/Felgo/mingw_64/bin/qmllint.exe" -I qml qml/pages/ProfilePage.qml 2>&1 | grep -E '^Error:' || echo CLEAN`
Expected: CLEAN. If `Clipboard` shows as unqualified, that's acceptable (it's a context property, like
`NativeUtils`); only a hard `Error:` fails.

- [ ] **Step 4: Commit**

```bash
git add qml/pages/ProfilePage.qml
git commit -m "feat(staff): copyable User ID row under the name in Profile"
```

---

### Task 6: Invite dialog UID hint

**Files:**
- Modify: `qml/pages/InviteMemberDialog.qml`

- [ ] **Step 1: Update the intro text to explain where the UID comes from**

In `qml/pages/InviteMemberDialog.qml`, the intro `Text` currently reads:
```qml
            text: "Invite an existing authenticated user by their UID. They'll receive workspace access immediately."
```
Replace that string with:
```qml
            text: qsTr("Invite someone who already has an account. Ask them to open their Profile and copy their User ID, then paste it below. They'll get workspace access immediately.")
```

- [ ] **Step 2: qmllint**

Run: `"/c/Felgo/Felgo/mingw_64/bin/qmllint.exe" -I qml qml/pages/InviteMemberDialog.qml 2>&1 | grep -E '^Error:' || echo CLEAN`
Expected: CLEAN.

- [ ] **Step 3: Commit**

```bash
git add qml/pages/InviteMemberDialog.qml
git commit -m "feat(staff): invite dialog explains where to find the User ID"
```

---

### Task 7: Verification (desktop + Android device)

**Files:** none (verification); fixes fold back into Tasks 1–6.

- [ ] **Step 1: Desktop build + run**

Build/run desktop. As an owner/admin account:
- Open Staff (Dashboard "Invite staff" tile or Profile "Team members") → tap the FAB → the choice
  sheet appears with "Add staff member" and "Invite existing user".
- "Add staff member" → opens AddStaffDialog. "Invite existing user" → opens InviteMemberDialog showing
  the new hint text.
- Open Profile → a "ID: …" row appears under the name. Tap it → "User ID copied" toast; paste into a
  text field elsewhere and confirm it's the FULL uid (not the truncated display).
- As a non-manager account (if available), the FAB opens AddStaffDialog directly (no sheet).

- [ ] **Step 2: Android device pass**

Clean Android rebuild + deploy (compiles the new `Clipboard` C++ class). On device:
- Staff FAB → choice sheet → both dialogs open.
- Profile → tap the User ID row → toast; long-press a text field → Paste → full UID present (real test
  of the clipboard backend on Android).
- Full round-trip: copy UID on account B → on owner account A, FAB → Invite existing user → paste UID →
  send → member appears.

- [ ] **Step 3: Final commit (if device fixes were needed)**

```bash
git add -A
git commit -m "fix(staff): device-verification adjustments"
```
If no changes were needed, skip.

---

## Self-Review Notes

- **Spec coverage:** §2a choice sheet → Tasks 2–4; §2b copyable UID row → Tasks 1 (clipboard) + 5;
  §2c invite hint → Task 6; §3 clipboard mechanism (no Felgo API → C++ helper) → Task 1; §4 data flow
  → Tasks 3–4 wiring; §6 verification → Task 7. No `AuthService` change (spec §1 non-goal) — honored.
- **Placeholder scan:** none. Every step has concrete code/commands. The only conditional is Task 5
  Step 2's "add `import "../components"` if missing" — a verify-then-act with a specific action.
- **Type/name consistency:** signals `staffActionsRequested` (StaffPage, Task 3) → `onStaffActionsRequested`
  (Main, Task 4); `addStaffSelected`/`inviteSelected` (StaffActionSheet, Task 2) → handlers in Main
  (Task 4). `Clipboard.copy(...)` defined Task 1, called Task 5. `_shortUid`/`_formatRole` are local
  ProfilePage functions. `AuthStore.uid` read-only display + full-value copy is consistent.
- **DRY:** the sheet reuses `ListCard` + `BottomSheet` (no new chrome); the copy path is one C++ entry
  point; both FAB branches reuse dialogs already hosted in Main.qml.
