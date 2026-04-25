
import QtQuick 6.5
import QtQuick.Controls 6.5

Rectangle {
    id: badge
    property string text: "status"
    property string status: "pending"   // "completed" | "processing" | "pending" | "out of stock"
    property bool showDropdown: false

    signal statusChangeRequested(string newStatus)

    radius: 12
    height: 24
    implicitWidth: content.implicitWidth + dropIcon.implicitWidth + (showDropdown ? 28 : 16)

    // Colors chosen per status
    property color fill:   status === "completed"   ? "#dcfce7"
                        : (status === "processing"  ? "#e0f2fe"
                        : (status === "out of stock" ? "#fee2e2" : "#fef3c7"))

    property color stroke: status === "completed"   ? "#22c55e"
                        : (status === "processing"  ? "#38bdf8"
                        : (status === "out of stock" ? "#ef4444" : "#f59e0b"))

    color: fill
    border.color: stroke

    Row {
        anchors.centerIn: parent
        spacing: 4
        Text {
            id: content
            text: badge.text
            color: badge.stroke
            font.pixelSize: 12
            font.bold: true
        }
        Text {
            id: dropIcon
            visible: badge.showDropdown
            text: "\u25BE"
            color: badge.stroke
            font.pixelSize: 10
        }
    }

    MouseArea {
        anchors.fill: parent
        visible: badge.showDropdown
        cursorShape: Qt.PointingHandCursor
        onClicked: statusMenu.open()
    }

    Menu {
        id: statusMenu
        MenuItem { text: "Pending";      onTriggered: badge.statusChangeRequested("pending") }
        MenuItem { text: "Processing";   onTriggered: badge.statusChangeRequested("processing") }
        MenuItem { text: "Completed";    onTriggered: badge.statusChangeRequested("completed") }
        MenuItem { text: "Out of Stock"; onTriggered: badge.statusChangeRequested("out of stock") }
    }
}
