# Desktop Shell Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the desktop navigation shell (sidebar + top bar) and wire it into the existing
Felgo app so Owner/Admin/Manager get a persistent-sidebar experience above the desktop-shell
breakpoint, while mobile's existing bottom-tab navigation is untouched below it.

**Architecture:** New `qml/desktop/` components (`Sidebar`, `TopBar`) compose into a chrome layer
that sits beside the existing `Navigation { id: navigation }` item rather than replacing or
reparenting it — `navigation` keeps rendering Dashboard/Orders/Inventory/Analysis exactly as it
does today, just resized to leave room for the sidebar and top bar. Section-to-navigation mapping
logic is extracted into a pure `.js` module (`DesktopNav.js`) so it's unit-testable independent of
the QML wiring, following the existing `qml/helper/StaffScope.js` pattern in this codebase.

**Tech Stack:** Qt 6 / QML (Felgo), Qt Quick Test (`qmltestrunner`) — same as the rest of this repo.

## Global Constraints

- Reuse `qml/helper/Constants.qml` tokens directly — no new color/spacing/radius values invented
  (per `docs/superpowers/specs/2026-07-14-desktop-ux-design.md` §4).
- Match the existing test style exactly: plain `TestCase` + `compare()` for `.js` logic modules
  (see `tests/tst_StaffScope.qml`); `TestCase` + `SignalSpy` + `findChild` for QML component
  behavior. No new test framework or helper library.
- No build or run in this session — Taher verifies locally (no Qt/Felgo toolchain in this
  container; confirmed in `AGENTS.md`). Every task ends with a "Verify" step describing exactly
  what Taher should run and expect, not an automated execution by me.
- Nav visibility is uniform across Owner/Admin/Manager (spec §2) — this plan does not add
  role-gating to the sidebar itself. `canViewFinancials`-style permission gating happens inside
  individual sections in later plans, not here.
- `isDesktopShell` is width-based only, matching the existing `compact` property's pattern
  (`qml/Main.qml:20`) — no `Qt.platform.os` check, so a resized desktop window degrades gracefully
  to the mobile shell instead of breaking.

---

## Task 1: Sidebar component

**Files:**
- Create: `qml/desktop/Sidebar.qml`
- Test: `tests/tst_Sidebar.qml`
- Modify: `qml/helper/Constants.qml:73` (add `desktopShellBreakpoint` next to the existing
  `compactBreakpoint: 520`)
- Modify: `qml/Main.qml:20` (add `isDesktopShell` next to the existing `compact` property)

**Interfaces:**
- Produces: `Sidebar` component with `currentSection: string` property (default `"dashboard"`),
  `items: var` (readonly array of `{key, label}`), `function selectSection(key)`, and
  `signal sectionSelected(section: string)`. Task 3 consumes all of these.
- Produces: `Constants.desktopShellBreakpoint` (int, dp units) and `app.isDesktopShell` (bool).
  Tasks 2 and 3 consume `app.isDesktopShell`.

- [ ] **Step 1: Write the failing tests**

Create `tests/tst_Sidebar.qml`:

```qml
import QtQuick
import QtTest
import "../qml/desktop"

TestCase {
    id: testCase
    name: "Sidebar"

    Sidebar {
        id: sidebar
        width: 216
        height: 400
    }

    SignalSpy {
        id: selectedSpy
        target: sidebar
        signalName: "sectionSelected"
    }

    function init() {
        sidebar.currentSection = "dashboard"
        selectedSpy.clear()
    }

    function test_default_current_section_is_dashboard() {
        compare(sidebar.currentSection, "dashboard")
    }

    function test_all_seven_sections_present() {
        compare(sidebar.items.length, 7)
    }

    function test_selectSection_updates_currentSection() {
        sidebar.selectSection("orders")
        compare(sidebar.currentSection, "orders")
    }

    function test_selectSection_emits_sectionSelected_with_key() {
        sidebar.selectSection("analysis")
        compare(selectedSpy.count, 1)
        compare(selectedSpy.signalArguments[0][0], "analysis")
    }

    function test_selectSection_same_section_does_not_reemit() {
        sidebar.selectSection("dashboard") // already the default from init()
        compare(selectedSpy.count, 0)
    }

    function test_clicking_orders_item_selects_it() {
        var item = findChild(sidebar, "sidebarItem_orders")
        verify(item !== null)
        mouseClick(item)
        compare(sidebar.currentSection, "orders")
        compare(selectedSpy.count, 1)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `qmltestrunner -input tests/tst_Sidebar.qml`
Expected: FAIL — `Sidebar` is not a type (file doesn't exist yet).

- [ ] **Step 3: Add the breakpoint constant**

Modify `qml/helper/Constants.qml`, immediately after line 73
(`readonly property int compactBreakpoint: 520`):

```qml
    // Below this width, the desktop sidebar shell gives way to the mobile
    // bottom-tab shell — see qml/desktop/. Distinct from compactBreakpoint,
    // which governs in-page layout density, not top-level navigation chrome.
    readonly property int desktopShellBreakpoint: 1000
