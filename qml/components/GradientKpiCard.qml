import QtQuick
import QtQuick.Layouts

import "../helper"

// Modern KPI card matching the prototype's grad-1..4 variants.
//
// Optional `spark: [v1, v2, v3, ...]` renders a thin white polyline at the
// bottom-right of the card, matching the prototype's `.spark` SVG. When the
// array has fewer than 2 points, no chart is drawn — the card looks identical
// to the original text-only design.
Rectangle {
    id: root

    property string label: ""
    property string value: ""
    property string trend: ""               // e.g. "▲ 12.4%" — leave empty to hide
    property string trendVariant: "up"      // "up" | "down" | "muted"
    property var palette: Constants.grad1
    property var spark: []                  // numeric array for sparkline
    property bool wide: false

    radius: dp(Constants.radius)
    implicitHeight: dp(110)
    Layout.fillWidth: true
    clip: true

    gradient: Gradient {
        orientation: Gradient.Vertical
        GradientStop { position: 0.0; color: root.palette ? root.palette.start : Constants.brand1 }
        GradientStop { position: 1.0; color: root.palette ? root.palette.end   : Constants.brand2 }
    }

    // Soft top-left highlight — gives the card depth without an extra image.
    Rectangle {
        anchors.fill: parent
        radius: parent.radius
        gradient: Gradient {
            orientation: Gradient.Vertical
            GradientStop { position: 0.0; color: Qt.rgba(1,1,1,0.30) }
            GradientStop { position: 0.55; color: Qt.rgba(1,1,1,0.0) }
            GradientStop { position: 1.0; color: Qt.rgba(1,1,1,0.0) }
        }
    }

    // Sparkline at bottom-right. Hidden when not enough data.
    Canvas {
        id: spark
        visible: root.spark && root.spark.length >= 2
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.rightMargin: dp(10)
        anchors.bottomMargin: dp(10)
        width: dp(72)
        height: dp(24)
        opacity: 0.9
        property var _data: root.spark
        on_DataChanged: requestPaint()
        onPaint: {
            var ctx = getContext("2d")
            ctx.clearRect(0, 0, width, height)
            var data = root.spark || []
            if (data.length < 2) return
            var maxV = 0
            for (var i = 0; i < data.length; ++i)
                if (data[i] > maxV) maxV = data[i]
            if (maxV <= 0) maxV = 1
            var stepX = width / (data.length - 1)
            ctx.beginPath()
            for (var j = 0; j < data.length; ++j) {
                var px = j * stepX
                var py = height - (data[j] / maxV) * (height - 2)
                if (j === 0) ctx.moveTo(px, py)
                else ctx.lineTo(px, py)
            }
            ctx.strokeStyle = "rgba(255, 255, 255, 0.95)"
            ctx.lineWidth = 2
            ctx.lineCap = "round"
            ctx.lineJoin = "round"
            ctx.stroke()
        }
    }

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: dp(Constants.space4)
        spacing: dp(Constants.space1)

        Text {
            text: root.label.toUpperCase()
            color: Qt.rgba(1, 1, 1, 0.85)
            font.pixelSize: sp(Constants.fsCaption)
            font.letterSpacing: 1
            font.bold: true
            elide: Text.ElideRight
            Layout.fillWidth: true
        }

        Text {
            text: root.value
            color: Constants.textOnBrand
            font.pixelSize: sp(Constants.fsH1)
            font.bold: true
            font.letterSpacing: -0.3
            Layout.topMargin: dp(2)
            elide: Text.ElideRight
            Layout.fillWidth: true
        }

        Item { Layout.fillHeight: true }

        // Trend pill — Layout.maximumWidth caps it at the available content
        // width so long labels like "temporarily away" elide instead of
        // overflowing. Layout.alignment pegs it to the left so the visible
        // pill never visually drifts past the card edge during transient
        // layout passes.
        Rectangle {
            id: trendPill
            visible: root.trend.length > 0
            radius: dp(Constants.radiusPill)
            color: root.trendVariant === "down"
                    ? Qt.rgba(0, 0, 0, 0.18)
                    : Qt.rgba(1, 1, 1, 0.22)
            Layout.alignment: Qt.AlignLeft
            Layout.preferredHeight: dp(22)
            // Available content area = card.width - 2 * outer margin.
            // Constants.space4 == 16; outer ColumnLayout uses anchors.margins
            // of dp(space4) on each side, so subtract 32dp of card width.
            readonly property real _maxW: root.width - dp(32)
            Layout.preferredWidth: Math.min(trendTxt.implicitWidth + dp(20), _maxW)
            Layout.maximumWidth: _maxW
            clip: true
            Text {
                id: trendTxt
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.leftMargin: dp(8)
                anchors.rightMargin: dp(8)
                text: root.trend
                color: Constants.textOnBrand
                font.pixelSize: sp(Constants.fsSmall)
                font.bold: true
                horizontalAlignment: Text.AlignHCenter
                elide: Text.ElideRight
            }
        }
    }
}
