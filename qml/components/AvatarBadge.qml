import QtQuick

import "../helper"

// Rounded square avatar with gradient fill and centered initials/emoji.
// Sizes: "sm" (28), "md" (38, default), "lg" (48), "xl" (88).
Rectangle {
    id: root

    property string label: "?"
    property string iconName: ""
    property var palette: Constants.grad1
    property string size: "md"
    property string imageSource: ""

    readonly property int _px: size === "sm" ? dp(28)
                              : size === "lg" ? dp(48)
                              : size === "xl" ? dp(88)
                              : dp(38)
    readonly property int _radius: size === "xl" ? dp(22) : (size === "lg" ? dp(14) : dp(12))
    readonly property int _font:  size === "xl" ? sp(32) : (size === "lg" ? sp(18) : (size === "sm" ? sp(11) : sp(13)))

    implicitWidth: _px
    implicitHeight: _px
    radius: _radius
    clip: true

    gradient: Gradient {
        orientation: Gradient.Vertical
        GradientStop { position: 0.0; color: root.palette ? root.palette.start : Constants.brand1 }
        GradientStop { position: 1.0; color: root.palette ? root.palette.end   : Constants.brand2 }
    }

    Image {
        anchors.fill: parent
        source: root.imageSource
        visible: source != ""
        fillMode: Image.PreserveAspectCrop
        cache: true
        sourceSize.width: root._px * 2
        sourceSize.height: root._px * 2
    }

    Text {
        anchors.centerIn: parent
        visible: root.imageSource.length === 0 && root.iconName.length === 0
        text: root.label
        color: Constants.textOnBrand
        font.pixelSize: root._font
        font.bold: true
    }

    Icon {
        anchors.centerIn: parent
        visible: root.imageSource.length === 0 && root.iconName.length > 0
        name: root.iconName
        color: Constants.textOnBrand
        size: root._font
    }
}
