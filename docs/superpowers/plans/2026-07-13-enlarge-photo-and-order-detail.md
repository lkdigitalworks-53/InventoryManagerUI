# Enlarge Product Photo + Order-Line Quick-View Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a user tap any product photo to see it enlarged, and tap an order line (New Order / Edit Order) to see a read-only quick-view of that product.

**Architecture:** Two new shared components hoisted once in `Main.qml` (mirroring the existing `photoSourceSheet` pattern) — `PhotoViewerPopup` (centered card, static image) and `ProductQuickViewDialog` (read-only `BottomSheet` with a "View full product" handoff to `EditProductDialog`). `AvatarBadge` gets one new **opt-in** property so its 13+ existing call sites are unaffected. Two small pure-JS helpers carry the only genuinely testable logic (Back-button dialog-priority ordering, and quick-view field resolution/fallback); everything else is view wiring, verified via an on-device test plan.

**Tech Stack:** Felgo QML / Qt Quick 6, JS helper modules (`.pragma library`), Qt Quick Test (`qmltestrunner`) for the two pure-logic helpers.

## Global Constraints

- No build/run of the Android app during implementation (per standing instruction) — verification is `qmltestrunner` for the two JS helpers (if a toolchain is available) plus an on-device test-plan doc for everything else.
- `AvatarBadge` changes must be strictly additive/opt-in (`enlargeOnTap: false` default) — do not change behavior at any of its 13 existing call sites.
- Quick-view tap-gate is **strict**: a line with no `productId` is fully non-tappable (no lenient name-fallback), confirmed with Taher.
- `Main.qml`'s `_handleBack()` dialog-priority array must place `photoViewerPopup` first (it can appear on top of anything, including `productQuickView`), then `productQuickView` (before `newOrderDlg`/`orderDetail`).
- "View full product" in the quick-view closes the quick-view first, then opens `editProductDlg.openFor(productId, false)` — never stack the two.
- Follow Conventional Commits messages; one commit per task, only after Taher reviews the diff.

---

### Task 1: `BackButtonRouter.js` — extract and test the dialog-priority-close logic

**Files:**
- Create: `qml/helper/BackButtonRouter.js`
- Test: `tests/tst_BackButtonRouter.qml`

**Interfaces:**
- Produces: `BackButtonRouter.closeTopmostOpen(dialogs)` — `dialogs` is an array of objects each optionally exposing `opened` (bool) and `close()` (function). Returns `true` and calls `.close()` on the first entry (in array order) whose `opened === true`; returns `false` if none are open. Used by Task 9 (`Main.qml`).

- [ ] **Step 1: Write the failing test**

```qml
// tests/tst_BackButtonRouter.qml
import QtQuick
import QtTest
import "../qml/helper/BackButtonRouter.js" as BackButtonRouter

TestCase {
    id: tc
    name: "BackButtonRouter"

    // Stand-in dialog: mirrors the real .opened/.close() contract every
    // BottomSheet/Popup/QQC.Dialog in this app already exposes.
    Component {
        id: dlgComp
        QtObject {
            property bool opened: false
            property int closeCount: 0
            function close() { opened = false; closeCount++ }
        }
    }

    function test_closes_first_opened_in_priority_order() {
        var a = dlgComp.createObject(tc, { opened: false })
        var b = dlgComp.createObject(tc, { opened: true })
        var c = dlgComp.createObject(tc, { opened: true })
        var closed = BackButtonRouter.closeTopmostOpen([a, b, c])
        compare(closed, true, "reports something was closed")
        compare(b.opened, false, "first opened dialog (b) was closed")
        compare(b.closeCount, 1)
        compare(c.opened, true, "later dialog (c) was left open even though it was also opened")
    }

    function test_returns_false_when_nothing_open() {
        var a = dlgComp.createObject(tc, { opened: false })
        var b = dlgComp.createObject(tc, { opened: false })
        var closed = BackButtonRouter.closeTopmostOpen([a, b])
        compare(closed, false)
        compare(a.closeCount, 0)
        compare(b.closeCount, 0)
    }

    function test_skips_null_entries() {
        var b = dlgComp.createObject(tc, { opened: true })
        var closed = BackButtonRouter.closeTopmostOpen([null, b])
        compare(closed, true)
        compare(b.closeCount, 1)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `qmltestrunner -input tests/tst_BackButtonRouter.qml` (if no Qt toolchain is available in this session, note that explicitly instead of claiming a result)
Expected: FAIL — `qml/helper/BackButtonRouter.js` does not exist yet.

- [ ] **Step 3: Write minimal implementation**

```js
// qml/helper/BackButtonRouter.js
.pragma library

