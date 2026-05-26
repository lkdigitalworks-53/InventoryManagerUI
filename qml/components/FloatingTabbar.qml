import QtQuick
import QtQuick.Controls as QQC
import QtQuick.Layouts

import "../helper"

// Floating glass-pill tabbar — matches the prototype's `.tabbar` exactly:
//   • Anchored 12dp from each side, 14dp from bottom
//   • 22dp corner radius, glass background, soft shadow
//   • Brand-color active state, subtle muted inactive
//
// Stateless: parent supplies `currentIndex` and listens to `tabChanged(idx)`.
// Bind to navigation.currentIndex from Main.qml.
Item {
    id: root

    property int currentIndex: 0
    // Each entry: { icon: "...", label: "Home" }
    property var tabs: []

    signal tabChanged(int index)

    // Outer geometry — caller provides anchors; we own height.
    implicitHeight: dp(64) + dp(28)   // includes drop-shadow gutter below

    // Drop shadow stack (Qt.Effects-free approximation — works on all targets).
    Rectangle {
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.bottomMargin: dp(4)
        height: dp(64)
        radius: dp(22)
        color: Qt.rgba(0.058, 0.090, 0.165, 0.10)
        opacity: 0.6
    }
    Rectangle {
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.bottomMargin: dp(2)
        height: dp(64)
        radius: dp(22)
        color: Qt.rgba(0.058, 0.090, 0.165, 0.06)
    }

    // The pill itself. Opaque white per the prototype — translucent looked
    // grimy when the page beneath had busy content.
    Rectangle {
        id: pill
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        height: dp(64)
        radius: dp(22)
        color: Constants.cardBg
        border.color: Constants.borderColor
        border.width: 1

        RowLayout {
            anchors.fill: parent
            anchors.margins: dp(6)
            spacing: dp(4)

            Repeater {
                model: root.tabs
                delegate: QQC.AbstractButton {
                    id: tab
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    readonly property bool isActive: index === root.currentIndex

                    background: Rectangle {
                        radius: dp(14)
                        color: tab.pressed ? Qt.rgba(0.39, 0.40, 0.95, 0.10) : "transparent"
                        Behavior on color { ColorAnimation { duration: Constants.durFast } }
                    }

                    contentItem: ColumnLayout {
                        spacing: dp(2)

                        Text {
                            Layout.alignment: Qt.AlignHCenter
                            text: modelData.icon
                            color: tab.isActive ? Constants.brand2 : Constants.textSecondary
                            font.pixelSize: sp(20)
                            horizontalAlignment: Text.AlignHCenter
                        }
                        Text {
                            Layout.alignment: Qt.AlignHCenter
                            text: modelData.label
                            color: tab.isActive ? Constants.brand2 : Constants.textSecondary
                            font.pixelSize: sp(10)
                            font.bold: tab.isActive
                            horizontalAlignment: Text.AlignHCenter
                        }
                    }

                    onClicked: {
                        root.currentIndex = index
                        root.tabChanged(index)
                    }
                }
            }
        }
    }
}
