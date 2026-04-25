import QtQuick 6.5
import QtQuick.Controls 6.5
import QtQuick.Layouts 6.5
import BusinessApp 1.0

Item {
    id: root
    property bool compact: false

    Flickable {
        anchors.fill: parent
        contentHeight: col.height
        clip: true
        flickableDirection: Flickable.VerticalFlick
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
            id: col
            width: root.width
            spacing: 16

            // ── Title + Download ──
            RowLayout {
                width: col.width; spacing: 8
                Column { spacing: 4; Layout.fillWidth: true
                    Label { text: "Sales Analytics"; color: "#111827"; font.bold: true; font.pixelSize: 18 }
                    Label { text: "Track revenue and sales performance"; color: "#6b7280"; font.pixelSize: 12 }
                }
                Button {
                    id: dlBtn; text: "Download Report"
                    background: Rectangle { radius: 8; color: "#ffffff"; border.color: "#d1d5db" }
                    contentItem: Text { text: dlBtn.text; color: "#374151"; font.pixelSize: 12
                        horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter }
                }
            }

            // ── KPI Cards ──
            Row {
                width: col.width; spacing: 12
                Rectangle {
                    width: (col.width - 36) / 4; height: 120; radius: 12
                    border.color: "#f97316"; border.width: 2; color: "#ffffff"
                    Column { x: 16; y: 14; spacing: 4; width: parent.width - 32
                        Row { width: parent.width; spacing: 0
                            Label { text: "Total Revenue"; font.pixelSize: 13; font.bold: true; color: "#374151"; Layout.fillWidth: true }
                            Item { width: parent.width - 100; height: 1 }
                            Label { text: "$"; font.pixelSize: 16; color: "#f97316" }
                        }
                        Item { width: 1; height: 4 }
                        Label { text: SalesStore.formatCurrency(SalesStore.totalRevenue); font.pixelSize: 20; font.bold: true; color: "#f97316" }
                        Label { text: "↗ 7.8% from last month"; font.pixelSize: 11; color: "#6b7280" }
                    }
                }
                Rectangle {
                    width: (col.width - 36) / 4; height: 120; radius: 12
                    border.color: "#22c55e"; border.width: 2; color: "#ffffff"
                    Column { x: 16; y: 14; spacing: 4; width: parent.width - 32
                        Row { width: parent.width; spacing: 0
                            Label { text: "Total Orders"; font.pixelSize: 13; font.bold: true; color: "#374151" }
                            Item { width: parent.width - 100; height: 1 }
                            Label { text: "☑"; font.pixelSize: 16; color: "#22c55e" }
                        }
                        Item { width: 1; height: 4 }
                        Label { text: SalesStore.formatNumber(SalesStore.totalOrders); font.pixelSize: 20; font.bold: true; color: "#22c55e" }
                        Label { text: "+12% from last month"; font.pixelSize: 11; color: "#6b7280" }
                    }
                }
                Rectangle {
                    width: (col.width - 36) / 4; height: 120; radius: 12
                    border.color: "#06b6d4"; border.width: 2; color: "#f0fdfa"
                    Column { x: 16; y: 14; spacing: 4; width: parent.width - 32
                        Row { width: parent.width; spacing: 0
                            Label { text: "Average Order"; font.pixelSize: 13; font.bold: true; color: "#374151" }
                            Item { width: parent.width - 110; height: 1 }
                            Label { text: "☰"; font.pixelSize: 16; color: "#06b6d4" }
                        }
                        Item { width: 1; height: 4 }
                        Label { text: SalesStore.formatCurrency(SalesStore.averageOrder); font.pixelSize: 20; font.bold: true; color: "#06b6d4" }
                        Label { text: "Per transaction"; font.pixelSize: 11; color: "#6b7280" }
                    }
                }
                Rectangle {
                    width: (col.width - 36) / 4; height: 120; radius: 12
                    border.color: "#f59e0b"; border.width: 2; color: "#fffbeb"
                    Column { x: 16; y: 14; spacing: 4; width: parent.width - 32
                        Row { width: parent.width; spacing: 0
                            Label { text: "Active Customers"; font.pixelSize: 13; font.bold: true; color: "#374151" }
                            Item { width: parent.width - 130; height: 1 }
                            Label { text: "👥"; font.pixelSize: 16; color: "#f59e0b" }
                        }
                        Item { width: 1; height: 4 }
                        Label { text: SalesStore.formatNumber(SalesStore.activeCustomers); font.pixelSize: 20; font.bold: true; color: "#f59e0b" }
                        Label { text: "+8% from last month"; font.pixelSize: 11; color: "#6b7280" }
                    }
                }
            }

            // ── Charts Row ──
            Row {
                width: col.width; spacing: 16

                // Revenue Overview (line chart)
                Rectangle {
                    width: (col.width - 16) / 2; height: 340; radius: 12
                    color: "#ffffff"; border.color: "#e5e7eb"
                    Column {
                        x: 16; y: 16; width: parent.width - 32; spacing: 8
                        Label { text: "Revenue Overview"; font.pixelSize: 14; font.bold: true; color: "#111827" }
                        Label { text: "Monthly revenue performance"; font.pixelSize: 11; color: "#6b7280" }
                        Item { width: 1; height: 8 }
                        // Chart area
                        Item {
                            id: revenueChart
                            width: parent.width; height: 220
                            property real maxVal: SalesStore.maxRevenueValue()
                            // Grid lines
                            Repeater {
                                model: 5
                                Rectangle {
                                    x: 50; y: index * (revenueChart.height - 30) / 4
                                    width: revenueChart.width - 60; height: 1; color: "#f3f4f6"
                                }
                            }
                            // Y-axis labels
                            Repeater {
                                model: 5
                                Text {
                                    x: 0; y: index * (revenueChart.height - 30) / 4 - 6
                                    text: String(Math.round(revenueChart.maxVal * (1 - index / 4) / 1000)) + "k"
                                    font.pixelSize: 9; color: "#9ca3af"
                                }
                            }
                            // Line + dots
                            Canvas {
                                anchors.fill: parent
                                onPaint: {
                                    var ctx = getContext("2d");
                                    ctx.clearRect(0, 0, width, height);
                                    var data = SalesStore.revenueData;
                                    var maxV = SalesStore.maxRevenueValue();
                                    var chartW = width - 70;
                                    var chartH = height - 30;
                                    var startX = 55;
                                    ctx.strokeStyle = "#3b82f6";
                                    ctx.lineWidth = 2;
                                    ctx.beginPath();
                                    for (var i = 0; i < data.length; ++i) {
                                        var px = startX + i * chartW / (data.length - 1);
                                        var py = chartH - (data[i].value / maxV) * chartH;
                                        if (i === 0) ctx.moveTo(px, py); else ctx.lineTo(px, py);
                                    }
                                    ctx.stroke();
                                    // dots
                                    ctx.fillStyle = "#3b82f6";
                                    for (var j = 0; j < data.length; ++j) {
                                        var dx = startX + j * chartW / (data.length - 1);
                                        var dy = chartH - (data[j].value / maxV) * chartH;
                                        ctx.beginPath(); ctx.arc(dx, dy, 4, 0, 2 * Math.PI); ctx.fill();
                                    }
                                }
                            }
                            // X-axis labels
                            Row {
                                x: 50; y: revenueChart.height - 20
                                width: revenueChart.width - 60; spacing: 0
                                Repeater {
                                    model: SalesStore.revenueData
                                    Text {
                                        width: (revenueChart.width - 60) / SalesStore.revenueData.length
                                        text: modelData.month; font.pixelSize: 10; color: "#9ca3af"
                                        horizontalAlignment: Text.AlignHCenter
                                    }
                                }
                            }
                        }
                    }
                }

                // Orders Overview (bar chart)
                Rectangle {
                    width: (col.width - 16) / 2; height: 340; radius: 12
                    color: "#ffffff"; border.color: "#e5e7eb"
                    Column {
                        x: 16; y: 16; width: parent.width - 32; spacing: 8
                        Label { text: "Orders Overview"; font.pixelSize: 14; font.bold: true; color: "#111827" }
                        Label { text: "Monthly order volume"; font.pixelSize: 11; color: "#6b7280" }
                        Item { width: 1; height: 8 }
                        Item {
                            id: ordersChart
                            width: parent.width; height: 220
                            property real maxVal: SalesStore.maxOrdersValue()
                            // Grid lines
                            Repeater {
                                model: 5
                                Rectangle {
                                    x: 40; y: index * (ordersChart.height - 30) / 4
                                    width: ordersChart.width - 50; height: 1; color: "#f3f4f6"
                                }
                            }
                            // Y-axis labels
                            Repeater {
                                model: 5
                                Text {
                                    x: 0; y: index * (ordersChart.height - 30) / 4 - 6
                                    text: String(Math.round(ordersChart.maxVal * (1 - index / 4)))
                                    font.pixelSize: 9; color: "#9ca3af"
                                }
                            }
                            // Bars
                            Row {
                                x: 45; y: 0; width: ordersChart.width - 55; height: ordersChart.height - 30
                                spacing: 4
                                Repeater {
                                    model: SalesStore.ordersData
                                    Item {
                                        width: (ordersChart.width - 55 - (SalesStore.ordersData.length - 1) * 4) / SalesStore.ordersData.length
                                        height: parent.height
                                        Rectangle {
                                            width: parent.width; radius: 3
                                            height: (modelData.value / ordersChart.maxVal) * parent.height
                                            y: parent.height - height
                                            gradient: Gradient {
                                                GradientStop { position: 0; color: "#60a5fa" }
                                                GradientStop { position: 1; color: "#3b82f6" }
                                            }
                                        }
                                    }
                                }
                            }
                            // X-axis labels
                            Row {
                                x: 45; y: ordersChart.height - 20
                                width: ordersChart.width - 55; spacing: 0
                                Repeater {
                                    model: SalesStore.ordersData
                                    Text {
                                        width: (ordersChart.width - 55) / SalesStore.ordersData.length
                                        text: modelData.month; font.pixelSize: 10; color: "#9ca3af"
                                        horizontalAlignment: Text.AlignHCenter
                                    }
                                }
                            }
                        }
                    }
                }
            }

            // ── Top Selling Products ──
            Rectangle {
                width: col.width; height: topCol.height + 32; radius: 12
                color: "#ffffff"; border.color: "#e5e7eb"
                Column {
                    id: topCol; x: 16; y: 16; width: parent.width - 32; spacing: 12
                    Label { text: "Top Selling Products"; font.pixelSize: 14; font.bold: true; color: "#111827" }
                    // Header
                    Row {
                        width: topCol.width; height: 28; spacing: 0
                        property var ws: [0.30, 0.20, 0.25, 0.25]
                        property var labels: ["Product", "Units Sold", "Revenue", "Share"]
                        Repeater {
                            model: parent.labels
                            Rectangle {
                                width: topCol.width * parent.ws[index]; height: 28; color: "transparent"
                                Text { text: modelData; color: "#6b7280"; font.pixelSize: 12; font.bold: true
                                    anchors.verticalCenter: parent.verticalCenter; leftPadding: 8 }
                            }
                        }
                    }
                    Rectangle { width: topCol.width; height: 1; color: "#e5e7eb" }
                    Repeater {
                        model: SalesStore.topProducts
                        Rectangle {
                            width: topCol.width; height: 40; color: index % 2 === 0 ? "#ffffff" : "#f9fafb"
                            Row {
                                anchors.verticalCenter: parent.verticalCenter; width: parent.width; spacing: 0
                                property var ws: [0.30, 0.20, 0.25, 0.25]
                                Item { width: parent.ws[0] * topCol.width; height: 32
                                    Text { text: modelData.name; color: "#111827"; font.pixelSize: 12; font.bold: true
                                        anchors.verticalCenter: parent.verticalCenter; leftPadding: 8 }
                                }
                                Item { width: parent.ws[1] * topCol.width; height: 32
                                    Text { text: String(modelData.sold); color: "#374151"; font.pixelSize: 12
                                        anchors.verticalCenter: parent.verticalCenter; leftPadding: 8 }
                                }
                                Item { width: parent.ws[2] * topCol.width; height: 32
                                    Text { text: SalesStore.formatCurrency(modelData.revenue); color: "#374151"; font.pixelSize: 12
                                        anchors.verticalCenter: parent.verticalCenter; leftPadding: 8 }
                                }
                                Item { width: parent.ws[3] * topCol.width; height: 32
                                    Rectangle {
                                        anchors.verticalCenter: parent.verticalCenter; x: 8
                                        width: parent.width - 20; height: 8; radius: 4; color: "#e5e7eb"
                                        Rectangle {
                                            width: parent.width * (modelData.revenue / SalesStore.totalRevenue)
                                            height: 8; radius: 4; color: "#3b82f6"
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