```

- [ ] **Step 4: Add the isDesktopShell property**

Modify `qml/Main.qml`, immediately after line 20
(`property bool compact: width < dp(Constants.compactBreakpoint)`):

```qml
    property bool isDesktopShell: width >= dp(Constants.desktopShellBreakpoint)
```

- [ ] **Step 5: Write the minimal implementation**

Create `qml/desktop/Sidebar.qml`:

```qml
import QtQuick
import "../helper"

Item {
    id: root

    property string currentSection: "dashboard"

    readonly property var items: [
        { key: "dashboard", label: qsTr("Dashboard") },
        { key: "orders",    label: qsTr("Orders") },
        { key: "inventory", label: qsTr("Inventory") },
        { key: "analysis",  label: qsTr("Analysis") },
        { key: "staff",     label: qsTr("Staff") },
        { key: "activity",  label: qsTr("Activity") },
        { key: "settings",  label: qsTr("Settings") }
    ]

    signal sectionSelected(string section)

    function selectSection(key) {
        if (currentSection === key)
            return
        currentSection = key
        sectionSelected(key)
    }

    Rectangle {
        anchors.fill: parent
        color: Constants.cardBg
        border.color: Constants.borderColor
        border.width: 1
    }

    Column {
        id: list
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.margins: dp(8)
        spacing: dp(2)

        Repeater {
            model: root.items

            delegate: Rectangle {
                id: delegate
                required property var modelData
                objectName: "sidebarItem_" + modelData.key
                width: list.width
                height: dp(36)
                radius: Constants.radiusSm
                color: modelData.key === root.currentSection
                       ? Qt.rgba(Constants.brand1.r, Constants.brand1.g, Constants.brand1.b, 0.12)
                       : "transparent"

                Text {
                    anchors.left: parent.left
                    anchors.leftMargin: dp(10)
                    anchors.verticalCenter: parent.verticalCenter
                    text: delegate.modelData.label
                    font.pixelSize: dp(13)
                    color: delegate.modelData.key === root.currentSection
                           ? Constants.brand1
                           : Constants.textSecondary
                }

                MouseArea {
                    anchors.fill: parent
                    onClicked: root.selectSection(delegate.modelData.key)
                }
            }
        }
    }
}
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `qmltestrunner -input tests/tst_Sidebar.qml`
Expected: PASS — 6/6 tests green.

- [ ] **Step 7: Commit**

```bash
git add qml/desktop/Sidebar.qml tests/tst_Sidebar.qml qml/helper/Constants.qml qml/Main.qml
git commit -m "desktop: add Sidebar component and desktop-shell breakpoint"
```

---

## Task 2: TopBar component

**Files:**
- Create: `qml/desktop/TopBar.qml`
- Test: `tests/tst_TopBar.qml`

**Interfaces:**
- Consumes: nothing from Task 1.
- Produces: `TopBar` component with `workspaceName`, `userName`, `userRole` (all `string`,
  default `""`) and `signal searchRequested(query: string)`. Task 3 consumes all of these. Search
  is wired to emit the signal in this task; nothing consumes it yet — that's out of scope until a
  later plan actually builds search. Not a placeholder: the field is real, working UI, the
  *handler* for the signal just doesn't exist yet.

