# Five Features Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship five independent features — editable price in the New Order dialog, swipe navigation between Analysis report views, the Add-Product advanced section open by default, always-visible staff-credential fields, and build-time dev/test/prd Firestore environments.

**Architecture:** Four are localized QML edits that reuse existing in-repo patterns. The fifth (environments) routes all Firestore traffic through a single `databaseId` resolved at build time from `PRODUCT_STAGE`, with the stage→database mapping extracted into a pure, unit-tested JS helper.

**Tech Stack:** Felgo QML (Qt 6.8), QtCore.Settings, Firestore REST, CMake, Qt Quick Test (`qmltestrunner`).

## Global Constraints

- **Spec:** `docs/superpowers/specs/2026-06-26-five-features-design.md` (authoritative; every task implements part of it).
- **No migration / back-compat code** — MVP fresh-data phase; implement clean schema directly.
- **Pages never import AuthStore directly** — gating booleans are bound from `Main.qml`.
- **Pages/dialogs never call stores directly** — user actions go through `Logic` signals; existing exception: blur-commit fields use raw `QQC.TextField` (AuthTextField has no `editingFinished`).
- **Tests live in `tests/` (outside `qml/`)** and test only pure `.pragma library` JS — page/singleton QML cannot load under `qmltestrunner`.
- **Run a test suite headlessly** (silent without the two `QT_*` vars on this box):
  ```bash
  QT_FORCE_STDERR_LOGGING=1 QT_LOGGING_TO_CONSOLE=1 \
    PATH="/c/Felgo/Felgo/mingw_64/bin:$PATH" \
    "C:/Felgo/Felgo/mingw_64/bin/qmltestrunner.exe" -platform offscreen -input tests/tst_<Name>.qml
  ```
- **Commit message trailer** — every commit ends with:
  `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`
- **Currency/format helpers:** `InventoryStore.formatCurrency`, `OrdersStore.formatCurrency`, `SalesStore.formatNumber` already exist — reuse, never re-implement.

---

### Task 1: Add-Product advanced section open by default

**Files:**
- Modify: `qml/pages/AddProductDialog.qml` (`advToggle` default ~line 200; `onOpened` ~line 31)

**Interfaces:**
- Consumes: nothing new.
- Produces: nothing other tasks depend on.

- [ ] **Step 1: Flip the toggle default to open**

In `qml/pages/AddProductDialog.qml`, in the `QQC.AbstractButton { id: advToggle ... }` block, change the property default:

```qml
QQC.AbstractButton {
    id: advToggle
    Layout.fillWidth: true
    Layout.preferredHeight: dp(32)
    property bool open: true        // was: false — advanced section starts expanded
```

- [ ] **Step 2: Re-open it on every sheet open**

The toggle keeps its state between opens, so also force it open in `onOpened`. Add the line at the end of the existing `onOpened` block (after `dlg._addPartyOpen = false`):

```qml
        dlg._addPartyOpen = false
        advToggle.open = true       // advanced section visible every time the sheet opens
    }
```

- [ ] **Step 3: Manually verify (device or desktop run)**

Open Add Product. Expected: SKU / Category / Unit / stock / reorder / Tax / Supplier are visible immediately. Collapse the section, close the sheet, reopen → expanded again.

- [ ] **Step 4: Commit**

```bash
git add qml/pages/AddProductDialog.qml
git commit -m "feat(inventory): open Add Product advanced section by default

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: Editable per-line price in the New Order dialog

**Files:**
- Modify: `qml/pages/NewOrderDialog.qml` (add `_setLinePrice` helper near `_setLineDiscount` ~line 456; add price field to the cart-row delegate ~lines 260–360)

**Interfaces:**
- Consumes: existing `selectedProducts` array of `{ name, qty, price, productId, discountType, discountValue }`; existing `_totalsCache` recompute on `selectedProducts` reassignment.
- Produces: `function _setLinePrice(idx, value)` — immutable replace of one line's `price`; rejects empty/NaN/negative (keeps old price). Drives `_totalsCache` and the `orderCreated` payload automatically.

- [ ] **Step 1: Add the `_setLinePrice` helper**

In `qml/pages/NewOrderDialog.qml`, immediately after the existing `_setLineDiscount` function (~line 464), add:

```qml
    // Commit an edited per-line unit price. Mirrors _setLineDiscount: immutable
    // array replace so _totalsCache (and the orderCreated payload) recompute.
    // Rejects empty / NaN / negative by keeping the existing price.
    function _setLinePrice(idx, value) {
        if (idx < 0 || idx >= selectedProducts.length) return
        var v = parseFloat(String(value).replace(/[^0-9.]/g, ""))
        if (isNaN(v) || v < 0) return
        var arr = selectedProducts.slice()
        arr[idx] = Object.assign({}, arr[idx], { price: v })
        selectedProducts = arr
    }
