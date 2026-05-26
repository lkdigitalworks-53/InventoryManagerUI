import QtQuick
import QtQuick.Controls as QQC

import "../helper"

// Horizontally scrolling row of chips. Pass a model of either:
//   ["All", "Pending", ...]                               (single string per chip)
//   [{ label: "All", count: 38 }, { label: "Pending" }]   (object form)
// `selected` index is the chip currently active. Emits `chipSelected(index, label)`.
//
// Uses a Flickable directly (instead of QQC.ScrollView wrapping a Row) so
// `contentWidth` is set explicitly to the row's actual implicit width — this
// guarantees overflow chips can be reached by horizontal flick / drag.
Item {
    id: root

    property var model: []
    property int selected: 0
    signal chipSelected(int index, string label)

    implicitHeight: dp(40)

    Flickable {
        id: flick
        anchors.fill: parent
        contentWidth: row.width
        contentHeight: height
        flickableDirection: Flickable.HorizontalFlick
        boundsBehavior: Flickable.StopAtBounds
        clip: true

        Row {
            id: row
            spacing: dp(Constants.space2)
            leftPadding: dp(Constants.space4)
            rightPadding: dp(Constants.space4)
            anchors.verticalCenter: parent.verticalCenter

            Repeater {
                model: root.model
                delegate: Rectangle {
                    id: chip
                    readonly property var entry: typeof modelData === "string" ? { label: modelData } : modelData
                    readonly property bool isOn: index === root.selected

                    height: dp(32)
                    radius: dp(Constants.radiusPill)
                    width: chipText.implicitWidth + dp(24)
                    border.color: isOn ? "transparent" : Constants.borderColor
                    border.width: 1

                    color: chip.isOn ? Constants.brand2 : Constants.cardBg

                    Rectangle {
                        visible: chip.isOn
                        anchors.fill: parent
                        radius: parent.radius
                        gradient: Gradient {
                            orientation: Gradient.Horizontal
                            GradientStop { position: 0.0; color: Constants.brand1 }
                            GradientStop { position: 1.0; color: Constants.brand2 }
                        }
                        z: 0
                    }

                    Text {
                        id: chipText
                        z: 1
                        anchors.centerIn: parent
                        text: chip.entry.count !== undefined
                                ? chip.entry.label + " · " + chip.entry.count
                                : chip.entry.label
                        color: chip.isOn ? Constants.textOnBrand : Constants.textSecondary
                        font.pixelSize: sp(Constants.fsSmall)
                        font.bold: true
                    }

                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            root.selected = index
                            root.chipSelected(index, chip.entry.label)
                        }
                    }
                }
            }
        }
    }
}
