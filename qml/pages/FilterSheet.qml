import QtQuick
import QtQuick.Layouts

import "../components"
import "../helper"

// Date-range filter for the Orders page.
//
// Status filtering already lives on the page itself (chip-scroller below the
// header), so this sheet now focuses solely on the date dimension. The orders
// page consumes `range` to narrow the visible list to today / last 7 days /
// last 30 days / all-time.
BottomSheet {
    id: root

    sheetTitle: qsTr("Date filter")
    primaryAction: qsTr("Apply")
    secondaryAction: qsTr("Reset")
    primaryPalette: Constants.gradHero

    // Public contract preserved for back-compat. `status` is unused — left in
    // place so existing handlers in Main.qml keep type-checking, but every
    // caller should treat it as cosmetic.
    property string status: "all"
    property string range:  "all"

    signal filtersApplied(string status, string range)
    signal resetRequested()

    onPrimaryClicked: { filtersApplied(status, range); close() }
    onSecondaryClicked: { status = "all"; range = "all"; resetRequested() }

    ColumnLayout {
        Layout.fillWidth: true
        spacing: dp(Constants.space3)

        Text {
            text: qsTr("Date")
            color: Constants.textSecondary
            font.pixelSize: sp(Constants.fsSmall)
            font.bold: true
        }

        Flow {
            Layout.fillWidth: true
            spacing: dp(Constants.space2)
            property var entries: [
                { key: "all",    label: qsTr("All time") },
                { key: "today",  label: qsTr("Today") },
                { key: "7days",  label: qsTr("Last 7 days") },
                { key: "30days", label: qsTr("Last 30 days") }
            ]

            Repeater {
                model: parent.entries
                delegate: Rectangle {
                    id: rangeChip
                    readonly property bool isOn: modelData.key === root.range
                    height: dp(32)
                    width: chipTxt.implicitWidth + dp(24)
                    radius: dp(Constants.radiusPill)
                    color: isOn ? Constants.brand2 : Constants.cardBg
                    border.color: isOn ? "transparent" : Constants.borderColor
                    border.width: 1

                    // Active gradient as a child Rectangle so Qt's
                    // gradient/color interaction can't black-hole the visual.
                    Rectangle {
                        visible: rangeChip.isOn
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
                        color: rangeChip.isOn ? Constants.textOnBrand : Constants.textSecondary
                        font.pixelSize: sp(Constants.fsSmall)
                        font.bold: true
                    }
                    MouseArea {
                        anchors.fill: parent
                        onClicked: root.range = modelData.key
                    }
                }
            }
        }
    }
}