```

- [ ] **Step 2: Add the editable price field to the cart-row delegate**

In the cart-row delegate, the discount row (`RowLayout` starting ~line 317 with the `Discount` label, `SegmentedPill`, and `lineDiscField`) is the natural home. Add a price field to the top row OR extend the discount row. Add this editable price `QQC.TextField` inside the discount `RowLayout`, before the `Discount` `Text` (so the row reads: Price ▢  Discount ₹/% ▢):

```qml
                            // Editable unit price — commits on blur/accept (never
                            // per-keystroke) so model.price and this field don't loop.
                            // Plain number while focused, formatted currency otherwise.
                            Text {
                                text: qsTr("Price")
                                color: Constants.textSecondary
                                font.pixelSize: sp(Constants.fsSmall)
                                font.bold: true
                            }
                            QQC.TextField {
                                id: linePriceField
                                Layout.preferredWidth: dp(72)
                                text: InventoryStore.formatCurrency(modelData.price)
                                inputMethodHints: Qt.ImhFormattedNumbersOnly
                                font.pixelSize: sp(Constants.fsBody)
                                horizontalAlignment: Text.AlignRight
                                selectByMouse: true
                                padding: 0
                                leftPadding: dp(6); rightPadding: dp(6)
                                topPadding: dp(6); bottomPadding: dp(6)
                                background: Rectangle {
                                    radius: dp(8)
                                    color: linePriceField.enabled ? Constants.cardBg : Constants.subtleBg
                                    border.color: linePriceField.activeFocus ? Constants.primaryBlue : Constants.borderColor
                                    border.width: linePriceField.activeFocus ? 2 : 1
                                }
                                onActiveFocusChanged: {
                                    if (activeFocus) { text = String(modelData.price); selectAll() }
                                    else { text = InventoryStore.formatCurrency(modelData.price) }
                                }
                                function _commitPrice() {
                                    dlg._setLinePrice(index, text)
                                    // Re-sync to whatever actually committed (rejects keep old price).
                                    var cur = dlg.selectedProducts[index]
                                    text = InventoryStore.formatCurrency(cur ? cur.price : modelData.price)
                                }
                                onEditingFinished: _commitPrice()
                                onAccepted: _commitPrice()
                            }
```

Note: the cart-row qty subtitle (`modelData.price ... · qty N`, ~line 281) continues to show the live price — no change needed there.

- [ ] **Step 3: Confirm the price reaches the order payload (read-through, no code)**

Re-read `trySubmit` (~line 528): `prods.push({ ... price: selectedProducts[i].price, ... })` already carries the per-line price. No change required — verify by reading.

- [ ] **Step 4: Manually verify (device or desktop run)**

Add a product to the cart. Edit its price field → blur. Expected: Subtotal / Tax / Total update; the qty subtitle shows the new price. Place the order, open it in Order Detail → the line shows the edited price. Empty/negative/letters → field snaps back to the last good price.

- [ ] **Step 5: Run the full test suite (regression guard)**

Run each suite in `tests/` with the headless command from Global Constraints. Expected: all PASS (no behavior changed in pure libs; this guards against an accidental break).

- [ ] **Step 6: Commit**

```bash
git add qml/pages/NewOrderDialog.qml
git commit -m "feat(orders): editable per-line price in New Order dialog

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: Always-visible staff-credential fields (remove checkbox)

**Files:**
- Modify: `qml/pages/AddStaffDialog.qml` (remove `createLoginCheck` ~lines 173–180; drop `visible:` gate ~line 183; `onOpened` ~line 30; `trySubmit` validation ~line 230 + payload ~lines 249/254)

**Interfaces:**
- Consumes: existing `staffCreated(payload)` signal; existing `_provisioning`/`busy` flags and the `Connections { target: AuthService; enabled: dlg._provisioning }` result listener.
- Produces: `payload.createLogin` is now always `true`; password is always required (≥6 chars).

- [ ] **Step 1: Remove the checkbox, make credential fields unconditional**

In `qml/pages/AddStaffDialog.qml`, replace the login `ColumnLayout` (the `RowLayout` holding `createLoginCheck` and the `ColumnLayout { visible: createLoginCheck.checked ... }`) so the App-role + password are always shown. The inner `ColumnLayout` block becomes:

