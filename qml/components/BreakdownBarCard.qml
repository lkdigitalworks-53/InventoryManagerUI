import QtQuick
import QtQuick.Layouts

import "../helper"

// Vertical-bar breakdown chart used across every Analysis view. Pure
// presentation — it renders `model` ([{ label, value, fullLabel }]) and
// computes its own max. The page supplies the title, colours, and units.
ColumnLayout {
    id: root

    property string title: ""
    property var    model: []
    property bool   currency: false   // ₹ prefix on axis + value tips
    property string emptyText: ""
    property var    barTop: Constants.brand3      // gradient start (top)
    property var    barBottom: Constants.brand2   // gradient end (bottom)
    property real   chartHeight: dp(180)
    property bool   showValueTips: true           // per-bar value caption (on every bar)

    spacing: dp(Constants.space2)
    Layout.fillWidth: true

    function _maxValue() {
        var m = 0
        var src = root.model || []
        for (var i = 0; i < src.length; ++i)
            if (src[i].value > m) m = src[i].value
        return m
    }

    // Compact axis label — mirrors SalesPage._formatAxisValue.
    function _formatAxis(v) {
        if (v === undefined || v === null || isNaN(v)) v = 0
        var n = Math.round(v)
        var compact
        if (Math.abs(n) >= 1e6) compact = (n / 1e6).toFixed(1) + "M"
        else if (Math.abs(n) >= 1e3) compact = (n / 1e3).toFixed(1) + "k"
        else compact = String(n)
        return root.currency ? "₹" + compact : compact
    }

    Text {
        text: root.title
        color: Constants.textPrimary
        font.pixelSize: sp(Constants.fsBodyLg)
        font.bold: true
        visible: root.title.length > 0
    }

    Rectangle {
        Layout.fillWidth: true
        Layout.preferredHeight: root.chartHeight
        radius: dp(Constants.radius)
        color: Constants.cardBg
        border.color: Constants.borderColor
        border.width: 1

        // Centered placeholder when there's nothing to chart.
        Text {
            anchors.centerIn: parent
            width: parent.width - dp(Constants.space4 * 2)
            visible: (root.model || []).length === 0 && root.emptyText.length > 0
            text: root.emptyText
            color: Constants.textMuted
            font.pixelSize: sp(Constants.fsCaption)
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.Wrap
        }

        Item {
            id: yAxis
            anchors.left: parent.left
            anchors.top: parent.top
            anchors.bottom: parent.bottom
            anchors.leftMargin: dp(Constants.space3)
            anchors.topMargin: dp(Constants.space3)
            anchors.bottomMargin: dp(Constants.space3) + dp(20)
            width: dp(28)
            visible: (root.model || []).length > 0
            Text {
                anchors.right: parent.right; anchors.top: parent.top
                text: root._formatAxis(root._maxValue())
                color: Constants.textMuted; font.pixelSize: sp(Constants.fsCaption)
            }
            Text {
                anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
                text: root._formatAxis(root._maxValue() / 2)
                color: Constants.textMuted; font.pixelSize: sp(Constants.fsCaption)
            }
            Text {
                anchors.right: parent.right; anchors.bottom: parent.bottom
                text: "0"; color: Constants.textMuted; font.pixelSize: sp(Constants.fsCaption)
            }
        }

        RowLayout {
            anchors.left: yAxis.right
            anchors.leftMargin: dp(Constants.space2)
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.bottom: parent.bottom
            anchors.rightMargin: dp(Constants.space3)
            anchors.topMargin: dp(Constants.space3)
            anchors.bottomMargin: dp(Constants.space3)
            spacing: dp(6)
            visible: (root.model || []).length > 0

            Repeater {
                model: root.model
                delegate: ColumnLayout {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    spacing: dp(4)
                    Item {
                        id: barCell
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        // Bar pixel height for this value (≥6px so a tiny non-zero
                        // value is still visible).
                        readonly property real _barH: Math.max(dp(6), height *
                                Math.min(1, modelData.value /
                                    Math.max(1, root._maxValue())))
                        // Show the value INSIDE the bar when it's tall enough to
                        // fit the caption; otherwise float it just ABOVE the bar
                        // so EVERY bar — even short ones — shows its number (bug 12).
                        readonly property bool _labelInside: _barH > dp(22)
                        Rectangle {
                            anchors.left: parent.left
                            anchors.right: parent.right
                            anchors.bottom: parent.bottom
                            radius: dp(Constants.radiusSm)
                            height: barCell._barH
                            gradient: Gradient {
                                orientation: Gradient.Vertical
                                GradientStop { position: 0.0; color: root.barTop }
                                GradientStop { position: 1.0; color: root.barBottom }
                            }
                            Behavior on height { NumberAnimation { duration: Constants.durMed } }
                        }
                        Text {
                            anchors.horizontalCenter: parent.horizontalCenter
                            anchors.bottom: parent.bottom
                            // Inside tall bars: sit just above the bar's bottom edge.
                            // Above short bars: float just over the bar top.
                            anchors.bottomMargin: barCell._labelInside
                                    ? dp(4)
                                    : barCell._barH + dp(2)
                            visible: root.showValueTips && modelData.value > 0
                            text: root._formatAxis(modelData.value)
                            color: barCell._labelInside ? Constants.textOnBrand : Constants.textSecondary
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
