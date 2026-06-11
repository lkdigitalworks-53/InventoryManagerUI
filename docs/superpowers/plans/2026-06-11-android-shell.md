# Android Shell (Safe Area + Hardware Back) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make app content land inside the Android device safe area (header/back button tappable, tabbar above the gesture bar) and make the hardware/keyboard Back button mirror the on-screen back button, with double-tap-to-exit on the Home root.

**Architecture:** A `SafeArea` singleton (`qml/helper/SafeArea.qml`) is bound once in `Main.qml` to Felgo's live `app.safeAreaInsets`. Chrome that touches a screen edge (`GlassHeader`, `FloatingTabbar`, top-pinned auth pages) reads `SafeArea.top`/`SafeArea.bottom`. A single `_handleBack()` router in `Main.qml` (driven by Felgo's `App.backButtonPressedGlobally`) closes the top-most transient layer first.

**Tech Stack:** Felgo + Qt 6.8.3, QML. Verified Felgo API: `App.safeAreaInsets` (`EdgeInset` with `.top/.bottom/.left/.right`, `safeAreaInsetsChanged`), `App.backButtonPressedGlobally` signal + `App.backButtonAutoAcceptGlobally` bool.

**Spec:** `docs/superpowers/specs/2026-06-11-android-shell-design.md`

---

## Verification model (read first)

No QML unit-test harness; this is layout + native-back behavior. "Tests" are concrete runnable checks:

1. **`qmllint`** on every changed/created file — no new errors. Binary:
   `"/c/Felgo/Felgo/mingw_64/bin/qmllint.exe" -I qml <file>`
   (Pre-existing Felgo import warnings and codebase-wide "unqualified access" / "member of a parent element" notes are acceptable; only NEW hard `Error:` lines fail.)
2. **Desktop run** — on desktop `safeAreaInsets` are all `0`, so every layout change in Tasks 1–3 must be **visually identical to today** (regression guard). The back router (Task 4) must still close dialogs.
3. **Android device** — the real verification (Task 5). Insets non-zero; header/tabbar inside safe area; hardware Back follows the ladder.

Desktop CANNOT exercise the safe-area offset (insets are 0) or the Android hardware Back — Task 5 is mandatory and only the user can run it.

---

## File Structure

**Created:**
- `qml/helper/SafeArea.qml` — inset singleton (4 real properties, default 0).

**Modified:**
- `qml/helper/qmldir` — register the `SafeArea` singleton.
- `qml/Main.qml` — bind `SafeArea` to `app.safeAreaInsets`; add back router + double-tap-exit.
- `qml/components/GlassHeader.qml` — add `topInset` property; offset content row.
- `qml/components/FloatingTabbar.qml` — add `extraBottomInset` property; apply to bottom margin.
- 7 pages with `GlassHeader` — pass `topInset: SafeArea.top` and grow the tabbar-clearance spacer:
  `StaffPage, SalesPage, ProfilePage, OrdersPage, InventoryPage, DashboardPage, ActivityPage`.
- `qml/pages/LoginPage.qml`, `qml/pages/TenantSetupPage.qml` — grow the leading top spacer by `SafeArea.top`.

**Verified, not modified:** Felgo `App`/`AppPage` internals; navigation structure; `Constants.tabbarClearance` stays 110 (we add the inset at the call sites).

---

### Task 1: `SafeArea` singleton + bind in Main.qml

**Files:**
- Create: `qml/helper/SafeArea.qml`
- Modify: `qml/helper/qmldir`
- Modify: `qml/Main.qml`

- [ ] **Step 1: Create the singleton**

Create `qml/helper/SafeArea.qml`:

```qml
pragma Singleton
import QtQuick

// Device safe-area insets (px), bound once in Main.qml to Felgo's live
// app.safeAreaInsets. Chrome that touches a screen edge reads these instead of
// prop-drilling through every page. All 0 on desktop, so layouts are unchanged
// there. See docs/superpowers/specs/2026-06-11-android-shell-design.md.
QtObject {
    property real top: 0
    property real bottom: 0
    property real left: 0
    property real right: 0
}
```

- [ ] **Step 2: Register the singleton in qmldir**

In `qml/helper/qmldir`, append a third line so it reads exactly:

```
singleton Constants 1.0 Constants.qml
singleton FormValidator 1.0 FormValidator.qml
singleton SafeArea 1.0 SafeArea.qml
```

