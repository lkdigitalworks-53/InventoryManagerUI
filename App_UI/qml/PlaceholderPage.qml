
import QtQuick 6.5
import QtQuick.Controls 6.5
Item { property string title: "Page"; anchors.fill: parent
    Rectangle { anchors.fill: parent; color: "#ffffff"; radius: 12; border.color: "#e5e7eb" }
    Label { text: title; anchors.centerIn: parent; font.pixelSize: 18; font.bold: true; color: "#111827" }
}
