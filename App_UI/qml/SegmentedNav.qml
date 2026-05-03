
import QtQuick 6.5
import QtQuick.Controls 6.5
import QtQuick.Layouts 6.5

Item {
    id: root
    property alias model: rep.model
    property int currentIndex: 0
    implicitHeight: 44

    Rectangle { anchors.fill: parent; color: "#ffffff"; radius: 12; border.color: "#e5e7eb"; border.width: 1 }

    Flickable {
        id: bar
        anchors.fill: parent; anchors.margins: 8
        contentWidth: row.implicitWidth
        contentHeight: height
        clip: true
        interactive: row.implicitWidth > width

        Row {
            id: row
            spacing: 8
            Repeater {
                id: rep
                delegate: Button {
                    width: Math.min(200, Math.max(96, (bar.width - (rep.count-1)*8) / Math.max(1, rep.count)))
                    height: bar.height - 2
                    checkable: true
                    checked: index === root.currentIndex
                    property color activeColor: modelData.activeColor || "#3b82f6"
                    background: Rectangle { radius: 10; color: checked ? activeColor : "#ffffff";
                                             border.color: checked ? activeColor : "transparent"; border.width: 0 }
                    contentItem: Row { spacing: 6; anchors.centerIn: parent
                        Text { text: modelData.icon; font.pixelSize: 14; color: checked ? "#ffffff" : "#6b7280" }
                        Text { text: modelData.label; font.pixelSize: 13; color: checked ? "#ffffff" : "#4b5563"; font.bold: checked }
                    }
                    onClicked: root.currentIndex = index
                }
            }
        }
        ScrollBar.horizontal: ScrollBar { }
    }
}
