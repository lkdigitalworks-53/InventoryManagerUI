import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC

import "../helper"

// Reusable list-row card. Avatar (slot) + title/sub + trailing slot.
//
// Layout strategy: pure anchors-based instead of nested RowLayouts. The prior
// Layout-based version was eliding title/subtitle aggressively because
// RowLayout couldn't decide column width when both `Layout.fillWidth` and a
// preferred width of 0 were combined with a trailing block of natural width.
// With anchors, the trailing slot sizes itself to its content (natural
// implicitWidth), the leading slot sizes to its avatar, and the title column
// gets exactly the space between them — so the text only elides when it
// genuinely doesn't fit.
QQC.AbstractButton {
    id: root

    property string title: ""
    property string subtitle: ""
    default property alias content: trailing.data
    property alias leading: leadingHolder.data
    // When true, render with no card chrome — used for the dashboard's
    // "Recent activity" section where rows sit on the page background.
    property bool flat: false

    implicitHeight: dp(64)
    padding: 0
    leftPadding: 0
    rightPadding: 0
    topPadding: 0
    bottomPadding: 0
    clip: true

    background: Rectangle {
        radius: dp(Constants.radius)
        color: root.flat
                ? "transparent"
                : (root.pressed ? Constants.subtleBg : Constants.cardBg)
        border.color: root.flat ? "transparent" : Constants.borderColor
        border.width: root.flat ? 0 : 1
        Behavior on color { ColorAnimation { duration: Constants.durFast } }
    }

    contentItem: Item {
        anchors.fill: parent

        // ── Leading slot (avatar) — anchored to left edge, sized by content.
        Item {
            id: leadingHolder
            anchors.left: parent.left
            anchors.leftMargin: dp(14)
            anchors.verticalCenter: parent.verticalCenter
            width: childrenRect.width
            height: childrenRect.height
        }

        // ── Trailing slot — anchored to right, sized by content (intrinsic
        // implicitWidth of the inner RowLayout, capped at 60% of the card so
        // long buttons can't push the title out).
        RowLayout {
            id: trailing
            anchors.right: parent.right
            anchors.rightMargin: dp(14)
            anchors.verticalCenter: parent.verticalCenter
            spacing: dp(Constants.space2)
            // implicitWidth comes from RowLayout summing children's preferred
            // widths. Cap so trailing can never eat more than 60% of card.
            width: Math.min(implicitWidth, root.width * 0.6)
        }

        // ── Title / subtitle column — fills the gap between leading and
        // trailing. Width is computed as parent.width minus both anchors and
        // both 14dp margins; this lets each Text honour its own
        // `elide: ElideRight` without the surrounding Layout shrinking it
        // beyond what's actually available.
        ColumnLayout {
            id: titleCol
            anchors.left: leadingHolder.right
            anchors.right: trailing.left
            anchors.verticalCenter: parent.verticalCenter
            anchors.leftMargin: leadingHolder.children.length > 0 ? dp(Constants.space3) : 0
            anchors.rightMargin: dp(Constants.space3)
            spacing: dp(2)

            Text {
                text: root.title
                color: Constants.textPrimary
                font.pixelSize: sp(Constants.fsBodyLg)
                font.bold: true
                elide: Text.ElideRight
                Layout.fillWidth: true
            }
            Text {
                visible: root.subtitle.length > 0
                text: root.subtitle
                color: Constants.textSecondary
                font.pixelSize: sp(Constants.fsSmall)
                elide: Text.ElideRight
                Layout.fillWidth: true
            }
        }
    }
}
