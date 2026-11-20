import QtQuick
import QtQuick.Controls as QQC
import QtQuick.Layouts

import "../helper"
import "../helper/CartStepperGeometry.js" as CSG

// Quantity stepper for one cart line: [-] qty [+] and, when `removable`, a remove button (picker v2, S5c).
// Every button is a 48 dp touch target (KNOWN-ISSUES 24a, 28b: they were 28 dp); the painted frame stays 32 dp,
// so the cart looks as light as before and the 8 dp ring around each frame is part of the target. The sizes come
// from CartStepperGeometry.js (tested headless); this file only paints them. The owner decides what the taps DO
// (stock ceiling, removing the row): this component never touches a model.
//
// TalkBack: each button has a name (it had none: "unlabeled button"); the quantity is a plain Text, read as its number.
RowLayout {
    id: root

    property real value: 0
    property bool removable: false
    property string itemName: ""      // product name, appended to the spoken button names
    signal decrement()
    signal increment()
    signal removeRequested()

    spacing: dp(CSG.GAP)

    // One button: a full-size touch area with a smaller painted frame in its middle.
    component StepButton: QQC.AbstractButton {
        id: btn
        property string iconName: ""
        property color iconColor: Constants.textPrimary
        property real iconSize: 16
        property bool framed: true

        implicitWidth: dp(CSG.TARGET)
        implicitHeight: dp(CSG.TARGET)
        Layout.preferredWidth: dp(CSG.TARGET)
        Layout.preferredHeight: dp(CSG.TARGET)
        padding: 0
        Accessible.role: Accessible.Button
        Accessible.name: text

        background: Item {
            Rectangle {
                anchors.centerIn: parent
                width: dp(CSG.VISUAL); height: dp(CSG.VISUAL)
                radius: dp(8)
                color: btn.pressed ? Constants.subtleBg : "transparent"
                border.color: Constants.borderColor
                border.width: btn.framed ? 1 : 0
            }
        }
        contentItem: Item {
            Icon { anchors.centerIn: parent; name: btn.iconName; size: sp(btn.iconSize); color: btn.iconColor }
        }
    }

    StepButton {
        iconName: "remove"
        text: root.itemName === "" ? qsTr("Decrease quantity") : qsTr("Decrease quantity of %1").arg(root.itemName)
        onClicked: root.decrement()
    }
    Text {
        text: String(root.value)
        color: Constants.textPrimary
        font.pixelSize: sp(Constants.fsBody)
        font.bold: true
        Layout.preferredWidth: dp(CSG.QTY_W)
        horizontalAlignment: Text.AlignHCenter
    }
    StepButton {
        iconName: "add"
        text: root.itemName === "" ? qsTr("Increase quantity") : qsTr("Increase quantity of %1").arg(root.itemName)
        onClicked: root.increment()
    }
    StepButton {
        visible: root.removable
        iconName: "close"
        iconColor: Constants.danger
        iconSize: 14
        framed: false
        text: root.itemName === "" ? qsTr("Remove item") : qsTr("Remove %1").arg(root.itemName)
        onClicked: root.removeRequested()
    }
}