- [ ] **Step 1: Write the failing tests**

Create `tests/tst_TopBar.qml`:

```qml
import QtQuick
import QtTest
import "../qml/desktop"

TestCase {
    id: testCase
    name: "TopBar"

    TopBar {
        id: topBar
        width: 700
        workspaceName: "Riverside store"
        userName: "Taher"
        userRole: "owner"
    }

    SignalSpy {
        id: searchSpy
        target: topBar
        signalName: "searchRequested"
    }

    function init() {
        searchSpy.clear()
    }

    function test_properties_are_exposed_as_set() {
        compare(topBar.workspaceName, "Riverside store")
        compare(topBar.userName, "Taher")
        compare(topBar.userRole, "owner")
    }

    function test_search_field_exists() {
        var field = findChild(topBar, "topBarSearchField")
        verify(field !== null)
    }

    function test_accepting_search_emits_searchRequested() {
        var field = findChild(topBar, "topBarSearchField")
        field.text = "priya"
        field.accepted()
        compare(searchSpy.count, 1)
        compare(searchSpy.signalArguments[0][0], "priya")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `qmltestrunner -input tests/tst_TopBar.qml`
Expected: FAIL — `TopBar` is not a type.

- [ ] **Step 3: Write the minimal implementation**

Create `qml/desktop/TopBar.qml`:

```qml
import QtQuick
import QtQuick.Controls
import "../helper"

