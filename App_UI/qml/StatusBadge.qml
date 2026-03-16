
import QtQuick 6.5

Rectangle {
    id: badge
    property string text: "status"
    property string status: "pending"   // "completed" | "processing" | "pending"

    radius: 12
    height: 24
    width: content.width + 16

    // Colors chosen per status
    property color fill:   status === "completed"  ? "#dcfce7"
                        : (status === "processing" ? "#e0f2fe" : "#fef3c7")

    property color stroke: status === "completed"  ? "#22c55e"
                        : (status === "processing" ? "#38bdf8" : "#f59e0b")

    color: fill
    border.color: stroke

    Text {
        id: content
        text: badge.text
        color: badge.stroke
        anchors.centerIn: parent
        font.pixelSize: 12
        font.bold: true
    }
}
