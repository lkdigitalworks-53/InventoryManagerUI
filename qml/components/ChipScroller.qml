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
//
// S5e-1 (picker v2; KNOWN-ISSUES 70c): every chip is a 48 dp touch target (it was the 32 dp painted pill) and is one
// accessible control: a radio button named like its label, checked when selected, with a press action. Before, the
// chip was a bare Rectangle and MouseArea that TalkBack could read as text but had no action on. The pill is still
// painted 32 dp tall (more at a large system font, and then the row grows with it) and centred in its 48 dp target, so
// the row looks as before but 8 dp taller than its old 40 dp. Four pages and the product sheet share this component (S5e-1 plan, D1 and D3).
Item {
    id: root

    property var model: []
    property int selected: 0
    signal chipSelected(int index, string label)

    // The pill follows the system font (a big font makes a taller pill); the 48 dp row follows the pill, 4 dp above and
    // below at least, so a huge text size grows the row instead of clipping the pill. One measured line, same font as the chip.
    readonly property real _pillHeight: Math.max(dp(32), lineMetrics.height + dp(12))
    implicitHeight: Math.max(dp(48), _pillHeight + dp(8))

    TextMetrics { id: lineMetrics; font.pixelSize: sp(Constants.fsSmall); font.bold: true; text: "Ag" }

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
                delegate: Item {
                    id: chip
                    readonly property var entry: typeof modelData === "string" ? { label: modelData } : modelData
                    readonly property bool isOn: index === root.selected
                    // What TalkBack says: the label and the count, with a comma where the picture has a dot.
                    readonly property string spoken: chip.entry.count !== undefined
                            ? chip.entry.label + ", " + chip.entry.count
                            : chip.entry.label

                    function choose() {
                        // A tap never reaches a disabled chip (StockRegisterPage dims the row while a load runs). The screen
                        // reader's press action is not guaranteed to stop there, so the same code refuses it here.
                        if (!chip.enabled) return
                        root.selected = index
                        root.chipSelected(index, chip.entry.label)
                    }

                    width: pill.width
                    height: root.implicitHeight

                    Accessible.role: Accessible.RadioButton
                    Accessible.name: chip.spoken
                    Accessible.checked: chip.isOn
                    Accessible.onPressAction: chip.choose()

                    Rectangle {
                        id: pill
                        anchors.verticalCenter: parent.verticalCenter
                        height: root._pillHeight
                        radius: dp(Constants.radiusPill)
                        width: chipText.implicitWidth + dp(24)
                        border.color: chip.isOn ? "transparent" : Constants.borderColor
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
                            Accessible.ignored: true    // the chip above is the one stop, not a second, silent one
                        }
                    }

                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: chip.choose()
                    }
                }
            }
        }
    }
}