Item {
    id: root
    height: dp(46)

    property string workspaceName: ""
    property string userName: ""
    property string userRole: ""

    signal searchRequested(string query)

    Rectangle {
        anchors.fill: parent
        color: Constants.cardBg
        border.color: Constants.borderColor
        border.width: 1
    }

    Row {
        anchors.left: parent.left
        anchors.leftMargin: dp(14)
        anchors.verticalCenter: parent.verticalCenter
        spacing: dp(14)

        Text {
            anchors.verticalCenter: parent.verticalCenter
            text: "Karobar"
            font.pixelSize: dp(13)
            font.bold: true
            color: Constants.textPrimary
        }

        Text {
            anchors.verticalCenter: parent.verticalCenter
            text: root.workspaceName
            font.pixelSize: dp(12)
            color: Constants.textMuted
        }

        TextField {
            id: searchField
            objectName: "topBarSearchField"
            anchors.verticalCenter: parent.verticalCenter
            width: dp(230)
            placeholderText: qsTr("Search orders, products, staff")
            font.pixelSize: dp(12)
            onAccepted: root.searchRequested(text)
        }
    }

    Row {
        anchors.right: parent.right
        anchors.rightMargin: dp(14)
        anchors.verticalCenter: parent.verticalCenter
        spacing: dp(6)

        Rectangle {
            width: dp(20)
            height: dp(20)
            radius: dp(10)
            color: Qt.rgba(Constants.brand1.r, Constants.brand1.g, Constants.brand1.b, 0.15)

            Text {
                anchors.centerIn: parent
                text: root.userName.length > 0 ? root.userName.charAt(0).toUpperCase() : ""
                font.pixelSize: dp(11)
                color: Constants.brand1
            }
        }

        Text {
            anchors.verticalCenter: parent.verticalCenter
            text: root.userRole.length > 0 ? root.userName + " · " + root.userRole : root.userName
            font.pixelSize: dp(12)
            color: Constants.textPrimary
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `qmltestrunner -input tests/tst_TopBar.qml`
Expected: PASS — 3/3 tests green.

- [ ] **Step 5: Commit**

```bash
git add qml/desktop/TopBar.qml tests/tst_TopBar.qml
git commit -m "desktop: add TopBar component"
```

---

## Task 3: DesktopShell composition and Main.qml integration

**Files:**
- Create: `qml/desktop/DesktopNav.js`
- Test: `tests/tst_DesktopNav.qml`
- Create: `qml/desktop/DesktopShell.qml`
- Modify: `qml/Main.qml:389` (add explicit anchors to the existing `Navigation { id: navigation }`)
- Modify: `qml/Main.qml:563-566` (add `isDesktopShell` guard to `FloatingTabbar.visible`)
- Modify: `qml/Main.qml:585` (insert `DesktopShell` instantiation after `FloatingTabbar` closes)

**Interfaces:**
- Consumes: `Sidebar` and `TopBar` (Tasks 1–2); `app.isDesktopShell` (Task 1).
- Consumes existing app internals confirmed by direct inspection this session: `navigation`
  (`Navigation` item, `currentIndex` 0=dashboard/1=orders/2=inventory/3=analysis — confirmed via
  the existing `onNavigateToOrders: navigation.currentIndex = 1` handlers in `Main.qml`),
  `staffPageOverlay`, `activityPageOverlay`, `profilePage` (each has `.open()`/`.visible`,
  confirmed via the existing `_handleBack()` dialog-closing logic in `Main.qml`).
- Produces: `DesktopShell` with `sidebarWidth`/`topBarHeight` (read-only, px) that
  `qml/Main.qml`'s modified `navigation` anchors consume as margins.

- [ ] **Step 1: Write the failing test for the pure-logic module**

Create `tests/tst_DesktopNav.qml`:

```qml
import QtQuick
import QtTest
import "../qml/desktop/DesktopNav.js" as DesktopNav

TestCase {
    name: "DesktopNav"

    function test_navigationIndexForSection_dashboard() {
        compare(DesktopNav.navigationIndexForSection("dashboard"), 0)
    }
    function test_navigationIndexForSection_orders() {
        compare(DesktopNav.navigationIndexForSection("orders"), 1)
    }
    function test_navigationIndexForSection_inventory() {
        compare(DesktopNav.navigationIndexForSection("inventory"), 2)
    }
    function test_navigationIndexForSection_analysis() {
        compare(DesktopNav.navigationIndexForSection("analysis"), 3)
    }
    function test_navigationIndexForSection_overlay_section_returns_negative_one() {
        compare(DesktopNav.navigationIndexForSection("staff"), -1)
    }
    function test_navigationIndexForSection_unknown_section_returns_negative_one() {
        compare(DesktopNav.navigationIndexForSection("bogus"), -1)
    }
    function test_overlayIdForSection_staff() {
        compare(DesktopNav.overlayIdForSection("staff"), "staffPageOverlay")
    }
    function test_overlayIdForSection_activity() {
        compare(DesktopNav.overlayIdForSection("activity"), "activityPageOverlay")
    }
    function test_overlayIdForSection_settings() {
        compare(DesktopNav.overlayIdForSection("settings"), "profilePage")
    }
    function test_overlayIdForSection_stack_section_returns_empty_string() {
        compare(DesktopNav.overlayIdForSection("dashboard"), "")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `qmltestrunner -input tests/tst_DesktopNav.qml`
Expected: FAIL — module not found.

- [ ] **Step 3: Write the minimal implementation**

Create `qml/desktop/DesktopNav.js`:

```js
.pragma library

var STACK_SECTIONS = {
    "dashboard": 0,
    "orders": 1,
    "inventory": 2,
    "analysis": 3
}

var OVERLAY_SECTIONS = {
    "staff": "staffPageOverlay",
    "activity": "activityPageOverlay",
    "settings": "profilePage"
}

function navigationIndexForSection(section) {
    if (Object.prototype.hasOwnProperty.call(STACK_SECTIONS, section))
        return STACK_SECTIONS[section]
    return -1
}

function overlayIdForSection(section) {
    if (Object.prototype.hasOwnProperty.call(OVERLAY_SECTIONS, section))
        return OVERLAY_SECTIONS[section]
    return ""
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `qmltestrunner -input tests/tst_DesktopNav.qml`
Expected: PASS — 10/10 tests green.

- [ ] **Step 5: Commit the logic module**

```bash
git add qml/desktop/DesktopNav.js tests/tst_DesktopNav.qml
git commit -m "desktop: add DesktopNav section-routing logic module"
```

- [ ] **Step 6: Write DesktopShell.qml**

Create `qml/desktop/DesktopShell.qml`:

```qml
import QtQuick
import "../helper"
import "DesktopNav.js" as DesktopNav

Item {
    id: root

    readonly property alias sidebarWidth: sidebar.width
    readonly property alias topBarHeight: topBar.height

    property var navigationTarget
    property var staffOverlay
    property var activityOverlay
    property var profileOverlay
    property string workspaceName: ""
    property string userName: ""
    property string userRole: ""
    property string currentSection: "dashboard"

    TopBar {
        id: topBar
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        workspaceName: root.workspaceName
        userName: root.userName
        userRole: root.userRole
    }

    Sidebar {
        id: sidebar
        width: dp(180)
        anchors.top: topBar.bottom
        anchors.bottom: parent.bottom
        anchors.left: parent.left
        currentSection: root.currentSection
        onSectionSelected: function(section) { root._goTo(section) }
    }

    function _goTo(section) {
        currentSection = section
        var stackIndex = DesktopNav.navigationIndexForSection(section)
        if (stackIndex >= 0) {
            if (navigationTarget)
                navigationTarget.currentIndex = stackIndex
            return
        }
        var overlayId = DesktopNav.overlayIdForSection(section)
        if (overlayId === "staffPageOverlay" && staffOverlay) staffOverlay.open()
        else if (overlayId === "activityPageOverlay" && activityOverlay) activityOverlay.open()
        else if (overlayId === "profilePage" && profileOverlay) profileOverlay.open()
    }
}
```

No dedicated `tst_DesktopShell.qml` — `DesktopShell` is integration glue over `navigationTarget`/
`staffOverlay`/etc., which are themselves complex Felgo objects (`Navigation`, full-screen page
overlays) unavailable in isolation outside `Main.qml`. Its actual logic (`_goTo`) delegates
entirely to `DesktopNav.js`, already covered by Step 1–4's tests. Verified for real via Step 8's
manual check, not a substitute for a unit test — flagged here explicitly rather than silently
skipped.

- [ ] **Step 7: Modify Main.qml**

**7a.** Add explicit anchors to `navigation`, immediately after line 389
(`footerView: Item { width: 1; height: 0 }`), before the blank line that precedes the first
`NavigationItem`:

```qml

        anchors.top: parent.top
        anchors.bottom: parent.bottom
        anchors.right: parent.right
        anchors.left: parent.left
        anchors.topMargin: app.isDesktopShell ? desktopShell.topBarHeight : 0
        anchors.leftMargin: app.isDesktopShell ? desktopShell.sidebarWidth : 0
```

**7b.** Modify `FloatingTabbar`'s `visible` property (currently lines 563–566):

Old:
```qml
        visible: navigation.visible
                 && !profilePage.visible
                 && !staffPageOverlay.visible
                 && !activityPageOverlay.visible
```

New:
```qml
        visible: navigation.visible
                 && !profilePage.visible
                 && !staffPageOverlay.visible
                 && !activityPageOverlay.visible
                 && !app.isDesktopShell
```

**7c.** Insert `DesktopShell` immediately after the `FloatingTabbar { ... }` block's closing brace
(currently line 585), before `LoginPage { id: loginPage ...`:

```qml

    DesktopShell {
        id: desktopShell
        anchors.fill: parent
        visible: app.isDesktopShell && navigation.visible
        navigationTarget: navigation
        staffOverlay: staffPageOverlay
        activityOverlay: activityPageOverlay
        profileOverlay: profilePage
        workspaceName: AuthStore.tenantName
        userName: AuthStore.displayName
        userRole: AuthStore.role
        currentSection: DesktopNav.navigationIndexForSection === undefined
                         ? "dashboard" : desktopShell.currentSection
    }
```

The last line above is wrong as literally written — it references itself circularly. Correct
version (`currentSection` should simply track `navigation.currentIndex` when that's what changed
it, e.g. via the Dashboard tile shortcuts at lines 413–415, so the sidebar highlight stays in sync
even when navigation changed via a route other than clicking the sidebar itself):

```qml
        currentSection: {
            switch (navigation.currentIndex) {
                case 0: return "dashboard"
                case 1: return "orders"
                case 2: return "inventory"
                case 3: return "analysis"
                default: return desktopShell.currentSection
            }
        }
```

**Note on `AuthStore.tenantName`/`displayName`/`role`:** these three property names are inferred
from naming convention (`AuthStore.isAuthenticated`, `AuthStore.tenantId`, `AuthStore.canViewFinancials`,
`AuthStore.currentStaffId` are all confirmed to exist, from lines 379, 405–406 and the RBAC work
described in `AGENTS.md`) but I have not directly confirmed these three exact names against
`AuthStore`'s source. **Step 7d below is a real verification step for this, not a placeholder.**

- [ ] **Step 7d: Confirm AuthStore's actual property names before this step is considered done**

Run: `grep -n "property.*tenant\|property.*display\|property.*role" qml/model/AuthStore.qml` (or
wherever `AuthStore` is defined — confirm the path too, it wasn't directly opened this session).
Update the three property bindings in Step 7c to match whatever this returns. If no exact
equivalent exists for one of them, use the closest existing property and note the gap rather than
inventing a new `AuthStore` property in this task (that's out of scope for a shell/navigation
plan).

- [ ] **Step 8: Manual verification (Taher, on the Windows/Felgo build — not run in this session)**

1. Build and run via the `felgo-mingw-debug` preset.
2. Resize the window above 1000px wide (in dp) — sidebar and top bar should appear, bottom
   floating tab bar should disappear.
3. Click each of the 4 stack sections (Dashboard/Orders/Inventory/Analysis) in the sidebar —
   page content should switch, same pages as mobile, now with room on the left for the sidebar.
4. Click Staff, Activity, Settings — each should still open as a full-screen overlay (same as
   mobile today; not yet redesigned to stay within the shell — that's Plans 5 and 7, not this one).
5. Resize below 1000px — shell should give way back to the mobile bottom-tab bar cleanly.
6. Run the full existing test suite once (`qmltestrunner`, no filter) to confirm nothing mobile
   broke — this plan didn't intend to touch any mobile-only code path, but confirm rather than
   assume.

- [ ] **Step 9: Commit**

```bash
git add qml/desktop/DesktopShell.qml qml/Main.qml
git commit -m "desktop: compose DesktopShell and wire into Main.qml"
```

---

## Self-Review

**Spec coverage:** This plan implements spec §5 (IA — the 7-item sidebar, top bar) and the
platform-detection groundwork §3 needs. It does **not** implement §6.1 (master-detail — no list
data yet, that's Plan 2/Orders), §6.2 (Analysis overview strip — Plan 3), or any of §7's
per-section pattern applications. That's intentional per the multi-plan breakdown Taher approved —
noting it here so the gap is explicit, not accidental.

**Placeholder scan:** No "TBD"/"TODO"/"implement later" anywhere above. The one open item (Step
7d, `AuthStore` property names) is a named, verifiable gap with an exact command to resolve it and
an explicit fallback instruction — not a vague placeholder. The self-corrected error in Step 7c
(the circular `currentSection` binding) was caught during this self-review and fixed inline, per
this section's own instructions, rather than left in.

**Type consistency:** `Sidebar.currentSection` (string) flows into `DesktopShell.currentSection`
(string) flows into the `switch` in Step 7c (string cases) — consistent. `sectionSelected(string)`
signal argument matches `DesktopNav.navigationIndexForSection(section)`'s string parameter —
consistent. `sidebarWidth`/`topBarHeight` are both `alias` properties reflecting real `dp()`-based
pixel dimensions, consumed as `anchors.*Margin` values in Step 7a, which expect plain numbers —
consistent (QML `dp()` returns a number, not a distinct unit type).

---

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-07-16-desktop-shell-foundation.md`. Two
execution options:

1. **Subagent-Driven (recommended)** — I dispatch a fresh subagent per task, review between tasks,
   fast iteration.
2. **Inline Execution** — Execute tasks in this session using `executing-plans`, batch execution
   with checkpoints.

Which approach?