```qml
            ColumnLayout {
                id: loginCol
                anchors.fill: parent
                anchors.margins: dp(Constants.space3)
                spacing: dp(Constants.space2)

                Text {
                    text: qsTr("App login")
                    color: Constants.textPrimary
                    font.pixelSize: sp(Constants.fsBody)
                    font.bold: true
                }

                RowLayout {
                    Layout.fillWidth: true
                    spacing: dp(Constants.space2)
                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: dp(4)
                        Text { text: "App role"; color: Constants.textSecondary; font.pixelSize: sp(Constants.fsSmall); font.bold: true }
                        AppComboBox {
                            id: appRoleCombo
                            Layout.fillWidth: true
                            model: ["Staff", "Manager", "Admin"]
                            font.pixelSize: sp(Constants.fsBody)
                        }
                    }
                }

                AuthPasswordField {
                    id: loginPasswordField
                    Layout.fillWidth: true
                    label: "Temporary password"
                    placeholderText: "min 6 characters"
                }
            }
```

(Removes the `QQC.CheckBox { id: createLoginCheck }` and the `visible: createLoginCheck.checked` binding entirely.)

- [ ] **Step 2: Drop the checkbox reset in `onOpened`**

In `onOpened` (~line 30), remove `createLoginCheck.checked = false` from the reset line:

```qml
        loginPasswordField.text = ""
        appRoleCombo.currentIndex = 0; deptCombo.currentIndex = 0; statusCombo.currentIndex = 0
```

(Delete the `createLoginCheck.checked = false` token only; keep the rest of that line intact.)

- [ ] **Step 3: Make password validation unconditional in `trySubmit`**

Replace the conditional password check (~line 230):

```qml
        if (!loginPasswordField.text || loginPasswordField.text.length < 6)
            errs.push("Login password ≥ 6 chars")
```

(was wrapped in `if (createLoginCheck.checked) { ... }` — remove that wrapper so it always runs.)

- [ ] **Step 4: Always set `createLogin: true` and always take the provision path**

In the payload (~line 249) change `createLogin: createLoginCheck.checked` to `createLogin: true`. Then replace the `if (createLoginCheck.checked) { ... } staffCreated(payload) ... ` tail (~lines 254–277) with the always-provision branch (the listener is armed BEFORE emitting — see memory `sync_signal_listener_arm_first`):

```qml
        var payload = {
            name: nameField.text,
            email: emailField.text,
            phone: phoneField.text,
            role: roleField.text,
            department: deptCombo.currentText,
            joinDate: joinPicker.date,
            status: statusCombo.currentText.toLowerCase().replace(" ", "_"),
            salary: sal,
            createLogin: true,
            loginPassword: loginPasswordField.text,
            appRole: appRoleCombo.currentText.toLowerCase()
        }

        // Login is mandatory. Arm the result listener BEFORE emitting — pre-Blaze
        // provisioning resolves SYNCHRONOUSLY (Gateway.provisioningAvailable=false
        // → "provisioning-unavailable" notice), and a late-armed listener drops it,
        // leaving the sheet stuck open. The Connections block closes the sheet on
        // success / shows the error on failure.
        _provisioning = true
        busy = true
        staffCreated(payload)
        return
    }
```

- [ ] **Step 5: Re-read the graceful-degrade path (no code, confirm)**

Confirm `AuthService` maps `provisioning-unavailable` to a friendly message and emits `memberOperationSucceeded` (success notice) — so with `Gateway.provisioningAvailable === false` the staff record is still added and the sheet closes (not a hard error). If instead it emits `authFailed` for the unavailable case, the dialog shows that text and stays open — acceptable per spec, but note it during verification. (`qml/model/AuthService.qml` `provisionStaffCredentials` + `_mapProvisionError`.)

- [ ] **Step 6: Run the existing AddStaff test (regression guard)**

```bash
QT_FORCE_STDERR_LOGGING=1 QT_LOGGING_TO_CONSOLE=1 \
  PATH="/c/Felgo/Felgo/mingw_64/bin:$PATH" \
  "C:/Felgo/Felgo/mingw_64/bin/qmltestrunner.exe" -platform offscreen -input tests/tst_AddStaffSyncClose.qml
```
Expected: PASS (the arm-before-emit ordering is preserved).

- [ ] **Step 7: Manually verify (device or desktop run)**

Open Add Staff. Expected: App-role + temporary-password always visible, no checkbox. Submit with blank/short password → validation error. Submit with a valid password → (pre-Blaze) staff added + "coming soon / login provisioning" notice, sheet closes; no stuck-open, no hard crash.

- [ ] **Step 8: Commit**

