import QtQuick 6.5
import QtQuick.Controls 6.5
import QtQuick.Layouts 6.5
import BusinessApp 1.0

Item {
    id: row
    property string orderId
    property string customer
    property int items
    property var total
    property string status
    property string date
    property var widths: [0.14,0.24,0.10,0.14,0.14,0.14,0.10]
    property bool compact: false
    signal viewClicked(string orderId)
    signal approveClicked(string orderId)
    signal editClicked(string orderId)
    signal statusDropdownChanged(string orderId, string newStatus)

    function colWidth(i) { return row.width * row.widths[i]; }

    implicitHeight: compact ? 68 : 44

    Rectangle { anchors.fill: parent; color: "#ffffff" }
    Rectangle { anchors.left: parent.left; anchors.right: parent.right; anchors.bottom: parent.bottom; height: 1; color: "#f1f5f9" }

    // ── Full row (7 columns) ──
    Item {
        anchors.fill: parent
        visible: !compact

        Text { x: 0;                                       width: colWidth(0); text: orderId;  color: "#111827"; font.pixelSize: 12; verticalAlignment: Text.AlignVCenter; height: parent.height; leftPadding: 8 }
        Text { x: colWidth(0);                              width: colWidth(1); text: customer; color: "#111827"; font.pixelSize: 12; verticalAlignment: Text.AlignVCenter; height: parent.height; leftPadding: 4 }
        Text { x: colWidth(0)+colWidth(1);                  width: colWidth(2); text: items;    color: "#111827"; font.pixelSize: 12; verticalAlignment: Text.AlignVCenter; height: parent.height; leftPadding: 4 }
        Text { x: colWidth(0)+colWidth(1)+colWidth(2);      width: colWidth(3); text: (typeof total === 'number' ? OrdersStore.formatCurrency(total) : total); color: "#111827"; font.pixelSize: 12; verticalAlignment: Text.AlignVCenter; height: parent.height; leftPadding: 4 }

        Item {
            x: colWidth(0)+colWidth(1)+colWidth(2)+colWidth(3)
            width: colWidth(4); height: parent.height
            StatusBadge { anchors.verticalCenter: parent.verticalCenter; text: status; status: status; showDropdown: true
                onStatusChangeRequested: function(s) { row.statusDropdownChanged(row.orderId, s) } }
        }

        Text { x: colWidth(0)+colWidth(1)+colWidth(2)+colWidth(3)+colWidth(4); width: colWidth(5); text: date; color: "#6b7280"; font.pixelSize: 12; verticalAlignment: Text.AlignVCenter; height: parent.height; leftPadding: 4 }

        Row {
            x: colWidth(0)+colWidth(1)+colWidth(2)+colWidth(3)+colWidth(4)+colWidth(5)
            width: colWidth(6); height: parent.height; spacing: 4
            anchors.verticalCenter: undefined
            Button {
                anchors.verticalCenter: parent.verticalCenter
                visible: row.status === "pending"
                width: 28; height: 28; padding: 0
                background: Rectangle { radius: 6; color: "#dcfce7"; border.color: "#22c55e" }
                contentItem: Text { text: "\u2713"; color: "#22c55e"; font.pixelSize: 14; font.bold: true
                    horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter }
                onClicked: row.approveClicked(row.orderId)
                ToolTip.visible: hovered; ToolTip.text: "Approve"
            }
            Button {
                anchors.verticalCenter: parent.verticalCenter
                width: 28; height: 28; padding: 0
                background: Rectangle { radius: 6; color: "#f3f4f6"; border.color: "#e5e7eb" }
                contentItem: Text { text: "\u270E"; color: "#6b7280"; font.pixelSize: 14
                    horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter }
                onClicked: row.editClicked(row.orderId)
                ToolTip.visible: hovered; ToolTip.text: "Edit"
            }
        }
    }

    // ── Compact row (2-line) ──
    Column {
        anchors.fill: parent; anchors.margins: 8
        visible: compact; spacing: 4

        Row {
            width: parent.width; height: 20
            Text { text: orderId; color: "#111827"; font.pixelSize: 13; font.bold: true }
            Text { text: "  " + items + " items"; color: "#6b7280"; font.pixelSize: 11 }
            Item { width: parent.width - x; height: 1 }
            Text { text: (typeof total === 'number' ? OrdersStore.formatCurrency(total) : total); color: "#111827"; font.pixelSize: 13 }
        }
        Row {
            width: parent.width; height: 24; spacing: 8
            Text { text: customer; color: "#111827"; font.pixelSize: 12; elide: Text.ElideRight; width: parent.width * 0.35 }
            StatusBadge { text: status; status: status; showDropdown: true; anchors.verticalCenter: parent.verticalCenter
                onStatusChangeRequested: function(s) { row.statusDropdownChanged(row.orderId, s) } }
            Text { text: date; color: "#6b7280"; font.pixelSize: 11 }
        }
    }
}
