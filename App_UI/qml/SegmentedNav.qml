
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
                    width: Math.min(160, Math.max(96, (bar.width - (rep.count-1)*8) / Math.max(1, rep.count)))
                    height: bar.height - 2
                    checkable: true
                    checked: index === root.currentIndex
                    background: Rectangle { radius: 10; color: checked ? "#ffe8d6" : "#ffffff";
                                             border.color: checked ? "#ff7a00" : "#e5e7eb"; border.width: checked ? 2 : 1 }
                    contentItem: Row { spacing: 6; anchors.centerIn: parent
                        Text { text: modelData.icon; font.family: "Segoe MDL2 Assets"; font.pixelSize: 14; color: checked ? "#ff7a00" : "#6b7280" }
                        Text { text: modelData.label; font.pixelSize: 13; color: checked ? "#1f2937" : "#4b5563"; font.bold: checked }
                    }
                    onClicked: root.currentIndex = index
                }
            }
        }
        ScrollBar.horizontal: ScrollBar { }
    }
}
