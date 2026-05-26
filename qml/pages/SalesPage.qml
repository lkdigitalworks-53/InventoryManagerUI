import QtQuick
import QtQuick.Controls as QQC
import QtQuick.Layouts

import "../components"
import "../helper"
import "../model"

// Modern sales report — segmented period pill, gradient hero card with area
// chart, weekly bar breakdown, top items list. All numbers from SalesStore.
Item {
    id: root

    property bool compact: false

    signal exportRequested()

    property int _period: 1   // 0=Day, 1=Week, 2=Month, 3=Year

    // Recomputed by _rebuildBreakdown() whenever _period or OrdersStore.revision changes.
    property var _breakdown: []
    property real _periodTotal: 0
    property string _periodLabel: ""
    property string _periodCompare: ""

    property int _ordersWatcher: OrdersStore.revision
    on_OrdersWatcherChanged: _rebuildBreakdown()
    on_PeriodChanged: _rebuildBreakdown()
    Component.onCompleted: _rebuildBreakdown()

    Rectangle { anchors.fill: parent; color: Constants.appBg }

    GlassHeader {
        id: header
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        title: "Sales"
        subtitle: "Revenue & performance"

        actions: [
            IconActionButton {
                variant: "glass"
                text: "⤴"
                onClicked: root.exportRequested()
            }
        ]
    }

    // Empty state — clean dedicated screen when nothing's been sold yet.
    Item {
        anchors.top: header.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        visible: SalesStore.totalOrders <= 0
        ColumnLayout {
            anchors.centerIn: parent
            spacing: dp(Constants.space3)
            Text { text: "📊"; font.pixelSize: sp(56); Layout.alignment: Qt.AlignHCenter }
            Text {
                text: "No sales data yet"
                font.pixelSize: sp(Constants.fsH2)
                font.bold: true
                color: Constants.textPrimary
                Layout.alignment: Qt.AlignHCenter
            }
            Text {
                text: "Complete orders to see analytics here."
                font.pixelSize: sp(Constants.fsBodyLg)
                color: Constants.textSecondary
                Layout.alignment: Qt.AlignHCenter
            }
        }
    }

    QQC.ScrollView {
        anchors.top: header.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        clip: true
        visible: SalesStore.totalOrders > 0
        QQC.ScrollBar.horizontal.policy: QQC.ScrollBar.AlwaysOff

        ColumnLayout {
            id: stack
            width: root.width
            spacing: dp(Constants.space4)

            SegmentedPill {
                Layout.fillWidth: true
                Layout.leftMargin: dp(Constants.space4)
                Layout.rightMargin: dp(Constants.space4)
                Layout.topMargin: dp(Constants.space3)
                model: ["Day", "Week", "Month", "Year"]
                selected: root._period
                onSegmentSelected: function(idx, label) { root._period = idx }
            }

            // Hero gradient card with area chart
            Rectangle {
                Layout.fillWidth: true
                Layout.leftMargin: dp(Constants.space4)
                Layout.rightMargin: dp(Constants.space4)
                Layout.preferredHeight: dp(200)
                radius: dp(Constants.radiusLg)
                clip: true
                gradient: Gradient {
                    orientation: Gradient.Vertical
                    GradientStop { position: 0.0; color: Constants.brand1 }
                    GradientStop { position: 0.55; color: Constants.brand2 }
                    GradientStop { position: 1.0; color: Constants.brand3 }
                }

                Rectangle {
                    anchors.fill: parent
                    radius: parent.radius
                    gradient: Gradient {
                        orientation: Gradient.Vertical
                        GradientStop { position: 0.0; color: Qt.rgba(1,1,1,0.30) }
                        GradientStop { position: 0.55; color: Qt.rgba(1,1,1,0) }
                        GradientStop { position: 1.0; color: Qt.rgba(1,1,1,0) }
                    }
                }

                ColumnLayout {
                    anchors.fill: parent
                    anchors.margins: dp(Constants.space4)
                    spacing: dp(4)

                    Text {
                        text: root._periodLabel
                        color: Qt.rgba(1,1,1,0.85)
                        font.pixelSize: sp(Constants.fsSmall)
                    }

                    Text {
                        text: SalesStore.formatCurrency(root._periodTotal)
                        color: Constants.textOnBrand
                        font.pixelSize: sp(Constants.fsDisplay)
                        font.bold: true
                        font.letterSpacing: -0.5
                        Layout.topMargin: dp(2)
                    }

                    Text {
                        text: root._periodCompare
                        color: Qt.rgba(1,1,1,0.92)
                        font.pixelSize: sp(Constants.fsSmall)
                    }

                    Item { Layout.fillHeight: true }

                    // Mini sparkline area chart drawn on Canvas — driven by _breakdown.
                    Item {
                        Layout.fillWidth: true
                        Layout.preferredHeight: dp(70)

                        // Loosened: any breakdown with at least 2 datapoints can
                        // render — even if some are zero, the line is informative.
                        // Previously hid for any single-nonzero history, which
                        // looked like a missing chart in early use.
                        readonly property bool _hasEnoughData: (root._breakdown || []).length >= 2

                        // Friendly placeholder when there isn't enough data to chart.
                        Text {
                            anchors.centerIn: parent
                            visible: !parent._hasEnoughData
                            text: "Not enough data yet"
                            color: Qt.rgba(1, 1, 1, 0.75)
                            font.pixelSize: sp(Constants.fsCaption)
                        }

                        Canvas {
                            id: heroChart
                            anchors.fill: parent
                            visible: parent._hasEnoughData
                            property var _data: root._breakdown
                            on_DataChanged: requestPaint()
                            onPaint: {
                                var ctx = getContext("2d")
                                ctx.clearRect(0, 0, width, height)
                                var data = root._breakdown || []
                                if (data.length < 2) return
                                var maxV = root._maxBreakdown()
                                if (maxV <= 0) return
                                var stepX = width / (data.length - 1)

                            // Filled area
                            ctx.beginPath()
                            ctx.moveTo(0, height)
                            for (var i = 0; i < data.length; ++i) {
                                var x = i * stepX
                                var y = height - (data[i].value / maxV) * (height - 6)
                                ctx.lineTo(x, y)
                            }
                            ctx.lineTo(width, height)
                            ctx.closePath()
                            var grad = ctx.createLinearGradient(0, 0, 0, height)
                            grad.addColorStop(0, "rgba(255,255,255,0.55)")
                            grad.addColorStop(1, "rgba(255,255,255,0.00)")
                            ctx.fillStyle = grad
                            ctx.fill()

                            // Line
                            ctx.beginPath()
                            for (var j = 0; j < data.length; ++j) {
                                var px = j * stepX
                                var py = height - (data[j].value / maxV) * (height - 6)
                                if (j === 0) ctx.moveTo(px, py)
                                else ctx.lineTo(px, py)
                            }
                            ctx.strokeStyle = "rgba(255,255,255,0.95)"
                            ctx.lineWidth = 2.5
                            ctx.lineCap = "round"
                            ctx.stroke()
                            }
                        }
                    }
                }
            }

            // Breakdown bars
            ColumnLayout {
                Layout.fillWidth: true
                Layout.leftMargin: dp(Constants.space4)
                Layout.rightMargin: dp(Constants.space4)
                spacing: dp(Constants.space2)

                Text {
                    text: "Breakdown"
                    color: Constants.textPrimary
                    font.pixelSize: sp(Constants.fsBodyLg)
                    font.bold: true
                }

                Rectangle {
                    Layout.fillWidth: true
                    Layout.preferredHeight: dp(200)
                    radius: dp(Constants.radius)
                    color: Constants.cardBg
                    border.color: Constants.borderColor
                    border.width: 1

                    RowLayout {
                        anchors.fill: parent
                        anchors.margins: dp(Constants.space3)
                        spacing: dp(6)

                        Repeater {
                            // Period-aware breakdown: hourly (Day) / daily (Week) /
                            // weekly (Month) / monthly (Year). Recomputed by
                            // _rebuildBreakdown() whenever _period changes.
                            model: root._breakdown
                            delegate: ColumnLayout {
                                Layout.fillWidth: true
                                Layout.fillHeight: true
                                spacing: dp(4)

                                Item {
                                    Layout.fillWidth: true
                                    Layout.fillHeight: true

                                    Rectangle {
                                        anchors.left: parent.left
                                        anchors.right: parent.right
                                        anchors.bottom: parent.bottom
                                        radius: dp(Constants.radiusSm)
                                        height: Math.max(dp(6), parent.height *
                                                Math.min(1, modelData.value /
                                                    Math.max(1, root._maxBreakdown())))
                                        gradient: Gradient {
                                            orientation: Gradient.Vertical
                                            GradientStop { position: 0.0; color: Constants.brand2 }
                                            GradientStop { position: 1.0; color: Constants.brand1 }
                                        }
                                        Behavior on height { NumberAnimation { duration: Constants.durMed } }
                                    }
                                }

                                Text {
                                    text: modelData.label
                                    color: Constants.textSecondary
                                    font.pixelSize: sp(Constants.fsCaption)
                                    Layout.alignment: Qt.AlignHCenter
                                    elide: Text.ElideRight
                                }
                            }
                        }
                    }
                }
            }

            // Top items
            ColumnLayout {
                Layout.fillWidth: true
                Layout.leftMargin: dp(Constants.space4)
                Layout.rightMargin: dp(Constants.space4)
                spacing: dp(Constants.space2)

                RowLayout {
                    Layout.fillWidth: true
                    Text {
                        text: "Top items"
                        color: Constants.textPrimary
                        font.pixelSize: sp(Constants.fsBodyLg)
                        font.bold: true
                        Layout.fillWidth: true
                    }
                }

                Repeater {
                    model: SalesStore.topProducts
                    delegate: ListCard {
                        Layout.fillWidth: true
                        title: modelData.name
                        subtitle: modelData.sold + " sold"

                        leading: AvatarBadge {
                            label: (modelData.name || "?").charAt(0).toUpperCase()
                            palette: index % 4 === 0 ? Constants.grad1
                                   : index % 4 === 1 ? Constants.grad2
                                   : index % 4 === 2 ? Constants.grad3
                                   :                   Constants.grad4
                        }

                        Text {
                            Layout.alignment: Qt.AlignVCenter | Qt.AlignRight
                            text: SalesStore.formatCurrency(modelData.revenue)
                            color: Constants.textPrimary
                            font.pixelSize: sp(Constants.fsBody)
                            font.bold: true
                        }
                    }
                }
            }

            Item { Layout.preferredHeight: dp(Constants.tabbarClearance); Layout.fillWidth: true }
        }
    }

    // ─── Period-aware aggregation ───────────────────────────────────────────
    // Buckets completed orders into N slots based on _period:
    //   Day:   24 hourly slots (0–23h of today)
    //   Week:  7 daily slots (Mon..Sun of current week)
    //   Month: 4 weekly slots (W1..W4 of current month)
    //   Year:  12 monthly slots (Jan..Dec of current year)
    // Sets _breakdown, _periodTotal, _periodLabel, _periodCompare.

    function _rebuildBreakdown() {
        var orders = OrdersStore.orders || []
        var now = new Date()
        var bins = []
        var labels = []

        if (_period === 0) { // Day — 24 hourly bins
            for (var i = 0; i < 24; ++i) {
                bins.push(0)
                labels.push((i % 6 === 0) ? (i + "h") : "")
            }
            for (var k = 0; k < orders.length; ++k) {
                var o = orders[k]
                if (o.status !== "completed") continue
                var d = new Date(o.date)
                if (isNaN(d.getTime())) continue
                if (d.getFullYear() === now.getFullYear()
                    && d.getMonth() === now.getMonth()
                    && d.getDate() === now.getDate()) {
                    bins[d.getHours()] += (o.total || 0)
                }
            }
            _periodLabel = "Revenue today"
            _periodCompare = "▲ from yesterday"
        } else if (_period === 1) { // Week — 7 daily bins (Mon–Sun)
            var dayLabels = ["Mon","Tue","Wed","Thu","Fri","Sat","Sun"]
            for (var w = 0; w < 7; ++w) { bins.push(0); labels.push(dayLabels[w]) }
            // Compute Monday of current week
            var monday = new Date(now)
            var dow = (monday.getDay() + 6) % 7  // 0=Mon..6=Sun
            monday.setDate(monday.getDate() - dow)
            monday.setHours(0,0,0,0)
            var nextMonday = new Date(monday)
            nextMonday.setDate(monday.getDate() + 7)
            for (var k2 = 0; k2 < orders.length; ++k2) {
                var o2 = orders[k2]
                if (o2.status !== "completed") continue
                var d2 = new Date(o2.date)
                if (isNaN(d2.getTime())) continue
                if (d2 >= monday && d2 < nextMonday) {
                    var idx = (d2.getDay() + 6) % 7
                    bins[idx] += (o2.total || 0)
                }
            }
            _periodLabel = "Revenue this week"
            _periodCompare = "▲ from last week"
        } else if (_period === 2) { // Month — 4 weekly bins
            for (var m = 0; m < 4; ++m) { bins.push(0); labels.push("W" + (m+1)) }
            var startMonth = new Date(now.getFullYear(), now.getMonth(), 1)
            var endMonth = new Date(now.getFullYear(), now.getMonth() + 1, 1)
            for (var k3 = 0; k3 < orders.length; ++k3) {
                var o3 = orders[k3]
                if (o3.status !== "completed") continue
                var d3 = new Date(o3.date)
                if (isNaN(d3.getTime())) continue
                if (d3 >= startMonth && d3 < endMonth) {
                    var weekIdx = Math.min(3, Math.floor((d3.getDate() - 1) / 7))
                    bins[weekIdx] += (o3.total || 0)
                }
            }
            _periodLabel = "Revenue this month"
            _periodCompare = "▲ from last month"
        } else { // Year — 12 monthly bins
            var monthLabels = ["J","F","M","A","M","J","J","A","S","O","N","D"]
            for (var y = 0; y < 12; ++y) { bins.push(0); labels.push(monthLabels[y]) }
            for (var k4 = 0; k4 < orders.length; ++k4) {
                var o4 = orders[k4]
                if (o4.status !== "completed") continue
                var d4 = new Date(o4.date)
                if (isNaN(d4.getTime())) continue
                if (d4.getFullYear() === now.getFullYear())
                    bins[d4.getMonth()] += (o4.total || 0)
            }
            _periodLabel = "Revenue this year"
            _periodCompare = "▲ vs prior year"
        }

        var arr = []
        var total = 0
        for (var b = 0; b < bins.length; ++b) {
            arr.push({ label: labels[b], value: bins[b] })
            total += bins[b]
        }
        _breakdown = arr
        _periodTotal = total
    }

    function _maxBreakdown() {
        var max = 0
        for (var i = 0; i < _breakdown.length; ++i)
            if (_breakdown[i].value > max) max = _breakdown[i].value
        return max
    }
}
