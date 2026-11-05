import QtQuick
import QtQuick.Controls as QQC
import QtQuick.Layouts

import "../helper"
import "../model"
import "../helper/PickerRowGeometry.js" as Geo

// One product row of ProductPickerSheet (picker v2, slice S2). Painting only: what the row says comes from
// PickerSheetModel.build (qml/helper/PickerSheetModel.js) and every size from PickerRowGeometry.js, both tested
// headless; this file cannot be loaded by qmltestrunner (Felgo), so its wiring is pinned by
// functions/test/pickerSheetWiring.test.js and checked on a device (test plan, slice S2).
//
// Use as a ListView delegate over a ListModel whose roles are exactly the required properties below: the roles
// fill them (Skill 78: a delegate with `required property` gets NO implicit `index` or `modelData`, none is read here).
// The row never changes the draft itself; it asks through the two signals and the sheet answers by updating the model.
Rectangle {
    id: root

    required property string productId
    required property string name
    required property string sku
    required property string category
    required property string unit
    required property string photoId
    required property real price
    required property int available
    required property int maxQty
    required property int inOrder
    required property int qty
    required property bool canAdd
    required property string reason
    required property string reasonText
    required property string pillStatus
    required property string pillLabel
    required property string inOrderLabel
    required property bool atMax

    // Ask for a change; the sheet applies it through PickerDraft and refreshes this row in place.
    signal stepRequested(string productId, int delta, int maxQty)
    signal qtyTyped(string productId, string text, int maxQty)

    // Felgo's sp() is dp() times the system font scale, so their ratio is the font scale the geometry widens for.
    readonly property real _fontScale: dp(1) > 0 ? Math.max(1, sp(1) / dp(1)) : 1
    readonly property var _geo: Geo.layout(width, dp(1), maxQty, _fontScale)

    // A scale-1 click target is still dp(48) high: the buttons use _geo.minus / _geo.plus, never a smaller literal.
    width: ListView.view ? ListView.view.width : dp(320)
    height: Math.max(_geo.minHeight, content.implicitHeight + 2 * _geo.pad)
    radius: dp(Constants.radius)
    color: canAdd ? Constants.cardBg : Constants.subtleBg
    border.color: qty > 0 ? Constants.brand1 : Constants.borderColor
    border.width: qty > 0 ? 2 : 1

    Accessible.role: Accessible.ListItem
    Accessible.name: name + ", " + productId + ", " + pillLabel + (inOrderLabel.length > 0 ? ", " + inOrderLabel : "")
                     + (canAdd ? "" : ", " + reasonText)

    // Keep the field in step with the draft. While the person types, leave a blank or already-equal field alone, but show
    // a clamp at once (typed 50 with 8 in stock: the field must say 8, not keep a number the draft refused).
    function syncField() {
        var want = String(root.qty)
        if (qtyField.activeFocus && (qtyField.text === "" || qtyField.text === want)) return
        qtyField.text = want
        qtyField.cursorPosition = want.length
    }
    onQtyChanged: syncField()
    Component.onCompleted: syncField()

    ColumnLayout {
        id: content
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.margins: root._geo.pad
        spacing: root._geo.gap

        // Line 1: photo (or the initial) and the text.
        RowLayout {
            Layout.fillWidth: true
            spacing: root._geo.gap

            AvatarBadge {
                Layout.alignment: Qt.AlignTop
                size: "lg"
                // Offline there is no thumbnail to fetch: keep the initial (design D3).
                imageSource: (root.photoId.length > 0 && AuthService.isOnline)
                    ? StorageService.photoDownloadUrl(root.productId, root.photoId, true) : ""
                label: root.name.length > 0 ? root.name.charAt(0).toUpperCase() : "?"
                palette: root.canAdd ? Constants.grad4 : Constants.grad3
            }

            ColumnLayout {
                Layout.fillWidth: true
                spacing: dp(2)

                Text {
                    Layout.fillWidth: true
                    text: root.name
                    color: Constants.textPrimary
                    font.pixelSize: sp(Constants.fsBody)
                    font.bold: true
                    wrapMode: Text.Wrap
                    maximumLineCount: 2
                    elide: Text.ElideRight
                }
                Text {
                    Layout.fillWidth: true
                    text: root.productId + (root.sku.length > 0 ? "  ·  SKU " + root.sku : "")
                    color: Constants.textSecondary
                    font.pixelSize: sp(Constants.fsCaption)
                    elide: Text.ElideRight
                }
                Text {
                    Layout.fillWidth: true
                    text: (root.category.length > 0 ? root.category + "  ·  " : "") + InventoryStore.formatCurrency(root.price)
                    color: Constants.textSecondary
                    font.pixelSize: sp(Constants.fsCaption)
                    elide: Text.ElideRight
                }
            }
        }

        // Line 2: pills on the left, the stepper on the right. When the pills would be squeezed below their floor
        // (narrow phone, large font) the grid drops to one column and the stepper goes under them.
        GridLayout {
            Layout.fillWidth: true
            columns: root._geo.pillsWrap ? 1 : 2
            columnSpacing: root._geo.gap
            rowSpacing: root._geo.gap

            // A Flow, not a RowLayout: the number of pills is data, and the area can be narrow (Skill 78).
            Flow {
                Layout.fillWidth: true
                Layout.alignment: Qt.AlignVCenter
                spacing: dp(6)
                StatusPill { status: root.pillStatus; label: root.pillLabel }
                StatusPill { visible: root.inOrderLabel.length > 0; status: "processing"; label: root.inOrderLabel }
                StatusPill { visible: root.atMax; status: "pending"; label: qsTr("Max") }
            }

            // Not addable: say why, in words (never colour alone), instead of a dead stepper.
            Text {
                visible: !root.canAdd
                Layout.alignment: Qt.AlignRight | Qt.AlignVCenter
                text: root.reasonText
                color: Constants.textSecondary
                font.pixelSize: sp(Constants.fsSmall)
                font.bold: true
            }

            RowLayout {
                visible: root.canAdd
                Layout.alignment: Qt.AlignRight | Qt.AlignVCenter
                spacing: root._geo.gap

                QQC.AbstractButton {
                    id: minusBtn
                    implicitWidth: root._geo.minus
                    implicitHeight: root._geo.minus
                    enabled: root.qty > 0
                    Accessible.role: Accessible.Button
                    Accessible.name: qsTr("One less of %1").arg(root.name)
                    contentItem: Item {
                        Icon { anchors.centerIn: parent; name: "remove"; size: sp(16); color: minusBtn.enabled ? Constants.textPrimary : Constants.textMuted }
                    }
                    background: Rectangle {
                        radius: dp(Constants.radiusSm)
                        color: Constants.subtleBg
                        border.color: Constants.borderColor
                        border.width: 1
                    }
                    onClicked: root.stepRequested(root.productId, -1, root.maxQty)
                }

                QQC.TextField {
                    id: qtyField
                    implicitWidth: root._geo.field
                    implicitHeight: root._geo.fieldHeight
                    horizontalAlignment: TextInput.AlignHCenter
                    verticalAlignment: TextInput.AlignVCenter
                    font.pixelSize: sp(Constants.fsBodyLg)
                    font.bold: true
                    color: Constants.textPrimary
                    inputMethodHints: Qt.ImhDigitsOnly
                    // Digits only, six at most (PickerDraft.MAX_DIGITS); the draft refuses anything else anyway.
                    maximumLength: 6
                    validator: RegularExpressionValidator { regularExpression: /[0-9]{0,6}/ }
                    selectByMouse: true
                    Accessible.name: qsTr("Quantity of %1").arg(root.name)
                    background: Rectangle {
                        radius: dp(Constants.radiusSm)
                        color: Constants.cardBg
                        border.color: qtyField.activeFocus ? Constants.brand1 : Constants.borderColor
                        border.width: qtyField.activeFocus ? 2 : 1
                    }
                    // Commit while typing so the footer and the Add button follow; an empty field is "not a number"
                    // (PickerDraft refuses it) and is put back to the draft quantity when the person is done.
                    onTextEdited: { root.qtyTyped(root.productId, text, root.maxQty); root.syncField() }   // the model answers synchronously
                    onEditingFinished: text = String(root.qty)
                    onActiveFocusChanged: if (!activeFocus) text = String(root.qty)
                }

                QQC.AbstractButton {
                    id: plusBtn
                    implicitWidth: root._geo.plus
                    implicitHeight: root._geo.plus
                    enabled: root.qty < root.maxQty
                    Accessible.role: Accessible.Button
                    Accessible.name: qsTr("One more of %1").arg(root.name)
                    contentItem: Item {
                        Icon { anchors.centerIn: parent; name: "add"; size: sp(16); color: plusBtn.enabled ? Constants.textOnBrand : Constants.textMuted }
                    }
                    background: Rectangle {
                        radius: dp(Constants.radiusSm)
                        color: plusBtn.enabled ? Constants.brand1 : Constants.subtleBg
                        border.color: plusBtn.enabled ? "transparent" : Constants.borderColor
                        border.width: 1
                    }
                    onClicked: root.stepRequested(root.productId, 1, root.maxQty)
                }
            }
        }
    }
}