// Closes the first dialog in `dialogs` (in priority order) that reports
// opened === true. Returns true if something was closed, false if none of
// the dialogs were open (caller should fall through to the next Back
// step). Extracted from Main.qml's _handleBack() so the priority-order
// logic can be verified without building/running the app.
function closeTopmostOpen(dialogs) {
    for (var i = 0; i < dialogs.length; ++i) {
        if (dialogs[i] && dialogs[i].opened) {
            dialogs[i].close()
            return true
        }
    }
    return false
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `qmltestrunner -input tests/tst_BackButtonRouter.qml`
Expected: PASS (3/3). If no toolchain is available this session, say so plainly rather than claiming a result — Taher runs it on his machine before merge.

- [ ] **Step 5: Commit**

```bash
git add qml/helper/BackButtonRouter.js tests/tst_BackButtonRouter.qml
git commit -m "feat(helper): extract BackButtonRouter.closeTopmostOpen with tests"
```

---

### Task 2: `ProductLineQuickView.js` — quick-view field resolution + tax label

**Files:**
- Create: `qml/helper/ProductLineQuickView.js`
- Test: `tests/tst_ProductLineQuickView.qml`

**Interfaces:**
- Produces:
  - `ProductLineQuickView.resolve(product, lineSnapshot)` — `product` is an `InventoryStore.getById()` result or `null`; `lineSnapshot` is `{name, price}` (the order line's own locally-captured fields, always present). Returns `{usingFallback, photoUrl, name, productId, sku, costPrice, sellingPrice, taxable, taxPercent, size}`.
  - `ProductLineQuickView.formatTax(taxable, taxPercent)` — returns `"Not taxable"` or `"<taxPercent>% GST"`.
- Consumed by: Task 5 (`ProductQuickViewDialog.qml`).

- [ ] **Step 1: Write the failing test**

```qml
// tests/tst_ProductLineQuickView.qml
import QtQuick
import QtTest
import "../qml/helper/ProductLineQuickView.js" as ProductLineQuickView

TestCase {
    id: tc
    name: "ProductLineQuickView"

    function test_resolve_uses_product_fields_when_found() {
        var product = {
            productId: "p1", name: "Widget", sku: "SKU-1", photoUrl: "http://x/photo.jpg",
            price: 40, sellingPrice: 55, taxable: true, taxPercent: 18, size: "M"
        }
        var r = ProductLineQuickView.resolve(product, { name: "Widget (typed)", price: 55 })
        compare(r.usingFallback, false)
        compare(r.photoUrl, "http://x/photo.jpg")
        compare(r.name, "Widget")
        compare(r.productId, "p1")
        compare(r.sku, "SKU-1")
        compare(r.costPrice, 40)
        compare(r.sellingPrice, 55)
        compare(r.taxable, true)
        compare(r.taxPercent, 18)
        compare(r.size, "M")
    }

    function test_resolve_falls_back_to_line_snapshot_when_product_missing() {
        var r = ProductLineQuickView.resolve(null, { name: "Deleted Product", price: 30 })
        compare(r.usingFallback, true)
        compare(r.photoUrl, "")
        compare(r.name, "Deleted Product")
        compare(r.productId, "")
        compare(r.sku, "")
        compare(r.sellingPrice, 30)
        compare(r.taxable, false)
        compare(r.size, "")
    }

    function test_resolve_defaults_selling_price_to_cost_when_unset() {
        var product = { productId: "p2", name: "NoSellPrice", price: 20, taxable: false }
        var r = ProductLineQuickView.resolve(product, { name: "NoSellPrice", price: 20 })
        compare(r.sellingPrice, 20, "falls back to cost price when sellingPrice is undefined")
    }

    function test_format_tax_not_taxable() {
        compare(ProductLineQuickView.formatTax(false, 18), "Not taxable")
    }

    function test_format_tax_taxable() {
        compare(ProductLineQuickView.formatTax(true, 18), "18% GST")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `qmltestrunner -input tests/tst_ProductLineQuickView.qml`
Expected: FAIL — `qml/helper/ProductLineQuickView.js` does not exist yet.

- [ ] **Step 3: Write minimal implementation**

```js
// qml/helper/ProductLineQuickView.js
.pragma library

// Resolves the fields ProductQuickViewDialog.qml displays for a tapped
// order line. `product` is an InventoryStore.getById() result, or null if
// the product record no longer exists (e.g. deleted after a completed
// order referencing it was placed). `lineSnapshot` ({name, price}) is the
// order line's own locally-captured data, always available regardless of
// whether the catalog product still exists.
//
// productId is intentionally not part of any fallback here: a line with
// no productId never reaches this function — its row isn't tappable at
// all (see NewOrderDialog.qml / OrderDetailDialog.qml).
function resolve(product, lineSnapshot) {
    if (product) {
        return {
            usingFallback: false,
            photoUrl: product.photoUrl || "",
            name: product.name || lineSnapshot.name || "",
            productId: product.productId || "",
            sku: product.sku || "",
            costPrice: product.price,
            sellingPrice: product.sellingPrice !== undefined && product.sellingPrice !== null
                ? product.sellingPrice
                : product.price,
            taxable: !!product.taxable,
            taxPercent: product.taxPercent || 0,
            size: product.size || ""
        }
    }
    return {
        usingFallback: true,
        photoUrl: "",
        name: lineSnapshot.name || "",
        productId: "",
        sku: "",
        costPrice: undefined,
        sellingPrice: lineSnapshot.price,
        taxable: false,
        taxPercent: 0,
        size: ""
    }
}

function formatTax(taxable, taxPercent) {
    return taxable ? (taxPercent + "% GST") : "Not taxable"
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `qmltestrunner -input tests/tst_ProductLineQuickView.qml`
Expected: PASS (5/5).

- [ ] **Step 5: Commit**

```bash
git add qml/helper/ProductLineQuickView.js tests/tst_ProductLineQuickView.qml
git commit -m "feat(helper): add ProductLineQuickView.resolve/formatTax with tests"
```

---

### Task 3: `AvatarBadge.qml` — additive `enlargeOnTap` property

**Files:**
- Modify: `qml/components/AvatarBadge.qml`
- Test: `tests/tst_AvatarBadgeEnlargeOnTap.qml`

**Interfaces:**
- Produces: `AvatarBadge.enlargeOnTap` (bool, default `false`), `AvatarBadge.photoTapped()` signal — emitted on tap only when `enlargeOnTap === true` and `imageSource.length > 0`. Consumed by Tasks 6, 7, 8.

- [ ] **Step 1: Write the failing test**

This is a real-component test (not a stand-in) since `AvatarBadge.qml` is small enough to instantiate directly, and the whole point is proving the actual file's new opt-in behavior plus non-regression of its default.

```qml
// tests/tst_AvatarBadgeEnlargeOnTap.qml
import QtQuick
import QtTest
import "../qml/components"

TestCase {
    id: tc
    name: "AvatarBadgeEnlargeOnTap"
    width: 100
    height: 100

    Component {
        id: badgeComp
        AvatarBadge {}
    }

    function test_default_off_does_not_intercept_tap() {
        // enlargeOnTap defaults to false — no MouseArea should be enabled,
        // so a tap must not consume the event (parent click handling, e.g.
        // a ListCard's own onClicked, must still fire in real usage).
        var badge = badgeComp.createObject(tc, { imageSource: "http://x/photo.jpg" })
        var spy = Qt.createQmlObject(
            'import QtTest; SignalSpy { }', tc, "spy")
        spy.target = badge
        spy.signalName = "photoTapped"
        mouseClick(badge)
        compare(spy.count, 0, "photoTapped must not fire when enlargeOnTap is false (default)")
        badge.destroy()
        spy.destroy()
    }

    function test_enlarge_on_tap_fires_when_photo_present() {
        var badge = badgeComp.createObject(tc, { enlargeOnTap: true, imageSource: "http://x/photo.jpg" })
        var spy = Qt.createQmlObject(
            'import QtTest; SignalSpy { }', tc, "spy")
        spy.target = badge
        spy.signalName = "photoTapped"
        mouseClick(badge)
        compare(spy.count, 1, "photoTapped fires when enlargeOnTap is true and a photo exists")
        badge.destroy()
        spy.destroy()
    }

    function test_enlarge_on_tap_does_not_fire_without_photo() {
        var badge = badgeComp.createObject(tc, { enlargeOnTap: true, imageSource: "" })
        var spy = Qt.createQmlObject(
            'import QtTest; SignalSpy { }', tc, "spy")
        spy.target = badge
        spy.signalName = "photoTapped"
        mouseClick(badge)
        compare(spy.count, 0, "no photo means nothing to enlarge, so no tap affordance")
        badge.destroy()
        spy.destroy()
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `qmltestrunner -input tests/tst_AvatarBadgeEnlargeOnTap.qml`
Expected: FAIL — `enlargeOnTap`/`photoTapped` don't exist on `AvatarBadge` yet.

- [ ] **Step 3: Write minimal implementation**

Modify `qml/components/AvatarBadge.qml`:

```qml
    property string label: "?"
    property string iconName: ""
    property var palette: Constants.grad1
    property string size: "md"
    property string imageSource: ""
    property bool enlargeOnTap: false
    signal photoTapped()
```

(inserted right after the existing `property string imageSource: ""` line)

And at the end of the file, after the existing `Icon { ... }` block:

```qml
    // Opt-in only (default false) so the 13+ other AvatarBadge call sites
    // across the app (staff, notifications, dashboard, sales, etc.) are
    // completely unaffected. When enlargeOnTap is false this MouseArea is
    // disabled, which in Qt Quick means it does not accept the press at
    // all — the event falls through to whatever the avatar sits inside
    // (e.g. a ListCard's own onClicked), exactly like before this change.
    MouseArea {
        anchors.fill: parent
        enabled: root.enlargeOnTap && root.imageSource.length > 0
        onClicked: root.photoTapped()
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `qmltestrunner -input tests/tst_AvatarBadgeEnlargeOnTap.qml`
Expected: PASS (3/3).

- [ ] **Step 5: Commit**

```bash
git add qml/components/AvatarBadge.qml tests/tst_AvatarBadgeEnlargeOnTap.qml
git commit -m "feat(AvatarBadge): add opt-in enlargeOnTap/photoTapped, default off"
```

---

### Task 4: `PhotoViewerPopup.qml` — new shared component

**Files:**
- Create: `qml/components/PhotoViewerPopup.qml`

**Interfaces:**
- Produces: `PhotoViewerPopup.openFor(url)`, `PhotoViewerPopup.opened` (inherited from `QQC.Popup`), `PhotoViewerPopup.close()` (inherited). Consumed by Task 9 (`Main.qml`, hoisted as `id: photoViewerPopup`).

No automated test for this task — it's pure layout/animation (centered sizing, scale+fade transition, backdrop dismiss). Covered by the on-device test plan (Task 10).

- [ ] **Step 1: Create the component**

```qml
// qml/components/PhotoViewerPopup.qml
import QtQuick
import QtQuick.Controls as QQC

import "../helper"

// Centered photo viewer, shared across every "tap a product photo to
// enlarge it" trigger point in the app (inventory list, add/edit product,
// order-line avatars). Not a full-screen viewer and not a slide-up
// BottomSheet — a centered card sized to roughly a third of the screen's
// height with side padding, per Taher's design call. Static image only
// (no pinch-to-zoom) for v1.
QQC.Popup {
    id: root

    property string photoUrl: ""

    function openFor(url) {
        photoUrl = url
        open()
    }

    modal: true
    focus: true
    parent: QQC.Overlay.overlay
    x: (parent.width - width) / 2
    y: (parent.height - height) / 2
    width: parent.width - dp(Constants.space5 * 2)
    height: parent.height / 3
    padding: 0
    closePolicy: QQC.Popup.CloseOnEscape | QQC.Popup.CloseOnPressOutside

    QQC.Overlay.modal: Rectangle { color: Constants.overlay }

    enter: Transition {
        NumberAnimation { properties: "scale"; from: 0.6; to: 1.0; duration: Constants.durMed; easing.type: Easing.OutCubic }
        NumberAnimation { property: "opacity"; from: 0.0; to: 1.0; duration: Constants.durMed }
    }
    exit: Transition {
        NumberAnimation { properties: "scale"; from: 1.0; to: 0.6; duration: Constants.durMed; easing.type: Easing.OutCubic }
        NumberAnimation { property: "opacity"; from: 1.0; to: 0.0; duration: Constants.durMed }
    }

    background: Rectangle {
        radius: dp(Constants.radiusXl)
        color: Constants.cardBg
    }

    contentItem: Item {
        Image {
            anchors.fill: parent
            anchors.margins: dp(Constants.space2)
            source: root.photoUrl
            fillMode: Image.PreserveAspectFit
            asynchronous: true
        }

        QQC.AbstractButton {
            anchors.top: parent.top
            anchors.right: parent.right
            anchors.margins: dp(Constants.space2)
            implicitWidth: dp(32)
            implicitHeight: dp(32)
            padding: 0
            background: Rectangle {
                radius: dp(16)
                color: Qt.rgba(0, 0, 0, 0.45)
            }
            contentItem: Item {
                Icon {
                    anchors.centerIn: parent
                    name: "close"
                    size: sp(18)
                    color: "#ffffff"
                }
            }
            onClicked: root.close()
        }
    }
}
```

- [ ] **Step 2: Commit**

```bash
git add qml/components/PhotoViewerPopup.qml
git commit -m "feat(components): add PhotoViewerPopup, centered enlarge-photo popup"
```

---

### Task 5: `ProductQuickViewDialog.qml` — new read-only order-line detail popup

**Files:**
- Create: `qml/pages/ProductQuickViewDialog.qml`

**Interfaces:**
- Consumes: `ProductLineQuickView.resolve`/`formatTax` (Task 2), `InventoryStore.getById`/`formatCurrency` (existing), `BottomSheet` (existing), `AvatarBadge` (Task 3 — used here with `enlargeOnTap: true`).
- Produces:
  - `ProductQuickViewDialog.openFor(productId, lineSnapshot)` — `lineSnapshot` is `{name, price}`.
  - `signal photoEnlargeRequested(string url)` — bubbled to `Main.qml` (Task 9), which opens `photoViewerPopup`.
  - `signal viewFullProductRequested(string productId)` — bubbled to `Main.qml`, which closes this dialog then opens `editProductDlg.openFor(productId, false)`.
- `opened`/`close()` inherited from `BottomSheet`. Consumed by Tasks 7, 8 (`NewOrderDialog.qml`, `OrderDetailDialog.qml`) and Task 9 (`Main.qml`, hoisted as `id: productQuickView`).

No automated test — this is a thin read-only view over already-tested logic (Task 2). Covered by the on-device test plan (Task 10).

- [ ] **Step 1: Create the component**

```qml
// qml/pages/ProductQuickViewDialog.qml
import QtQuick
import QtQuick.Controls as QQC
import QtQuick.Layouts

import "../components"
import "../helper"
import "../helper/ProductLineQuickView.js" as ProductLineQuickView
import "../model"

// Read-only quick-view opened by tapping an order line (New Order / Edit
// Order). Shows photo, name, product ID, SKU, cost price, selling price,
// tax info, size. "View full product" hands off to EditProductDialog.
// Never editable from here.
BottomSheet {
    id: root

    signal photoEnlargeRequested(string url)
    signal viewFullProductRequested(string productId)

    sheetTitle: qsTr("Product details")
    secondaryAction: qsTr("Close")
    primaryAction: _fields.usingFallback ? "" : qsTr("View full product")

    property var _fields: ({
        usingFallback: true, photoUrl: "", name: "", productId: "",
        sku: "", costPrice: undefined, sellingPrice: undefined,
        taxable: false, taxPercent: 0, size: ""
    })

    function openFor(productId, lineSnapshot) {
        var product = productId ? InventoryStore.getById(productId) : null
        _fields = ProductLineQuickView.resolve(product, lineSnapshot || { name: "", price: 0 })
        open()
    }

    onPrimaryClicked: {
        if (_fields.usingFallback) return
        var pid = _fields.productId
        root.close()
        root.viewFullProductRequested(pid)
    }

    ColumnLayout {
        Layout.fillWidth: true
        spacing: dp(Constants.space4)

        RowLayout {
            Layout.fillWidth: true
            spacing: dp(Constants.space3)
            visible: root._fields.photoUrl.length > 0

            AvatarBadge {
                size: "xl"
                imageSource: root._fields.photoUrl
                enlargeOnTap: true
                onPhotoTapped: root.photoEnlargeRequested(root._fields.photoUrl)
            }
        }

        Text {
            text: root._fields.name
            color: Constants.textPrimary
            font.pixelSize: sp(Constants.fsH3)
            font.bold: true
            Layout.fillWidth: true
            wrapMode: Text.Wrap
        }

        Text {
            visible: !root._fields.usingFallback
            text: qsTr("ID: %1  ·  SKU: %2").arg(root._fields.productId).arg(root._fields.sku || "—")
            color: Constants.textSecondary
            font.pixelSize: sp(Constants.fsSmall)
            Layout.fillWidth: true
        }

        Text {
            visible: root._fields.usingFallback
            text: qsTr("This product is no longer in your catalog — showing what this order captured.")
            color: Constants.textMuted
            font.pixelSize: sp(Constants.fsSmall)
            wrapMode: Text.Wrap
            Layout.fillWidth: true
        }

        RowLayout {
            Layout.fillWidth: true
            spacing: dp(Constants.space4)
            visible: root._fields.costPrice !== undefined

            ColumnLayout {
                spacing: dp(2)
                Text { text: qsTr("Cost price"); color: Constants.textMuted; font.pixelSize: sp(Constants.fsCaption) }
                Text {
                    text: InventoryStore.formatCurrency(root._fields.costPrice)
                    color: Constants.textPrimary
                    font.pixelSize: sp(Constants.fsBodyLg)
                    font.bold: true
                }
            }
            ColumnLayout {
                spacing: dp(2)
                Text { text: qsTr("Selling price"); color: Constants.textMuted; font.pixelSize: sp(Constants.fsCaption) }
                Text {
                    text: InventoryStore.formatCurrency(root._fields.sellingPrice)
                    color: Constants.textPrimary
                    font.pixelSize: sp(Constants.fsBodyLg)
                    font.bold: true
                }
            }
        }

        RowLayout {
            Layout.fillWidth: true
            spacing: dp(Constants.space4)

            ColumnLayout {
                spacing: dp(2)
                visible: !root._fields.usingFallback
                Text { text: qsTr("Tax"); color: Constants.textMuted; font.pixelSize: sp(Constants.fsCaption) }
                Text {
                    text: ProductLineQuickView.formatTax(root._fields.taxable, root._fields.taxPercent)
                    color: Constants.textPrimary
                    font.pixelSize: sp(Constants.fsBody)
                }
            }
            ColumnLayout {
                spacing: dp(2)
                visible: root._fields.size.length > 0
                Text { text: qsTr("Size"); color: Constants.textMuted; font.pixelSize: sp(Constants.fsCaption) }
                Text {
                    text: root._fields.size
                    color: Constants.textPrimary
                    font.pixelSize: sp(Constants.fsBody)
                }
            }
        }
    }
}
```

**Verified against the real `qml/components/BottomSheet.qml`:** its body slot is a `default property alias body: bodyHolder.data` — content is declared as a plain top-level child (a single `ColumnLayout`, exactly as `OrderDetailDialog.qml`/`NewOrderDialog.qml` already do), not via a `contentLayout:` property. Its `GhostButton` (secondary action) already calls `root.close()` internally on click — so `onSecondaryClicked` only needs to run if there's dialog-specific cleanup to do; here there isn't any, so it's omitted. Its `PrimaryButton` does NOT auto-close — `onPrimaryClicked` handling the close-then-navigate sequence (per the spec's §4.2 rationale) is required, not redundant. The code above already reflects this: replace the `contentLayout: ColumnLayout { ... }` wrapper with a plain top-level `ColumnLayout { Layout.fillWidth: true; spacing: dp(Constants.space4) ... }` declared directly as a child of `BottomSheet { id: root ... }` (no property name prefix), and drop the `onSecondaryClicked: root.close()` line entirely.

- [ ] **Step 2: Commit**

```bash
git add qml/pages/ProductQuickViewDialog.qml
git commit -m "feat(pages): add ProductQuickViewDialog, read-only order-line quick-view"
```

---

### Task 6: Wire photo-enlarge tap in `InventoryPage.qml`, `AddProductDialog.qml`, `EditProductDialog.qml`

**Files:**
- Modify: `qml/pages/InventoryPage.qml` (around the `AvatarBadge` in `ProductCard`, ~line 235-238)
- Modify: `qml/pages/AddProductDialog.qml` (photo box, ~line 97-114)
- Modify: `qml/pages/EditProductDialog.qml` (photo box, ~line 200-231)

**Interfaces:**
- Produces: `signal photoEnlargeRequested(string url)` on all three (new signal, same name, for consistent wiring in Task 9).
- Consumes: `AvatarBadge.enlargeOnTap`/`photoTapped` (Task 3).

- [ ] **Step 1: `InventoryPage.qml`** — add the signal declaration near the file's other `signal` lines, and update the `AvatarBadge` in `ProductCard`:

```qml
    signal photoEnlargeRequested(string url)
```

Verified exact current block (`ProductCard`'s leading avatar) and the addition — `InventoryPage.qml`'s root `Item` is `id: root`, confirmed:

```qml
            AvatarBadge {
                Layout.alignment: Qt.AlignVCenter
                size: "lg"
                imageSource: card.product && card.product.photoUrl ? card.product.photoUrl : ""
                label: card.product && card.product.name && card.product.name.length > 0
                    ? card.product.name.charAt(0).toUpperCase() : "?"
                palette: card.product && card.product.stock <= card.product.minStock
                        ? Constants.grad3 : Constants.grad4
                enlargeOnTap: true
                onPhotoTapped: root.photoEnlargeRequested(imageSource)
            }
```

- [ ] **Step 2: `AddProductDialog.qml`** (root id is `dlg`) — add the signal near the file's other `signal` lines:

```qml
    signal photoEnlargeRequested(string url)
```

Verified exact current photo `Rectangle` plus the addition (a `MouseArea` as its last child, so it sits on top of the `Image`/`Icon`):

```qml
            Rectangle {
                width: dp(64); height: dp(64); radius: dp(16)
                color: Qt.rgba(0.39, 0.40, 0.95, 0.10)
                clip: true

                Image {
                    anchors.fill: parent
                    anchors.margins: dp(2)
                    source: dlg.pendingPhotoSource
                    visible: dlg.pendingPhotoSource.length > 0
                    fillMode: Image.PreserveAspectCrop
                    sourceSize.width: 128; sourceSize.height: 128
                }
                Icon {
                    anchors.centerIn: parent
                    visible: dlg.pendingPhotoSource.length === 0
                    name: "camera"
                    size: sp(24)
                    color: Constants.textSecondary
                }

                MouseArea {
                    anchors.fill: parent
                    enabled: dlg.pendingPhotoSource.length > 0
                    onClicked: dlg.photoEnlargeRequested(dlg.pendingPhotoSource)
                }
            }
```

- [ ] **Step 3: `EditProductDialog.qml`** (root id is `root`) — add the signal:

```qml
    signal photoEnlargeRequested(string url)
```

Verified exact current photo `Rectangle` plus the addition:

```qml
            Rectangle {
                Layout.preferredWidth: dp(80)
                Layout.preferredHeight: dp(80)
                radius: dp(Constants.radius)
                color: Constants.subtleBg
                border.color: Constants.borderColor
                border.width: 1
                clip: true

                Image {
                    anchors.fill: parent
                    anchors.margins: dp(2)
                    source: root.photoUrl
                    sourceSize.width: 160
                    sourceSize.height: 160
                    fillMode: Image.PreserveAspectCrop
                    cache: true
                    visible: root.photoUrl.length > 0
                }
                Icon {
                    anchors.centerIn: parent
                    name: "box"
                    size: sp(32)
                    color: Constants.textSecondary
                    visible: root.photoUrl.length === 0
                }
                QQC.BusyIndicator {
                    anchors.centerIn: parent
                    running: root.photoBusy
                    visible: root.photoBusy
                }

                MouseArea {
                    anchors.fill: parent
                    enabled: root.photoUrl.length > 0 && !root.photoBusy
                    onClicked: root.photoEnlargeRequested(root.photoUrl)
                }
            }
```

(`!root.photoBusy` guards the moment a new photo is uploading — the `BusyIndicator` is showing and there's nothing settled yet to enlarge.)

- [ ] **Step 4: Self-check**

Re-open all three files after editing and confirm the new `MouseArea`/`AvatarBadge` additions landed inside the photo box only — the "Change photo"/"Add photo" `GhostButton` is a sibling declared below the photo `Rectangle`, not inside it, so it's untouched.

- [ ] **Step 5: Commit**

```bash
git add qml/pages/InventoryPage.qml qml/pages/AddProductDialog.qml qml/pages/EditProductDialog.qml
git commit -m "feat: wire tap-to-enlarge photo in inventory list, add/edit product"
```

---

### Task 7: Wire `NewOrderDialog.qml` — avatar enlarge + row quick-view

**Files:**
- Modify: `qml/pages/NewOrderDialog.qml` (cart line delegate, ~line 249-300)

**Interfaces:**
- Produces: `signal photoEnlargeRequested(string url)`, `signal quickViewRequested(string productId, var lineSnapshot)`.
- Consumes: `AvatarBadge.enlargeOnTap`/`photoTapped` (Task 3).

- [ ] **Step 1: Add the two signals** near the file's existing signal declarations:

```qml
    signal photoEnlargeRequested(string url)
    signal quickViewRequested(string productId, var lineSnapshot)
```

- [ ] **Step 2: Add a row-level `MouseArea`** as the first child of the `cartRow` delegate `Rectangle`, before `cartCol` — full-row, gated strictly on `productId`:

```qml
                delegate: Rectangle {
                    id: cartRow
                    Layout.fillWidth: true
                    Layout.preferredHeight: cartCol.implicitHeight + dp(Constants.space3 * 2)
                    radius: dp(Constants.radius)
                    color: Constants.cardBg
                    border.color: Constants.borderColor
                    border.width: 1

                    MouseArea {
                        anchors.fill: parent
                        enabled: !!modelData.productId
                        onClicked: dlg.quickViewRequested(modelData.productId,
                            { name: modelData.name, price: modelData.price })
                    }

                    ColumnLayout {
                        id: cartCol
                        // ...unchanged...
```

This `MouseArea` sits underneath `cartCol` in paint order (declared first), so every existing interactive control inside `cartCol` (qty steppers, price/discount fields) still receives its own clicks first — the same reason the qty-stepper buttons inside `OrderDetailDialog`'s `ListCard` don't trigger that row's click today.

- [ ] **Step 3: Upgrade the cart-line `AvatarBadge`** to show the real photo and enlarge on tap:

```qml
                            AvatarBadge {
                                label: (modelData.name || "?").charAt(0).toUpperCase()
                                palette: Constants.grad2
                                imageSource: {
                                    var inv = modelData.productId ? InventoryStore.getById(modelData.productId) : null
                                    return inv && inv.photoUrl ? inv.photoUrl : ""
                                }
                                enlargeOnTap: true
                                onPhotoTapped: dlg.photoEnlargeRequested(imageSource)
                            }
```

- [ ] **Step 4: Self-check**

Re-view the edited cart-line delegate end to end and confirm: (a) `MouseArea`'s `enabled: !!modelData.productId` genuinely gates the whole row (strict rule, no name-fallback, per Taher's decision), and (b) the qty stepper `onClicked` handlers a few lines below are untouched. (`NewOrderDialog.qml`'s root id is `dlg`, already verified.)

- [ ] **Step 5: Commit**

```bash
git add qml/pages/NewOrderDialog.qml
git commit -m "feat(NewOrderDialog): tap avatar to enlarge photo, tap row for quick-view"
```

---

### Task 8: Wire `OrderDetailDialog.qml` — avatar enlarge + `ListCard` quick-view

**Files:**
- Modify: `qml/pages/OrderDetailDialog.qml` (line-item delegate, ~line 519-627)

**Interfaces:**
- Produces: `signal photoEnlargeRequested(string url)`, `signal quickViewRequested(string productId, var lineSnapshot)`.
- Consumes: `AvatarBadge.enlargeOnTap`/`photoTapped` (Task 3). `ListCard` already exposes `onClicked` (it's a `QQC.AbstractButton`) — no new `MouseArea` needed here, unlike Task 7.

- [ ] **Step 1: Add the two signals**, matching Task 7's names exactly (both dialogs feed the same `Main.qml` wiring in Task 9):

```qml
    signal photoEnlargeRequested(string url)
    signal quickViewRequested(string productId, var lineSnapshot)
```

- [ ] **Step 2: Add `onClicked` to the `ListCard`**, gated strictly on `productId`:

```qml
                  ListCard {
                    Layout.fillWidth: true
                    title: model.name
                    subtitle: {
                        // ...unchanged...
                    }
                    onClicked: {
                        if (!model.productId) return
                        dlg.quickViewRequested(model.productId, { name: model.name, price: model.price })
                    }

                    leading: AvatarBadge {
                        label: (model.name || "?").charAt(0).toUpperCase()
                        palette: index % 4 === 0 ? Constants.grad1
                                                 : index % 4 === 1 ? Constants.grad2
                                                                   : index % 4 === 2 ? Constants.grad3
                                                                                     : Constants.grad4
                        imageSource: {
                            var inv = model.productId ? InventoryStore.getById(model.productId) : null
                            return inv && inv.photoUrl ? inv.photoUrl : ""
                        }
                        enlargeOnTap: true
                        onPhotoTapped: dlg.photoEnlargeRequested(imageSource)
                    }

                    RowLayout {
                        // ...unchanged (qty steppers, price/discount fields)...
```

- [ ] **Step 3: Self-check**

Confirm the `ListCard.onClicked` addition doesn't collide with any existing handler already on this `ListCard` (there wasn't one before this change, per the current file). The qty-stepper `AbstractButton`s a few lines below (remove/add/delete) will keep consuming their own clicks and won't trigger the new `ListCard.onClicked` — this is the same behavior the file already relies on today (nested `AbstractButton`s inside a `ListCard` don't trigger the card's click). (`OrderDetailDialog.qml`'s root id is `dlg`, already verified.)

- [ ] **Step 4: Commit**

```bash
git add qml/pages/OrderDetailDialog.qml
git commit -m "feat(OrderDetailDialog): tap avatar to enlarge photo, tap row for quick-view"
```

---

### Task 9: Wire `Main.qml` — hoist both popups, connect signals, update Back-button routing

**Files:**
- Modify: `qml/Main.qml`

**Interfaces:**
- Consumes: everything from Tasks 1, 4, 5, 6, 7, 8.

- [ ] **Step 1: Hoist `PhotoViewerPopup` and `ProductQuickViewDialog`**, near the existing `photoSourceSheet` declaration (~line 724-742):

```qml
    PhotoViewerPopup {
        id: photoViewerPopup
    }

    ProductQuickViewDialog {
        id: productQuickView
        onPhotoEnlargeRequested: function(url) { photoViewerPopup.openFor(url) }
        onViewFullProductRequested: function(pid) { editProductDlg.openFor(pid, false) }
    }
```

- [ ] **Step 2: Connect `photoEnlargeRequested` from every trigger point.** In `InventoryPage {}` (~line 489-498):

```qml
                        onPhotoEnlargeRequested: function(url) { photoViewerPopup.openFor(url) }
```

In `AddProductDialog { id: addProductDlg ... }` (~line 709-713):

```qml
        onPhotoEnlargeRequested: function(url) { photoViewerPopup.openFor(url) }
```

In `EditProductDialog { id: editProductDlg ... }` (~line 716-722):

```qml
        onPhotoEnlargeRequested: function(url) { photoViewerPopup.openFor(url) }
```

In `NewOrderDialog { id: newOrderDlg ... }` (~line 677-685):

```qml
        onPhotoEnlargeRequested: function(url) { photoViewerPopup.openFor(url) }
        onQuickViewRequested: function(pid, snapshot) { productQuickView.openFor(pid, snapshot) }
```

In `OrderDetailDialog { id: orderDetail ... }` (~line 686-691):

```qml
        onPhotoEnlargeRequested: function(url) { photoViewerPopup.openFor(url) }
        onQuickViewRequested: function(pid, snapshot) { productQuickView.openFor(pid, snapshot) }
```

- [ ] **Step 3: Update `_handleBack()`** to use `BackButtonRouter` and include the two new popups, positioned per the spec (`photoViewerPopup` first, `productQuickView` next):

```qml
    function _handleBack() {
        // 1. Open modal sheet / dialog → close the first open one.
        var dialogs = [photoViewerPopup, productQuickView,
                       photoSourceSheet, addProductDlg, editProductDlg,
                       newOrderDlg, orderDetail, restockDlg, addStaffDlg, inviteMemberDlg,
                       memberMgmtDlg, staffDetailDlg, profileDlg, manageCategoriesDlg,
                       manageChannelsDlg, notificationsSheet, filterSheet, exportSheet,
                       forgotPasswordDlg, confirmDlg, stockErrorDlg, permissionErrorDlg]
        if (BackButtonRouter.closeTopmostOpen(dialogs)) return
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

Add the import near the top of `Main.qml`, alongside the other relative imports:

```qml
import "helper/BackButtonRouter.js" as BackButtonRouter
```

- [ ] **Step 4: Self-check**

Re-view the edited `_handleBack()` and confirm every dialog id referenced (`photoViewerPopup`, `productQuickView`, plus all the pre-existing ones) actually exists in the file after Steps 1-2. Confirm the comment above the `dialogs` array (`"If a dialog id is added/renamed, update the dialogs list below"`) is still accurate — it is, since this task follows that exact instruction.

- [ ] **Step 5: Commit**

```bash
git add qml/Main.qml
git commit -m "feat(Main): hoist PhotoViewerPopup/ProductQuickViewDialog, wire signals, extend Back routing"
```

---

### Task 10: Docs — `AGENTS.md` note + on-device test plan

**Files:**
- Modify: `AGENTS.md`
- Create: `docs/superpowers/test-plans/2026-07-13-on-device-test-plan-enlarge-photo-order-detail.md`

- [ ] **Step 1: Add a Back-button routing note to `AGENTS.md`'s "6. Pages & Dialogs Agent" section** (verified: starts at its own `### 6. Pages & Dialogs Agent` heading, `**Responsibilities**` bullet list ends right before the `**Responsive Design**:` heading). Insert a new subsection between those two:

```markdown
**Android/hardware Back-button routing**:
`Main.qml`'s `onBackButtonPressedGlobally` → `_handleBack()` is the single
place that closes the top-most open dialog/popup on Back press, via
`BackButtonRouter.closeTopmostOpen(dialogs)` (`qml/helper/BackButtonRouter.js`).
`dialogs` is a flat, priority-ordered array — the router closes the FIRST
entry whose `opened === true`. Any new popup that can appear on top of an
existing dialog (e.g. a photo viewer opened from inside another dialog)
must be added to this array, positioned BEFORE anything it can appear on
top of, or Back will close the wrong layer first. Worked example:
`photoViewerPopup` and `productQuickView` in
`docs/superpowers/specs/2026-07-13-enlarge-photo-and-order-detail-design.md`.
```

Also add `` `qml/pages/ProductQuickViewDialog.qml` `` to that section's **Key Files** list (after `AddProductDialog.qml`).

- [ ] **Step 2: Update `AGENTS.md`'s "7. Shared Components Agent" section.** Add `` `qml/components/PhotoViewerPopup.qml` `` to its **Key Files** list (after the `BreakdownBarCard.qml` line), and extend the pure-JS-helpers **Responsibilities** bullet (the one listing `BreakdownMath.js`/`RealisedMath.js`/`OrderMath.js`/`ImportMath.js`) to also mention: `` `BackButtonRouter.js` — closeTopmostOpen(dialogs), the Back-button dialog-priority closer used by Main.qml; `ProductLineQuickView.js` — resolve/formatTax for the order-line quick-view popup, degrading gracefully when a referenced product has been deleted. ``

- [ ] **Step 3: Write the on-device test plan.** Structure it like the existing plans in `docs/superpowers/test-plans/` (re-review one, e.g. `2026-07-11-on-device-test-plan-adjustment-reason.md`, for the expected format before writing this one) and cover at minimum:
  - Tap-to-enlarge from all 5 trigger points (inventory list, add product, edit product, new-order cart line avatar, edit-order line avatar) — photo appears centered, correctly sized, closes via ✕/backdrop tap/hardware Back.
  - No-photo case: avatar/photo box is not tappable, no visual affordance.
  - Order-line quick-view: tap a matched line in both New Order and Edit Order → correct fields shown; tap an unmatched (no-`productId`) line → nothing happens, no visual change.
  - "View full product" closes the quick-view and opens the real Edit Product dialog with correct data.
  - Deleted-product edge case: open Edit Order on a completed order whose product was since deleted → quick-view shows the fallback state, "View full product" is hidden.
  - Back-button chain: with New Order open, open a cart line's quick-view, then its photo — confirm Back closes photo viewer, then quick-view, then New Order stays open (three presses, three distinct outcomes), not two dialogs at once or the wrong one closing first.
  - Regression spot-check: tap an `AvatarBadge` somewhere unrelated to this feature (e.g. a Staff row) and confirm it behaves exactly as before (opens whatever it always opened, no new popup).

- [ ] **Step 4: Commit**

```bash
git add AGENTS.md docs/superpowers/test-plans/2026-07-13-on-device-test-plan-enlarge-photo-order-detail.md
git commit -m "docs: Back-button routing convention note + on-device test plan"
```