```bash
git add qml/pages/AddStaffDialog.qml
git commit -m "feat(staff): always-visible mandatory app-login fields (remove checkbox)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: Swipe between Analysis report views

**Files:**
- Modify: `qml/pages/SalesPage.qml` (add `_stepViewMode(dir)` near the other page helpers ~line 130; wrap the `AppScrollView` content with a horizontal swipe recognizer ~lines 285–290)

**Interfaces:**
- Consumes: existing `_viewMode`, `_MODE_*` constants, `canViewFinancials`.
- Produces: `function _stepViewMode(dir)` — `dir = -1` (swipe-left → previous) | `+1` (swipe-right → next); steps within the allowed mode list, clamps at both ends (no wrap).

- [ ] **Step 1: Add the mode-stepping helper**

In `qml/pages/SalesPage.qml`, after `_enforceStaffScope()` (~line 133), add:

```qml
    // Ordered list of view modes the current user may see — mirrors the
    // SegmentedPill gating: staff (no financials) see only Current + Sold.
    function _allowedViewModes() {
        return canViewFinancials
            ? [_MODE_VALUE, _MODE_PURCHASED, _MODE_CURRENT, _MODE_REVENUE, _MODE_SOLD, _MODE_PROFIT]
            : [_MODE_CURRENT, _MODE_SOLD]
    }

    // Step the view mode by a swipe. dir = -1 (swipe-left → previous view),
    // +1 (swipe-right → next view). Clamps at the ends — no wraparound.
    function _stepViewMode(dir) {
        var modes = _allowedViewModes()
        var cur = modes.indexOf(_viewMode)
        if (cur < 0) cur = 0
        var next = cur + dir
        if (next < 0 || next >= modes.length) return
        _viewMode = modes[next]
    }
```

- [ ] **Step 2: Add a horizontal swipe recognizer over the scroll content**

The report body is `AppScrollView` (a vertical `Flickable`; `qml/components/AppScrollView.qml`). A naïve `MouseArea` would steal vertical scroll, so use a `MouseArea` that only consumes a *dominantly-horizontal* drag and stays out of the Flickable's way otherwise. Inside the `AppScrollView` (sibling to / wrapping `ColumnLayout { id: stack }`), or as an overlay anchored to the scroll area, add:

```qml
    // Horizontal swipe → prev/next view. Only acts on a dominantly-horizontal
    // gesture; vertical drags fall through so the page still scrolls. Touch
    // gesture conflicts differ on Android vs desktop — MUST be device-verified
    // (see memory scrollview_touch_freedrag).
    MouseArea {
        anchors.top: header.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        visible: root._hasAnyData
        propagateComposedEvents: true
        preventStealing: false
        property real _pressX: 0
        property real _pressY: 0
        property bool _tracking: false
        onPressed: function(mouse) { _pressX = mouse.x; _pressY = mouse.y; _tracking = true; mouse.accepted = false }
        onReleased: function(mouse) {
            if (!_tracking) return
            _tracking = false
            var dx = mouse.x - _pressX
            var dy = mouse.y - _pressY
            var THRESH = dp(60)
            if (Math.abs(dx) > THRESH && Math.abs(dx) > Math.abs(dy) * 1.5) {
                // finger left (dx<0) = swipe-left = previous; finger right = next
                root._stepViewMode(dx < 0 ? -1 : +1)
            }
        }
    }
```

If during device verification this still blocks vertical scroll, fall back to a `DragHandler { yAxis.enabled: false }` / `SwipeArea` approach that only grabs horizontal drags — the contract (`_stepViewMode(dir)`) stays the same. Place the `MouseArea` so it does not cover interactive controls it would block (the SegmentedPill, filter chips, "See all" button); if conflicts arise, anchor it to only the hero/chart region rather than the whole scroll area.

- [ ] **Step 3: Manually verify on an Android device (required)**

- Financials user: swipe-left and swipe-right cycle Value↔Purchased↔Current↔Revenue↔Sold↔Profit in order; clamps (no movement) at Value (left edge) and Profit (right edge).
- Staff account: swipe only toggles Current↔Sold.
- Vertical scrolling of charts and lists still works.
- The SegmentedPill, period pill, filter chips, and "See all" button still tap normally.

- [ ] **Step 4: Run the full test suite (regression guard)**

Run each suite in `tests/` headlessly. Expected: all PASS.

- [ ] **Step 5: Commit**

```bash
git add qml/pages/SalesPage.qml
git commit -m "feat(analysis): swipe left/right to move between report views

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 5: Environment config helper + unit test (pure logic)

**Files:**
- Create: `qml/helper/EnvConfig.js` (`.pragma library`)
- Create: `tests/tst_EnvConfig.qml`

