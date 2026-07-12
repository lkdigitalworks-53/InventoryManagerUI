import QtQuick
import QtQuick.Controls as QQC
import QtQuick.Layouts

import "../components"
import "../helper"
import "../model"
import "../helper/BreakdownMath.js" as BreakdownMath
import "../helper/OrderMath.js" as OrderMath
import "../helper/RealisedMath.js" as RealisedMath

// Modern sales report — segmented period pill, gradient hero card with area
// chart, weekly bar breakdown, top items list. All numbers from SalesStore.
Item {
    id: root

    property bool compact: false

    // Staff-restriction inputs (bound from Main.qml). Permissive defaults so
    // non-staff and tests are unaffected.
    property bool canViewFinancials: true
    property bool canViewSuppliers: true
    property bool canViewAllSales: true
    property string currentStaffId: ""
    property string currentStaffName: ""

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
    // Sentinel staffId used to hard-scope a staff user who has no resolved
    // staffId (unlinked account). It can never equal a real staffId ("STF-…")
    // nor an empty staffId, so every comparison fails → the staff user sees
    // zero rows (fail-closed), never the whole tenant's data.
    readonly property string _STAFF_SCOPE_NONE: " __no_staff__"
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
    property bool _showAllActivities: false  // Toggle for showing all vs limited recent activities

    // Recomputed by _rebuildBreakdown() whenever the period, view mode, or
    // OrdersStore/TransactionStore revisions change.
    property var _breakdown: []
    property real _periodTotal: 0
    property real _periodTax: 0
    property real _periodDiscount: 0
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
    property var _breakdownByCategory: []
    property var _breakdownBySupplier: []
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
    on_ViewModeChanged: { _rebuildBreakdown(); _showAllActivities = false }
    on_PartyFilterChanged: _rebuildBreakdown()
    on_ProfitModeChanged: _rebuildBreakdown()
    on_DateFilterChanged: _rebuildBreakdown()
    on_CustomFromChanged: _rebuildBreakdown()
    on_CustomToChanged: _rebuildBreakdown()
    on_ChannelFilterChanged: _rebuildBreakdown()
    on_StaffFilterChanged: _rebuildBreakdown()
    on_CategoryFilterChanged: _rebuildBreakdown()
    Component.onCompleted: {
        if (!canViewFinancials && _viewMode !== _MODE_CURRENT && _viewMode !== _MODE_SOLD)
            _viewMode = _MODE_CURRENT
        _rebuildBreakdown()
    }
    onCanViewFinancialsChanged: {
        if (!canViewFinancials && _viewMode !== _MODE_CURRENT && _viewMode !== _MODE_SOLD)
            _viewMode = _MODE_CURRENT
    }

    // Staff are hard-scoped to their own sales: force the existing name-keyed
    // staff filter to themselves and keep it pinned (the removable filter chip
    // and filter sheet are hidden for staff in their respective edits).
    function _enforceStaffScope() {
        if (!canViewAllSales && currentStaffName.length > 0 && _staffFilter !== currentStaffName)
            _staffFilter = currentStaffName
    }

    // Ordered list of view modes the current user may see — mirrors the
    // SegmentedPill gating: staff (no financials) see only Current + Sold.
    function _allowedViewModes() {
        return canViewFinancials
            ? [_MODE_VALUE, _MODE_PURCHASED, _MODE_CURRENT, _MODE_REVENUE, _MODE_SOLD, _MODE_PROFIT]
            : [_MODE_CURRENT, _MODE_SOLD]
    }

    // Step the view mode by a swipe. dir = -1 (swipe-left → previous view),
    // +1 (swipe-right → next view). Clamps at the ends — no wraparound.
    function _stepViewMode(dir) {
        var modes = _allowedViewModes()
        var cur = modes.indexOf(_viewMode)
        if (cur < 0) cur = 0
        var next = cur + dir
        if (next < 0 || next >= modes.length) return
        _viewMode = modes[next]
    }

    // The viewing identity changed (logout → login as a different user). The
    // page instance persists across that switch, so clear every carried-over
    // filter to a clean slate — otherwise the previous user's filters (notably
    // a staff member's auto-pinned self-filter) leak into the next session.
    // After clearing, re-apply the forced own-scope for staff.
    function _resetFiltersForViewer() {
        _dateFilter = "all"
        _customFrom = ""
        _customTo = ""
        _partyFilter = "All"
        _channelFilter = "All"
        _staffFilter = "All"
        _categoryFilter = "All"
        _enforceStaffScope()
    }
    onCanViewAllSalesChanged: _resetFiltersForViewer()
    onCurrentStaffIdChanged: _resetFiltersForViewer()
    onCurrentStaffNameChanged: _enforceStaffScope()

    // Resolve the active staff filter to a stable staffId. When the page is
    // hard-scoped to the current staff member, use their resolved currentStaffId
    // directly (robust against display-name vs roster-name mismatch and name
    // collisions). Otherwise fall back to resolving the filter NAME against the
    // roster (the normal owner/admin filter-by-name path). Returns "" when the
    // filter is "All" or no match resolves.
    function _resolveStaffFilterId() {
        // Staff are always hard-scoped to themselves, regardless of _staffFilter.
        // Unknown id (unlinked account) → sentinel that matches nothing (fail-closed).
        if (!canViewAllSales)
            return currentStaffId.length > 0 ? currentStaffId : _STAFF_SCOPE_NONE
        // Non-staff: resolve the chosen filter NAME against the roster (unchanged).
        if (_staffFilter === "All") return ""
        var roster = StaffStore.staff || []
        for (var i = 0; i < roster.length; ++i)
            if (roster[i].name === _staffFilter) return roster[i].staffId || ""
        return ""
    }

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
                iconName: "settings"
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
                            root.canViewAllSales && !isPotentialProfit && (
                                root._viewMode === root._MODE_REVENUE
                                || root._viewMode === root._MODE_SOLD
                                || root._viewMode === root._MODE_PROFIT)
                    // Date applies only to time-bucketed views. Hide for
                    // Value, Current, and Potential profit (snapshot views).
                    analysisFilterSheet.showDate =
                            !isPotentialProfit
                            && root._viewMode !== root._MODE_VALUE
                            && root._viewMode !== root._MODE_CURRENT
                    analysisFilterSheet.showSupplier = root.canViewSuppliers
                    analysisFilterSheet.open()
                }
            },
            IconActionButton {
                variant: "glass"
                iconName: "export"
                // Multi-sheet workbook: one sheet per report view (bug 11).
                onClicked: root.exportRequested(root.buildAnalysisWorkbook())
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
            Icon { name: "analytics"; size: sp(56); color: Constants.textMuted; Layout.alignment: Qt.AlignHCenter }
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

    AppScrollView {
        id: reportScroll
        anchors.top: header.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        visible: root._hasAnyData

        // Horizontal swipe → prev/next view. Constrained to the X axis so it
        // only claims dominantly-horizontal drags; vertical flicks stay with the
        // Flickable and taps pass through to the pills/buttons. target:null means
        // it detects without moving anything. Touch gesture behaviour differs on
        // Android vs desktop — device-verify (see memory scrollview_touch_freedrag).
        DragHandler {
            target: null
            yAxis.enabled: false
            xAxis.enabled: true
            // finger left (dx<0) = swipe-left = previous view; right = next.
            onActiveChanged: {
                if (active) return
                var dx = centroid.position.x - centroid.pressPosition.x
                if (Math.abs(dx) > dp(60))
                    root._stepViewMode(dx < 0 ? -1 : +1)
            }
        }

        ColumnLayout {
            id: stack
            width: root.width
            spacing: dp(Constants.space4)

            SegmentedPill {
                Layout.fillWidth: true
                Layout.leftMargin: dp(Constants.space4)
                Layout.rightMargin: dp(Constants.space4)
                Layout.topMargin: dp(Constants.space3)
                // Staff see only Current + Sold; everyone else sees all six.
                model: root.canViewFinancials
                       ? [qsTr("Value"), qsTr("Purchased"), qsTr("Current"),
                          qsTr("Revenue"), qsTr("Sold"), qsTr("Profit")]
                       : [qsTr("Current"), qsTr("Sold")]
                // Map the visible segment index back to the real _MODE_* value.
                selected: root.canViewFinancials
                          ? root._viewMode
                          : (root._viewMode === root._MODE_SOLD ? 1 : 0)
                onSegmentSelected: function(idx, label) {
                    if (root.canViewFinancials) root._viewMode = idx
                    else root._viewMode = (idx === 1 ? root._MODE_SOLD : root._MODE_CURRENT)
                }
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
                visible: root.canViewSuppliers
                         && root._viewMode === root._MODE_CURRENT
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
                            Icon {
                                id: closeIcon
                                anchors.verticalCenter: parent.verticalCenter
                                name: "close"
                                color: Constants.textOnBrand
                                size: sp(14)
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
                        visible: root._viewMode === root._MODE_REVENUE
                                 && (root._periodTax > 0 || root._periodDiscount > 0)
                        text: qsTr("incl. %1 tax · %2 discount")
                              .arg(SalesStore.formatCurrency(root._periodTax))
                              .arg(SalesStore.formatCurrency(root._periodDiscount))
                        color: Qt.rgba(1,1,1,0.92)
                        font.pixelSize: sp(Constants.fsSmall)
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
                            Text { text: SalesStore.formatNumber(InventoryStore.totalProducts()); color: Constants.textPrimary; font.pixelSize: sp(Constants.fsTitle); font.bold: true }
                            Text { text: qsTr("Products"); color: Constants.textSecondary; font.pixelSize: sp(Constants.fsCaption) }
                        }
                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: 0
                            Text { text: SalesStore.formatNumber(InventoryStore.totalItems()); color: Constants.textPrimary; font.pixelSize: sp(Constants.fsTitle); font.bold: true }
                            Text { text: qsTr("Items"); color: Constants.textSecondary; font.pixelSize: sp(Constants.fsCaption) }
                        }
                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: 0
                            Text { text: String(root._distinctNames()); color: Constants.textPrimary; font.pixelSize: sp(Constants.fsTitle); font.bold: true }
                            Text { text: qsTr("Unique names"); color: Constants.textSecondary; font.pixelSize: sp(Constants.fsCaption) }
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

            // ── By-category breakdown (all views) ──
            BreakdownBarCard {
                Layout.fillWidth: true
                Layout.leftMargin: dp(Constants.space4)
                Layout.rightMargin: dp(Constants.space4)
                visible: (root._breakdownByCategory || []).length > 0
                title: root._breakdownTitles().category
                model: root._breakdownByCategory
                currency: root._isCurrency
                barTop: Constants.brand3
                barBottom: Constants.brand2
            }

            // ── By-supplier breakdown (all views) ──
            BreakdownBarCard {
                Layout.fillWidth: true
                Layout.leftMargin: dp(Constants.space4)
                Layout.rightMargin: dp(Constants.space4)
                visible: root.canViewSuppliers
                         && (root._viewMode === root._MODE_CURRENT
                             || (root._breakdownBySupplier || []).length > 0
                             || root._supplierBreakdownApplies())
                title: root._breakdownTitles().supplier
                model: root._breakdownBySupplier
                currency: root._isCurrency
                barTop: Constants.brand4
                barBottom: Constants.brand5
                emptyText: root._viewMode === root._MODE_CURRENT
                           ? qsTr("No supplier purchases recorded yet — capture a supplier on your next restock.")
                           : qsTr("No supplier data for this period.")
            }

            // Main breakdown — time series for Revenue/Sold/Purchased, top-N
            // for Value/Profit, stock-health for Current. Title flips per view.
            BreakdownBarCard {
                Layout.fillWidth: true
                Layout.leftMargin: dp(Constants.space4)
                Layout.rightMargin: dp(Constants.space4)
                title: root._viewMode === root._MODE_CURRENT ? qsTr("Stock health") : qsTr("Breakdown")
                model: root._breakdown
                currency: root._isCurrency
                chartHeight: dp(200)
                showValueTips: true
                barTop: Constants.brand2
                barBottom: Constants.brand1
            }

            // Top items — only meaningful for revenue / sold-stock views.
            ColumnLayout {
                Layout.fillWidth: true
                Layout.leftMargin: dp(Constants.space4)
                Layout.rightMargin: dp(Constants.space4)
                spacing: dp(Constants.space2)
                visible: root.canViewFinancials && (root._viewMode === root._MODE_REVENUE || root._viewMode === root._MODE_SOLD)

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

            // Recent transactions — shown in Revenue and Purchased views only.
            //   Revenue   → recent sales (each completed order line)
            //   Purchased → recent restocks + new-product creations
            //   Sold/Profit/Current/Value → hidden to avoid repetition
            ColumnLayout {
                Layout.fillWidth: true
                Layout.leftMargin: dp(Constants.space4)
                Layout.rightMargin: dp(Constants.space4)
                spacing: dp(Constants.space2)
                visible: root.canViewFinancials && (root._viewMode === root._MODE_REVENUE || root._viewMode === root._MODE_PURCHASED)

                RowLayout {
                    Layout.fillWidth: true
                    Text {
                        text: root._viewMode === root._MODE_PURCHASED
                                ? qsTr("Recent purchases")
                                : qsTr("Recent sales")
                        color: Constants.textPrimary
                        font.pixelSize: sp(Constants.fsBodyLg)
                        font.bold: true
                        Layout.fillWidth: true
                    }
                    QQC.AbstractButton {
                        visible: root._scopedTransactions(999).length > 5
                        implicitWidth: dp(60)
                        implicitHeight: dp(28)
                        contentItem: Text {
                            text: root._showAllActivities ? qsTr("Show less") : qsTr("See all")
                            color: Constants.brand2
                            font.pixelSize: sp(Constants.fsSmall)
                            font.bold: true
                            horizontalAlignment: Text.AlignRight
                            verticalAlignment: Text.AlignVCenter
                        }
                        background: Rectangle { color: "transparent" }
                        onClicked: root._showAllActivities = !root._showAllActivities
                    }
                }

                Repeater {
                    model: root._scopedTransactions(root._showAllActivities ? 999 : 5)
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
                    visible: root._scopedTransactions(999).length === 0
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

            Item { Layout.preferredHeight: dp(Constants.tabbarClearance) + SafeArea.bottom; Layout.fillWidth: true }
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
        _enforceStaffScope()
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
            var vm = _valueMaps(filterId, _categoryFilter)
            var byProductV  = vm.byProduct
            var bySupplierV = vm.bySupplier
            var byCategoryV = vm.byCategory

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
            _breakdownByCategory = _valueByCategory   // reuse the existing card
            _valueBySupplier = _topNFromMap(supplierNamed, 8)
            _breakdownBySupplier = _valueBySupplier      // reuse the existing card

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
                _breakdownByCategory = _profitByCategory
                _breakdownBySupplier = _profitBySupplier

                _periodTotal = totalProfit
                _periodLabel = qsTr("Potential profit on open stock")
                _periodSecondary = totalCogs > 0
                        ? qsTr("Markup %1%").arg((totalProfit / totalCogs * 100).toFixed(1))
                        : ""
                _periodCompare = qsTr("at current selling prices") + partySuffix
                return
            }

            // Hero revenue / cogs / profit AND every by-dimension section share
            // ONE filter scope (A) and ONE source — the event log — so the hero
            // reconciles to Σ(by-dimension) under any active filter. The profit
            // bins go through the SAME canonical RealisedMath path as the Revenue
            // hero (metric "profit"): scope carries supplier/channel/staff/category
            // + the period∩date window, so a supplier-filtered price_adjust is
            // attributed via its stamped slices and the bins use the identical
            // window as the by-dimension cards (no hand-duplicated walker to drift).
            var realisedScope = _realisedScope(true)
            bins = InventoryStore.realisedBucketWalk("profit", _period, realisedScope)
            for (var bb2 = 0; bb2 < bins.length; ++bb2)
                totalProfit += bins[bb2].value

            var realisedTotals = InventoryStore.realisedTotals(realisedScope)
            totalRevenue = realisedTotals.net
            totalCogs = realisedTotals.cogs
            _breakdown = bins
            _profitByCategory = _profitTopN(InventoryStore.realisedProfitByDimension("category", realisedScope), 8, "")
            var realisedBySup = InventoryStore.realisedProfitByDimension("supplierId", realisedScope) || {}
            _profitBySupplier = _profitTopN(_namedSupplierMap(realisedBySup), 8, "")
            _profitByChannel = _profitTopN(InventoryStore.realisedProfitByDimension("channel", realisedScope), 8, "")
            _profitByStaff = _profitTopN(_namedStaffMap(InventoryStore.realisedProfitByDimension("staffId", realisedScope)), 8, "")
            _breakdownByCategory = _profitByCategory
            _breakdownBySupplier = _profitBySupplier
            _topByName = _profitTopN(_namedProductMap(InventoryStore.realisedProfitByDimension("productId", realisedScope)), 8, "")

            _periodTotal = totalProfit
            _periodLabel = qsTr("Realised profit this period")
            _periodSecondary = totalCogs > 0
                    ? qsTr("Markup %1%").arg((totalProfit / totalCogs * 100).toFixed(1))
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
            _breakdownByCategory = _topNFromMap(byCat, 8)
            _breakdownBySupplier = _topNFromMap(bySupplier, 8)
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
            _breakdownByCategory = _topNFromMap(_breakdownByDimension("sold", "category", false), 8)
            _breakdownBySupplier = _topNFromMap(_breakdownByDimension("sold", "supplier", false), 8)
            _topByName = _topNFromMap(_breakdownByDimension("sold", "name", false), 8)
            return
        }

        // Purchased view — events directly carry supplierId on `e.party`, so
        // bucketsForFiltered handles whole-row inclusion correctly. Date /
        // category filters apply the same way; channel + staff only affect
        // sales, so they pass-through (a purchase event has no channel).
        if (_viewMode === _MODE_PURCHASED) {
            var bought = TransactionStore.bucketsForFiltered(["purchase", "created"], _period, _purchasePredicate(filterId))
            _breakdown = bought
            var boughtTotal = 0
            for (var pb = 0; pb < bought.length; ++pb) boughtTotal += bought[pb].value
            _periodTotal = boughtTotal
            _periodLabel = qsTr("Units purchased this period")
            _periodCompare = qsTr("from restocks") + partySuffix
            _breakdownByCategory = _topNFromMap(_breakdownByDimension("purchased", "category", false), 8)
            _breakdownBySupplier = _topNFromMap(_breakdownByDimension("purchased", "supplier", false), 8)
            _topByName = _topNFromMap(_breakdownByDimension("purchased", "name", false), 8)
            return
        }

        // Revenue view — every event is gated by every active filter (date /
        // channel / staff / category / supplier) inside the scope object.
        // Revenue now walks the IMMUTABLE event log (SITE 5) — the same source
        // as the Profit view — so an adjusted/returned order nets correctly
        // (the ledger keeps the sale + return rows) and Revenue reconciles with
        // Profit. The period bins are scoped to period ∩ date-filter ∩ the other
        // active filters via realisedBucketWalk.
        var periodScope = _realisedScope(true)
        var arr = InventoryStore.realisedBucketWalk("net", _period, periodScope)
        var total = 0
        for (var b = 0; b < arr.length; ++b) total += arr[b].value
        _breakdown = arr
        _periodTotal = total
        if (_period === 0) {
            _periodLabel = qsTr("Revenue today");      _periodCompare = qsTr("▲ from yesterday") + partySuffix
        } else if (_period === 1) {
            _periodLabel = qsTr("Revenue this week");   _periodCompare = qsTr("▲ from last week") + partySuffix
        } else if (_period === 2) {
            _periodLabel = qsTr("Revenue this month");  _periodCompare = qsTr("▲ from last month") + partySuffix
        } else {
            _periodLabel = qsTr("Revenue this year");   _periodCompare = qsTr("▲ vs prior year") + partySuffix
        }

        // Hero sublines: tax collected + discount given over the same scope.
        // Order-level tax/discount can't be cleanly attributed to category/supplier
        // (they're whole-order aggregates). Hide the subline when a line-level
        // filter is active to avoid misleading the user.
        if (_categoryFilter !== "All" || filterId) {
            _periodTax = 0
            _periodDiscount = 0
        } else {
            // Tax/discount over the same period scope, from the event log.
            var subTotals = InventoryStore.realisedTotals(periodScope)
            _periodTax = subTotals.tax
            _periodDiscount = subTotals.discount
        }
        _breakdownByCategory = _topNFromMap(_breakdownByDimension("revenue", "category", false), 8)
        _breakdownBySupplier = _topNFromMap(_breakdownByDimension("revenue", "supplier", false), 8)
        _topByName = _profitTopN(_namedProductMap(InventoryStore.realisedProfitByDimension("productId", periodScope)), 8, "", "revenue")
    }

    // Build the live opts bundle and delegate the grouping to BreakdownMath.
    // metric ∈ "revenue"|"tax"|"discount"|"sold"|"purchased"; dim ∈ "category"|"supplier".
    // ignorePeriod=true skips the period window (used by the export, whose
    // category/supplier sections are filter-scoped totals, not single-period).
    // Returns a { key -> number } map; callers wrap it with _topNFromMap.
    //
    // The MONEY metrics (revenue/tax/discount) route through the immutable event
    // log via RealisedMath (SITE 5) so the Revenue cards + export net/tax/discount
    // sections reconcile with the Totals block on adjusted/returned orders. The
    // UNIT metrics (sold/purchased) stay on BreakdownMath (qty over events).
    function _breakdownByDimension(metric, dim, ignorePeriod) {
        // Window = period ∩ date-filter (or just date-filter when ignoring period).
        var periodWin = ignorePeriod ? null : BreakdownMath.periodWindow(_period, new Date())
        var win = BreakdownMath.intersect(periodWin, _dateWindow())

        // Resolve staff filter → stable id (prefers currentStaffId when staff-scoped).
        var staffId = _resolveStaffFilterId()

        if (metric === "revenue" || metric === "tax" || metric === "discount") {
            // Event-log money aggregation. dim → RealisedMath field; the returned
            // {key→row} is flattened to {key→number} for the metric column, then
            // id keys are resolved to display names for the supplier dim (parity
            // with BreakdownMath's _supplierKey/_categoryKey output).
            var field = dim === "supplier" ? "supplierId" : "category"
            var scope = {
                window: win,
                channel: _channelFilter === "All" ? "" : _channelFilter,
                staffId: staffId,
                category: _categoryFilter === "All" ? "" : _categoryFilter,
                supplierId: _partyFilter !== "All" ? _supplierIdForName(_partyFilter) : ""
            }
            var rows = InventoryStore.realisedProfitByDimension(field, scope)
            var col = metric === "revenue" ? "revenue" : metric === "tax" ? "tax" : "discount"
            var out = {}
            var rk = Object.keys(rows)
            for (var ri = 0; ri < rk.length; ++ri) {
                var key = rk[ri]
                var label = dim === "supplier"
                        ? (key ? (SupplierStore.nameOf(key) || qsTr("(removed)")) : qsTr("Unknown"))
                        : (key || qsTr("(uncategorised)"))
                out[label] = (out[label] || 0) + (rows[key][col] || 0)
            }
            return out
        }

        // productId → category, supplierId → name lookup maps.
        var productCategory = {}
        var inv = InventoryStore.products || []
        for (var pi = 0; pi < inv.length; ++pi)
            productCategory[inv[pi].productId] = inv[pi].category || ""
        var supplierName = {}
        var sup = SupplierStore.suppliers || []
        for (var sj = 0; sj < sup.length; ++sj)
            supplierName[sup[sj].supplierId] = sup[sj].name
        var productName = {}
        for (var pk = 0; pk < inv.length; ++pk)
            productName[inv[pk].productId] = inv[pk].name || inv[pk].productId

        return BreakdownMath.breakdown({
            metric: metric,
            dim: dim,
            orders: OrdersStore.orders || [],
            entries: TransactionStore.entries || [],
            window: win,
            channel: _channelFilter === "All" ? "" : _channelFilter,
            staffId: staffId,
            category: _categoryFilter === "All" ? "" : _categoryFilter,
            supplierId: _partyFilter !== "All" ? _supplierIdForName(_partyFilter) : "",
            productCategory: productCategory,
            supplierName: supplierName,
            productName: productName,
            allocate: OrderMath.allocate
        })
    }

    function _maxBreakdown() {
        var max = 0
        for (var i = 0; i < _breakdown.length; ++i)
            if (_breakdown[i].value > max) max = _breakdown[i].value
        return max
    }

    // Per-view titles for the two breakdown cards. Wording lives in one place
    // so the cards stay declarative.
    function _breakdownTitles() {
        switch (_viewMode) {
        case _MODE_VALUE:     return { category: qsTr("Value by category"),          supplier: qsTr("Value by supplier") }
        case _MODE_PURCHASED: return { category: qsTr("Purchased units by category"), supplier: qsTr("Purchased units by supplier") }
        case _MODE_CURRENT:   return { category: qsTr("Stock by category"),           supplier: qsTr("Purchases by party") }
        case _MODE_REVENUE:   return { category: qsTr("Revenue by category"),         supplier: qsTr("Revenue by supplier") }
        case _MODE_SOLD:      return { category: qsTr("Units sold by category"),      supplier: qsTr("Units sold by supplier") }
        case _MODE_PROFIT:    return { category: qsTr("Profit by category"),          supplier: qsTr("Profit by supplier") }
        }
        return { category: qsTr("By category"), supplier: qsTr("By supplier") }
    }

    // True for views where a supplier breakdown is meaningful — so the card
    // shows its empty-state message rather than disappearing when there's no
    // supplier lineage yet (e.g. pre-FIFO sales).
    function _supplierBreakdownApplies() {
        return _viewMode === _MODE_VALUE
            || _viewMode === _MODE_REVENUE
            || _viewMode === _MODE_SOLD
            || _viewMode === _MODE_PURCHASED
            || _viewMode === _MODE_PROFIT
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
            // Scope to the active supplier + category so the export matches the
            // on-screen Value view (shared via _valueMaps).
            var vmx = _valueMaps(root._partyFilter !== "All" ? _supplierIdForName(root._partyFilter) : "",
                                 root._categoryFilter)
            var byProd = root._namedProductMapValue(vmx.byProduct)
            var bySup = {}
            var bySupRaw = vmx.bySupplier
            var supKeys = Object.keys(bySupRaw)
            for (var sk = 0; sk < supKeys.length; ++sk) {
                var sNm = supKeys[sk] ? (SupplierStore.nameOf(supKeys[sk]) || qsTr("(removed)"))
                                      : qsTr("Unknown")
                bySup[sNm] = (bySup[sNm] || 0) + bySupRaw[supKeys[sk]]
            }
            var byCat = vmx.byCategory
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
                // Every realised section shares ONE filter scope (A) and ONE
                // source — the event log — so the Totals block reconciles to
                // Σ(each by-dimension section). The by-dimension sections are
                // whole-window totals (not period-bucketed), so periodScoped=false.
                var exportScope = _realisedScope(false)
                // By-period section: buckets are anchored to *now* (today/this
                // week/month/year). Under a custom/back-dated date filter those
                // buckets ∩ the filter window are near-empty and would disagree
                // with the Totals block, so omit the section entirely (B).
                if (root._dateFilter !== "custom") {
                    var periodBins = InventoryStore.realisedBucketWalk("profit", root._period, exportScope)
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
                }
                sectionsP.push(_exportProfitSection(qsTr("By product"),
                        _namedProductMap(InventoryStore.realisedProfitByDimension("productId", exportScope))))
                sectionsP.push(_exportProfitSection(qsTr("By supplier"),
                        _namedSupplierMap(InventoryStore.realisedProfitByDimension("supplierId", exportScope))))
                sectionsP.push(_exportProfitSection(qsTr("By category"),
                        InventoryStore.realisedProfitByDimension("category", exportScope)))
                sectionsP.push(_exportProfitSection(qsTr("By channel"),
                        InventoryStore.realisedProfitByDimension("channel", exportScope)))
                sectionsP.push(_exportProfitSection(qsTr("By staff"),
                        _namedStaffMap(InventoryStore.realisedProfitByDimension("staffId", exportScope))))
                sectionsP.unshift(_exportTotalsBlock())
            } else {
                // Potential is a batch snapshot — only supplier + category apply
                // (no date/channel/staff lineage), matching the on-screen view.
                var potScope = {
                    supplierId: root._partyFilter !== "All" ? _supplierIdForName(root._partyFilter) : "",
                    category: root._categoryFilter !== "All" ? root._categoryFilter : ""
                }
                sectionsP.push(_exportProfitSection(qsTr("By product"),
                        _namedProductMap(InventoryStore.potentialProfitByDimension("productId", potScope))))
                sectionsP.push(_exportProfitSection(qsTr("By supplier"),
                        _namedSupplierMap(InventoryStore.potentialProfitByDimension("supplierId", potScope))))
                sectionsP.push(_exportProfitSection(qsTr("By category"),
                        InventoryStore.potentialProfitByDimension("category", potScope)))
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
            var showSup = root.canViewSuppliers
            var snapHeaders = showSup
                    ? [qsTr("Name"), qsTr("SKU"), qsTr("Category"), qsTr("Supplier"),
                       qsTr("Stock"), qsTr("Min stock"), qsTr("Status")]
                    : [qsTr("Name"), qsTr("SKU"), qsTr("Category"),
                       qsTr("Stock"), qsTr("Min stock"), qsTr("Status")]
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
                // Honour the active category filter, same as the on-screen
                // Current view (the snapshot must match what's charted).
                if (root._categoryFilter !== "All"
                        && (p.category || qsTr("Uncategorised")) !== root._categoryFilter)
                    continue
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
                if (showSup)
                    snapRows.push([p.name || "", p.sku || "", p.category || "",
                                   sup, s, p.minStock || 0, status])
                else
                    snapRows.push([p.name || "", p.sku || "", p.category || "",
                                   s, p.minStock || 0, status])
            }
            if (showSup)
                snapRows.push(["", "", "", qsTr("Total"), grandTotal, "", ""])
            else
                snapRows.push(["", "", qsTr("Total"), grandTotal, "", ""])
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
        // Category + supplier breakdowns mirror the on-screen cards. Filter-
        // scoped totals (ignorePeriod) — the period tables above already cover
        // the time dimension, so these summarise across the active filters.
        var metricKey = root._viewMode === root._MODE_REVENUE ? "revenue"
                      : root._viewMode === root._MODE_SOLD ? "sold" : "purchased"
        var dimUnit = root._viewMode === root._MODE_REVENUE ? qsTr("Amount (₹)") : qsTr("Units")
        if (root._viewMode === root._MODE_REVENUE) {
            // Build net/tax/discount maps per dimension and emit reconciling sections.
            var catNet  = _breakdownByDimension("revenue", "category", true)
            var catTax  = _breakdownByDimension("tax", "category", true)
            var catDisc = _breakdownByDimension("discount", "category", true)
            sections.push(_exportNetSection(qsTr("By category"), _mergeNetMaps(catNet, catTax, catDisc)))
            if (root.canViewSuppliers) {
                var supNet  = _breakdownByDimension("revenue", "supplier", true)
                var supTax  = _breakdownByDimension("tax", "supplier", true)
                var supDisc = _breakdownByDimension("discount", "supplier", true)
                sections.push(_exportNetSection(qsTr("By supplier"), _mergeNetMaps(supNet, supTax, supDisc)))
            }
            sections.unshift(_exportTotalsBlock())
        } else {
            // Sold / Purchased stay unit-based (no tax/discount dimension).
            sections.push(_exportSectionFromMap(qsTr("By category"),
                    [qsTr("Category"), dimUnit],
                    _breakdownByDimension(metricKey, "category", true)))
            if (root.canViewSuppliers)
                sections.push(_exportSectionFromMap(qsTr("By supplier"),
                        [qsTr("Supplier"), dimUnit],
                        _breakdownByDimension(metricKey, "supplier", true)))
        }
        return {
            title: titleMap[root._viewMode] + partyTag,
            suggestedName: "analysis_" + (titleMap[root._viewMode] || "report").toLowerCase() + "_" + stamp + ".xlsx",
            sections: sections
        }
    }

    // Build a MULTI-SHEET workbook payload: every report view the current user
    // can see becomes its own sheet (bug 11). Reuses buildAnalysisExport() per
    // view by briefly switching _viewMode/_profitMode (synchronous, pure reads),
    // then restoring — the active filters (date/channel/staff/party/category)
    // stay applied to every sheet, so the workbook reflects what's on screen.
    //   → { suggestedName, sheets: [{ name, title, sections }] }
    function buildAnalysisWorkbook() {
        var savedView = root._viewMode
        var savedProfit = root._profitMode
        var stamp = Qt.formatDateTime(new Date(), "yyyyMMdd_HHmmss")

        // View list gated by permission — mirrors the on-screen SegmentedPill.
        // Each entry: { mode, profit?, name }.
        var views = []
        if (root.canViewFinancials) {
            views.push({ mode: root._MODE_VALUE,     name: qsTr("Inventory value") })
            views.push({ mode: root._MODE_PURCHASED, name: qsTr("Purchased") })
            views.push({ mode: root._MODE_CURRENT,   name: qsTr("Current stock") })
            views.push({ mode: root._MODE_REVENUE,   name: qsTr("Revenue") })
            views.push({ mode: root._MODE_SOLD,      name: qsTr("Sold") })
            views.push({ mode: root._MODE_PROFIT, profit: "Realised", name: qsTr("Realised profit") })
            views.push({ mode: root._MODE_PROFIT, profit: "Potential", name: qsTr("Potential profit") })
        } else {
            // Staff (no financials) see only stock + units sold.
            views.push({ mode: root._MODE_CURRENT, name: qsTr("Current stock") })
            views.push({ mode: root._MODE_SOLD,    name: qsTr("Sold") })
        }

        var sheets = []
        for (var i = 0; i < views.length; ++i) {
            var v = views[i]
            root._viewMode = v.mode
            if (v.profit !== undefined) root._profitMode = v.profit
            var payload = buildAnalysisExport()
            if (payload && payload.sections && payload.sections.length > 0)
                sheets.push({ name: v.name, title: payload.title, sections: payload.sections })
        }

        // Restore the on-screen view exactly as it was.
        root._viewMode = savedView
        root._profitMode = savedProfit
        _rebuildBreakdown()

        return {
            suggestedName: "analysis_report_" + stamp + ".xlsx",
            sheets: sheets
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
            return TransactionStore.bucketsForFiltered("sale", periodIdx, _passesCrossFilters)
        }
        if (viewMode === root._MODE_PURCHASED) {
            // Same predicate as the on-screen Purchased view (supplier + date +
            // category), so the export bins narrow with the active filters.
            return TransactionStore.bucketsForFiltered(["purchase", "created"], periodIdx, _purchasePredicate(filterId))
        }

        // Revenue — net per period bin from the IMMUTABLE event log (SITE 5),
        // scoped to the active date/channel/staff/category/supplier filters, so
        // an adjusted/returned order nets correctly and the export period tables
        // reconcile with the Totals block. The bucketing for `periodIdx` lives in
        // RealisedMath.bucketWalk (shared with the on-screen chart). The Year
        // labels here use 3-letter months (export convention) vs the on-screen
        // single-letter; remap to preserve the export's wider labels.
        var scope = {
            window: _dateWindow(),
            channel: root._channelFilter === "All" ? "" : root._channelFilter,
            staffId: _resolveStaffFilterId(),
            category: root._categoryFilter === "All" ? "" : root._categoryFilter,
            supplierId: filterId
        }
        var arr = InventoryStore.realisedBucketWalk("net", periodIdx, scope)
        if (periodIdx === 3) {
            var ml = ["Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec"]
            for (var bi = 0; bi < arr.length; ++bi) arr[bi].label = ml[bi]
        }
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
    function _profitTopN(rows, n, filterKey, field) {
        field = field || "profit"
        var keys = Object.keys(rows || {})
        if (filterKey) keys = keys.filter(function(k) { return k === filterKey })
        keys.sort(function(a, b) { return (rows[b][field] || 0) - (rows[a][field] || 0) })
        if (n && keys.length > n) keys = keys.slice(0, n)
        var out = []
        for (var i = 0; i < keys.length; ++i) {
            var k = keys[i]
            var lbl = k.length > 6 ? k.substring(0, 5) + "…" : k
            out.push({
                label: lbl,
                value: rows[k][field],
                fullLabel: k,
                revenue: rows[k].revenue,
                cogs: rows[k].cogs,
                margin: rows[k].margin
            })
        }
        return out
    }

    // Replace { supplierId → row } with { supplierName → row } so chart
    // labels match the chip strip without a per-bar lookup. Thin shim over
    // RealisedMath.nameMerge (the shared id→name merge — closes the X1 gap).
    function _namedSupplierMap(rows) {
        return RealisedMath.nameMerge(rows,
                function(k) { return SupplierStore.nameOf(k) || qsTr("(removed)") },
                qsTr("Unknown"))
    }

    // { staffId → row } → { staffName → row }. Empty keys roll up under
    // "(unassigned)" so a removed/blank staffId still renders.
    function _namedStaffMap(rows) {
        var roster = StaffStore.staff || []
        var lookup = {}
        for (var ri = 0; ri < roster.length; ++ri) lookup[roster[ri].staffId || ""] = roster[ri].name
        return RealisedMath.nameMerge(rows,
                function(k) { return lookup[k] || qsTr("(removed)") },
                qsTr("(unassigned)"))
    }

    // { productId → row } → { productName → row }. Unknown product falls back to
    // the raw key (the productId), preserving the original behaviour.
    function _namedProductMap(rows) {
        return RealisedMath.nameMerge(rows,
                function(k) { var p = InventoryStore.getById(k); return p ? (p.name || k) : k },
                qsTr("Unknown"))
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

    // Combine three {key → number} maps (net, tax, discount) into
    // {key → {revenue, tax, discount}} for _exportNetSection.
    function _mergeNetMaps(netMap, taxMap, discMap) {
        var out = {}
        function _acc(map, field) {
            var ks = Object.keys(map || {})
            for (var i = 0; i < ks.length; ++i) {
                if (!out[ks[i]]) out[ks[i]] = { revenue: 0, tax: 0, discount: 0 }
                out[ks[i]][field] += map[ks[i]] || 0
            }
        }
        _acc(netMap, "revenue"); _acc(taxMap, "tax"); _acc(discMap, "discount")
        return out
    }

    // Net-section builder: a {key → {revenue, tax, discount}} map → rows with
    // Net / Discount / Tax columns and a reconciling Total row.
    function _exportNetSection(heading, rows) {
        var keys = Object.keys(rows || {})
        keys.sort(function(a, b) { return (rows[b].revenue || 0) - (rows[a].revenue || 0) })
        var out = []
        var tNet = 0, tTax = 0, tDisc = 0
        for (var i = 0; i < keys.length; ++i) {
            var r = rows[keys[i]]
            out.push([keys[i] || qsTr("(unspecified)"), r.revenue || 0, r.discount || 0, r.tax || 0])
            tNet += r.revenue || 0; tTax += r.tax || 0; tDisc += r.discount || 0
        }
        out.push([qsTr("Total"), tNet, tDisc, tTax])
        return {
            heading: heading,
            headers: [qsTr("Key"), qsTr("Net Revenue (₹)"), qsTr("Discount (₹)"), qsTr("Tax (₹)")],
            rows: out
        }
    }

    // Export Totals block — net/discount/tax/cogs/profit over the active filter
    // scope. Aggregated from the IMMUTABLE event log (RealisedMath.totals), so it
    // equals Σ(each by-dimension section) by construction and honours exactly the
    // same scope the sections do (date/channel/staff/category/supplier).
    function _exportTotalsBlock() {
        // Single source of truth: aggregate the IMMUTABLE event log over the
        // active filter scope (SITE 5). This reconciles to Σ(each by-dimension
        // section) by construction (RealisedMath.totals == Σ byDimension), and
        // a returned/adjusted order nets correctly because the ledger keeps the
        // sale + return rows rather than reading the mutated live order. gross is
        // computed as net + discount, rounded once (D).
        var t = InventoryStore.realisedTotals(_realisedScope(false))
        var margin = t.cogs > 0 ? ((t.profit / t.cogs) * 100).toFixed(1) + "%" : "0%"
        return {
            heading: qsTr("Totals"),
            headers: [qsTr("Metric"), qsTr("Amount (₹)")],
            rows: [
                [qsTr("Gross sales"), t.gross],
                [qsTr("Discount"), t.discount],
                [qsTr("Net Revenue"), t.net],
                [qsTr("Tax Collected"), t.tax],
                [qsTr("COGS"), t.cogs],
                [qsTr("Profit"), t.profit],
                [qsTr("Markup %"), margin]
            ]
        }
    }

    // Build a 7-column profit section (key, revenue, discount, tax, cogs, profit, margin%)
    // from the InventoryStore.{realised|potential}ProfitByDimension shape.
    function _exportProfitSection(heading, rows) {
        var keys = Object.keys(rows || {})
        keys.sort(function(a, b) { return (rows[b].profit || 0) - (rows[a].profit || 0) })
        var out = []
        var totRev = 0, totCogs = 0, totProfit = 0, totTax = 0, totDisc = 0
        for (var i = 0; i < keys.length; ++i) {
            var r = rows[keys[i]]
            out.push([
                keys[i] || qsTr("(unspecified)"),
                r.revenue || 0, r.discount || 0, r.tax || 0,
                r.cogs || 0, r.profit || 0,
                (r.margin || 0).toFixed(1) + "%"
            ])
            totRev += r.revenue || 0; totCogs += r.cogs || 0; totProfit += r.profit || 0
            totTax += r.tax || 0; totDisc += r.discount || 0
        }
        var totalMargin = totCogs > 0 ? ((totProfit / totCogs) * 100).toFixed(1) + "%" : "0%"
        out.push([qsTr("Total"), totRev, totDisc, totTax, totCogs, totProfit, totalMargin])
        return {
            heading: heading,
            headers: [qsTr("Key"), qsTr("Net Revenue (₹)"), qsTr("Discount (₹)"),
                      qsTr("Tax (₹)"), qsTr("COGS (₹)"), qsTr("Profit (₹)"), qsTr("Markup %")],
            rows: out
        }
    }

    // Inventory-value maps, scoped to the active supplier (id) + category.
    // Returns id-keyed { byProduct, bySupplier, byCategory } so both the
    // on-screen Value view and the export read ONE source and agree under a
    // filter. With no filter active it returns the unfiltered store maps
    // (byte-for-byte the prior behaviour). category "" / "All" = no category gate.
    function _valueMaps(filterId, categoryFilter) {
        var catOn = categoryFilter && categoryFilter !== "All"
        if (!filterId && !catOn) {
            return {
                byProduct:  InventoryStore.valueByProduct() || {},
                bySupplier: InventoryStore.valueBySupplier() || {},
                byCategory: InventoryStore.valueByCategory() || {}
            }
        }
        // Walk batches once, applying supplier AND category filters together,
        // so every map reflects the same filtered set.
        var byProduct = {}, bySupplier = {}, byCategory = {}
        var bs = StockBatchStore.batches || []
        for (var bi = 0; bi < bs.length; ++bi) {
            var b = bs[bi]
            if (filterId && b.supplierId !== filterId) continue
            var pc = InventoryStore.getById(b.productId)
            var cat = (pc && pc.category) ? pc.category : "(uncategorised)"
            if (catOn && cat !== categoryFilter) continue
            var v = (b.qtyRemaining || 0) * (b.unitCost || 0)
            if (v <= 0) continue
            byProduct[b.productId] = (byProduct[b.productId] || 0) + v
            bySupplier[b.supplierId || ""] = (bySupplier[b.supplierId || ""] || 0) + v
            byCategory[cat] = (byCategory[cat] || 0) + v
        }
        return { byProduct: byProduct, bySupplier: bySupplier, byCategory: byCategory }
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

    // NOTE: the realised-profit hero + export "By period" section now use the
    // canonical InventoryStore.realisedBucketWalk("profit", …) — the same path as
    // the Revenue hero. The old hand-duplicated _profitBucketWalk was deleted
    // (2026-06-26): it had drifted from RealisedMath.bucketWalk and produced two
    // reconciliation bugs (supplier-filtered price_adjust dropped; date window not
    // intersected with the period). See docs/.../profit-hero-dedupe-walker-design.md.

    function _distinctNames() {
        var w = root._invWatcher
        var seen = {}
        var inv = InventoryStore.products || []
        for (var i = 0; i < inv.length; ++i) {
            if (inv[i].stock <= 0) continue
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
            if (inv[i].stock <= 0) continue
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
            if (inv[i].stock <= 0) continue
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
            // A staff user's _staffFilter is auto-pinned to themselves; that's
            // not a user-applied filter, so it must not light the filter badge.
            || (_staffFilter !== "All" && canViewAllSales)
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
        if (_staffFilter !== "All" && canViewAllSales)
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
    // Per-event predicate for purchase/created rows, gating on supplier (id) +
    // date + category. Channel/staff are intentionally no-ops — purchase events
    // carry neither field. Shared by the on-screen Purchased view and the
    // export bins so both narrow identically. `filterId` "" = no supplier gate.
    function _purchasePredicate(filterId) {
        return function(e) {
            if (filterId) {
                var pid = e.party || (e.snapshot ? e.snapshot.supplierId || e.snapshot.party || "" : "")
                if (pid !== filterId) return false
            }
            if (_dateFilter !== "all") {
                var win = _dateWindow()
                if (win) {
                    var ed = OrderMath.eventDate(e)
                    if (isNaN(ed.getTime()) || ed < win.from || ed >= win.to) return false
                }
            }
            if (_categoryFilter !== "All") {
                var p = InventoryStore.getById(e.productId)
                if (!p || (p.category || "") !== _categoryFilter) return false
            }
            return true
        }
    }

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
            // Parse as LOCAL midnight (+"T00:00:00"): the period bounds and the
            // inclusive `to` below are local, and events are filtered by absolute
            // instant. A bare new Date("yyyy-MM-dd") is UTC midnight, which shifts
            // the `from` edge by the tz offset and drops start-of-day sales in
            // positive-offset zones (IST). Mirrors OrdersPage._dateWindow.
            var f = new Date(_customFrom + "T00:00:00")
            var t = new Date(_customTo + "T00:00:00")
            if (isNaN(f.getTime()) || isNaN(t.getTime())) return null
            // Inclusive `to` — bump by one day so a window of [Mar 1, Mar 1]
            // catches all of March 1st.
            from = f
            to = new Date(t.getFullYear(), t.getMonth(), t.getDate() + 1)
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
            var ed = OrderMath.eventDate(e)
            if (isNaN(ed.getTime())) return false
            if (ed < win.from || ed >= win.to) return false
        }
        if (_channelFilter !== "All") {
            if ((e.orderChannel || "") !== _channelFilter) return false
        }
        if (_staffFilter !== "All" || !canViewAllSales) {
            // Translate the staff filter to a stable id (prefers currentStaffId
            // when staff-scoped) and gate the entry on it.
            var sid = _resolveStaffFilterId()
            if ((e.staffId || "") !== sid) return false
        }
        if (_categoryFilter !== "All") {
            var p = InventoryStore.getById(e.productId)
            if (!p || (p.category || "") !== _categoryFilter) return false
        }
        return true
    }

    // Bundle the active filters into the scope object RealisedMath consumes, so
    // the realised hero / Totals / by-dimension sections all honour the same
    // filters (A). Mirrors _passesCrossFilters' gating exactly. supplierId is
    // resolved from the chip NAME; "" everywhere = "all".
    //
    // `periodScoped` true (on-screen view): intersect the active date window with
    // the selected period (Day/Week/Month/Year), so the by-dimension sections
    // cover the SAME span the hero/chart bins do and Σ(by-dimension) reconciles
    // with the hero. false (export): the by-dimension sections are whole-window
    // totals across all periods, so only the date filter applies.
    function _realisedScope(periodScoped) {
        var staffId = _resolveStaffFilterId()
        var win = _dateWindow()
        if (periodScoped)
            win = BreakdownMath.intersect(BreakdownMath.periodWindow(_period, new Date()), win)
        return {
            window: win,
            channel: _channelFilter !== "All" ? _channelFilter : "",
            // Match _passesCrossFilters: a staff user is always self-scoped even
            // when _staffFilter === "All".
            staffId: (_staffFilter !== "All" || !canViewAllSales) ? staffId : "",
            category: _categoryFilter !== "All" ? _categoryFilter : "",
            supplierId: _partyFilter !== "All" ? _supplierIdForName(_partyFilter) : ""
        }
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
            // Returns net against sales: include them whenever sales are requested.
            if (e.kind !== kind && !(kind === "sale" && e.kind === "return")) continue
            // Cross-cutting filters (date / channel / staff / category)
            // gate every row before we consider its consumption[]. A row
            // outside the date window or with the wrong channel never
            // contributes regardless of supplier match.
            if (!_passesCrossFilters(e)) continue
            var dd = OrderMath.eventDate(e)
            if (isNaN(dd.getTime())) continue
            var idx = bucket(dd)
            if (idx < 0) continue
            var c = e.consumption || []
            // Revenue/margin distribute the STAMPED net (discounted) by
            // qtyConsumed/lineQty — NOT gross qty*unitPrice (SITE 7) — so they
            // match the net-revenue convention used everywhere else. qty stays
            // a plain unit count.
            var lineQty = 0
            for (var lq = 0; lq < c.length; ++lq) lineQty += (c[lq].qtyConsumed || 0)
            var evNet = (e.net !== undefined && e.net !== null) ? e.net : 0
            for (var ci = 0; ci < c.length; ++ci) {
                if (c[ci].supplierId !== supplierId) continue
                var qc = c[ci].qtyConsumed || 0
                if (field === "qty") {
                    bins[idx] += qc
                } else if (field === "revenue") {
                    bins[idx] += evNet * (lineQty !== 0 ? (qc / lineQty) : 0)
                } else if (field === "margin") {
                    var rowNet = evNet * (lineQty !== 0 ? (qc / lineQty) : 0)
                    bins[idx] += rowNet - (qc * (c[ci].unitCost || 0))
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
    function _scopedTransactions(limit) {
        var maxItems = (typeof limit === "number" && limit > 0) ? limit : 5
        var w = root._txWatcher
        var v = root._viewMode
        // Recent transactions list is meaningless for snapshot views
        // (Current, Value) — caller hides the section in those modes.
        if (v === root._MODE_CURRENT || v === root._MODE_VALUE) return []
        var allow = v === root._MODE_PURCHASED
                ? { purchase: true, created: true }
                : { sale: true, "return": true, price_adjust: true }
        var partyOn = root._partyFilter !== "All" && root._partyFilter.length > 0
        var filterId = partyOn ? _supplierIdForName(root._partyFilter) : ""
        var arr = TransactionStore.entries || []
        var out = []
        for (var i = 0; i < arr.length && out.length < maxItems; ++i) {
            var e = arr[i]
            if (!allow[e.kind]) continue
            // Date / channel / staff / category gating — same predicate the
            // on-screen breakdown uses, so the list narrows with the active
            // filters instead of only honouring the supplier chip.
            if (!_passesCrossFilters(e)) continue
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
        var name = d.productName || qsTr("(unknown)")
        // Show the order number alongside the product on sale-cycle rows (bug 13)
        // so a recent-sales line ties back to its order at a glance.
        if (d.orderId && (d.kind === "sale" || d.kind === "return" || d.kind === "price_adjust"))
            return name + "  ·  #" + d.orderId
        return name
    }

    function _txSubtitle(d) {
        var head
        if (d.kind === "purchase")    head = qsTr("Restocked +%1").arg(d.quantity || 0)
        else if (d.kind === "created") head = d.quantity > 0
                                              ? qsTr("Created with %1").arg(d.quantity)
                                              : qsTr("Created")
        else if (d.kind === "return")  head = qsTr("Returned %1").arg(Math.abs(d.quantity || 0))
        // price_adjust covers two edits: a discount-rate change (reason
        // "discount") and a per-unit price modify. Distinguish them so the row
        // is meaningful — mirrors OrderDetailDialog's history wording.
        else if (d.kind === "price_adjust") head = d.reason === "discount"
                                                   ? qsTr("Discount changed")
                                                   : qsTr("Price adjusted")
        else if (d.kind === "sale")    head = qsTr("Sold %1").arg(d.quantity || 0)
        else                            head = ""
        // SKU (resolved from inventory by productId) on sale-cycle rows —
        // includes price_adjust so discount/price-change rows show their SKU
        // like every other sale-cycle entry (bug 13).
        var skuTail = ""
        if (d.productId && (d.kind === "sale" || d.kind === "return" || d.kind === "price_adjust")) {
            var inv = InventoryStore.getById(d.productId)
            if (inv && inv.sku) skuTail = "  ·  " + qsTr("SKU %1").arg(inv.sku)
        }
        var party = d.party || (d.snapshot ? d.snapshot.party || "" : "")
        var partyTail = party ? "  ·  " + qsTr("from %1").arg(party) : ""
        return head + skuTail + partyTail + (d.date ? "  ·  " + d.date : "")
    }
}
