# Android Shell — Safe Area + Hardware Back — Design Spec

**Date:** 2026-06-11
**Stream:** A (first of four — see the Android bug-batch decomposition)
**Bugs addressed:** #2 (header/back-button under the status bar — unreachable), #3 (Android hardware/keyboard Back does nothing)
**Platform:** Felgo + Qt 6.8.3, QML. Target = mobile (Android primary; iOS shares the same code paths).

---

## 1. Problem & Goal

The app renders **edge-to-edge** on Android: Felgo draws content under the status bar / camera
cutout (top) and the gesture navigation bar (bottom). Two consequences:

- **#2** Every page draws its own `GlassHeader` anchored at `y=0`, so the title and back button
  sit *under* the status bar and can't be tapped. The `FloatingTabbar` sits in the bottom gesture
  area.
- **#3** Nothing intercepts the Android Back gesture/button, so it doesn't mirror the on-screen
  back button (and can abruptly background/kill the app).

**Goal:** content lands inside the device safe area on all screens, and hardware Back behaves like a
well-mannered Android app (close the top-most transient layer; on Home root, double-tap to exit).

**Non-goals:** landscape-specific layout; iOS notch tuning beyond what the shared inset code gives
for free; redesigning navigation. Left/right insets are wired but not applied (portrait-first — YAGNI).

---

## 2. Confirmed Felgo API (verified in the local install)

- `App.safeAreaInsets` — readonly `EdgeInset` with `.top/.bottom/.left/.right`; emits
  `safeAreaInsetsChanged` on rotation/cutout change. (`qml/Felgo/felgo.qmltypes`.)
- `AppPage.safeArea` (Item), `AppPage.useSafeArea` (bool, default true) — not used here because our
  pages set `navigationBarHidden: true` + `anchors.fill: parent` and render custom `GlassHeader`s.
- `App.backButtonPressedGlobally` (signal) + `App.backButtonAutoAcceptGlobally` (bool) — the
  Android hardware-back hook. (`qml/Felgo/core/App.qml`.)

---

## 3. Architecture — one shared inset singleton + one back router

### 3a. `SafeArea` singleton (new)

`qml/helper/SafeArea.qml`, registered in `qml/helper/qmldir`, mirroring the existing `Constants`
singleton pattern:

```qml
pragma Singleton
import QtQuick
QtObject {
    property real top: 0
    property real bottom: 0
    property real left: 0
    property real right: 0
}
```

`Main.qml` binds it once to the live Felgo insets:

```qml
Binding { target: SafeArea; property: "top";    value: app.safeAreaInsets.top }
Binding { target: SafeArea; property: "bottom"; value: app.safeAreaInsets.bottom }
Binding { target: SafeArea; property: "left";   value: app.safeAreaInsets.left }
Binding { target: SafeArea; property: "right";  value: app.safeAreaInsets.right }
```

Rationale: one source of truth that custom headers, the floating tabbar, and the full-screen overlay
pages all read — no prop-drilling through every page. Consistent with the app's singleton-heavy
design (`Constants`, the stores). On desktop the insets are `0`, so behavior is unchanged there.

### 3b. Back router (new, in `Main.qml`)

`App { backButtonAutoAcceptGlobally: false; onBackButtonPressedGlobally: app._handleBack() }` with a
single prioritized router (details in §5).

---

## 4. #2 Safe-area insets — where applied

Only chrome that touches a screen edge, each in exactly one place:

1. **`GlassHeader.qml`** — add `property real topInset: 0`. Header `height: dp(64) + topInset`; the
   inner content `RowLayout` gets `anchors.topMargin: topInset`. The glass background still paints
   up under the status bar (correct: translucent bar over header), but the tappable title/back row
   drops below it. Every page that instantiates `GlassHeader` passes `topInset: SafeArea.top`.

2. **`FloatingTabbar.qml`** — `anchors.bottomMargin` becomes `dp(14) + SafeArea.bottom` so it clears
   the gesture bar. One file; every tab screen benefits.

3. **Top-pinned full-screen pages without a GlassHeader** — `LoginPage`, `TenantSetupPage` — get a
   leading top spacer of `SafeArea.top` (their scroll content currently starts at `y=0`). Profile /
   Staff / Activity use `GlassHeader`, so (1) covers them.

**Left/right insets:** exposed on the singleton but not applied in this stream (portrait-first). Add
application only if landscape support is added later.

**Double-counting guard:** the app is effectively edge-to-edge (overflow is observed), so we rely
solely on `safeAreaInsets` and do **not** also toggle `immersiveMode`. The plan verifies the
measured `SafeArea.top` is non-zero on-device before trusting the binding.

---

## 5. #3 Hardware/keyboard Back — central router