- [ ] **Step 3: Bind SafeArea to Felgo insets in Main.qml**

In `qml/Main.qml`, immediately after the `Component.onCompleted { ... }` block (currently ends at
line ~33, just before the `// Bring the app window to the foreground…` Connections), add:

```qml
    // Bind the SafeArea singleton to Felgo's live device insets. Updates on
    // rotation / cutout change via safeAreaInsetsChanged. 0 on desktop.
    Binding { target: SafeArea; property: "top";    value: app.safeAreaInsets.top }
    Binding { target: SafeArea; property: "bottom"; value: app.safeAreaInsets.bottom }
    Binding { target: SafeArea; property: "left";   value: app.safeAreaInsets.left }
    Binding { target: SafeArea; property: "right";  value: app.safeAreaInsets.right }
```

`SafeArea` resolves with no new import: `Main.qml` already has `import "helper"` (line 11).

- [ ] **Step 4: qmllint the singleton and Main.qml**

Run:
```bash
"/c/Felgo/Felgo/mingw_64/bin/qmllint.exe" -I qml qml/helper/SafeArea.qml
"/c/Felgo/Felgo/mingw_64/bin/qmllint.exe" -I qml qml/Main.qml
```
Expected: no new `Error:` lines. (`app.safeAreaInsets` is a Felgo `App` member; if qmllint emits an "unqualified"/"member of a parent element" note for it, that is acceptable — Main.qml already has many such notes.)

- [ ] **Step 5: Commit**

```bash
git add qml/helper/SafeArea.qml qml/helper/qmldir qml/Main.qml
git commit -m "feat(shell): add SafeArea singleton bound to Felgo safeAreaInsets"
```

---

### Task 2: GlassHeader top inset + apply at 7 call sites

**Files:**
- Modify: `qml/components/GlassHeader.qml`
- Modify: `qml/pages/{StaffPage,SalesPage,ProfilePage,OrdersPage,InventoryPage,DashboardPage,ActivityPage}.qml`

- [ ] **Step 1: Add `topInset` to GlassHeader and offset the content**

In `qml/components/GlassHeader.qml`:

(a) Add the property after `property bool elevated: true` (line ~21):

```qml
    // Top safe-area inset (status bar / cutout). The glass background still
    // paints up under the status bar, but the tappable title/action row drops
    // below it by this amount. 0 on desktop. Callers pass SafeArea.top.
    property real topInset: 0
```

(b) Change the header height (line ~18) from:

```qml
    height: dp(64)
```
to:
```qml
    height: dp(64) + topInset
```

(c) The content `RowLayout` currently uses `anchors.fill: parent` (line ~31). Replace that anchor
with explicit edges so the row sits below the inset:

```qml
    RowLayout {
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.top: parent.top
        anchors.topMargin: root.topInset
        anchors.leftMargin: dp(Constants.space4)
        anchors.rightMargin: dp(Constants.space4)
        spacing: dp(Constants.space2)
```

(Leave the rest of the `RowLayout` body unchanged. The bottom hairline `Rectangle` stays anchored to
the header bottom — unchanged.)

- [ ] **Step 2: qmllint GlassHeader**

Run: `"/c/Felgo/Felgo/mingw_64/bin/qmllint.exe" -I qml qml/components/GlassHeader.qml`
Expected: no new `Error:` lines.

- [ ] **Step 3: Pass `topInset: SafeArea.top` at all 7 call sites**

In each file below, find the `GlassHeader {` block (line numbers as of now) and add
`topInset: SafeArea.top` as the first property inside the block. Each page already has
`import "../helper"` (so `SafeArea` resolves) and `import "../components"` (for `GlassHeader`) — verify
both are present; if `import "../helper"` is missing in any, add it.

- `qml/pages/StaffPage.qml:32`
- `qml/pages/SalesPage.qml:102`
- `qml/pages/ProfilePage.qml:22`
- `qml/pages/OrdersPage.qml:34`
- `qml/pages/InventoryPage.qml:41`
- `qml/pages/DashboardPage.qml:218`
- `qml/pages/ActivityPage.qml:56`

Example (StaffPage.qml — apply the identical 1-line addition in each):

Before:
```qml
    GlassHeader {
```
After:
```qml
    GlassHeader {
        topInset: SafeArea.top
```