**Interfaces:**
- Produces:
  - `EnvConfig.envForStage(stage)` → `"prd" | "test" | "dev"`. Maps `"dev"→"dev"`, `"test"→"test"`, `"publish"→"prd"`; **any other / empty → `"prd"`** (fail-safe to production).
  - `EnvConfig.databaseIdForEnv(env)` → `"(default)"` for `"prd"`, else the env string (`"dev"`/`"test"`).
  - `EnvConfig.databaseIdForStage(stage)` → convenience: `databaseIdForEnv(envForStage(stage))`.

- [ ] **Step 1: Write the failing test**

Create `tests/tst_EnvConfig.qml`:

```qml
import QtQuick
import QtTest
import "../qml/helper/EnvConfig.js" as Env

TestCase {
    name: "EnvConfig"

    function test_stage_maps_to_env() {
        compare(Env.envForStage("dev"), "dev")
        compare(Env.envForStage("test"), "test")
        compare(Env.envForStage("publish"), "prd")
    }

    function test_unknown_or_empty_stage_falls_back_to_prd() {
        compare(Env.envForStage(""), "prd")
        compare(Env.envForStage("garbage"), "prd")
        compare(Env.envForStage(undefined), "prd")
        compare(Env.envForStage(null), "prd")
    }

    function test_env_maps_to_database_id() {
        compare(Env.databaseIdForEnv("prd"), "(default)")
        compare(Env.databaseIdForEnv("dev"), "dev")
        compare(Env.databaseIdForEnv("test"), "test")
    }

    function test_stage_to_database_id_end_to_end() {
        compare(Env.databaseIdForStage("publish"), "(default)")
        compare(Env.databaseIdForStage("dev"), "dev")
        compare(Env.databaseIdForStage("test"), "test")
        compare(Env.databaseIdForStage(""), "(default)")   // fail-safe → prd → default db
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
QT_FORCE_STDERR_LOGGING=1 QT_LOGGING_TO_CONSOLE=1 \
  PATH="/c/Felgo/Felgo/mingw_64/bin:$PATH" \
  "C:/Felgo/Felgo/mingw_64/bin/qmltestrunner.exe" -platform offscreen -input tests/tst_EnvConfig.qml
```
Expected: FAIL — `EnvConfig.js` does not exist / functions undefined.

- [ ] **Step 3: Implement `EnvConfig.js`**

Create `qml/helper/EnvConfig.js`:

```js
.pragma library

// Build-time environment resolution. PRODUCT_STAGE (CMake) → app stage string,
// surfaced to QML as the APP_STAGE context property, mapped here to an env and
// the Firestore database id. Pure + headless-testable (tests/tst_EnvConfig.qml).
//
// Mapping:                    fail-safe: unknown/empty stage → "prd" so a
//   dev     → dev   db dev    misconfigured/unflagged build talks to the real
//   test    → test  db test   production (default) database, never silently to
//   publish → prd   db (default)   an empty dev database.

function envForStage(stage) {
    var s = (stage === undefined || stage === null) ? "" : String(stage)
    if (s === "dev")     return "dev"
    if (s === "test")    return "test"
    if (s === "publish") return "prd"
    return "prd"
}

function databaseIdForEnv(env) {
    return env === "prd" ? "(default)" : env
}

function databaseIdForStage(stage) {
    return databaseIdForEnv(envForStage(stage))
}
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
QT_FORCE_STDERR_LOGGING=1 QT_LOGGING_TO_CONSOLE=1 \
  PATH="/c/Felgo/Felgo/mingw_64/bin:$PATH" \
  "C:/Felgo/Felgo/mingw_64/bin/qmltestrunner.exe" -platform offscreen -input tests/tst_EnvConfig.qml
```
Expected: PASS — 4 cases, 0 fail.

- [ ] **Step 5: Commit**

```bash
git add qml/helper/EnvConfig.js tests/tst_EnvConfig.qml
git commit -m "feat(env): pure stage→database-id helper + tests

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 6: Wire `PRODUCT_STAGE` from CMake into QML as `APP_STAGE`

**Files:**
- Modify: `CMakeLists.txt` (`target_compile_definitions` ~line 90)
- Modify: `main.cpp` (context-property registrations ~lines 22–43)

**Interfaces:**
- Consumes: existing `set(PRODUCT_STAGE "test")` (CMakeLists ~line 25).
- Produces: a QML context property `APP_STAGE` (string) readable from any QML — equal to `PRODUCT_STAGE`.

- [ ] **Step 1: Emit `PRODUCT_STAGE` as a compile definition**

In `CMakeLists.txt`, extend the existing `target_compile_definitions` (~line 90) to add the stage macro:

```cmake
target_compile_definitions(appBusinessManagement
    PRIVATE $<$<OR:$<CONFIG:Debug>,$<CONFIG:RelWithDebInfo>>:QT_QML_DEBUG>
    PRIVATE PRODUCT_STAGE_DEF="${PRODUCT_STAGE}")