`Main.qml` owns one `_handleBack()` that closes the top-most transient layer first (first match
wins):

```
1. Any open modal popup (BottomSheet-derived dialog / sheet) → close it
2. Full-screen overlay Item visible (profilePage / staffPageOverlay / activityPageOverlay) → close()
3. navigation.currentIndex !== 0 (not Home tab) → navigation.currentIndex = 0
4. On Home root → double-tap-to-exit (see §5a)
```

**Design decisions:**

- **One central router**, not per-page `Keys.onBackPressed`. All dialogs/overlays are declared in
  `Main.qml`, so one function has clean access to the whole stack — same shape as the existing
  `_routeActivity` router.
- **Mirrors the on-screen back button:** overlay pages already emit `onBackRequested: …close()`; the
  router calls the same `close()`, so hardware-Back and the `←` button are identical by construction.
- **Open-popup detection:** the modal sheets all extend `BottomSheet` (a `QQC.Dialog`), which exposes
  `opened`. The router checks the known dialog/sheet ids' `opened` property (close the first open
  one). Implementation note for the plan: prefer iterating a single list of the dialog ids over a
  hand-maintained `if`-ladder, to resist drift as dialogs are added. The three full-screen overlays
  (`profilePage`, `staffPageOverlay`, `activityPageOverlay`) are plain `Item`s using `visible`, so
  they're checked separately in step 2.
- **Keyboard back:** Android collapses the soft keyboard before our handler fires (OS-level), so no
  extra work — the plan verifies IME-dismiss-first ordering on-device.

### 5a. Home-root exit — double-tap to exit

On Back at the Home tab root: first press shows a brief toast ("Press back again to exit") via the
existing `Toast.show(...)` host and arms a ~2s timer; a second Back while armed backgrounds the app
(`Qt.quit()` / Felgo accept). If the timer lapses, the next Back re-arms (shows the toast again).
Prevents accidental exits — the common Android pattern.

---

## 6. Files touched

**Created:**
- `qml/helper/SafeArea.qml` — inset singleton.

**Modified:**
- `qml/helper/qmldir` — register `SafeArea` singleton.
- `qml/Main.qml` — bind `SafeArea` to `app.safeAreaInsets`; add `backButtonAutoAcceptGlobally:
  false` + `onBackButtonPressedGlobally` + `_handleBack()` router + double-tap-exit state/timer.
- `qml/components/GlassHeader.qml` — add `topInset`; offset content row.
- `qml/components/FloatingTabbar.qml` — add `SafeArea.bottom` to bottom margin.
- Pages instantiating `GlassHeader` — pass `topInset: SafeArea.top`. (Enumerated in the plan by
  grepping `GlassHeader {` call sites.)
- `qml/pages/LoginPage.qml`, `qml/pages/TenantSetupPage.qml` — top spacer of `SafeArea.top`.

**Verified, not modified:** Felgo `App`/`AppPage` internals; navigation structure.

---

## 7. Verification

No QML unit-test harness; rendering + native back are visual/device behaviors.

1. **`qmllint`** on every changed/created QML — no new errors.
   Binary: `"/c/Felgo/Felgo/mingw_64/bin/qmllint.exe" -I qml <file>`.
2. **Desktop run** — insets are `0`, so layout must be visually identical to today (regression
   guard). Back router: dialogs close on Esc/back as before.
3. **Android device (the real verification):**
   - `SafeArea.top` measured non-zero (log it once at startup); header title + back button are fully
     below the status bar and tappable on every page (Dashboard, Orders, Inventory, Sales, Profile,
     Staff, Activity, Login, Tenant-setup).
   - Floating tabbar sits above the gesture bar (not clipped/overlapping).
   - Hardware Back: closes an open sheet; closes a full-screen overlay to Dashboard; from a non-Home
     tab returns to Home; on Home root shows the exit toast, second press backgrounds the app.
   - Soft keyboard: Back dismisses the IME first, then the next Back follows the ladder.

---

## 8. Build sequence (preview — full plan via writing-plans)

1. Create `SafeArea` singleton + register in `qmldir`; bind in `Main.qml`. qmllint. (Insets land as 0 on desktop — no visual change yet.)
2. `GlassHeader.topInset` + offset; pass `topInset: SafeArea.top` at all call sites. qmllint + desktop regression check.
3. `FloatingTabbar` bottom inset; Login/TenantSetup top spacers. qmllint.
4. Back router in `Main.qml` (`backButtonAutoAcceptGlobally: false` + `_handleBack()` ladder + double-tap-exit). qmllint + desktop.
5. Android device pass (§7.3); adjust if `SafeArea.top` reads 0 (fall back to documenting immersive-mode interaction).