- [ ] **Step 4: qmllint the 7 pages**

Run `qmllint -I qml <file>` for each of the 7 pages. Expected: no new `Error:` lines.

- [ ] **Step 5: Desktop regression check**

Build/run desktop. Because `SafeArea.top` is 0 on desktop, every header must look exactly as before
(no gap above the title). Confirm Dashboard/Orders/Inventory/Sales/Profile/Staff/Activity headers
are unchanged.

- [ ] **Step 6: Commit**

```bash
git add qml/components/GlassHeader.qml qml/pages/StaffPage.qml qml/pages/SalesPage.qml qml/pages/ProfilePage.qml qml/pages/OrdersPage.qml qml/pages/InventoryPage.qml qml/pages/DashboardPage.qml qml/pages/ActivityPage.qml
git commit -m "feat(shell): GlassHeader topInset; apply SafeArea.top on all pages"
```

---

### Task 3: FloatingTabbar bottom inset + clearance + auth-page top spacers

**Files:**
- Modify: `qml/components/FloatingTabbar.qml`
- Modify: `qml/Main.qml` (tabbar instance bottom margin)
- Modify: the 7 pages' tabbar-clearance spacers
- Modify: `qml/pages/LoginPage.qml`, `qml/pages/TenantSetupPage.qml` (top spacers)

- [ ] **Step 1: Apply the bottom inset to the FloatingTabbar instance in Main.qml**

In `qml/Main.qml`, the `FloatingTabbar` instance (line ~468) currently has
`anchors.bottomMargin: dp(14)`. Change it to:

```qml
        anchors.bottomMargin: dp(14) + SafeArea.bottom
```

- [ ] **Step 2: Grow the tabbar-clearance spacer on the 7 scrollable pages**

Each page ends its scroll content with:
```qml
            Item { Layout.preferredHeight: dp(Constants.tabbarClearance); Layout.fillWidth: true }
```
Change the height on each to add the bottom inset (so content clears the now-higher tabbar):
```qml
            Item { Layout.preferredHeight: dp(Constants.tabbarClearance) + SafeArea.bottom; Layout.fillWidth: true }
```
Apply at:
- `qml/pages/ActivityPage.qml:165`
- `qml/pages/DashboardPage.qml:485`
- `qml/pages/InventoryPage.qml:192`
- `qml/pages/OrdersPage.qml:294`
- `qml/pages/ProfilePage.qml:227`
- `qml/pages/SalesPage.qml:961`
- `qml/pages/StaffPage.qml:198`

