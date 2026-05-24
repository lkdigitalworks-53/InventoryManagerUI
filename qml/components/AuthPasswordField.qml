import QtQuick
import QtQuick.Controls as QQC
import QtQuick.Layouts

import "../helper"

ColumnLayout {
    id: root

    property alias text: input.text
    property alias placeholderText: input.placeholderText
    property alias inputItem: input

    property string label: ""
    property string helperText: ""
    property string errorText: ""
    property string trailingLinkText: ""

    property bool showStrength: false
    property int strengthScore: 0   // 0..4
    property string strengthLabel: ""

    signal trailingLinkClicked()
    signal accepted()

    spacing: 4

    RowLayout {
        Layout.fillWidth: true
        spacing: 8
        visible: root.label.length > 0 || root.trailingLinkText.length > 0

        Text {
            text: root.label
            color: "#374151"
            font.pixelSize: 12
            font.bold: true
            Layout.fillWidth: true
            visible: root.label.length > 0
        }

        Text {
            visible: root.trailingLinkText.length > 0
            text: root.trailingLinkText
            color: Constants.primaryBlue
            font.pixelSize: 11
            font.bold: true

            MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: root.trailingLinkClicked()
            }
        }
    }

    Rectangle {
        Layout.fillWidth: true
        Layout.preferredHeight: 42
        radius: 8
        color: input.enabled ? "#ffffff" : "#f9fafb"
        border.color: root.errorText.length > 0
            ? "#dc2626"
            : (input.activeFocus ? Constants.primaryBlue : "#d1d5db")
        border.width: input.activeFocus || root.errorText.length > 0 ? 2 : 1

        QQC.TextField {
            id: input
            anchors.left: parent.left
            anchors.right: toggleButton.left
            anchors.top: parent.top
            anchors.bottom: parent.bottom
            anchors.leftMargin: 4
            font.pixelSize: 13
            leftPadding: 8
            rightPadding: 4
            selectByMouse: true
            echoMode: toggleButton.revealed ? TextInput.Normal : TextInput.Password
            background: Item {}
            onAccepted: root.accepted()
        }

        Item {
            id: toggleButton
            property bool revealed: false
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.bottom: parent.bottom
            width: 42

            Text {
                anchors.centerIn: parent
                text: toggleButton.revealed ? "🙈" : "👁"
                font.pixelSize: 16
                color: "#6b7280"
            }

            MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: toggleButton.revealed = !toggleButton.revealed
            }
        }
    }

    // Strength meter (signup only)
    RowLayout {
        Layout.fillWidth: true
        Layout.topMargin: 2
        spacing: 4
        visible: root.showStrength && input.text.length > 0

        Repeater {
            model: 4
            delegate: Rectangle {
                Layout.fillWidth: true
                height: 4
                radius: 2
                color: {
                    if (root.strengthScore <= index) return "#e5e7eb"
                    if (root.strengthScore <= 1) return "#dc2626"
                    if (root.strengthScore === 2) return "#f59e0b"
                    if (root.strengthScore === 3) return "#22c55e"
                    return "#16a34a"
                }
            }
        }

        Text {
            text: root.strengthLabel
            color: {
                if (root.strengthScore <= 1) return "#b91c1c"
                if (root.strengthScore === 2) return "#b45309"
                return "#15803d"
            }
            font.pixelSize: 11
            font.bold: true
        }
    }

    Text {
        Layout.fillWidth: true
        visible: root.errorText.length > 0 || root.helperText.length > 0
        text: root.errorText.length > 0 ? root.errorText : root.helperText
        color: root.errorText.length > 0 ? "#b91c1c" : "#6b7280"
        font.pixelSize: 11
        wrapMode: Text.Wrap
    }
}
