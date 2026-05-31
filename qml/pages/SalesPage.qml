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

    // The payload contains everything Main.qml needs to write an xlsx —
    // packaged here because `id: salesPage` is nested inside a NavigationStack
    // Component and isn't reachable from Main's top-level scope.
    signal exportRequested(var payload)

    property int _period: 1   // 0=Day, 1=Week, 2=Month, 3=Year
    // View-mode indices match the on-screen pill order so the user sees
    // them as: Value, Purchased, Current, Revenue, Sold, Profit.
    //   0 = Inventory value (snapshot, currency)
    //   1 = Purchased stock  (period bucket, qty)
    //   2 = Current stock    (snapshot, qty)
    //   3 = Revenue          (period bucket, currency)
    //   4 = Sold stock       (period bucket, qty)
    //   5 = Profit           (period bucket OR snapshot via Realised/Potential)
    readonly property int _MODE_VALUE: 0
    readonly property int _MODE_PURCHASED: 1
    readonly property int _MODE_CURRENT: 2
    readonly property int _MODE_REVENUE: 3
    readonly property int _MODE_SOLD: 4
    readonly property int _MODE_PROFIT: 5
    property int _viewMode: _MODE_VALUE
    // "Realised" or "Potential" — only consumed when _viewMode === _MODE_PROFIT.
    property string _profitMode: "Realised"
    property string _partyFilter: "All"
    // New filter dimensions, all default to "All time" / "All".
    property string _dateFilter: "all"   // all | thisMonth | custom
    property string _customFrom: ""      // yyyy-MM-dd, only when _dateFilter === "custom"
    property string _customTo: ""        // yyyy-MM-dd
    property string _channelFilter: "All"
    property string _staffFilter: "All"
    property string _categoryFilter: "All"

    // Recomputed by _rebuildBreakdown() whenever the period, view mode, or
    // OrdersStore/TransactionStore revisions change.
    property var _breakdown: []
    property real _periodTotal: 0
    property string _periodLabel: ""
    property string _periodCompare: ""
    // Currency for Value / Revenue / Profit; raw qty for the rest.
    property bool _isCurrency: _viewMode === _MODE_VALUE
                             || _viewMode === _MODE_REVENUE
                             || _viewMode === _MODE_PROFIT
    property bool _isQty: !_isCurrency
    // Optional secondary metric shown under the hero (e.g. margin % for Profit).
    property string _periodSecondary: ""

    // Current-view-only datasets, populated alongside _breakdown.
    property var _stockByCategory: []
    property var _stockByParty: []
    property var _topByName: []
    // Inventory-value + Profit datasets — populated when those views build.
    // Each is an array of { label, value, fullLabel? } compatible with the
    // existing breakdown bar template.
    property var _valueByCategory: []
    property var _valueBySupplier: []
    property var _profitByCategory: []
    property var _profitBySupplier: []
    property var _profitByChannel: []
    property var _profitByStaff: []

    property int _ordersWatcher: OrdersStore.revision
    property int _txWatcher: TransactionStore.revision
    property int _invWatcher: InventoryStore.revision
    property int _batchWatcher: StockBatchStore.revision
    property int _supWatcher: SupplierStore.revision
    on_OrdersWatcherChanged: _rebuildBreakdown()
    on_TxWatcherChanged: _rebuildBreakdown()
    on_InvWatcherChanged: _rebuildBreakdown()
    // FIFO consumption / qty-remaining changes drive Current view + Sold
    // attribution; supplier rename refreshes chip labels.
    on_BatchWatcherChanged: _rebuildBreakdown()
    on_SupWatcherChanged: _rebuildBreakdown()
    on_PeriodChanged: _rebuildBreakdown()
    on_ViewModeChanged: _rebuildBreakdown()
    on_PartyFilterChanged: _rebuildBreakdown()
    on_ProfitModeChanged: _rebuildBreakdown()
    on_DateFilterChanged: _rebuildBreakdown()
    on_CustomFromChanged: _rebuildBreakdown()
    on_CustomToChanged: _rebuildBreakdown()
    on_ChannelFilterChanged: _rebuildBreakdown()
    on_StaffFilterChanged: _rebuildBreakdown()
    on_CategoryFilterChanged: _rebuildBreakdown()
    Component.onCompleted: _rebuildBreakdown()

    Rectangle { anchors.fill: parent; color: Constants.appBg }

    GlassHeader {
        id: header
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        title: qsTr("Analysis")
        subtitle: qsTr("Revenue, stock & transactions")

        actions: [
            IconActionButton {
                variant: "glass"
                text: "⚙"
                // Dot badge when any filter has moved off its default — the
                // user can tell at a glance that the on-screen numbers are
                // narrowed without expanding the sheet.
                badgeText: root._anyFilterActive() ? "•" : ""
                onClicked: {
                    analysisFilterSheet.dateRange    = root._dateFilter
                    analysisFilterSheet.customFrom   = root._customFrom
                    analysisFilterSheet.customTo     = root._customTo
                    analysisFilterSheet.supplierName = root._partyFilter
                    analysisFilterSheet.channelName  = root._channelFilter
                    analysisFilterSheet.staffName    = root._staffFilter
                    analysisFilterSheet.categoryName = root._categoryFilter
                    // Channel + staff only attach to sale events. Hide them
                    // for views that never reference those fields. Note
                    // that Profit/Potential is a snapshot — it reads the
                    // batch ledger and has no sales lineage to filter on.
                    var isPotentialProfit = root._viewMode === root._MODE_PROFIT
                            && root._profitMode === "Potential"
                    analysisFilterSheet.showChannelStaff =
                            !isPotentialProfit && (
                                root._viewMode === root._MODE_REVENUE
                                || root._viewMode === root._MODE_SOLD
                                || root._viewMode === root._MODE_PROFIT)
                    // Date applies only to time-bucketed views. Hide for
                    // Value, Current, and Potential profit (snapshot views).
                    analysisFilterSheet.showDate =
                            !isPotentialProfit
                            && root._viewMode !== root._MODE_VALUE
                            && root._viewMode !== root._MODE_CURRENT
                    analysisFilterSheet.open()
                }
            },
            IconActionButton {
                variant: "glass"
                text: "⤴"
                onClicked: root.exportRequested(root.buildAnalysisExport())
            }
        ]
    }

    // Filter sheet — single source of truth for every filter dimension.
    // The supplier ChipScroller below remains as a quick-tap fallback;
    // both write into the same `_partyFilter` property.
    AnalysisFilterSheet {
        id: analysisFilterSheet
        onFiltersApplied: function(payload) {
            root._dateFilter      = payload.dateRange    || "all"
            root._customFrom      = payload.customFrom   || ""
            root._customTo        = payload.customTo     || ""
            root._partyFilter     = payload.supplierName || "All"
            root._channelFilter   = payload.channelName  || "All"
            root._staffFilter     = payload.staffName    || "All"
            root._categoryFilter  = payload.categoryName || "All"
        }
        onResetRequested: {
            root._dateFilter     = "all"
            root._customFrom     = ""
            root._customTo       = ""
            root._partyFilter    = "All"
            root._channelFilter  = "All"
            root._staffFilter    = "All"
            root._categoryFilter = "All"
        }
    }

    // Empty state — clean dedicated screen when no orders, no transactions,
    // and no inventory exist yet.
    readonly property bool _hasAnyData: SalesStore.totalOrders > 0
        || (TransactionStore.entries || []).length > 0
        || (InventoryStore.products || []).length > 0
    Item {
        anchors.top: header.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        visible: !root._hasAnyData
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
        visible: root._hasAnyData
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
                model: [qsTr("Value"), qsTr("Purchased"), qsTr("Current"),
                        qsTr("Revenue"), qsTr("Sold"), qsTr("Profit")]
                selected: root._viewMode
                onSegmentSelected: function(idx, label) { root._viewMode = idx }
            }

            // Period pill — applies to the time-bucketed views (Revenue,
            // Sold, Purchased, and Profit when in Realised mode). Hidden for
            // snapshot views (Current, Inventory value, Potential profit).
            SegmentedPill {
                Layout.fillWidth: true
                Layout.leftMargin: dp(Constants.space4)
                Layout.rightMargin: dp(Constants.space4)
                visible: root._viewMode !== root._MODE_CURRENT
                         && root._viewMode !== root._MODE_VALUE
                         && !(root._viewMode === root._MODE_PROFIT && root._profitMode === "Potential")
                model: [qsTr("Day"), qsTr("Week"), qsTr("Month"), qsTr("Year")]
                selected: root._period
                onSegmentSelected: function(idx, label) { root._period = idx }
            }

            // Realised vs Potential profit toggle — only visible in the
            // Profit view. Realised walks completed-sale consumption[] for a
            // historical P&L; Potential values open stock at sellingPrice.
            SegmentedPill {
                Layout.fillWidth: true
                Layout.leftMargin: dp(Constants.space4)
                Layout.rightMargin: dp(Constants.space4)
                visible: root._viewMode === root._MODE_PROFIT
                model: [qsTr("Realised"), qsTr("Potential")]
                selected: root._profitMode === "Potential" ? 1 : 0
                onSegmentSelected: function(idx, label) {
                    root._profitMode = idx === 1 ? "Potential" : "Realised"
                }
            }

            // Supplier quick-filter chips — only on the Current view, where
            // they're the primary tool for slicing on-hand stock by source.
            // Every other view exposes the same filter (and four others)
            // through the bottom-sheet filter menu, so this strip is hidden
            // there to avoid two ways to do the same thing.
            ChipScroller {
                Layout.fillWidth: true
                // Source of supplier names — pulls live from the SupplierStore
                // singleton so a rename or add elsewhere refreshes the chips
                // automatically (the `revision` integer makes it reactive).
                visible: root._viewMode === root._MODE_CURRENT
                         && (SupplierStore.suppliers || []).length > 0
                model: {
                    var sRev = SupplierStore.revision
                    var names = ["All"]
                    var src = SupplierStore.suppliers || []
                    for (var i = 0; i < src.length; ++i) names.push(src[i].name)
                    return names
                }
                onChipSelected: function(idx, label) {
                    root._partyFilter = label || "All"
                }
            }

            // Active-filter chip strip — one removable pill per filter that
            // isn't on its default. Tapping the X clears that single
            // dimension without affecting the others.
            Flow {
                Layout.fillWidth: true
                Layout.leftMargin: dp(Constants.space4)
                Layout.rightMargin: dp(Constants.space4)
                spacing: dp(Constants.space2)
                visible: root._anyFilterActive()

                Repeater {
                    model: root._activeFilterChips()
                    delegate: Rectangle {
                        height: dp(28)
                        width: chipText.implicitWidth + closeIcon.implicitWidth + dp(28)
                        radius: dp(Constants.radiusPill)
                        color: Constants.brand2
                        Row {
                            anchors.centerIn: parent
                            spacing: dp(6)
                            Text {
                                id: chipText
                                anchors.verticalCenter: parent.verticalCenter
                                text: modelData.label
                                color: Constants.textOnBrand
                                font.pixelSize: sp(Constants.fsCaption)
                                font.bold: true
                            }
                            Text {
                                id: closeIcon
                                anchors.verticalCenter: parent.verticalCenter
                                text: "×"
                                color: Constants.textOnBrand
                                font.pixelSize: sp(14)
                                font.bold: true
                            }
                        }
                        MouseArea {
                            anchors.fill: parent
                            onClicked: root._clearFilter(modelData.dimension)
                        }
                    }
                }
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
                        text: root._isCurrency
                            ? SalesStore.formatCurrency(root._periodTotal)
                            : SalesStore.formatNumber(root._periodTotal) + qsTr(" units")
                        color: Constants.textOnBrand
                        font.pixelSize: sp(Constants.fsDisplay)
                        font.bold: true
                        font.letterSpacing: -0.5
                        Layout.topMargin: dp(2)
                    }

                    // Secondary metric — currently used by the Profit view to
                    // surface margin % alongside the absolute profit figure.
                    Text {
                        visible: root._periodSecondary.length > 0
                        text: root._periodSecondary
                        color: Qt.rgba(1,1,1,0.92)
                        font.pixelSize: sp(Constants.fsSmall)
                        font.bold: true
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

            // ── Current-stock totals card (only in view 3) ──
            // Aggregate counters: total items, distinct SKUs, distinct categories.
            // Per-product detail lives on the Stock page; this view stays summary.
            Rectangle {
                Layout.fillWidth: true
                Layout.leftMargin: dp(Constants.space4)
                Layout.rightMargin: dp(Constants.space4)
                visible: root._viewMode === root._MODE_CURRENT
                radius: dp(Constants.radius)
                color: Constants.cardBg
                border.color: Constants.borderColor
                border.width: 1
                Layout.preferredHeight: stockTotalsCol.implicitHeight + dp(Constants.space4 * 2)

                ColumnLayout {
                    id: stockTotalsCol
                    anchors.fill: parent
                    anchors.margins: dp(Constants.space4)
                    spacing: dp(Constants.space2)

                    Text {
                        text: qsTr("Stock totals")
                        color: Constants.textPrimary
                        font.pixelSize: sp(Constants.fsBodyLg)
                        font.bold: true
                    }
                    RowLayout {
                        Layout.fillWidth: true
                        spacing: dp(Constants.space3)
                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: 0
                            Text { text: SalesStore.formatNumber(InventoryStore.totalItems()); color: Constants.textPrimary; font.pixelSize: sp(Constants.fsTitle); font.bold: true }
                            Text { text: qsTr("Total items"); color: Constants.textSecondary; font.pixelSize: sp(Constants.fsCaption) }
                        }
                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: 0
                            Text { text: String(root._distinctNames()); color: Constants.textPrimary; font.pixelSize: sp(Constants.fsTitle); font.bold: true }
                            Text { text: qsTr("Products"); color: Constants.textSecondary; font.pixelSize: sp(Constants.fsCaption) }
                        }
                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: 0
                            Text { text: String(root._distinctSkus()); color: Constants.textPrimary; font.pixelSize: sp(Constants.fsTitle); font.bold: true }
                            Text { text: qsTr("Unique SKUs"); color: Constants.textSecondary; font.pixelSize: sp(Constants.fsCaption) }
                        }
                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: 0
                            Text { text: String(root._distinctCategories()); color: Constants.textPrimary; font.pixelSize: sp(Constants.fsTitle); font.bold: true }
                            Text { text: qsTr("Categories"); color: Constants.textSecondary; font.pixelSize: sp(Constants.fsCaption) }
                        }
                    }
                }
            }

            // ── Current-view: Stock by category chart ──
            ColumnLayout {
                Layout.fillWidth: true
                Layout.leftMargin: dp(Constants.space4)
                Layout.rightMargin: dp(Constants.space4)
                spacing: dp(Constants.space2)
                visible: root._viewMode === root._MODE_CURRENT

                Text {
                    text: qsTr("Stock by category")
                    color: Constants.textPrimary
                    font.pixelSize: sp(Constants.fsBodyLg)
                    font.bold: true
                }
                Rectangle {
                    Layout.fillWidth: true
                    Layout.preferredHeight: dp(180)
                    radius: dp(Constants.radius)
                    color: Constants.cardBg
                    border.color: Constants.borderColor
                    border.width: 1

                    Item {
                        id: yAxisCat
                        anchors.left: parent.left
                        anchors.top: parent.top
                        anchors.bottom: parent.bottom
                        anchors.leftMargin: dp(Constants.space3)
                        anchors.topMargin: dp(Constants.space3)
                        anchors.bottomMargin: dp(Constants.space3) + dp(20)
                        width: dp(28)
                        Text {
                            anchors.right: parent.right; anchors.top: parent.top
                            text: root._formatAxisValue(root._maxValue(root._stockByCategory))
                            color: Constants.textMuted; font.pixelSize: sp(Constants.fsCaption)
                        }
                        Text {
                            anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
                            text: root._formatAxisValue(root._maxValue(root._stockByCategory) / 2)
                            color: Constants.textMuted; font.pixelSize: sp(Constants.fsCaption)
                        }
                        Text {
                            anchors.right: parent.right; anchors.bottom: parent.bottom
                            text: "0"; color: Constants.textMuted; font.pixelSize: sp(Constants.fsCaption)
                        }
                    }

                    RowLayout {
                        anchors.left: yAxisCat.right
                        anchors.leftMargin: dp(Constants.space2)
                        anchors.right: parent.right
                        anchors.top: parent.top
                        anchors.bottom: parent.bottom
                        anchors.rightMargin: dp(Constants.space3)
                        anchors.topMargin: dp(Constants.space3)
                        anchors.bottomMargin: dp(Constants.space3)
                        spacing: dp(6)
                        Repeater {
                            model: root._stockByCategory
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
                                                    Math.max(1, root._maxValue(root._stockByCategory))))
                                        gradient: Gradient {
                                            orientation: Gradient.Vertical
                                            GradientStop { position: 0.0; color: Constants.brand3 }
                                            GradientStop { position: 1.0; color: Constants.brand2 }
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

            // ── Current-view: Stock by party chart ──
            ColumnLayout {
                Layout.fillWidth: true
                Layout.leftMargin: dp(Constants.space4)
                Layout.rightMargin: dp(Constants.space4)
                spacing: dp(Constants.space2)
                visible: root._viewMode === root._MODE_CURRENT

                Text {
                    // Reads as "purchased qty per supplier (lifetime)" —
                    // unaffected by later restocks from a different party.
                    text: qsTr("Purchases by party")
                    color: Constants.textPrimary
                    font.pixelSize: sp(Constants.fsBodyLg)
                    font.bold: true
                }
                Rectangle {
                    Layout.fillWidth: true
                    Layout.preferredHeight: dp(180)
                    radius: dp(Constants.radius)
                    color: Constants.cardBg
                    border.color: Constants.borderColor
                    border.width: 1

                    Item {
                        id: yAxisParty
                        anchors.left: parent.left
                        anchors.top: parent.top
                        anchors.bottom: parent.bottom
                        anchors.leftMargin: dp(Constants.space3)
                        anchors.topMargin: dp(Constants.space3)
                        anchors.bottomMargin: dp(Constants.space3) + dp(20)
                        width: dp(28)
                        Text {
                            anchors.right: parent.right; anchors.top: parent.top
                            text: root._formatAxisValue(root._maxValue(root._stockByParty))
                            color: Constants.textMuted; font.pixelSize: sp(Constants.fsCaption)
                        }
                        Text {
                            anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
                            text: root._formatAxisValue(root._maxValue(root._stockByParty) / 2)
                            color: Constants.textMuted; font.pixelSize: sp(Constants.fsCaption)
                        }
                        Text {
                            anchors.right: parent.right; anchors.bottom: parent.bottom
                            text: "0"; color: Constants.textMuted; font.pixelSize: sp(Constants.fsCaption)
                        }
                    }

                    RowLayout {
                        anchors.left: yAxisParty.right
                        anchors.leftMargin: dp(Constants.space2)
                        anchors.right: parent.right
                        anchors.top: parent.top
                        anchors.bottom: parent.bottom
                        anchors.rightMargin: dp(Constants.space3)
                        anchors.topMargin: dp(Constants.space3)
                        anchors.bottomMargin: dp(Constants.space3)
                        spacing: dp(6)
                        Repeater {
                            model: root._stockByParty
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
                                                    Math.max(1, root._maxValue(root._stockByParty))))
                                        gradient: Gradient {
                                            orientation: Gradient.Vertical
                                            GradientStop { position: 0.0; color: Constants.brand4 }
                                            GradientStop { position: 1.0; color: Constants.brand5 }
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
                Text {
                    visible: (root._stockByParty || []).length === 0
                    text: qsTr("No supplier purchases recorded yet — capture a supplier on your next restock.")
                    color: Constants.textMuted
                    font.pixelSize: sp(Constants.fsCaption)
                    Layout.fillWidth: true
                    horizontalAlignment: Text.AlignHCenter
                    wrapMode: Text.Wrap
                }
            }

            // Breakdown bars — title flips per view. For Current we replaced
            // the old per-product chart (which duplicated the Stock page) with
            // a "Stock health" distribution: how many SKUs are in stock vs low
            // vs out of stock. Actionable at a glance.
            ColumnLayout {
                Layout.fillWidth: true
                Layout.leftMargin: dp(Constants.space4)
                Layout.rightMargin: dp(Constants.space4)
                spacing: dp(Constants.space2)

                Text {
                    text: root._viewMode === root._MODE_CURRENT ? qsTr("Stock health") : qsTr("Breakdown")
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

                    // Y-axis labels — anchored to the left edge so they don't
                    // eat horizontal space the bar row would otherwise use.
                    // Bottom label aligns with the top of the x-axis caption
                    // line so the "0" sits flush with where bars begin.
                    Item {
                        id: yAxisMain
                        anchors.left: parent.left
                        anchors.top: parent.top
                        anchors.bottom: parent.bottom
                        anchors.leftMargin: dp(Constants.space3)
                        anchors.topMargin: dp(Constants.space3)
                        anchors.bottomMargin: dp(Constants.space3) + dp(20)
                        width: dp(28)
                        Text {
                            anchors.right: parent.right
                            anchors.top: parent.top
                            text: root._formatAxisValue(root._maxBreakdown())
                            color: Constants.textMuted
                            font.pixelSize: sp(Constants.fsCaption)
                        }
                        Text {
                            anchors.right: parent.right
                            anchors.verticalCenter: parent.verticalCenter
                            text: root._formatAxisValue(root._maxBreakdown() / 2)
                            color: Constants.textMuted
                            font.pixelSize: sp(Constants.fsCaption)
                        }
                        Text {
                            anchors.right: parent.right
                            anchors.bottom: parent.bottom
                            text: "0"
                            color: Constants.textMuted
                            font.pixelSize: sp(Constants.fsCaption)
                        }
                    }

                    RowLayout {
                        // Anchor past the y-axis. Right margin keeps the last
                        // bar from touching the card edge.
                        anchors.left: yAxisMain.right
                        anchors.leftMargin: dp(Constants.space2)
                        anchors.right: parent.right
                        anchors.top: parent.top
                        anchors.bottom: parent.bottom
                        anchors.rightMargin: dp(Constants.space3)
                        anchors.topMargin: dp(Constants.space3)
                        anchors.bottomMargin: dp(Constants.space3)
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
                                    // Per-bar value tip — only when the bar is
                                    // tall enough to host the text.
                                    Text {
                                        anchors.horizontalCenter: parent.horizontalCenter
                                        anchors.bottom: parent.bottom
                                        anchors.bottomMargin: dp(2)
                                        visible: modelData.value > 0 && parent.height > dp(40)
                                                 && (modelData.value / Math.max(1, root._maxBreakdown())) > 0.18
                                        text: root._formatAxisValue(modelData.value)
                                        color: Constants.textOnBrand
                                        font.pixelSize: sp(Constants.fsCaption)
                                        font.bold: true
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

            // Top items — only meaningful for revenue / sold-stock views.
            ColumnLayout {
                Layout.fillWidth: true
                Layout.leftMargin: dp(Constants.space4)
                Layout.rightMargin: dp(Constants.space4)
                spacing: dp(Constants.space2)
                visible: root._viewMode === root._MODE_REVENUE || root._viewMode === root._MODE_SOLD

                RowLayout {
                    Layout.fillWidth: true
                    Text {
                        text: qsTr("Top items")
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

            // Recent transactions — scoped to the active view:
            //   Revenue   → recent sales (each completed order line)
            //   Sold      → recent sales
            //   Purchased → recent restocks + new-product creations
            //   Current   → hidden (snapshot view; transactions aren't relevant)
            ColumnLayout {
                Layout.fillWidth: true
                Layout.leftMargin: dp(Constants.space4)
                Layout.rightMargin: dp(Constants.space4)
                spacing: dp(Constants.space2)
                visible: root._viewMode !== root._MODE_CURRENT
                         && root._viewMode !== root._MODE_VALUE

                Text {
                    text: root._viewMode === root._MODE_PURCHASED
                            ? qsTr("Recent purchases")
                            : qsTr("Recent sales")
                    color: Constants.textPrimary
                    font.pixelSize: sp(Constants.fsBodyLg)
                    font.bold: true
                }

                Repeater {
                    model: root._scopedTransactions()
                    delegate: ListCard {
                        Layout.fillWidth: true
                        title: root._txTitle(modelData)
                        subtitle: root._txSubtitle(modelData)

                        leading: AvatarBadge {
                            label: (modelData.productName || "?").charAt(0).toUpperCase()
                            palette: (modelData.kind === "purchase" || modelData.kind === "created")
                                ? Constants.grad4 : Constants.grad2
                        }

                        Text {
                            Layout.alignment: Qt.AlignVCenter | Qt.AlignRight
                            text: SalesStore.formatCurrency(modelData.total || 0)
                            color: Constants.textPrimary
                            font.pixelSize: sp(Constants.fsBody)
                            font.bold: true
                        }
                    }
                }

                Text {
                    visible: root._scopedTransactions().length === 0
                    text: root._viewMode === root._MODE_PURCHASED
                            ? qsTr("No purchases yet — restock or add a product.")
                            : qsTr("No sales yet — complete an order.")
                    color: Constants.textSecondary
                    font.pixelSize: sp(Constants.fsSmall)
                    Layout.fillWidth: true
                    Layout.topMargin: dp(Constants.space2)
                    horizontalAlignment: Text.AlignHCenter
                    wrapMode: Text.Wrap
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
        var partyOn = _partyFilter !== "All" && _partyFilter.length > 0
        var partySuffix = partyOn ? qsTr(" · party: %1").arg(_partyFilter) : ""
        // The chip stores a supplier *name* (label is what users see); resolve
        // to the stable supplierId once so the per-event/per-batch comparisons
        // below don't have to do the lookup on every iteration. Empty string
        // when no chip is active.
        var filterId = partyOn ? _supplierIdForName(_partyFilter) : ""

        // ── Inventory value — snapshot, currency. ────────────────────
        // Hero shows total ₹ on the shelves. Breakdown bars are top-8
        // products by value. The two parallel charts (category / supplier)
        // populate `_valueByCategory` / `_valueBySupplier` for the Current-
        // view-style chart cards already on the page.
        if (_viewMode === _MODE_VALUE) {
            var byProductV
            var bySupplierV
            var byCategoryV
            var anyValueFilter = !!filterId || _categoryFilter !== "All"

            if (anyValueFilter) {
                // Walk batches once and apply both supplier AND category
                // filters. We rebuild every map from the filtered set so the
                // hero, breakdown, and parallel charts agree.
                var bs = StockBatchStore.batches || []
                byProductV = {}
                bySupplierV = {}
                byCategoryV = {}
                for (var bi = 0; bi < bs.length; ++bi) {
                    var b = bs[bi]
                    if (filterId && b.supplierId !== filterId) continue
                    var pc = InventoryStore.getById(b.productId)
                    var cat = (pc && pc.category) ? pc.category : "(uncategorised)"
                    if (_categoryFilter !== "All" && cat !== _categoryFilter) continue
                    var v = (b.qtyRemaining || 0) * (b.unitCost || 0)
                    if (v <= 0) continue
                    byProductV[b.productId] = (byProductV[b.productId] || 0) + v
                    bySupplierV[b.supplierId || ""] = (bySupplierV[b.supplierId || ""] || 0) + v
                    byCategoryV[cat] = (byCategoryV[cat] || 0) + v
                }
            } else {
                byProductV  = InventoryStore.valueByProduct() || {}
                bySupplierV = InventoryStore.valueBySupplier() || {}
                byCategoryV = InventoryStore.valueByCategory() || {}
            }

            // Top-N bars grouped by product *name* — collapse SKU-only
            // duplicates so a product family with multiple SKUs appears as
            // one bar (per the user's grouping request).
            var byNameValue = {}
            var pkeys = Object.keys(byProductV)
            for (var pk = 0; pk < pkeys.length; ++pk) {
                var prod = InventoryStore.getById(pkeys[pk])
                var disp = prod ? (prod.name || pkeys[pk]) : pkeys[pk]
                byNameValue[disp] = (byNameValue[disp] || 0) + byProductV[pkeys[pk]]
            }
            var nameKeys = Object.keys(byNameValue)
            nameKeys.sort(function(a, b) { return byNameValue[b] - byNameValue[a] })
            if (nameKeys.length > 8) nameKeys = nameKeys.slice(0, 8)
            var topRows = []
            for (var tr = 0; tr < nameKeys.length; ++tr) {
                var nm = nameKeys[tr]
                topRows.push({
                    fullLabel: nm,
                    label: nm.length > 6 ? nm.substring(0, 5) + "…" : nm,
                    value: byNameValue[nm]
                })
            }

            // Replace product ids with supplier names for the bySupplier map
            // so the chart label matches the chip strip.
            var supplierNamed = {}
            var skeys = Object.keys(bySupplierV)
            for (var sk = 0; sk < skeys.length; ++sk) {
                var sName = skeys[sk]
                        ? (SupplierStore.nameOf(skeys[sk]) || qsTr("(removed)"))
                        : qsTr("Unknown")
                supplierNamed[sName] = (supplierNamed[sName] || 0) + bySupplierV[skeys[sk]]
            }

            var totalV = 0
            for (var tk = 0; tk < pkeys.length; ++tk) totalV += byProductV[pkeys[tk]]
            _breakdown = topRows
            _topByName = topRows
            _valueByCategory = _topNFromMap(byCategoryV, 8)
            _stockByCategory = _valueByCategory   // reuse the existing card
            _valueBySupplier = _topNFromMap(supplierNamed, 8)
            _stockByParty = _valueBySupplier      // reuse the existing card

            _periodTotal = totalV
            _periodLabel = qsTr("Inventory value")
            _periodSecondary = ""
            _periodCompare = topRows.length > 0
                    ? qsTr("top %1 by value").arg(topRows.length) + partySuffix
                    : qsTr("no stock yet") + partySuffix
            return
        }

        // ── Profit — Realised or Potential. Currency. ────────────────────
        // Realised walks completed-sale consumption[] for a historical P&L
        // bucketed into the active period. Potential is a snapshot of open
        // stock valued at the difference between sellingPrice and the
        // batch's captured unitCost (no period — hidden by the pill).
        if (_viewMode === _MODE_PROFIT) {
            var dim = "supplierId"   // default secondary breakdown
            var bins = []
            var labels = []
            var totalProfit = 0
            var totalRevenue = 0
            var totalCogs = 0

            if (_profitMode === "Potential") {
                // Snapshot — single pass over the batch ledger applies
                // supplier + category filter together, builds three parallel
                // breakdowns (by product name, by category, by supplier) and
                // the hero totals in one go. Date / channel / staff are
                // intentionally ignored here — Potential profit is a
                // batch-level snapshot with no time or sale-event lineage.
                var bsP = StockBatchStore.batches || []
                var byNameAccum = {}     // productName → { revenue, cogs, profit }
                var byCatAccum = {}
                var bySupAccum = {}      // supplierName → { revenue, cogs, profit }
                for (var bp = 0; bp < bsP.length; ++bp) {
                    var bb = bsP[bp]
                    if (filterId && bb.supplierId !== filterId) continue
                    var qtyR = bb.qtyRemaining || 0
                    if (qtyR <= 0) continue
                    var prr = InventoryStore.getById(bb.productId)
                    var cat = (prr && prr.category) ? prr.category : qsTr("(uncategorised)")
                    if (root._categoryFilter !== "All" && cat !== root._categoryFilter) continue
                    var sell = prr ? (prr.sellingPrice !== undefined
                                      ? prr.sellingPrice : (prr.price || 0)) : 0
                    var rev = qtyR * sell
                    var cogs = qtyR * (bb.unitCost || 0)
                    var pf = rev - cogs
                    var pname = prr ? (prr.name || bb.productId) : bb.productId
                    if (!byNameAccum[pname]) byNameAccum[pname] = { revenue: 0, cogs: 0, profit: 0 }
                    byNameAccum[pname].revenue += rev
                    byNameAccum[pname].cogs += cogs
                    byNameAccum[pname].profit += pf

                    if (!byCatAccum[cat]) byCatAccum[cat] = { revenue: 0, cogs: 0, profit: 0 }
                    byCatAccum[cat].revenue += rev
                    byCatAccum[cat].cogs += cogs
                    byCatAccum[cat].profit += pf

                    var supName = bb.supplierId
                            ? (SupplierStore.nameOf(bb.supplierId) || qsTr("(removed)"))
                            : qsTr("Unknown")
                    if (!bySupAccum[supName]) bySupAccum[supName] = { revenue: 0, cogs: 0, profit: 0 }
                    bySupAccum[supName].revenue += rev
                    bySupAccum[supName].cogs += cogs
                    bySupAccum[supName].profit += pf

                    totalRevenue += rev
                    totalCogs += cogs
                    totalProfit += pf
                }

                // Top-N rows for the breakdown chart, grouped by product
                // *name* (collapses SKU-only duplicates the user requested).
                var topRowsP = []
                var nks = Object.keys(byNameAccum)
                nks.sort(function(a, b) { return byNameAccum[b].profit - byNameAccum[a].profit })
                if (nks.length > 8) nks = nks.slice(0, 8)
                for (var ni = 0; ni < nks.length; ++ni) {
                    var nm = nks[ni]
                    topRowsP.push({
                        fullLabel: nm,
                        label: nm.length > 6 ? nm.substring(0, 5) + "…" : nm,
                        value: byNameAccum[nm].profit,
                        revenue: byNameAccum[nm].revenue,
                        cogs: byNameAccum[nm].cogs,
                        margin: byNameAccum[nm].cogs > 0
                                ? (byNameAccum[nm].profit / byNameAccum[nm].cogs) * 100 : 0
                    })
                }
                _breakdown = topRowsP
                _topByName = topRowsP
                _profitByCategory = _profitTopN(byCatAccum, 8, "")
                _profitBySupplier = _profitTopN(bySupAccum, 8, "")
                _profitByChannel = []
                _profitByStaff = []
                _stockByCategory = _profitByCategory
                _stockByParty = _profitBySupplier

                _periodTotal = totalProfit
                _periodLabel = qsTr("Potential profit on open stock")
                _periodSecondary = totalCogs > 0
                        ? qsTr("Margin %1%").arg((totalProfit / totalCogs * 100).toFixed(1))
                        : ""
                _periodCompare = qsTr("at current selling prices") + partySuffix
                return
            }

            // Realised — walk consumption[] grouped into period bins. Each
            // sale entry can contribute partial supplier qty (mixed-supplier
            // FIFO consumption), so we use the per-line predicate model
            // already proven on the Sold view.
            bins = _profitBucketWalk(_period, filterId)
            for (var bb2 = 0; bb2 < bins.length; ++bb2)
                totalProfit += bins[bb2].value

            // Compute revenue / cogs across the same scope so the hero can
            // show margin %. Slightly redundant pass — clarity > perf here.
            var realisedAgg = InventoryStore.realisedProfitByDimension("supplierId") || {}
            if (filterId) {
                var rR = realisedAgg[filterId] || { revenue: 0, cogs: 0 }
                totalRevenue = rR.revenue; totalCogs = rR.cogs
            } else {
                var rks = Object.keys(realisedAgg)
                for (var rk = 0; rk < rks.length; ++rk) {
                    totalRevenue += realisedAgg[rks[rk]].revenue
                    totalCogs += realisedAgg[rks[rk]].cogs
                }
            }
            _breakdown = bins
            _profitByCategory = _profitTopN(InventoryStore.realisedProfitByDimension("category"), 8, "")
            var realisedBySup = InventoryStore.realisedProfitByDimension("supplierId") || {}
            _profitBySupplier = _profitTopN(_namedSupplierMap(realisedBySup), 8, "")
            _profitByChannel = _profitTopN(InventoryStore.realisedProfitByDimension("channel"), 8, "")
            _profitByStaff = _profitTopN(_namedStaffMap(InventoryStore.realisedProfitByDimension("staffId")), 8, "")
            _stockByCategory = _profitByCategory
            _stockByParty = _profitBySupplier
            _topByName = _profitTopN(_namedProductMap(InventoryStore.realisedProfitByDimension("productId")), 8, "")

            _periodTotal = totalProfit
            _periodLabel = qsTr("Realised profit this period")
            _periodSecondary = totalCogs > 0
                    ? qsTr("Margin %1%").arg((totalProfit / totalCogs * 100).toFixed(1))
                    : ""
            _periodCompare = qsTr("from completed sales") + partySuffix
            return
        }

        // Current-stock view: snapshot — total items + per-product top-N bars
        // grouped by display name (collapses SKU duplicates), plus parallel
        // breakdowns by category and by per-batch supplier.
        if (_viewMode === _MODE_CURRENT) {
            // Apply category filter at the top so every downstream chart
            // (health, by-name, by-supplier) reflects the same product set.
            var invAll = InventoryStore.products || []
            var inv
            if (_categoryFilter !== "All") {
                inv = invAll.filter(function(pr) {
                    return (pr.category || qsTr("Uncategorised")) === _categoryFilter
                })
            } else {
                inv = invAll
            }
            // productId → product lookup so the batch loop can apply the
            // category filter without an O(n*m) inventory scan per batch.
            var invById = {}
            for (var ii = 0; ii < inv.length; ++ii) invById[inv[ii].productId] = inv[ii]

            var total = 0
            var byCat = {}
            var inStockCount = 0
            var lowStockCount = 0
            var outOfStockCount = 0
            var byName = {}
            for (var i = 0; i < inv.length; ++i) {
                var p = inv[i]
                var s = p.stock || 0
                total += s
                var c = p.category || qsTr("Uncategorised")
                byCat[c] = (byCat[c] || 0) + s
                var n = p.name || qsTr("(unnamed)")
                byName[n] = (byName[n] || 0) + s
                if (s <= 0) outOfStockCount++
                else if (s <= (p.minStock || 0)) lowStockCount++
                else inStockCount++
            }
            // Stock-by-supplier walks the batch ledger but skips batches
            // whose product was excluded by the category filter (via the
            // `invById` lookup we just built).
            var bySupplier = {}
            var allBatches = StockBatchStore.batches || []
            for (var bi = 0; bi < allBatches.length; ++bi) {
                var b = allBatches[bi]
                var rem = b.qtyRemaining || 0
                if (rem <= 0) continue
                if (filterId && b.supplierId !== filterId) continue
                if (_categoryFilter !== "All" && !invById[b.productId]) continue
                var sName = b.supplierId
                        ? (SupplierStore.nameOf(b.supplierId) || qsTr("(removed)"))
                        : qsTr("Unknown")
                bySupplier[sName] = (bySupplier[sName] || 0) + rem
            }
            // Supplier filter active: restrict every breakdown so the values
            // reflect only the units attributed to the filter supplier — NOT
            // each covered product's full `product.stock`.
            //
            // Earlier this branch counted `fp.stock` per covered product,
            // which double-counted: a product holding 3 from Vendor-1 + 2
            // from Vendor-2 would show "5" under both vendors when filtered.
            // The correct per-supplier qty for a product is the sum of
            // `qtyRemaining` across that product's batches owned by the
            // filter supplier — already pre-aggregated in `bySupplierProduct`.
            if (filterId) {
                // productId → qty attributed to the filter supplier.
                var qtyForProduct = {}
                for (var bj = 0; bj < allBatches.length; ++bj) {
                    var bb = allBatches[bj]
                    if (bb.supplierId !== filterId) continue
                    var rem = bb.qtyRemaining || 0
                    if (rem <= 0) continue
                    qtyForProduct[bb.productId] = (qtyForProduct[bb.productId] || 0) + rem
                }
                var filteredTotal = 0
                var filteredByCat = {}
                var filteredByName = {}
                inStockCount = 0; lowStockCount = 0; outOfStockCount = 0
                for (var fi = 0; fi < inv.length; ++fi) {
                    var fp = inv[fi]
                    var fs = qtyForProduct[fp.productId] || 0
                    if (fs <= 0) continue   // not covered by this supplier
                    filteredTotal += fs
                    var fc = fp.category || qsTr("Uncategorised")
                    filteredByCat[fc] = (filteredByCat[fc] || 0) + fs
                    var fn = fp.name || qsTr("(unnamed)")
                    filteredByName[fn] = (filteredByName[fn] || 0) + fs
                    // Stock health uses per-supplier qty against the
                    // product's own minStock — a meaningful "is this
                    // supplier's portion running low?" signal.
                    if (fs <= (fp.minStock || 0)) lowStockCount++
                    else inStockCount++
                }
                total = filteredTotal
                byCat = filteredByCat
                byName = filteredByName
            }

            _breakdown = [
                { label: qsTr("In stock"),    value: inStockCount },
                { label: qsTr("Low"),         value: lowStockCount },
                { label: qsTr("Out"),         value: outOfStockCount }
            ]
            _stockByCategory = _topNFromMap(byCat, 8)
            _stockByParty = _topNFromMap(bySupplier, 8)
            _topByName = _topNFromMap(byName, 8)

            _periodTotal = total
            _periodLabel = qsTr("Total items in stock")
            _periodCompare = total > 0
                    ? qsTr("on hand") + partySuffix
                    : qsTr("no products yet") + partySuffix
            return
        }

        // Sold view — walk the FIFO consumption array on each sale entry and
        // count units whose batch came from the filter supplier. Sale rows
        // that pre-date FIFO (no consumption) only count against the
        // unfiltered total ("Pre-FIFO" data).
        if (_viewMode === _MODE_SOLD) {
            // For supplier-filtered Sold we need partial-attribution per row
            // (a sale of 12 from Acme+Beta should contribute only Acme's qty
            // when the filter is Acme). The custom walker handles that AND
            // applies the cross-cutting filters internally.
            if (filterId) {
                _breakdown = _consumptionBucketWalk("sale", filterId, "qty")
            } else {
                // Unfiltered (by supplier) Sold still has to honour every
                // cross-cutting dimension — wrap them into a single-row
                // predicate handed to bucketsForFiltered.
                var soldPredicate = function(e) { return _passesCrossFilters(e) }
                _breakdown = TransactionStore.bucketsForFiltered("sale", _period, soldPredicate)
            }
            var soldTotal = 0
            for (var sb = 0; sb < _breakdown.length; ++sb) soldTotal += _breakdown[sb].value
            _periodTotal = soldTotal
            _periodLabel = qsTr("Units sold this period")
            _periodCompare = qsTr("from completed orders") + partySuffix
            return
        }

        // Purchased view — events directly carry supplierId on `e.party`, so
        // bucketsForFiltered handles whole-row inclusion correctly. Date /
        // category filters apply the same way; channel + staff only affect
        // sales, so they pass-through (a purchase event has no channel).
        if (_viewMode === _MODE_PURCHASED) {
            var purchasePredicate = function(e) {
                if (filterId) {
                    var pid = e.party || (e.snapshot ? e.snapshot.supplierId || e.snapshot.party || "" : "")
                    if (pid !== filterId) return false
                }
                // Reuse the cross-filter helper — channel/staff are no-ops
                // for purchase events (those fields don't exist) which means
                // those filters effectively bypass purchases.
                if (_dateFilter !== "all") {
                    var win = _dateWindow()
                    if (win) {
                        var ed = new Date(e.timestamp || e.date)
                        if (isNaN(ed.getTime()) || ed < win.from || ed >= win.to) return false
                    }
                }
                if (_categoryFilter !== "All") {
                    var p = InventoryStore.getById(e.productId)
                    if (!p || (p.category || "") !== _categoryFilter) return false
                }
                return true
            }
            var bought = TransactionStore.bucketsForFiltered(["purchase", "created"], _period, purchasePredicate)
            _breakdown = bought
            var boughtTotal = 0
            for (var pb = 0; pb < bought.length; ++pb) boughtTotal += bought[pb].value
            _periodTotal = boughtTotal
            _periodLabel = qsTr("Units purchased this period")
            _periodCompare = qsTr("from restocks") + partySuffix
            return
        }

        // Revenue view — every order is gated by every active filter:
        // channel + staff at the order level, category + supplier at the
        // line level. The previous implementation had a "no filter →
        // o.total" short-circuit that swallowed the channel/staff result
        // when supplier/category were All; that's gone now, so the
        // behaviour is consistent regardless of which filters are set.
        //
        // Staff filter resolves the chip's display name into a stable
        // staffId once. If the chip name doesn't resolve (e.g. the staff
        // member was deleted after the chip was applied), `staffFilterId`
        // stays "" and we just match orders that also have empty staffId.
        var staffFilterId = ""
        if (_staffFilter !== "All") {
            var roster = StaffStore.staff || []
            for (var sri = 0; sri < roster.length; ++sri)
                if (roster[sri].name === _staffFilter) { staffFilterId = roster[sri].staffId || ""; break }
        }
        var revenueOf = function(o) {
            if (_channelFilter !== "All" && (o.orderChannel || "") !== _channelFilter) return 0
            if (_staffFilter !== "All" && (o.staffId || "") !== staffFilterId) return 0
            // Category + supplier require per-line walk. When neither is
            // set, the line-level walk simplifies to summing every line's
            // qty × unit price — that yields the same result as o.total
            // *and* preserves the channel/staff gating above.
            var sum = 0
            var lines = o.products || []
            for (var li = 0; li < lines.length; ++li) {
                var ln = lines[li]
                if (_categoryFilter !== "All") {
                    var p = InventoryStore.getById(ln.productId)
                    if (!p || (p.category || "") !== _categoryFilter) continue
                }
                var pr = (typeof ln.price === "number") ? ln.price : 0
                if (filterId) {
                    var c = ln.consumption || []
                    for (var ci = 0; ci < c.length; ++ci) {
                        if (c[ci].supplierId !== filterId) continue
                        sum += (c[ci].qtyConsumed || 0) * pr
                    }
                } else {
                    var qty = ln.quantity || ln.qty || 0
                    sum += qty * pr
                }
            }
            return sum
        }
        // Date filter — applied per-bucket below by intersecting the
        // period bin against the active window.
        var dateWin = _dateWindow()
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
                if (dateWin && (d < dateWin.from || d >= dateWin.to)) continue
                if (d.getFullYear() === now.getFullYear()
                    && d.getMonth() === now.getMonth()
                    && d.getDate() === now.getDate()) {
                    bins[d.getHours()] += revenueOf(o)
                }
            }
            _periodLabel = qsTr("Revenue today")
            _periodCompare = qsTr("▲ from yesterday") + partySuffix
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
                if (dateWin && (d2 < dateWin.from || d2 >= dateWin.to)) continue
                if (d2 >= monday && d2 < nextMonday) {
                    var idx = (d2.getDay() + 6) % 7
                    bins[idx] += revenueOf(o2)
                }
            }
            _periodLabel = qsTr("Revenue this week")
            _periodCompare = qsTr("▲ from last week") + partySuffix
        } else if (_period === 2) { // Month — 4 weekly bins
            for (var m = 0; m < 4; ++m) { bins.push(0); labels.push("W" + (m+1)) }
            var startMonth = new Date(now.getFullYear(), now.getMonth(), 1)
            var endMonth = new Date(now.getFullYear(), now.getMonth() + 1, 1)
            for (var k3 = 0; k3 < orders.length; ++k3) {
                var o3 = orders[k3]
                if (o3.status !== "completed") continue
                var d3 = new Date(o3.date)
                if (isNaN(d3.getTime())) continue
                if (dateWin && (d3 < dateWin.from || d3 >= dateWin.to)) continue
                if (d3 >= startMonth && d3 < endMonth) {
                    var weekIdx = Math.min(3, Math.floor((d3.getDate() - 1) / 7))
                    bins[weekIdx] += revenueOf(o3)
                }
            }
            _periodLabel = qsTr("Revenue this month")
            _periodCompare = qsTr("▲ from last month") + partySuffix
        } else { // Year — 12 monthly bins
            var monthLabels = ["J","F","M","A","M","J","J","A","S","O","N","D"]
            for (var y = 0; y < 12; ++y) { bins.push(0); labels.push(monthLabels[y]) }
            for (var k4 = 0; k4 < orders.length; ++k4) {
                var o4 = orders[k4]
                if (o4.status !== "completed") continue
                var d4 = new Date(o4.date)
                if (isNaN(d4.getTime())) continue
                if (dateWin && (d4 < dateWin.from || d4 >= dateWin.to)) continue
                if (d4.getFullYear() === now.getFullYear())
                    bins[d4.getMonth()] += revenueOf(o4)
            }
            _periodLabel = qsTr("Revenue this year")
            _periodCompare = qsTr("▲ vs prior year") + partySuffix
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

    // Build an export payload for the active view. Called from Main.qml's
    // `_exportSalesReport`. Returns:
    //   { title, suggestedName, sections: [{ heading, headers, rows }] }
    //
    // Revenue / Sold / Purchased emit FOUR sections — one per period
    // (Day, Week, Month, Year) — so the user gets the full timeline in one
    // workbook, not just the period currently selected on screen.
    // Current emits a single section: per-product snapshot.
    function buildAnalysisExport() {
        // Aggregate every active filter into one tag so the export title
        // tells the user what they were looking at when they pressed share.
        var partyTag = ""
        if (root._partyFilter !== "All")    partyTag += " · " + root._partyFilter
        if (root._channelFilter !== "All")  partyTag += " · " + root._channelFilter
        if (root._staffFilter !== "All")    partyTag += " · " + root._staffFilter
        if (root._categoryFilter !== "All") partyTag += " · " + root._categoryFilter
        if (root._dateFilter !== "all")     partyTag += " · " + root._dateFilter
        var stamp = Qt.formatDateTime(new Date(), "yyyyMMdd_HHmmss")

        // ── Inventory value snapshot ────────────────────────────────────
        if (root._viewMode === root._MODE_VALUE) {
            var byProd = root._namedProductMapValue(InventoryStore.valueByProduct())
            var bySup = {}
            var bySupRaw = InventoryStore.valueBySupplier()
            var supKeys = Object.keys(bySupRaw)
            for (var sk = 0; sk < supKeys.length; ++sk) {
                var sNm = supKeys[sk] ? (SupplierStore.nameOf(supKeys[sk]) || qsTr("(removed)"))
                                      : qsTr("Unknown")
                bySup[sNm] = (bySup[sNm] || 0) + bySupRaw[supKeys[sk]]
            }
            var byCat = InventoryStore.valueByCategory()
            return {
                title: qsTr("Inventory value") + partyTag,
                suggestedName: "inventory_value_" + stamp + ".xlsx",
                sections: [
                    _exportSectionFromMap(qsTr("By product"), [qsTr("Product"), qsTr("Value (₹)")], byProd),
                    _exportSectionFromMap(qsTr("By supplier"), [qsTr("Supplier"), qsTr("Value (₹)")], bySup),
                    _exportSectionFromMap(qsTr("By category"), [qsTr("Category"), qsTr("Value (₹)")], byCat)
                ]
            }
        }

        // ── Profit (Realised or Potential) ──────────────────────────────
        if (root._viewMode === root._MODE_PROFIT) {
            var realised = root._profitMode !== "Potential"
            var titleP = realised ? qsTr("Realised profit") : qsTr("Potential profit")
            var sectionsP = []
            if (realised) {
                // Period bucket section first — mirrors the on-screen chart.
                var periodBins = _profitBucketWalk(root._period, "")
                var periodRows = []
                var pTotal = 0
                for (var pb = 0; pb < periodBins.length; ++pb) {
                    periodRows.push([periodBins[pb].label, periodBins[pb].value])
                    pTotal += periodBins[pb].value
                }
                periodRows.push([qsTr("Total"), pTotal])
                sectionsP.push({
                    heading: qsTr("By period"),
                    headers: [qsTr("Bucket"), qsTr("Profit (₹)")],
                    rows: periodRows
                })
                sectionsP.push(_exportProfitSection(qsTr("By product"),
                        _namedProductMap(InventoryStore.realisedProfitByDimension("productId"))))
                sectionsP.push(_exportProfitSection(qsTr("By supplier"),
                        _namedSupplierMap(InventoryStore.realisedProfitByDimension("supplierId"))))
                sectionsP.push(_exportProfitSection(qsTr("By category"),
                        InventoryStore.realisedProfitByDimension("category")))
                sectionsP.push(_exportProfitSection(qsTr("By channel"),
                        InventoryStore.realisedProfitByDimension("channel")))
                sectionsP.push(_exportProfitSection(qsTr("By staff"),
                        _namedStaffMap(InventoryStore.realisedProfitByDimension("staffId"))))
            } else {
                sectionsP.push(_exportProfitSection(qsTr("By product"),
                        _namedProductMap(InventoryStore.potentialProfitByDimension("productId"))))
                sectionsP.push(_exportProfitSection(qsTr("By supplier"),
                        _namedSupplierMap(InventoryStore.potentialProfitByDimension("supplierId"))))
                sectionsP.push(_exportProfitSection(qsTr("By category"),
                        InventoryStore.potentialProfitByDimension("category")))
            }
            return {
                title: titleP + partyTag,
                suggestedName: "profit_" + (realised ? "realised" : "potential") + "_" + stamp + ".xlsx",
                sections: sectionsP
            }
        }

        if (root._viewMode === root._MODE_CURRENT) {
            // Current — full per-product snapshot, with a totals row at the
            // bottom so the user can sanity-check the chart.
            var snapHeaders = [qsTr("Name"), qsTr("SKU"), qsTr("Category"),
                               qsTr("Supplier"), qsTr("Stock"), qsTr("Min stock"),
                               qsTr("Status")]
            var snapRows = []
            var inv = (InventoryStore.products || []).slice()
            inv.sort(function(a, b) { return (b.stock || 0) - (a.stock || 0) })
            var grandTotal = 0
            // Resolve filter id once (export runs in user-driven flow, not
            // a hot binding, so a single lookup is fine).
            var filterIdSnap = root._partyFilter !== "All"
                    ? _supplierIdForName(root._partyFilter) : ""
            for (var i = 0; i < inv.length; ++i) {
                var p = inv[i]
                // The display "supplier" for the Current-stock export is the
                // most-recent batch's supplier — same convention as the
                // EditProductDialog banner (UI consistency, not analytics).
                var supId = TransactionStore.lastSupplierFor(p.productId) || ""
                var sup = supId ? (SupplierStore.nameOf(supId) || "") : ""
                if (filterIdSnap && supId !== filterIdSnap)
                    continue
                var s = p.stock || 0
                grandTotal += s
                var status = s <= 0 ? qsTr("Out of stock")
                            : s <= (p.minStock || 0) ? qsTr("Low")
                            : qsTr("In stock")
                snapRows.push([p.name || "", p.sku || "", p.category || "",
                               sup, s, p.minStock || 0, status])
            }
            snapRows.push(["", "", "", qsTr("Total"), grandTotal, "", ""])
            return {
                title: qsTr("Current stock snapshot") + partyTag,
                suggestedName: "current_stock_" + stamp + ".xlsx",
                sections: [{
                    heading: qsTr("Snapshot"),
                    headers: snapHeaders,
                    rows: snapRows
                }]
            }
        }

        // Revenue / Sold / Purchased — emit one section per period so the
        // workbook captures hourly / daily / weekly / monthly views in one go.
        // Keyed on the new _MODE_* constants (Purchased=1, Revenue=3, Sold=4).
        var titleMap = {}
        titleMap[root._MODE_REVENUE]   = qsTr("Revenue")
        titleMap[root._MODE_SOLD]      = qsTr("Sold stock")
        titleMap[root._MODE_PURCHASED] = qsTr("Purchased stock")
        var unitHeader = root._viewMode === root._MODE_REVENUE
                ? qsTr("Amount (₹)") : qsTr("Units")
        var periodMeta = [
            { idx: 0, heading: qsTr("Today (hourly)"),     bucket: qsTr("Hour")  },
            { idx: 1, heading: qsTr("This week (daily)"),  bucket: qsTr("Day")   },
            { idx: 2, heading: qsTr("This month (weekly)"),bucket: qsTr("Week")  },
            { idx: 3, heading: qsTr("This year (monthly)"),bucket: qsTr("Month") }
        ]
        var sections = []
        for (var pm = 0; pm < periodMeta.length; ++pm) {
            var meta = periodMeta[pm]
            var bins = _binsFor(root._viewMode, meta.idx)
            var rows = []
            var total = 0
            for (var b = 0; b < bins.length; ++b) {
                rows.push([bins[b].label, bins[b].value])
                total += bins[b].value
            }
            rows.push([qsTr("Total"), total])
            sections.push({
                heading: meta.heading,
                headers: [meta.bucket, unitHeader],
                rows: rows
            })
        }
        return {
            title: titleMap[root._viewMode] + partyTag,
            suggestedName: "analysis_" + (titleMap[root._viewMode] || "report").toLowerCase() + "_" + stamp + ".xlsx",
            sections: sections
        }
    }

    // Compute bins for an arbitrary (viewMode, periodIdx) — extracted from
    // _rebuildBreakdown so the export can produce all four periods even when
    // the page is showing just one. Mirrors the FIFO-aware logic in the
    // on-screen branch (consumption-array walks for Sold and Revenue;
    // event-supplierId match for Purchased).
    function _binsFor(viewMode, periodIdx) {
        var partyOn = root._partyFilter !== "All" && root._partyFilter.length > 0
        var filterId = partyOn ? _supplierIdForName(root._partyFilter) : ""
        if (viewMode === root._MODE_SOLD) {
            if (filterId) {
                // Use the consumption walker so partial-supplier sales
                // contribute their attributed qty correctly (a 12-unit sale
                // split 10/2 across Acme/Beta lands 10 in Acme's bin).
                var savedPeriod = root._period
                root._period = periodIdx
                var bins = _consumptionBucketWalk("sale", filterId, "qty")
                root._period = savedPeriod
                return bins
            }
            return TransactionStore.bucketsForFiltered("sale", periodIdx, null)
        }
        if (viewMode === root._MODE_PURCHASED) {
            var purchasePredicate = null
            if (filterId) {
                purchasePredicate = function(e) {
                    var pid = e.party || (e.snapshot ? e.snapshot.supplierId || e.snapshot.party || "" : "")
                    return pid === filterId
                }
            }
            return TransactionStore.bucketsForFiltered(["purchase", "created"], periodIdx, purchasePredicate)
        }

        // Revenue — bucket completed orders by period. Per-supplier filter
        // walks each line's consumption array (qty × unit price for batches
        // belonging to the supplier).
        var revenueOf = function(o) {
            if (!filterId) return o.total || 0
            var sum = 0
            var lines = o.products || []
            for (var li = 0; li < lines.length; ++li) {
                var ln = lines[li]
                var pr = (typeof ln.price === "number") ? ln.price : 0
                var c = ln.consumption || []
                for (var ci = 0; ci < c.length; ++ci) {
                    if (c[ci].supplierId !== filterId) continue
                    sum += (c[ci].qtyConsumed || 0) * pr
                }
            }
            return sum
        }
        var orders = OrdersStore.orders || []
        var now = new Date()
        var bins = []
        var labels = []

        if (periodIdx === 0) {
            for (var h = 0; h < 24; ++h) { bins.push(0); labels.push((h % 6 === 0) ? (h + "h") : "") }
            for (var k = 0; k < orders.length; ++k) {
                var o = orders[k]
                if (o.status !== "completed") continue
                var d = new Date(o.date)
                if (isNaN(d.getTime())) continue
                if (d.getFullYear() === now.getFullYear()
                    && d.getMonth() === now.getMonth()
                    && d.getDate() === now.getDate())
                    bins[d.getHours()] += revenueOf(o)
            }
        } else if (periodIdx === 1) {
            var dl = ["Mon","Tue","Wed","Thu","Fri","Sat","Sun"]
            for (var w = 0; w < 7; ++w) { bins.push(0); labels.push(dl[w]) }
            var monday = new Date(now); var dow = (monday.getDay() + 6) % 7
            monday.setDate(monday.getDate() - dow); monday.setHours(0,0,0,0)
            var nextMonday = new Date(monday); nextMonday.setDate(monday.getDate() + 7)
            for (var k2 = 0; k2 < orders.length; ++k2) {
                var o2 = orders[k2]
                if (o2.status !== "completed") continue
                var d2 = new Date(o2.date)
                if (isNaN(d2.getTime())) continue
                if (d2 >= monday && d2 < nextMonday)
                    bins[(d2.getDay() + 6) % 7] += revenueOf(o2)
            }
        } else if (periodIdx === 2) {
            for (var m = 0; m < 4; ++m) { bins.push(0); labels.push("W" + (m+1)) }
            var startMonth = new Date(now.getFullYear(), now.getMonth(), 1)
            var endMonth = new Date(now.getFullYear(), now.getMonth() + 1, 1)
            for (var k3 = 0; k3 < orders.length; ++k3) {
                var o3 = orders[k3]
                if (o3.status !== "completed") continue
                var d3 = new Date(o3.date)
                if (isNaN(d3.getTime())) continue
                if (d3 >= startMonth && d3 < endMonth)
                    bins[Math.min(3, Math.floor((d3.getDate() - 1) / 7))] += revenueOf(o3)
            }
        } else {
            var ml = ["Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec"]
            for (var y = 0; y < 12; ++y) { bins.push(0); labels.push(ml[y]) }
            for (var k4 = 0; k4 < orders.length; ++k4) {
                var o4 = orders[k4]
                if (o4.status !== "completed") continue
                var d4 = new Date(o4.date)
                if (isNaN(d4.getTime())) continue
                if (d4.getFullYear() === now.getFullYear())
                    bins[d4.getMonth()] += revenueOf(o4)
            }
        }
        var arr = []
        for (var bi = 0; bi < bins.length; ++bi)
            arr.push({ label: labels[bi], value: bins[bi] })
        return arr
    }

    // Compact axis label — currency for Revenue view, otherwise raw qty.
    // Truncates large numbers (1.2k, 3.4M) so the y-axis column stays narrow.
    function _formatAxisValue(v) {
        if (v === undefined || v === null || isNaN(v)) v = 0
        var n = Math.round(v)
        var compact
        if (Math.abs(n) >= 1e6) compact = (n / 1e6).toFixed(1) + "M"
        else if (Math.abs(n) >= 1e3) compact = (n / 1e3).toFixed(1) + "k"
        else compact = String(n)
        if (root._isCurrency) {
            // Currency views (Revenue / Value / Profit) — prefix ₹.
            return "₹" + compact
        }
        return compact
    }

    function _maxValue(arr) {
        var m = 0
        for (var i = 0; i < (arr || []).length; ++i)
            if (arr[i].value > m) m = arr[i].value
        return m
    }

    // Take an object {key: number} and return up to N {label, value} sorted
    // by value descending. The label is truncated for compact bar charts.
    function _topNFromMap(obj, n) {
        var keys = Object.keys(obj || {})
        keys.sort(function(a, b) { return obj[b] - obj[a] })
        if (n && keys.length > n) keys = keys.slice(0, n)
        var out = []
        for (var i = 0; i < keys.length; ++i) {
            var k = keys[i]
            var lbl = k.length > 6 ? k.substring(0, 5) + "…" : k
            out.push({ label: lbl, value: obj[k], fullLabel: k })
        }
        return out
    }

    // Profit-table top-N. Input map is `{ key → { revenue, cogs, profit, margin } }`
    // (the shape returned by InventoryStore.realisedProfitByDimension). Returns
    // chart-ready rows sorted by profit descending. `filterKey` (when truthy)
    // restricts the result to a single key — used when the supplier filter
    // chip is active and we still want a single bar to render.
    function _profitTopN(rows, n, filterKey) {
        var keys = Object.keys(rows || {})
        if (filterKey) keys = keys.filter(function(k) { return k === filterKey })
        keys.sort(function(a, b) { return (rows[b].profit || 0) - (rows[a].profit || 0) })
        if (n && keys.length > n) keys = keys.slice(0, n)
        var out = []
        for (var i = 0; i < keys.length; ++i) {
            var k = keys[i]
            var lbl = k.length > 6 ? k.substring(0, 5) + "…" : k
            out.push({
                label: lbl,
                value: rows[k].profit,
                fullLabel: k,
                revenue: rows[k].revenue,
                cogs: rows[k].cogs,
                margin: rows[k].margin
            })
        }
        return out
    }

    // Replace { supplierId → row } with { supplierName → row } so chart
    // labels match the chip strip without a per-bar lookup.
    function _namedSupplierMap(rows) {
        var out = {}
        var keys = Object.keys(rows || {})
        for (var i = 0; i < keys.length; ++i) {
            var k = keys[i]
            var name = k ? (SupplierStore.nameOf(k) || qsTr("(removed)"))
                         : qsTr("Unknown")
            // Sum if multiple supplierIds resolve to the same display name
            // (shouldn't happen but cheap to guard).
            if (!out[name]) out[name] = { revenue: 0, cogs: 0, profit: 0, margin: 0 }
            out[name].revenue += rows[k].revenue
            out[name].cogs += rows[k].cogs
            out[name].profit += rows[k].profit
        }
        // Recompute margin% per merged row.
        var nks = Object.keys(out)
        for (var n = 0; n < nks.length; ++n) {
            var r = out[nks[n]]
            r.margin = r.cogs > 0 ? (r.profit / r.cogs) * 100 : 0
        }
        return out
    }

    // { staffId → row } → { staffName → row }. Empty keys roll up under
    // "(unassigned)" so a removed/blank staffId still renders.
    function _namedStaffMap(rows) {
        var out = {}
        var keys = Object.keys(rows || {})
        var roster = StaffStore.staff || []
        var lookup = {}
        for (var ri = 0; ri < roster.length; ++ri) lookup[roster[ri].staffId || ""] = roster[ri].name
        for (var i = 0; i < keys.length; ++i) {
            var k = keys[i]
            var name = k ? (lookup[k] || qsTr("(removed)"))
                         : qsTr("(unassigned)")
            if (!out[name]) out[name] = { revenue: 0, cogs: 0, profit: 0, margin: 0 }
            out[name].revenue += rows[k].revenue
            out[name].cogs += rows[k].cogs
            out[name].profit += rows[k].profit
        }
        var nks = Object.keys(out)
        for (var n = 0; n < nks.length; ++n) {
            var r = out[nks[n]]
            r.margin = r.cogs > 0 ? (r.profit / r.cogs) * 100 : 0
        }
        return out
    }

    // { productId → row } → { productName → row }.
    function _namedProductMap(rows) {
        var out = {}
        var keys = Object.keys(rows || {})
        for (var i = 0; i < keys.length; ++i) {
            var k = keys[i]
            var p = InventoryStore.getById(k)
            var name = p ? (p.name || k) : k
            if (!out[name]) out[name] = { revenue: 0, cogs: 0, profit: 0, margin: 0 }
            out[name].revenue += rows[k].revenue
            out[name].cogs += rows[k].cogs
            out[name].profit += rows[k].profit
        }
        var nks = Object.keys(out)
        for (var n = 0; n < nks.length; ++n) {
            var r = out[nks[n]]
            r.margin = r.cogs > 0 ? (r.profit / r.cogs) * 100 : 0
        }
        return out
    }

    // ── Export helpers ─────────────────────────────────────────────────
    // Build a 2-column section from a `{key → number}` map, sorted by value
    // descending and capped to a sensible row count. Used by Inventory-value
    // exports.
    function _exportSectionFromMap(heading, headers, obj) {
        var keys = Object.keys(obj || {})
        keys.sort(function(a, b) { return (obj[b] || 0) - (obj[a] || 0) })
        var rows = []
        var total = 0
        for (var i = 0; i < keys.length; ++i) {
            rows.push([keys[i] || qsTr("(unspecified)"), obj[keys[i]] || 0])
            total += obj[keys[i]] || 0
        }
        rows.push([qsTr("Total"), total])
        return { heading: heading, headers: headers, rows: rows }
    }

    // Build a 5-column profit section (key, revenue, cogs, profit, margin%)
    // from the InventoryStore.{realised|potential}ProfitByDimension shape.
    function _exportProfitSection(heading, rows) {
        var keys = Object.keys(rows || {})
        keys.sort(function(a, b) { return (rows[b].profit || 0) - (rows[a].profit || 0) })
        var out = []
        var totRev = 0; var totCogs = 0; var totProfit = 0
        for (var i = 0; i < keys.length; ++i) {
            var r = rows[keys[i]]
            out.push([
                keys[i] || qsTr("(unspecified)"),
                r.revenue || 0,
                r.cogs || 0,
                r.profit || 0,
                (r.margin || 0).toFixed(1) + "%"
            ])
            totRev += r.revenue || 0
            totCogs += r.cogs || 0
            totProfit += r.profit || 0
        }
        var totalMargin = totCogs > 0 ? ((totProfit / totCogs) * 100).toFixed(1) + "%" : "0%"
        out.push([qsTr("Total"), totRev, totCogs, totProfit, totalMargin])
        return {
            heading: heading,
            headers: [qsTr("Key"), qsTr("Revenue (₹)"), qsTr("COGS (₹)"),
                      qsTr("Profit (₹)"), qsTr("Margin %")],
            rows: out
        }
    }

    // { productId → number } → { productName → number }. Used for the
    // Inventory-value "By product" export (the running balance is a single
    // number, not a profit row).
    function _namedProductMapValue(rows) {
        var out = {}
        var keys = Object.keys(rows || {})
        for (var i = 0; i < keys.length; ++i) {
            var p = InventoryStore.getById(keys[i])
            var name = p ? (p.name || keys[i]) : keys[i]
            out[name] = (out[name] || 0) + (rows[keys[i]] || 0)
        }
        return out
    }

    // Bucket realised profit (revenue − cogs) into the active period bins.
    // Handles supplier filtering by short-circuiting consumption[] entries
    // whose supplierId doesn't match. Mirrors `_consumptionBucketWalk` but
    // emits profit instead of qty/revenue, so a single pass per call
    // suffices.
    function _profitBucketWalk(periodIdx, supplierId) {
        var bins = []; var labels = []; var bucket
        var now = new Date()
        if (periodIdx === 0) {
            for (var i = 0; i < 24; ++i) { bins.push(0); labels.push((i % 6 === 0) ? (i + "h") : "") }
            bucket = function(d) {
                if (d.getFullYear() === now.getFullYear()
                    && d.getMonth() === now.getMonth()
                    && d.getDate() === now.getDate()) return d.getHours()
                return -1
            }
        } else if (periodIdx === 1) {
            var dl = ["Mon","Tue","Wed","Thu","Fri","Sat","Sun"]
            for (var w = 0; w < 7; ++w) { bins.push(0); labels.push(dl[w]) }
            var monday = new Date(now); var dow = (monday.getDay() + 6) % 7
            monday.setDate(monday.getDate() - dow); monday.setHours(0,0,0,0)
            var nextMonday = new Date(monday); nextMonday.setDate(monday.getDate() + 7)
            bucket = function(d) {
                if (d >= monday && d < nextMonday) return (d.getDay() + 6) % 7
                return -1
            }
        } else if (periodIdx === 2) {
            for (var m = 0; m < 4; ++m) { bins.push(0); labels.push("W" + (m+1)) }
            var startMonth = new Date(now.getFullYear(), now.getMonth(), 1)
            var endMonth = new Date(now.getFullYear(), now.getMonth() + 1, 1)
            bucket = function(d) {
                if (d >= startMonth && d < endMonth)
                    return Math.min(3, Math.floor((d.getDate() - 1) / 7))
                return -1
            }
        } else {
            var ml = ["J","F","M","A","M","J","J","A","S","O","N","D"]
            for (var y = 0; y < 12; ++y) { bins.push(0); labels.push(ml[y]) }
            bucket = function(d) {
                if (d.getFullYear() === now.getFullYear()) return d.getMonth()
                return -1
            }
        }

        var entries = TransactionStore.entries || []
        for (var k = 0; k < entries.length; ++k) {
            var e = entries[k]
            if (e.kind !== "sale") continue
            if (!_passesCrossFilters(e)) continue
            var dd = new Date(e.timestamp || e.date)
            if (isNaN(dd.getTime())) continue
            var idx = bucket(dd)
            if (idx < 0) continue
            var unitPrice = e.unitPrice || 0
            var c = e.consumption || []
            for (var ci = 0; ci < c.length; ++ci) {
                if (supplierId && c[ci].supplierId !== supplierId) continue
                var qty = c[ci].qtyConsumed || 0
                if (qty <= 0) continue
                bins[idx] += qty * (unitPrice - (c[ci].unitCost || 0))
            }
        }
        var arr = []
        for (var b = 0; b < bins.length; ++b) arr.push({ label: labels[b], value: bins[b] })
        return arr
    }

    function _distinctNames() {
        var w = root._invWatcher
        var seen = {}
        var inv = InventoryStore.products || []
        for (var i = 0; i < inv.length; ++i) {
            var n = inv[i].name || ""
            if (n) seen[n] = true
        }
        return Object.keys(seen).length
    }

    function _distinctSkus() {
        var w = root._invWatcher
        var seen = {}
        var inv = InventoryStore.products || []
        for (var i = 0; i < inv.length; ++i) {
            var s = inv[i].sku || ""
            if (s) seen[s] = true
        }
        return Object.keys(seen).length
    }

    function _distinctCategories() {
        var w = root._invWatcher
        var seen = {}
        var inv = InventoryStore.products || []
        for (var i = 0; i < inv.length; ++i) {
            var c = inv[i].category || ""
            if (c) seen[c] = true
        }
        return Object.keys(seen).length
    }

    // ── Active-filter helpers ──────────────────────────────────────────
    // Whether any filter dimension differs from its "show everything"
    // default. Used to drive the dot badge on the Filter button and the
    // visibility of the removable-chip strip.
    function _anyFilterActive() {
        return _dateFilter !== "all"
            || _partyFilter !== "All"
            || _channelFilter !== "All"
            || _staffFilter !== "All"
            || _categoryFilter !== "All"
    }

    // Build `[{ dimension, label }]` for the chip strip. Each non-default
    // filter contributes one chip; tapping it routes to `_clearFilter`.
    function _activeFilterChips() {
        var out = []
        if (_dateFilter !== "all") {
            var dateLabel = _dateFilter === "thisMonth" ? qsTr("This month")
                          : _dateFilter === "custom"
                                ? (_customFrom && _customTo
                                       ? qsTr("%1 → %2").arg(_customFrom).arg(_customTo)
                                       : qsTr("Custom"))
                          : _dateFilter
            out.push({ dimension: "date", label: dateLabel })
        }
        if (_partyFilter !== "All")
            out.push({ dimension: "supplier", label: qsTr("Supplier: %1").arg(_partyFilter) })
        if (_channelFilter !== "All")
            out.push({ dimension: "channel", label: qsTr("Channel: %1").arg(_channelFilter) })
        if (_staffFilter !== "All")
            out.push({ dimension: "staff", label: qsTr("Staff: %1").arg(_staffFilter) })
        if (_categoryFilter !== "All")
            out.push({ dimension: "category", label: qsTr("Category: %1").arg(_categoryFilter) })
        return out
    }

    function _clearFilter(dimension) {
        if (dimension === "date") {
            _dateFilter = "all"
            _customFrom = ""
            _customTo = ""
        }
        else if (dimension === "supplier") _partyFilter = "All"
        else if (dimension === "channel")  _channelFilter = "All"
        else if (dimension === "staff")    _staffFilter = "All"
        else if (dimension === "category") _categoryFilter = "All"
    }

    // ── Filter predicates ──────────────────────────────────────────────
    // Resolve the active date filter into a [from, to) Date window. Returns
    // `null` when the filter is "all" so callers can short-circuit. The
    // bucket walkers compare an event's timestamp against this window.
    function _dateWindow() {
        if (!_dateFilter || _dateFilter === "all") return null
        var now = new Date()
        var to = new Date(now.getFullYear(), now.getMonth(), now.getDate() + 1)
        var from
        if (_dateFilter === "thisMonth") {
            from = new Date(now.getFullYear(), now.getMonth(), 1)
        } else if (_dateFilter === "custom") {
            // Only honour the window when both ends parse — otherwise treat
            // the filter as inactive so we don't show an empty chart.
            var f = new Date(_customFrom)
            var t = new Date(_customTo)
            if (isNaN(f.getTime()) || isNaN(t.getTime())) return null
            // Inclusive `to` — bump by one day so a window of [Mar 1, Mar 1]
            // catches all of March 1st.
            t = new Date(t.getFullYear(), t.getMonth(), t.getDate() + 1)
            from = f
            to = t
        } else {
            return null
        }
        return { from: from, to: to }
    }

    // Returns true when a sale/purchase entry passes every cross-cutting
    // filter (date, channel, staff, category). Supplier is handled by the
    // per-walker caller because it sometimes requires partial-row matching
    // against `consumption[].supplierId`.
    function _passesCrossFilters(e) {
        var win = _dateWindow()
        if (win) {
            var ed = new Date(e.timestamp || e.date)
            if (isNaN(ed.getTime())) return false
            if (ed < win.from || ed >= win.to) return false
        }
        if (_channelFilter !== "All") {
            if ((e.orderChannel || "") !== _channelFilter) return false
        }
        if (_staffFilter !== "All") {
            // Filter by staff name — translate name → id via StaffStore.
            var roster = StaffStore.staff || []
            var sid = ""
            for (var i = 0; i < roster.length; ++i)
                if (roster[i].name === _staffFilter) { sid = roster[i].staffId || ""; break }
            if ((e.staffId || "") !== sid) return false
        }
        if (_categoryFilter !== "All") {
            var p = InventoryStore.getById(e.productId)
            if (!p || (p.category || "") !== _categoryFilter) return false
        }
        return true
    }

    // The chip uses supplier *names*; everywhere else we compare by id.
    // Walks SupplierStore once per call; the supplier list is small (handful
    // of items) so the linear scan is cheap.
    function _supplierIdForName(name) {
        if (!name) return ""
        var src = SupplierStore.suppliers || []
        for (var i = 0; i < src.length; ++i)
            if (src[i].name === name) return src[i].supplierId
        return ""
    }

    // Custom bucket walker for the supplier-filtered Sold view. Each sale
    // entry can contribute partial qty (the consumption[] array may span
    // multiple suppliers); the generic bucketsForFiltered only does
    // whole-row inclusion. `field` is "qty" today; future "revenue" /
    // "margin" callers can pass other strings without re-implementing the
    // bucketing math.
    function _consumptionBucketWalk(kind, supplierId, field) {
        var w = root._txWatcher
        var bins = []
        var labels = []
        var bucket
        var now = new Date()
        if (root._period === 0) {
            for (var i = 0; i < 24; ++i) { bins.push(0); labels.push((i % 6 === 0) ? (i + "h") : "") }
            bucket = function(d) {
                if (d.getFullYear() === now.getFullYear()
                    && d.getMonth() === now.getMonth()
                    && d.getDate() === now.getDate()) return d.getHours()
                return -1
            }
        } else if (root._period === 1) {
            var dl = ["Mon","Tue","Wed","Thu","Fri","Sat","Sun"]
            for (var w2 = 0; w2 < 7; ++w2) { bins.push(0); labels.push(dl[w2]) }
            var monday = new Date(now); var dow = (monday.getDay() + 6) % 7
            monday.setDate(monday.getDate() - dow); monday.setHours(0,0,0,0)
            var nextMonday = new Date(monday); nextMonday.setDate(monday.getDate() + 7)
            bucket = function(d) {
                if (d >= monday && d < nextMonday) return (d.getDay() + 6) % 7
                return -1
            }
        } else if (root._period === 2) {
            for (var m = 0; m < 4; ++m) { bins.push(0); labels.push("W" + (m+1)) }
            var startMonth = new Date(now.getFullYear(), now.getMonth(), 1)
            var endMonth = new Date(now.getFullYear(), now.getMonth() + 1, 1)
            bucket = function(d) {
                if (d >= startMonth && d < endMonth)
                    return Math.min(3, Math.floor((d.getDate() - 1) / 7))
                return -1
            }
        } else {
            var ml = ["J","F","M","A","M","J","J","A","S","O","N","D"]
            for (var y = 0; y < 12; ++y) { bins.push(0); labels.push(ml[y]) }
            bucket = function(d) {
                if (d.getFullYear() === now.getFullYear()) return d.getMonth()
                return -1
            }
        }

        var entries = TransactionStore.entries || []
        for (var k = 0; k < entries.length; ++k) {
            var e = entries[k]
            if (e.kind !== kind) continue
            // Cross-cutting filters (date / channel / staff / category)
            // gate every row before we consider its consumption[]. A row
            // outside the date window or with the wrong channel never
            // contributes regardless of supplier match.
            if (!_passesCrossFilters(e)) continue
            var dd = new Date(e.timestamp || e.date)
            if (isNaN(dd.getTime())) continue
            var idx = bucket(dd)
            if (idx < 0) continue
            var c = e.consumption || []
            for (var ci = 0; ci < c.length; ++ci) {
                if (c[ci].supplierId !== supplierId) continue
                if (field === "qty") {
                    bins[idx] += (c[ci].qtyConsumed || 0)
                } else if (field === "revenue") {
                    bins[idx] += (c[ci].qtyConsumed || 0) * (e.unitPrice || 0)
                } else if (field === "margin") {
                    bins[idx] += (c[ci].qtyConsumed || 0)
                            * ((e.unitPrice || 0) - (c[ci].unitCost || 0))
                }
            }
        }

        var arr = []
        for (var b = 0; b < bins.length; ++b)
            arr.push({ label: labels[b], value: bins[b] })
        return arr
    }

    // Most recent transactions (capped) — uses _txWatcher binding to refresh.
    function _recentTransactions() {
        var w = root._txWatcher;   // make this read reactive
        var arr = (TransactionStore.entries || []).slice()
        if (arr.length > 20) arr = arr.slice(0, 20)
        return arr
    }

    // Transactions filtered by the active view mode AND supplier chip.
    //   Revenue (0) / Sold (1) → completed-order line items only
    //   Purchased (2)          → restocks + new-product initial stock
    //   Current (3)            → none (caller hides the section)
    //
    // For Sold rows under a supplier filter: include the row when its
    // consumption array references the filter supplier, even if the sale
    // also drew from other suppliers (partial match — the row is still a
    // record the user wants to see).
    function _scopedTransactions() {
        var w = root._txWatcher
        var v = root._viewMode
        // Recent transactions list is meaningless for snapshot views
        // (Current, Value) — caller hides the section in those modes.
        if (v === root._MODE_CURRENT || v === root._MODE_VALUE) return []
        var allow = v === root._MODE_PURCHASED
                ? { purchase: true, created: true }
                : { sale: true }
        var partyOn = root._partyFilter !== "All" && root._partyFilter.length > 0
        var filterId = partyOn ? _supplierIdForName(root._partyFilter) : ""
        var arr = TransactionStore.entries || []
        var out = []
        for (var i = 0; i < arr.length && out.length < 20; ++i) {
            var e = arr[i]
            if (!allow[e.kind]) continue
            if (partyOn) {
                if (v === root._MODE_PURCHASED) {
                    var ep = e.party || (e.snapshot ? e.snapshot.supplierId || e.snapshot.party || "" : "")
                    if (ep !== filterId) continue
                } else {
                    var c = e.consumption || []
                    var matched = false
                    for (var ci = 0; ci < c.length; ++ci)
                        if (c[ci].supplierId === filterId) { matched = true; break }
                    if (!matched) continue
                }
            }
            out.push(e)
        }
        return out
    }

    function _txTitle(d) {
        var icon = d.kind === "purchase" ? "📥 "
                 : d.kind === "created"  ? "🆕 "
                 : d.kind === "sale"     ? "📤 "
                 :                          ""
        return icon + (d.productName || qsTr("(unknown)"))
    }

    function _txSubtitle(d) {
        var head
        if (d.kind === "purchase")    head = qsTr("Restocked +%1").arg(d.quantity || 0)
        else if (d.kind === "created") head = d.quantity > 0
                                              ? qsTr("Created with %1").arg(d.quantity)
                                              : qsTr("Created")
        else if (d.kind === "sale")    head = qsTr("Sold %1").arg(d.quantity || 0)
        else                            head = ""
        var party = d.party || (d.snapshot ? d.snapshot.party || "" : "")
        var partyTail = party ? "  ·  " + qsTr("from %1").arg(party) : ""
        return head + partyTail + (d.date ? "  ·  " + d.date : "")
    }
}
