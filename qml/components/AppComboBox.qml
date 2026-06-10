import QtQuick
import QtQuick.Controls as QQC
import QtQuick.Templates as T

import "../helper"

// Modern dropdown matching the prototype's `.field input` look — rounded
// 14dp radius, light bg, 1px subtle border, brand-color caret on focus,
// brand-tinted highlight on selected popup item.
//
// Drop-in replacement for QQC.ComboBox: same `model`, `currentIndex`,
// `currentText`, `onActivated`, etc.
QQC.ComboBox {
    id: root

    implicitHeight: dp(44)
    // Cap implicitWidth so a long display text (e.g. a product name with
    // SKU + price + stock) doesn't push sibling controls off-screen in a
    // RowLayout. Layout.fillWidth still grows it back up to the available
    // space — this just prevents it from being naturally too wide.
    implicitWidth: dp(160)
    leftPadding: dp(14)
    rightPadding: dp(36)   // room for caret
    font.pixelSize: sp(Constants.fsBody)

    // ── Closed state ────────────────────────────────────────────────────────
    background: Rectangle {
        radius: dp(14)
        color: Constants.cardBg
        border.color: root.activeFocus ? Constants.brand2 : Constants.borderColor
        border.width: root.activeFocus ? 2 : 1
        Behavior on border.color { ColorAnimation { duration: Constants.durFast } }
    }

    contentItem: Text {
        leftPadding: 0
        rightPadding: 0
        text: root.displayText
        color: root.enabled ? Constants.textPrimary : Constants.textMuted
        font: root.font
        verticalAlignment: Text.AlignVCenter
        elide: Text.ElideRight
    }

    indicator: Item {
        x: root.width - width - dp(10)
        y: (root.height - height) / 2
        width: dp(20)
        height: dp(20)
        Icon {
            anchors.centerIn: parent
            name: "dropdown"
            color: Constants.textSecondary
            size: sp(14)
        }
    }

    // ── Popup ───────────────────────────────────────────────────────────────
    // Cap height at ~6 rows so long lists become scrollable instead of
    // pushing the popup off-screen. The inner ListView already supports
    // flick-scrolling — the cap lets it actually exercise that.
    popup: T.Popup {
        y: root.height + dp(4)
        width: root.width
        implicitHeight: Math.min(contentItem.implicitHeight + dp(8), dp(260))
        padding: dp(4)

        background: Rectangle {
            radius: dp(14)
            color: Constants.cardBg
            border.color: Constants.borderColor
            border.width: 1
        }

        contentItem: ListView {
            clip: true
            implicitHeight: contentHeight
            model: root.popup.visible ? root.delegateModel : null
            currentIndex: root.highlightedIndex
            boundsBehavior: Flickable.StopAtBounds
            QQC.ScrollIndicator.vertical: QQC.ScrollIndicator { }
        }
    }

    delegate: T.ItemDelegate {
        width: ListView.view ? ListView.view.width : 0
        height: dp(40)
        padding: dp(10)

        contentItem: Text {
            text: modelData
            color: highlighted ? Constants.brand2 : Constants.textPrimary
            font.pixelSize: sp(Constants.fsBody)
            font.bold: highlighted
            verticalAlignment: Text.AlignVCenter
            elide: Text.ElideRight
        }

        background: Rectangle {
            radius: dp(10)
            color: highlighted ? Qt.rgba(0.39, 0.40, 0.95, 0.10) : "transparent"
        }

        highlighted: root.highlightedIndex === index
    }
}
