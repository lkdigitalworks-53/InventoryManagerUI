import QtQuick
import QtQuick.Layouts

import "../components"
import "../helper"

// Generic filter bottom sheet used by the orders page (and reusable elsewhere).
// Holds two chip rows: status & date range. Emits applied(status, date).
BottomSheet {
    id: root

    sheetTitle: "Filters"
    primaryAction: "Apply"
    secondaryAction: "Reset"
    primaryPalette: Constants.gradHero

    property string status: "all"
    property string range:  "today"

    signal filtersApplied(string status, string range)
    signal resetRequested()

    onPrimaryClicked: { filtersApplied(status, range); close() }
    onSecondaryClicked: { status = "all"; range = "today"; resetRequested() }

    ColumnLayout {
        Layout.fillWidth: true
        spacing: dp(Constants.space3)

        Text {
            text: "Status"
            color: Constants.textSecondary
            font.pixelSize: sp(Constants.fsSmall)
            font.bold: true
        }

        Flow {
            Layout.fillWidth: true
            spacing: dp(Constants.space2)
            property var entries: [
                { key: "all",        label: "All" },
                { key: "pending",    label: "Pending" },
                { key: "processing", label: "Processing" },
                { key: "completed",  label: "Completed" },
                { key: "cancelled",  label: "Cancelled" }
            ]

            Repeater {
                model: parent.entries
                delegate: Rectangle {
                    id: statusChip
                    readonly property bool isOn: modelData.key === root.status
                    height: dp(32)
                    width: chipTxt.implicitWidth + dp(24)
                    radius: dp(Constants.radiusPill)
                    color: isOn ? Constants.brand2 : Constants.cardBg
                    border.color: isOn ? "transparent" : Constants.borderColor
                    border.width: 1

                    // Active gradient renders as a child Rectangle so Qt's
                    // gradient/color interaction can't black-hole the visual.
                    Rectangle {
                        visible: statusChip.isOn
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
                        color: statusChip.isOn ? Constants.textOnBrand : Constants.textSecondary
                        font.pixelSize: sp(Constants.fsSmall)
                        font.bold: true
                    }
                    MouseArea {
                        anchors.fill: parent
                        onClicked: root.status = modelData.key
                    }
                }
            }
        }

        Text {
            text: "Date"
            color: Constants.textSecondary
            font.pixelSize: sp(Constants.fsSmall)
            font.bold: true
            Layout.topMargin: dp(Constants.space2)
        }

        Flow {
            Layout.fillWidth: true
            spacing: Constants.space2
            property var entries: [
                { key: "today",  label: "Today" },
                { key: "7days",  label: "7 days" },
                { key: "30days", label: "30 days" },
                { key: "custom", label: "Custom" }
            ]

            Repeater {
                model: parent.entries
                delegate: Rectangle {
                    id: rangeChip
                    readonly property bool isOn: modelData.key === root.range
                    height: dp(32)
                    width: chipTxt2.implicitWidth + dp(24)
                    radius: dp(Constants.radiusPill)
                    color: isOn ? Constants.brand2 : Constants.cardBg
                    border.color: isOn ? "transparent" : Constants.borderColor
                    border.width: 1

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
                        id: chipTxt2
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
