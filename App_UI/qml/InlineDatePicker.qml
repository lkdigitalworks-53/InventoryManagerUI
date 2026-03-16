
import QtQuick 6.5
import QtQuick.Layouts 6.5
import QtQuick.Controls 6.5

Popup {
    id: picker
    modal: true
    focus: true
    closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside
    width: Math.min(360, parent ? parent.width - 24 : 360)
    height: Math.min(420, parent ? parent.height - 24 : 420)

    property date date: new Date()
    signal accepted(date date)

    contentItem: Frame {
        padding: 8
        ColumnLayout { spacing: 6; anchors.fill: parent
            DayOfWeekRow { Layout.fillWidth: true; locale: Qt.locale("en_US") }
            MonthGrid {
                id: monthGrid
                Layout.fillWidth: true
                Layout.fillHeight: true
                implicitWidth: 280
                implicitHeight: 220
                month: picker.date.getMonth()
                year: picker.date.getFullYear()
                locale: Qt.locale("en_US")
                onClicked: function(d) { picker.date = d; picker.accepted(d); picker.close(); }
            }
            RowLayout { Layout.fillWidth: true
                Button { text: "Today"; onClicked: {
                    const now = new Date(); picker.date = now; monthGrid.year = now.getFullYear(); monthGrid.month = now.getMonth(); picker.accepted(picker.date); picker.close(); } }
                Item { Layout.fillWidth: true }
                Button { text: "Cancel"; onClicked: picker.close() }
            }
        }
    }
}
