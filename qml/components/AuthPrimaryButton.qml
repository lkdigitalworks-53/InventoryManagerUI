import QtQuick
import QtQuick.Controls as QQC
import QtQuick.Layouts

import "../helper"

QQC.Button {
    id: root

    property bool loading: false
    property color baseColor: Constants.primaryBlue
    property color textColor: "#ffffff"

    height: 44
    // Don't set `enabled` here — let the consumer fully control it. Setting
    // a default binding on `enabled` competes with the consumer's binding and
    // can cause one to silently win at construction time, leaving the button
    // permanently disabled.

    contentItem: RowLayout {
        spacing: 8

        Item { Layout.fillWidth: true }

        QQC.BusyIndicator {
            visible: root.loading
            running: root.loading
            implicitHeight: 18
            implicitWidth: 18
            palette.dark: root.textColor
        }

        Text {
            text: root.text
            color: root.textColor
            font.bold: true
            font.pixelSize: 14
            elide: Text.ElideRight
        }

        Item { Layout.fillWidth: true }
    }

    background: Rectangle {
        radius: 8
        color: !root.enabled
            ? Qt.lighter(root.baseColor, 1.4)
            : (root.pressed ? Qt.darker(root.baseColor, 1.15)
                : (root.hovered ? Qt.darker(root.baseColor, 1.05) : root.baseColor))
        Behavior on color { ColorAnimation { duration: 120 } }
    }
}
