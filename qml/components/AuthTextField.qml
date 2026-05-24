import QtQuick
import QtQuick.Controls as QQC
import QtQuick.Layouts

import "../helper"

ColumnLayout {
    id: root

    property alias text: input.text
    property alias placeholderText: input.placeholderText
    property alias echoMode: input.echoMode
    property alias inputMethodHints: input.inputMethodHints
    property alias readOnly: input.readOnly
    property alias acceptableInput: input.acceptableInput
    property alias inputItem: input

    property string label: ""
    property string helperText: ""
    property string errorText: ""
    property string trailingText: ""
    property string trailingLinkText: ""

    signal trailingLinkClicked()
    signal accepted()

    spacing: 4

    RowLayout {
        Layout.fillWidth: true
        spacing: 8
        visible: root.label.length > 0 || root.trailingLinkText.length > 0 || root.trailingText.length > 0

        Text {
            text: root.label
            color: "#374151"
            font.pixelSize: 12
            font.bold: true
            Layout.fillWidth: true
            visible: root.label.length > 0
        }

        Text {
            visible: root.trailingText.length > 0 && root.trailingLinkText.length === 0
            text: root.trailingText
            color: "#6b7280"
            font.pixelSize: 11
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

    QQC.TextField {
        id: input
        Layout.fillWidth: true
        font.pixelSize: 13
        leftPadding: 12
        rightPadding: 12
        topPadding: 10
        bottomPadding: 10
        selectByMouse: true
        onAccepted: root.accepted()

        background: Rectangle {
            radius: 8
            color: input.enabled ? "#ffffff" : "#f9fafb"
            border.color: root.errorText.length > 0
                ? "#dc2626"
                : (input.activeFocus ? Constants.primaryBlue : "#d1d5db")
            border.width: input.activeFocus || root.errorText.length > 0 ? 2 : 1
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
