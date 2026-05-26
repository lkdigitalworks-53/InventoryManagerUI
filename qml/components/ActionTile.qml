import QtQuick
import QtQuick.Controls as QQC

import "../helper"

// Square Quick-Action tile used on the dashboard. Icon stacked above caption.
QQC.AbstractButton {
    id: root

    property string emoji: "✨"
    property string caption: ""

    implicitWidth: dp(80)
    implicitHeight: dp(84)

    contentItem: Item {
        // Bare Column couldn't centre vertically inside the AbstractButton's
        // content slot — it collapsed to children's natural height and sat at
        // the top. Wrap it in an Item that fills the button and use
        // anchors.centerIn for true 2-axis centring.
        Column {
            anchors.centerIn: parent
            spacing: dp(6)

            // Fixed-width emoji container — emoji glyphs have asymmetric
            // padding around their drawn shape, so centering the Text element
            // alone isn't optically centred. Pinning a known-size box gives
            // a predictable centre.
            Item {
                anchors.horizontalCenter: parent.horizontalCenter
                width: dp(28)
                height: dp(28)
                Text {
                    anchors.centerIn: parent
                    text: root.emoji
                    font.pixelSize: sp(22)
                }
            }
            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: root.caption
                color: Constants.textPrimary
                font.pixelSize: sp(Constants.fsCaption)
                font.bold: true
                elide: Text.ElideRight
                width: root.width - dp(12)
                horizontalAlignment: Text.AlignHCenter
            }
        }
    }

    background: Rectangle {
        radius: dp(Constants.radius)
        color: root.pressed ? Constants.subtleBg : Constants.cardBg
        border.color: Constants.borderColor
        border.width: 1
        Behavior on color { ColorAnimation { duration: Constants.durFast } }
    }
}
