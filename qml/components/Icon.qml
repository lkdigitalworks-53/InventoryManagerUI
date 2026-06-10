import QtQuick
import QtQuick.Window
import Felgo

import "../helper"

// The single icon-rendering element for the whole app. Two backends, chosen by
// name:
//   • Color SVG (Twemoji)   — illustrative icons; full-color; `color` IGNORED.
//   • FontAwesome (AppIcon) — functional chrome; monochrome; tinted by `color`.
//
// Names in Constants.colorIconSet render as assets/icons/<name>.svg; everything
// else resolves through Constants.iconMap. Never put a raw Unicode glyph in a
// Text element — color emoji crash on Android (see the colorful-svg-icons spec).
//
//   Icon { name: "dropdown"; size: sp(14); color: Constants.textSecondary }  // chrome, tinted
//   Icon { name: "box";      size: sp(28) }                                   // color SVG (color ignored)
Item {
    id: root

    property string name: ""
    property real size: sp(16)
    property color color: Constants.textPrimary   // chrome only — ignored for color SVG

    implicitWidth: size
    implicitHeight: size

    readonly property bool _isColor: Constants.isColorIcon(name)

    Loader {
        anchors.fill: parent
        sourceComponent: root._isColor ? colorIcon : glyphIcon
    }

    Component {
        id: glyphIcon
        AppIcon {
            anchors.centerIn: parent
            iconType: Constants.icon(root.name)
            size: root.size
            color: root.color
        }
    }

    Component {
        id: colorIcon
        Image {
            anchors.centerIn: parent
            width: root.size
            height: root.size
            source: Constants.colorIconSource(root.name)
            // Rasterize the SVG at PHYSICAL pixel resolution. On a scaled/HiDPI
            // display the item spans size×devicePixelRatio physical pixels, so a
            // raster pinned to logical `size` gets upscaled and looks soft. Cap
            // the ratio so a misreported DPR can't blow up the texture.
            sourceSize.width: root.size * Math.min(Screen.devicePixelRatio, 3)
            sourceSize.height: root.size * Math.min(Screen.devicePixelRatio, 3)
            fillMode: Image.PreserveAspectFit
            smooth: true
            mipmap: true
            asynchronous: true
            cache: true
        }
    }
}
