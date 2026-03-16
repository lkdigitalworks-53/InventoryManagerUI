
import QtQuick 6.5
import QtQuick.Controls 6.5
import QtQuick.Layouts 6.5
import BusinessApp 1.0

ApplicationWindow {
    id: app
    width: 1024; height: 640; visible: true
    title: "Business Management"

    // Keep graphics/scene graph around across Android lifecycle transitions
    persistentSceneGraph: true
    persistentGraphics: true

    // Helper: only recalc 'compact' while the app is active to avoid delegate churn during stop
    function updateCompact() { page.compact = page.width < 480 }

    Rectangle {
        id: header
        anchors.left: parent.left; anchors.right: parent.right; anchors.top: parent.top
        height: 120
        gradient: Gradient {
            GradientStop { position: 0.0; color: "#3158ff" }
            GradientStop { position: 1.0; color: "#6b41ff" }
        }
        ColumnLayout {
            anchors.fill: parent; anchors.margins: 16; spacing: 8
            ColumnLayout { spacing: 4
                Label { text: "Business Management"; color: "#ffffff"; font.bold: true; font.pixelSize: 18 }
                Label { text: "Manage your business operations efficiently"; color: "#dbeafe"; font.pixelSize: 12 }
            }
            SegmentedNav {
                id: nav
                Layout.alignment: Qt.AlignHCenter
                Layout.preferredWidth: Math.min(800, app.width - 32)
                model: [
                    { label: "Orders",    icon: "" },
                    { label: "Inventory", icon: "" },
                    { label: "Sales",     icon: "" },
                    { label: "Staff",     icon: "" }
                ]
                currentIndex: 0
                onCurrentIndexChanged: stack.currentIndex = currentIndex
            }
        }
    }

    Button {
        id: newOrder
        text: "+  New Order"
        anchors.top: header.bottom; anchors.topMargin: 12
        anchors.right: parent.right; anchors.rightMargin: 16
        padding: 10
        background: Rectangle { radius: 8; color: "#ff7a00" }
        contentItem: Text { text: newOrder.text; color: "white"; font.bold: true; font.pixelSize: 12
            horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter }
        onClicked: dlg.open()
    }

    Flickable {
        id: page
        anchors.top: newOrder.bottom
        anchors.left: parent.left; anchors.right: parent.right; anchors.bottom: parent.bottom
        contentWidth: width
        contentHeight: contentCol.implicitHeight
        clip: true
        ScrollBar.vertical: ScrollBar {}
        property bool compact: false

        // Recompute compact only while active
        onWidthChanged: if (Qt.application.state === Qt.ApplicationActive) app.updateCompact()
        Component.onCompleted: app.updateCompact()
        Connections {
            target: Qt.application
            function onStateChanged() {
                if (Qt.application.state === Qt.ApplicationActive) app.updateCompact()
                // Freeze interaction during stop to avoid work while surface is going away
                table.interactive = (Qt.application.state === Qt.ApplicationActive)
            }
        }

        Column { id: contentCol; width: page.width; spacing: 16
            Column { spacing: 4
                Label { text: "Order Management"; color: "#111827"; font.bold: true; font.pixelSize: 18 }
                Label { text: "Manage and track customer orders"; color: "#6b7280"; font.pixelSize: 12 }
            }

            RowLayout {
                spacing: 16
                Layout.fillWidth: true
                width: page.width
                CardKPI { title: "Total Orders"; subtitle: "All time"; value: String(typeof OrdersStore.count === 'number' ? OrdersStore.count : 0) }
                CardKPI { title: "Pending"; subtitle: "Awaiting processing"; value: String(OrdersStore.pendingCount()) }
                CardKPI { title: "Completed"; subtitle: "This month"; value: String(OrdersStore.completedThisMonth()) }
                Item { Layout.fillWidth: true }
            }

            Rectangle {
                id: tableCard
                radius: 12; color: "#ffffff"; border.color: "#e5e7eb"
                anchors.left: parent.left; anchors.right: parent.right
                width: parent.width

                Column {
                    anchors.fill: parent; anchors.margins: 16; spacing: 12
                    Label { text: "Recent Orders"; font.pixelSize: 14; font.bold: true; color: "#111827" }
                    Label { text: "Latest customer orders"; font.pixelSize: 11; color: "#6b7280" }
                    TextField { id: search; placeholderText: "Search orders..."; font.pixelSize: 12
                        background: Rectangle { radius: 8; color: "#f3f4f6"; border.color: "#e5e7eb" } }

                    // Full header always exists; we only toggle visibility
                    Row {
                        id: headerRowFull
                        visible: !page.compact
                        spacing: 0; height: 32
                        property var roles:    ["Order ID","Customer","Items","Total","Status","Date","Actions"]
                        property var roleKeys: ["orderId","customer","items","total","status","date","actions"]
                        property var widths:   [0.14,0.24,0.10,0.14,0.14,0.14,0.10]
                        Repeater {
                            model: headerRowFull.roles
                            delegate: Button {
                                width: page.width * headerRowFull.widths[index]
                                height: parent.height
                                enabled: index < 6
                                background: Rectangle { color: "#ffffff" }
                                contentItem: Row {
                                    spacing: 4; anchors.verticalCenter: parent.verticalCenter; anchors.left: parent.left; anchors.leftMargin: 8
                                    Text { text: modelData; color: "#6b7280"; font.pixelSize: 12; font.bold: true }
                                    Text { visible: index < 6 && OrdersStore.currentSortRole === headerRowFull.roleKeys[index]
                                          ; text: OrdersStore.currentSortAscending ? "▲" : "▼"; color: "#9ca3af"; font.pixelSize: 10 }
                                }
                                onClicked: {
                                    var role = headerRowFull.roleKeys[index]
                                    var asc  = OrdersStore.currentSortRole === role ? !OrdersStore.currentSortAscending : true
                                    OrdersStore.sortBy(role, asc)
                                }
                            }
                        }
                    }

                    // Compact header also always exists; just toggle visibility
                    Row {
                        id: headerRowCompact
                        visible: page.compact
                        spacing: 0; height: 28
                        property var roles:    ["Order","Customer","Amt","Status"]
                        property var widths:   [0.40,0.30,0.15,0.15]
                        Repeater {
                            model: headerRowCompact.roles
                            delegate: Rectangle {
                                width: page.width * headerRowCompact.widths[index]
                                height: parent.height
                                color: "#ffffff"
                                Text { anchors.centerIn: parent; text: modelData; color: "#6b7280"; font.pixelSize: 12; font.bold: true }
                            }
                        }
                    }

                    Rectangle { height: 1; color: "#e5e7eb"; width: parent.width }

                    ListView {
                        id: table
                        model: OrdersStore
                        clip: true
                        spacing: 0
                        boundsBehavior: Flickable.StopAtBounds
                        height: Math.max(240, Math.min(page.height * 0.6, 480))
                        cacheBuffer: 200
                        delegate: OrderRow {
                            width: parent.width
                            compact: page.compact
                            widths: page.compact ? headerRowCompact.widths : headerRowFull.widths
                            orderId: orderId; customer: customer; items: items; total: total; status: status; date: date
                            onViewClicked: detail.openFor(orderId)
                            visible: search.text === "" || (String(orderId).toLowerCase() + String(customer).toLowerCase() + String(status).toLowerCase()).indexOf(search.text.toLowerCase()) >= 0
                            height: visible ? implicitHeight : 0
                        }
                        ScrollBar.vertical: ScrollBar {}
                    }
                }
            }
        }
    }

    NewOrderDialog { id: dlg; parent: app.contentItem }
}