(All 7 already import `"../helper"` from Task 2's verification, so `SafeArea` resolves.)

- [ ] **Step 3: Auth pages don't use GlassHeader — add a top spacer**

`LoginPage.qml` and `TenantSetupPage.qml` are full-screen `Item`s whose scroll content starts with a
fixed spacer `Item { Layout.preferredHeight: dp(Constants.space7); ... }`.

In `qml/pages/LoginPage.qml` line ~120 (the first child of `scrollCol`, currently
`Item { Layout.preferredHeight: dp(Constants.space7); Layout.fillWidth: true }`), change to:
```qml
            Item { Layout.preferredHeight: dp(Constants.space7) + SafeArea.top; Layout.fillWidth: true }
```
`LoginPage.qml` already has `import "../helper"` (line 6).

In `qml/pages/TenantSetupPage.qml` line ~37 (the first `Item { Layout.preferredHeight: dp(Constants.space7) ... }` inside its `ColumnLayout`), change identically:
```qml
            Item { Layout.preferredHeight: dp(Constants.space7) + SafeArea.top; Layout.fillWidth: true }
```
Verify `TenantSetupPage.qml` has `import "../helper"`; if missing, add it.

- [ ] **Step 4: `FloatingTabbar.qml` — no internal change needed, but verify**

The bottom inset is applied at the instance (Step 1), not inside the component, so
`FloatingTabbar.qml` itself needs no edit. Confirm it has no hard-coded bottom anchor that would
fight the instance margin (it owns only its internal pill/shadow layout — leave as-is).

- [ ] **Step 5: qmllint all touched files**

Run `qmllint -I qml <file>` for: `qml/Main.qml`, the 7 pages, `LoginPage.qml`, `TenantSetupPage.qml`.
Expected: no new `Error:` lines.

- [ ] **Step 6: Desktop regression check**

Build/run desktop. Insets are 0 → tabbar position, content clearance, and auth-page top spacing must
be visually identical to today.

- [ ] **Step 7: Commit**

```bash
git add qml/Main.qml qml/pages/ActivityPage.qml qml/pages/DashboardPage.qml qml/pages/InventoryPage.qml qml/pages/OrdersPage.qml qml/pages/ProfilePage.qml qml/pages/SalesPage.qml qml/pages/StaffPage.qml qml/pages/LoginPage.qml qml/pages/TenantSetupPage.qml
git commit -m "feat(shell): tabbar + content clearance + auth pages respect bottom/top insets"
```

---

### Task 4: Central hardware-Back router in Main.qml

**Files:**
- Modify: `qml/Main.qml`

Context: every modal sheet/dialog exposes `opened` (BottomSheet→QQC.Dialog, ConfirmDialog→QQC.Dialog,
PhotoSourceSheet→QQC.Popup, and the raw QQC.Dialogs `stockErrorDlg`/`permissionErrorDlg`/`importPathPrompt`).
The 3 full-screen overlays (`profilePage`, `staffPageOverlay`, `activityPageOverlay`) are plain `Item`s using `visible`.

- [ ] **Step 1: Add back-router state + handler to the App root**

In `qml/Main.qml`, on the root `App { ... }` add the property and signal handler. Place
`backButtonAutoAcceptGlobally: false` near the other top-level `App` properties (after
`property string successMessage: ""`, line ~24), and add the handler + helper function just after the
`Component.onCompleted` block:

```qml
    // Don't let Felgo auto-exit on Android Back — we route it ourselves.
    backButtonAutoAcceptGlobally: false

    // Armed by the first Back on the Home root; a second Back within the window exits.
    property bool _exitArmed: false
    Timer {
        id: _exitArmTimer
        interval: 2000
        onTriggered: app._exitArmed = false
    }

    onBackButtonPressedGlobally: app._handleBack()

    // Close the top-most transient layer; mirrors the on-screen back button.
    function _handleBack() {
        // 1. Open modal sheet / dialog → close the first open one.
        var dialogs = [photoSourceSheet, importPathPrompt, addProductDlg, editProductDlg,
                       newOrderDlg, orderDetail, restockDlg, addStaffDlg, inviteMemberDlg,
                       memberMgmtDlg, staffDetailDlg, profileDlg, manageCategoriesDlg,
                       manageChannelsDlg, notificationsSheet, filterSheet, exportSheet,
                       forgotPasswordDlg, confirmDlg, stockErrorDlg, permissionErrorDlg]
        for (var i = 0; i < dialogs.length; ++i) {
            if (dialogs[i] && dialogs[i].opened) { dialogs[i].close(); return }
        }
        // 2. Full-screen overlay visible → close back to Dashboard.
        if (profilePage.visible)         { profilePage.close();         return }
        if (staffPageOverlay.visible)    { staffPageOverlay.close();    return }
        if (activityPageOverlay.visible) { activityPageOverlay.close(); return }
        // 3. Not on Home tab → go to Home.
        if (navigation.visible && navigation.currentIndex !== 0) {
            navigation.currentIndex = 0
            return
        }
        // 4. Home root → double-tap to exit.
        if (_exitArmed) { Qt.quit(); return }
        _exitArmed = true
        Toast.show(qsTr("Press back again to exit"))
        _exitArmTimer.restart()
    }
```

Notes for the implementer:
- All ids referenced above exist in `Main.qml` (verified). If any id is renamed later, update this
  one list — it is the single source of truth for back behavior.
- `Toast` is the existing singleton (`Toast.show(msg)`); `Main.qml` already uses it (`onSuccessMessageChanged`).
- Do NOT add per-page `Keys.onBackPressed` — this central router is the only back handler.

- [ ] **Step 2: qmllint Main.qml**

Run: `"/c/Felgo/Felgo/mingw_64/bin/qmllint.exe" -I qml qml/Main.qml`
Expected: no new `Error:` lines. (`opened`/`close()` on the dialog ids and `Qt.quit()` are valid;
"unqualified"/"parent element" notes are acceptable.)

- [ ] **Step 3: Desktop sanity (partial — no hardware Back on desktop)**

Build/run desktop. The handler won't fire from a hardware button on desktop, but the app must still
launch and behave normally (this step only guards against a syntax/runtime error in the new block).
Confirm dialogs still open/close via their normal UI controls.

- [ ] **Step 4: Commit**

```bash
git add qml/Main.qml
git commit -m "feat(shell): central hardware-Back router with double-tap-to-exit"
```

---

### Task 5: Android device verification (the real proof)

**Files:** none (device test); fixes, if any, fold back into Tasks 1–4.

- [ ] **Step 1: Clean Android rebuild + deploy**

Clean the Android build dir (or Qt Creator → Build → Clean), then Rebuild + deploy to a device.
(`CONFIGURE_DEPENDS` already in CMake from prior work picks up the new `SafeArea.qml`.) Expected:
build + deploy succeed; app launches.

- [ ] **Step 2: Confirm insets are non-zero**

Temporarily log once at startup (in `Main.qml` `Component.onCompleted`, then remove before final commit):
`console.log("[SafeArea] top", app.safeAreaInsets.top, "bottom", app.safeAreaInsets.bottom)`.
Expected: `top` > 0 on a device with a status bar / cutout.
**If `top` reads 0** while the header still overflows: Felgo is not reporting insets in the current
window mode. Document it and fall back — set the page top offset from `Qt.application` /
`Screen`-derived status-bar height, or enable Felgo immersive handling — then re-test. Capture the
finding in the spec before changing approach.

- [ ] **Step 3: Safe-area visual pass**

On the device confirm, on every screen, the header title + back button sit fully below the status bar
and are tappable: Dashboard, Orders, Inventory, Sales, Profile, Staff, Activity, Login, Tenant-setup.
Confirm the floating tabbar sits above the gesture bar (not clipped) and list content scrolls clear
of it (no row hidden behind the tabbar at the bottom).

- [ ] **Step 4: Hardware Back pass**

Verify the ladder on-device:
- Open a bottom sheet (e.g. Add product) → Back closes the sheet (stays on the page).
- Open Profile/Staff/Activity overlay → Back returns to Dashboard.
- Switch to Orders/Stock/Sales tab → Back returns to Home tab.
- On Home root → Back shows "Press back again to exit" toast; a second Back within 2s backgrounds the
  app; waiting >2s then Back re-arms (toast again, no exit).
- With a text field focused and soft keyboard up → Back dismisses the keyboard first; the next Back
  follows the ladder.

- [ ] **Step 5: Remove the debug log + final commit (if any fixes were needed)**

Remove the Step 2 `console.log`. If Steps 2–4 required code changes, commit them:
```bash
git add -A
git commit -m "fix(shell): device-verification adjustments for safe area / back"
```
If no changes were needed beyond removing the log, commit just that removal.

---

## Self-Review Notes

- **Spec coverage:**
  - §3a SafeArea singleton + binding → Task 1.
  - §4.1 GlassHeader topInset + 7 call sites → Task 2.
  - §4.2 FloatingTabbar bottom inset (+ content clearance) → Task 3 Steps 1–2.
  - §4.3 Login/TenantSetup top spacers → Task 3 Step 3.
  - §5 back router ladder + §5a double-tap-exit → Task 4.
  - §7 verification (qmllint / desktop regression / device) → each task's lint+desktop steps and Task 5.
  - Left/right insets intentionally exposed-but-unapplied (spec §4) — no task applies them (YAGNI), matching the spec.
- **Placeholder scan:** none. Every code block is concrete; the only conditional is Task 5 Step 2's documented fallback if the device reports zero insets (a real branch, with a specific action).
- **Type/name consistency:** `SafeArea.top/bottom/left/right` defined in Task 1 are the exact names read in Tasks 2–3. `topInset` (GlassHeader) and the tabbar `bottomMargin: dp(14) + SafeArea.bottom` match the spec. Back-router ids (`photoSourceSheet`, `importPathPrompt`, `profilePage`, `staffPageOverlay`, `activityPageOverlay`, etc.) all verified present in `Main.qml`.
- **Clearance correctness:** Task 3 grows the 7 clearance spacers by `SafeArea.bottom` to match the tabbar moving up by the same amount — prevents content hiding behind the raised tabbar (caught during planning; not separately in the spec but consistent with §4.2's intent).