```

- [ ] **Step 2: Expose it to QML in `main.cpp`**

In `main.cpp`, after the existing context-property registrations (after the `PkceGenerator` block ~line 43), add:

```cpp
    // Build-time environment stage (PRODUCT_STAGE from CMake) → QML context.
    // EnvConfig.js maps this to the Firestore database. Fallback "publish" keeps
    // an undefined macro on production (default db).
#ifndef PRODUCT_STAGE_DEF
#define PRODUCT_STAGE_DEF "publish"
#endif
    engine.rootContext()->setContextProperty(
        QStringLiteral("APP_STAGE"), QStringLiteral(PRODUCT_STAGE_DEF));
```

Add `#include <QQmlContext>` is already present (used by existing `setContextProperty` calls) — confirm at the top of `main.cpp`.

- [ ] **Step 3: Build to verify it compiles**

Build the project (the Build agent's command), e.g.:
```bash
cmake --build build
```
Expected: compiles cleanly; no macro/definition errors.

- [ ] **Step 4: Commit**

```bash
git add CMakeLists.txt main.cpp
git commit -m "feat(env): pass PRODUCT_STAGE to QML as APP_STAGE context property

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 7: Route Firestore through the env-selected `databaseId`

**Files:**
- Modify: `qml/model/FirebaseService.qml` (URL props ~lines 7–10; commit doc-name ~line 220)
- Modify: `qml/helper/Constants.qml` (legacy `firebaseDatabaseUrl` ~line 8)

**Interfaces:**
- Consumes: `APP_STAGE` context property (Task 6); `EnvConfig.envForStage` / `databaseIdForEnv` (Task 5).
- Produces: `FirebaseService.environment` (`"prd"|"test"|"dev"`) and `FirebaseService.databaseId` for the env badge (Task 8) and any consumer.

- [ ] **Step 1: Resolve env + databaseId, rebuild `databaseUrl`**

In `qml/model/FirebaseService.qml`, add the import at the top (after `import QtQuick`):

```qml
import "../helper/EnvConfig.js" as EnvConfig
```

Replace the `databaseUrl` block (~lines 9–10) and add env props:

```qml
    readonly property string projectId: "inventorymanager-48392"
    readonly property string apiKey: "AIzaSyAeA5Mb6ZmtKLOb3Oxw_n-dh62_qY0r4mA"

    // Build-time environment (APP_STAGE from CMake PRODUCT_STAGE). prd → the
    // existing (default) database; test/dev → named databases in the same
    // project. Single point of change — every get/put/patch/remove builds its
    // URL from databaseUrl/databaseId below, so all data access switches here.
    readonly property string environment: EnvConfig.envForStage(
        (typeof APP_STAGE !== "undefined" && APP_STAGE) ? APP_STAGE : "")
    readonly property string databaseId: EnvConfig.databaseIdForEnv(environment)
    readonly property string databaseUrl: "https://firestore.googleapis.com/v1/projects/"
                                          + projectId + "/databases/" + databaseId + "/documents"
```

- [ ] **Step 2: Route the commit doc-name through `databaseId`**

In `_buildCommitWrites` (~line 220), replace the hard-coded `(default)`:

```qml
            var docName = "projects/" + projectId + "/databases/" + databaseId + "/documents/"
                          + collectionPath + "/" + docId
```

(The `:commit` URL at ~line 279 already builds off `databaseUrl`, so it now points at the right database automatically — verify by reading.)

- [ ] **Step 3: Retire the misleading legacy `Constants.firebaseDatabaseUrl`**

`Constants.qml:8` is a second hard-coded `(default)` URL with **no code consumers** (grep-verified). To stop a future caller wiring up a prod-only URL, replace it with a pointer comment:

```qml
    // ── Backend ──────────────────────────────────────────────────────────────
    // The live Firestore base URL is environment-aware and owned by
    // FirebaseService.databaseUrl (resolved from PRODUCT_STAGE via EnvConfig.js).
    // Do NOT hard-code a database URL here — it would bypass dev/test/prd routing.
```

(If a grep at implementation time finds any consumer, instead bind it to `FirebaseService.databaseUrl` rather than deleting.)

- [ ] **Step 4: Verify no remaining hard-coded `(default)` data paths**

```bash
grep -rn "databases/(default)" qml/ CMakeLists.txt main.cpp
```
Expected: no matches in `qml/model/FirebaseService.qml` data paths (the only acceptable occurrence of the literal string `(default)` is inside `EnvConfig.js` / FirebaseService's `databaseId` ternary). `Gateway.qml` server URLs are out of scope (documented follow-up).

- [ ] **Step 5: Run the full test suite (regression guard)**

Run each suite in `tests/` headlessly. Expected: all PASS (incl. `tst_EnvConfig`).

- [ ] **Step 6: Commit**

```bash
git add qml/model/FirebaseService.qml qml/helper/Constants.qml
git commit -m "feat(env): route all Firestore traffic through env-selected database

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 8: Non-prod environment badge

**Files:**
- Modify: `qml/pages/SalesPage.qml` GlassHeader subtitle, OR `qml/pages/ProfileSettingsDialog.qml` Account card — pick the Account card (always reachable, unobtrusive).

**Interfaces:**
- Consumes: `FirebaseService.environment` (Task 7).
- Produces: a visible `DEV` / `TEST` badge, hidden when `prd`.

- [ ] **Step 1: Add the badge to the Profile Account card**

In `qml/pages/ProfileSettingsDialog.qml`, inside the read-only Account `ColumnLayout { id: accountCol ... }` (~line 69), add a small env pill that is hidden on production:

```qml
                // Build environment — only shown on non-production builds so a
                // dev/test build is unmistakable (prd hides it entirely).
                Rectangle {
                    visible: FirebaseService.environment !== "prd"
                    Layout.alignment: Qt.AlignLeft
                    radius: dp(Constants.radiusPill)
                    color: Constants.warn
                    implicitHeight: dp(22)
                    implicitWidth: envBadgeText.implicitWidth + dp(20)
                    Text {
                        id: envBadgeText
                        anchors.centerIn: parent
                        text: FirebaseService.environment.toUpperCase()   // "DEV" | "TEST"
                        color: Constants.textOnBrand
                        font.pixelSize: sp(Constants.fsCaption)
                        font.bold: true
                    }
                }
```

Confirm `import "../model"` is present in `ProfileSettingsDialog.qml` (it is — used for `AuthStore`/`AuthService`), so `FirebaseService` resolves.

- [ ] **Step 2: Manually verify (build per env)**

- Build with `PRODUCT_STAGE "dev"` → open Profile → `DEV` pill shown.
- Build with `PRODUCT_STAGE "publish"` → no pill.

- [ ] **Step 3: Commit**

```bash
git add qml/pages/ProfileSettingsDialog.qml
git commit -m "feat(env): show DEV/TEST badge on non-production builds

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 9: Backend setup runbook + end-to-end env verification

**Files:**
- Create/append: `README.md` (env section)

**Interfaces:** none (operational + docs).

- [ ] **Step 1: Document the one-time Firestore database creation**

> **Correction (2026-07-10):** the scaffold below (written when this plan was drafted) uses
> stale values — database id `dev` (invalid, <4 chars; actual id is `dev1`) and region
> `asia-southeast1` (wrong; the project's actual region, confirmed via `gcloud firestore
> databases list`, is `asia-south1`). The version actually shipped into `README.md` uses the
> corrected `dev1`/`asia-south1` values — treat `README.md` as authoritative, not this excerpt.

Append an "Environments" section to `README.md` with the exact `gcloud` commands (project `inventorymanager-48392`, region `asia-southeast1`):

```markdown
## Environments (dev / test / prd)

The app selects its Firestore database at **build time** from `PRODUCT_STAGE` in
`CMakeLists.txt`:

| PRODUCT_STAGE | env  | Firestore database |
|---------------|------|--------------------|
| `dev`         | dev  | `dev`              |
| `test`        | test | `test`             |
| `publish`     | prd  | `(default)`        |

Unknown/unset stage falls back to **prd** (`(default)`), so a misconfigured
release never points at an empty dev database.

### One-time backend setup (per non-default database)

```bash
gcloud firestore databases create --database=dev  --location=asia-southeast1 --type=firestore-native
gcloud firestore databases create --database=test --location=asia-southeast1 --type=firestore-native
```

Then apply the same security rules (`FIRESTORE_RULES.md`) to each database
(Firebase console → Firestore → select database → Rules, or
`firebase deploy --only firestore:rules` targeting each database).

Auth users, Storage, and Cloud Functions are **shared** across environments —
only the Firestore database differs. `dev`/`test` start empty (MVP fresh-data).

> **Follow-up (not yet built):** the Cloud Functions gateway (`Gateway.qml`)
> still writes to `(default)` server-side; make it env-aware when Blaze + the
> functions are deployed.
```

- [ ] **Step 2: End-to-end verification (dev build)**

Set `set(PRODUCT_STAGE "dev")` in `CMakeLists.txt`, create the `dev` database (Step 1), build, run. Create a product. Expected: it appears in the `dev` database (Firebase console) and **not** in `(default)`. The `DEV` badge shows in Profile.

- [ ] **Step 3: End-to-end verification (publish build)**

Set `set(PRODUCT_STAGE "publish")`, build, run. Expected: existing production data is present (reads `(default)`); no env badge.

- [ ] **Step 4: Restore the working stage and commit the runbook**

Set `PRODUCT_STAGE` back to the team's working value (e.g. `dev` or `test`).

```bash
git add README.md CMakeLists.txt
git commit -m "docs: environment setup runbook (dev/test/prd Firestore databases)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 10: Update AGENTS.md and SKILLS.md

**Files:**
- Modify: `AGENTS.md` (Feature Status table; Build agent §1; Compliance §8 follow-up; Store agent §5)
- Modify: `SKILLS.md` (new skill entry for the env model; note new-order price + report swipe)

**Interfaces:** none (docs).

- [ ] **Step 1: Update `AGENTS.md`**

- In **Current Feature Status**, add rows: `Editable price in New Order dialog ✅`, `Swipe between Analysis views ✅`, `Add Product advanced open by default ✅`, `Mandatory always-visible staff login fields ✅`, `dev/test/prd Firestore environments (build-time) ✅`.
- In **§1 Build & Infrastructure Agent**, add a bullet: `PRODUCT_STAGE (dev|test|publish) selects the Firestore database via PRODUCT_STAGE_DEF → APP_STAGE → EnvConfig.js; publish→(default), dev/test→named DBs.`
- In **§5 Store & Firebase Agent**, add: `FirebaseService.databaseUrl/databaseId are environment-aware (EnvConfig.js); never hard-code databases/(default).`
- In **§8 Compliance & Audit Agent**, add a follow-up line: `Cloud Functions gateway still writes to (default) server-side — make env-aware when Blaze lands.`

- [ ] **Step 2: Update `SKILLS.md`**

Add **Skill 30: Build-time environments (dev/test/prd)** describing: `PRODUCT_STAGE` → `PRODUCT_STAGE_DEF` (CMake) → `APP_STAGE` (context property, main.cpp) → `EnvConfig.js` (`envForStage`/`databaseIdForEnv`, fail-safe prd) → `FirebaseService.databaseId`; named Firestore databases; shared Auth/Storage/Functions; `tests/tst_EnvConfig.qml`. Add one-liners to existing skills noting the New Order dialog now has an editable per-line price field (mirrors OrderDetailDialog) and the Analysis page supports swipe-left/right view navigation (`_stepViewMode`).

- [ ] **Step 3: Commit**

```bash
git add AGENTS.md SKILLS.md
git commit -m "docs: AGENTS/SKILLS for env model, new-order price, report swipe

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Self-Review

**Spec coverage:**
- Feature 1 (new-order price) → Task 2. ✅
- Feature 2 (report swipe, left=prev/right=next, gating, no-wrap, device-verify) → Task 4. ✅
- Feature 3 (advanced open) → Task 1. ✅
- Feature 4 (always-visible mandatory staff login + Blaze graceful-degrade) → Task 3. ✅
- Feature 5 (named DBs, PRODUCT_STAGE dev/test/publish, fail-safe prd, single-point switch, env badge, CF follow-up, backend runbook) → Tasks 5–9. ✅
- Docs update (AGENTS/SKILLS/README) → Tasks 9 (README) + 10. ✅

**Type/name consistency:** `_setLinePrice(idx, value)` (Task 2), `_stepViewMode(dir)` / `_allowedViewModes()` (Task 4), `EnvConfig.envForStage`/`databaseIdForEnv`/`databaseIdForStage` (Task 5, used identically in Tasks 7), `APP_STAGE` (Task 6 produces → Tasks 7 consumes), `PRODUCT_STAGE_DEF` (Task 6), `FirebaseService.environment`/`databaseId` (Task 7 produces → Task 8 consumes). All aligned.

**Placeholder scan:** No TBD/TODO; every code step shows full code; the two device-only verifications (swipe gesture, per-env build) are explicit manual steps with concrete expected behavior, as the spec requires.

**Notes:** Swipe stepping is verified by device test (Task 4 Step 3) rather than a headless unit test — page QML can't load under `qmltestrunner`, the gesture itself mandates device verification, and the stepping is a clamp over a fixed array. The data-safety-critical env mapping (Task 5) gets the rigorous unit test.
