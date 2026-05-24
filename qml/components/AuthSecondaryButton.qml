import QtQuick
import QtQuick.Controls as QQC

QQC.Button {
    id: root

    height: 40

    contentItem: Text {
        text: root.text
        color: root.enabled ? "#374151" : "#9ca3af"
        font.bold: true
        font.pixelSize: 13
        horizontalAlignment: Text.AlignHCenter
        verticalAlignment: Text.AlignVCenter
        elide: Text.ElideRight
    }

    background: Rectangle {
        radius: 8
        color: root.pressed ? "#f3f4f6" : (root.hovered ? "#f9fafb" : "#ffffff")
        border.color: "#d1d5db"
        border.width: 1
    }
}
