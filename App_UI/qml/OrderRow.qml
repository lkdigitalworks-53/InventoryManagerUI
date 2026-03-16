
import QtQuick 6.5
import QtQuick.Controls 6.5
import QtQuick.Layouts 1.3

Item {
    id: row
    property string orderId
    property string customer
    property int items
    property string total
    property string status
    property string date
    property var widths: [0.14,0.24,0.10,0.14,0.14,0.14,0.10]
    property bool compact: false
    signal viewClicked(string orderId)

    implicitHeight: compact ? 68 : 44

    Rectangle { anchors.fill: parent; color: "#ffffff" }
    Rectangle { anchors.left: parent.left; anchors.right: parent.right; anchors.bottom: parent.bottom; height: 1; color: "#f1f5f9" }

    // Keep both variants resident to avoid destruction/creation during size/lifecycle changes
    StackLayout {
        anchors.fill: parent
        currentIndex: compact ? 1 : 0

        // Full, 7-column row
        Row {
            spacing: 0
            function colWidth(i) { return row.width * row.widths[i]; }
            Text { width: colWidth(0); text: orderId; anchors.verticalCenter: parent.verticalCenter; anchors.leftMargin: 8; color: "#111827"; font.pixelSize: 12 }
            Text { width: colWidth(1); text: customer; anchors.verticalCenter: parent.verticalCenter; color: "#111827"; font.pixelSize: 12 }
            Text { width: colWidth(2); text: items; anchors.verticalCenter: parent.verticalCenter; color: "#111827"; font.pixelSize: 12 }
            Text { width: colWidth(3); text: (typeof total === 'number' ? OrdersStore.formatCurrency(total) : total); anchors.verticalCenter: parent.verticalCenter; color: "#111827"; font.pixelSize: 12 }
            Item { width: colWidth(4); height: parent.height
                StatusBadge { anchors.verticalCenter: parent.verticalCenter; text: status; status: status } }
            Text { width: colWidth(5); text: date; anchors.verticalCenter: parent.verticalCenter; color: "#6b7280"; font.pixelSize: 12 }
            Button { width: colWidth(6); height: 28; anchors.verticalCenter: parent.verticalCenter; text: "View"; padding: 6
                background: Rectangle { radius: 6; color: "#f3f4f6"; border.color: "#e5e7eb" }
                contentItem: Text { text: "View"; color: "#1f2937"; font.pixelSize: 12; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter }
                onClicked: row.viewClicked(row.orderId) }
        }

        // Compact, 2-line row (collapsed columns)
        Column {
            anchors.fill: parent; anchors.margins: 8; spacing: 4
            Row {
                width: parent.width
                Text { text: orderId; color: "#111827"; font.pixelSize: 13; font.bold: true }
                Item { width: 8 }
                Text { text: items + " items"; color: "#6b7280"; font.pixelSize: 11 }
                Item { Layout.fillWidth: true }
                Text { text: (typeof total === 'number' ? OrdersStore.formatCurrency(total) : total); color: "#111827"; font.pixelSize: 13; anchors.right: parent.right }
            }
            Row {
                width: parent.width; spacing: 8
                Text { text: customer; color: "#111827"; font.pixelSize: 12; elide: Text.ElideRight; width: parent.width * 0.45 }
                StatusBadge { text: status; status: status }
                Item { width: 8 }
                Text { text: date; color: "#6b7280"; font.pixelSize: 11; horizontalAlignment: Text.AlignRight; width: parent.width * 0.25 }
                ToolButton { text: "›"; onClicked: row.viewClicked(row.orderId) }
            }
        }
    }
}
