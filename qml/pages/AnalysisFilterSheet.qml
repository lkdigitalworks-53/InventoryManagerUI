import QtQuick
import QtQuick.Layouts

import "../components"
import "../helper"
import "../model"

// Unified filter sheet for the Analysis page. Date / supplier / channel /
// staff / category chips, each with an "All" entry that means "no filter
// for this dimension". Apply emits one payload back to the page; Reset
// clears every dimension.
//
// Public contract:
//   property string dateRange   = "all" | "thisMonth" | "custom"
//   property string customFrom   = "yyyy-MM-dd" — only when dateRange === "custom"
//   property string customTo     = "yyyy-MM-dd"
//   property string supplierName = "All"
//   property string channelName  = "All"
//   property string staffName    = "All"
//   property string categoryName = "All"
//   property bool   showChannelStaff = true   — caller hides for views
//                                              that don't carry channel/staff
//   signal filtersApplied(var payload)
//   signal resetRequested()
BottomSheet {
    id: root

    sheetTitle: qsTr("Filters")
    primaryAction: qsTr("Apply")
    secondaryAction: qsTr("Reset")
    primaryPalette: Constants.gradHero

    // Round-trip state — the page reads these back via filtersApplied.
    // The day-/week-/month-/year-of-period coverage already lives on the
    // page's period pill, so this sheet keeps only complementary buckets.
    property string dateRange: "all"
    property string customFrom: ""
    property string customTo: ""
    property string supplierName: "All"
    property string channelName: "All"
    property string staffName: "All"
    property string categoryName: "All"
    // Caller toggles based on _viewMode — Channel/Staff make no sense for
    // views that operate on stock or purchase events.
    property bool showChannelStaff: true
    // Snapshot views (Inventory value, Potential profit) read the live
    // batch ledger and don't have a time dimension. Caller hides the
    // Date row entirely so the user can't pick something that won't apply.
    property bool showDate: true
    property bool showSupplier: true

    signal filtersApplied(var payload)
    signal resetRequested()

    onPrimaryClicked: {
        filtersApplied({
            dateRange: dateRange,
            customFrom: customFrom,
            customTo: customTo,
            supplierName: supplierName,
            channelName: channelName,
            staffName: staffName,
            categoryName: categoryName
        })
        close()
    }
    onSecondaryClicked: {
        dateRange = "all"
        customFrom = ""
        customTo = ""
        supplierName = "All"
        channelName = "All"
        staffName = "All"
        categoryName = "All"
        resetRequested()
    }

    // Reusable chip-row factory. `entries` is `[{ key, label }]`; `selectedKey`
    // is the currently-active key. Emits `chipPicked(key)` on tap.
    component FilterChipRow: Flow {
        id: row
        property var entries: []
        property string selectedKey: ""
        signal chipPicked(string key)
        Layout.fillWidth: true
        spacing: dp(Constants.space2)

        Repeater {
            model: row.entries
            delegate: Rectangle {
                id: chip
                readonly property bool isOn: modelData.key === row.selectedKey
                height: dp(32)
                width: chipTxt.implicitWidth + dp(24)
                radius: dp(Constants.radiusPill)
                color: isOn ? Constants.brand2 : Constants.cardBg
                border.color: isOn ? "transparent" : Constants.borderColor
                border.width: 1
                Rectangle {
                    visible: chip.isOn
                    anchors.fill: parent
                    radius: parent.radius
                    gradient: Gradient {
                        orientation: Gradient.Horizontal
                        GradientStop { position: 0.0; color: Constants.brand1 }
                        GradientStop { position: 1.0; color: Constants.brand2 }
                    }
                }
                Text {
                    id: chipTxt
                    z: 1
                    anchors.centerIn: parent
                    text: modelData.label
                    color: chip.isOn ? Constants.textOnBrand : Constants.textSecondary
                    font.pixelSize: sp(Constants.fsSmall)
                    font.bold: true
                }
                MouseArea {
                    anchors.fill: parent
                    onClicked: row.chipPicked(modelData.key)
                }
            }
        }
    }

    ColumnLayout {
        Layout.fillWidth: true
        spacing: dp(Constants.space3)

        // ── Date range ─────────────────────────────────────────────────
        // Day / Week / Month / Year are already covered by the period pill
        // on the page, so this sheet keeps only the complementary buckets:
        // "All time" (default), "This month" (single tap), and "Custom"
        // (user-defined window). Hidden entirely on snapshot views (caller
        // sets `showDate: false`) — there's no time dimension to filter.
        Text {
            visible: root.showDate
            text: qsTr("Date")
            color: Constants.textSecondary
            font.pixelSize: sp(Constants.fsSmall)
            font.bold: true
        }
        FilterChipRow {
            visible: root.showDate
            entries: [
                { key: "all",       label: qsTr("All time") },
                { key: "thisMonth", label: qsTr("This month") },
                { key: "custom",    label: qsTr("Custom") }
            ]
            selectedKey: root.dateRange
            onChipPicked: function(key) { root.dateRange = key }
        }
        // Custom-range inputs — only when "Custom" is selected AND the date
        // section is shown at all. Plain text fields with a yyyy-MM-dd hint;
        // the page validates strings via _dateWindow() before applying.
        RowLayout {
            Layout.fillWidth: true
            visible: root.showDate && root.dateRange === "custom"
            spacing: dp(Constants.space2)
            AuthTextField {
                id: customFromField
                Layout.fillWidth: true
                label: qsTr("From")
                placeholderText: "yyyy-MM-dd"
                text: root.customFrom
                onTextChanged: root.customFrom = text
            }
            AuthTextField {
                id: customToField
                Layout.fillWidth: true
                label: qsTr("To")
                placeholderText: "yyyy-MM-dd"
                text: root.customTo
                onTextChanged: root.customTo = text
            }
        }

        // ── Supplier ───────────────────────────────────────────────────
        Text {
            text: qsTr("Supplier")
            color: Constants.textSecondary
            font.pixelSize: sp(Constants.fsSmall)
            font.bold: true
            Layout.topMargin: dp(Constants.space2)
            visible: root.showSupplier && (SupplierStore.suppliers || []).length > 0
        }
        FilterChipRow {
            visible: root.showSupplier && (SupplierStore.suppliers || []).length > 0
            entries: {
                var sRev = SupplierStore.revision   // reactivity
                var arr = [{ key: "All", label: qsTr("All") }]
                var src = SupplierStore.suppliers || []
                for (var i = 0; i < src.length; ++i)
                    arr.push({ key: src[i].name, label: src[i].name })
                return arr
            }
            selectedKey: root.supplierName
            onChipPicked: function(key) { root.supplierName = key }
        }

        // ── Order channel ──────────────────────────────────────────────
        // Channel + staff only attach to sale events. For Purchased (which
        // tracks restock/created events), Current and Value (which read the
        // live stock/batch ledger), neither field exists, so the caller
        // hides the rows via `showChannelStaff`.
        Text {
            visible: root.showChannelStaff
            text: qsTr("Order channel")
            color: Constants.textSecondary
            font.pixelSize: sp(Constants.fsSmall)
            font.bold: true
            Layout.topMargin: dp(Constants.space2)
        }
        FilterChipRow {
            visible: root.showChannelStaff
            entries: {
                var arr = [{ key: "All", label: qsTr("All") }]
                var src = OrderChannelStore.channels || []
                for (var i = 0; i < src.length; ++i)
                    arr.push({ key: src[i], label: src[i] })
                return arr
            }
            selectedKey: root.channelName
            onChipPicked: function(key) { root.channelName = key }
        }

        // ── Staff (active members only) ────────────────────────────────
        Text {
            visible: root.showChannelStaff && (StaffStore.staff || []).length > 0
            text: qsTr("Staff")
            color: Constants.textSecondary
            font.pixelSize: sp(Constants.fsSmall)
            font.bold: true
            Layout.topMargin: dp(Constants.space2)
        }
        FilterChipRow {
            visible: root.showChannelStaff && (StaffStore.staff || []).length > 0
            entries: {
                var arr = [{ key: "All", label: qsTr("All") }]
                var src = StaffStore.staff || []
                for (var i = 0; i < src.length; ++i) {
                    var s = src[i]
                    if (s.status && s.status !== "active") continue
                    arr.push({ key: s.name, label: s.name })
                }
                return arr
            }
            selectedKey: root.staffName
            onChipPicked: function(key) { root.staffName = key }
        }

        // ── Category ───────────────────────────────────────────────────
        Text {
            text: qsTr("Category")
            color: Constants.textSecondary
            font.pixelSize: sp(Constants.fsSmall)
            font.bold: true
            Layout.topMargin: dp(Constants.space2)
            visible: (CategoryStore.categories || []).length > 0
        }
        FilterChipRow {
            visible: (CategoryStore.categories || []).length > 0
            entries: {
                var arr = [{ key: "All", label: qsTr("All") }]
                var src = CategoryStore.categories || []
                for (var i = 0; i < src.length; ++i)
                    arr.push({ key: src[i], label: src[i] })
                return arr
            }
            selectedKey: root.categoryName
            onChipPicked: function(key) { root.categoryName = key }
        }
    }
}
