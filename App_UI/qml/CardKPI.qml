
import QtQuick 6.5
import QtQuick.Controls 6.5
import QtQuick.Layouts 6.5

Rectangle {
    id: card
    property string title: ""
    property string subtitle: ""
    property string value: ""

    radius: 12
    color: "#ffffff"
    border.color: "#e5e7eb"

    Layout.fillWidth: true
    Layout.preferredWidth: 320
    height: 100

    Rectangle { anchors.fill: parent; anchors.margins: 12; radius: 12; color: "#f3f4f6"; border.color: "#e5e7eb"; border.width: 1 }

    Column { anchors.fill: parent; anchors.margins: 20; spacing: 6
        Label { text: title; font.pixelSize: 13; font.bold: true; color: "#1f2937" }
        Label { text: subtitle; font.pixelSize: 11; color: "#6b7280" }
        Label { text: value; font.pixelSize: 16; color: "#ef4444" }
    }
}
