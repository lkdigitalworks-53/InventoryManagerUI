import QtQuick
import QtQuick.Effects

// RoundedThumb — a small Image that is actually clipped to a rounded rectangle.
//
// `clip: true` on a Rectangle clips children to the Rectangle's axis-aligned bounding box, NOT
// to its rounded shape (`radius` only affects what the Rectangle itself paints). A
// PreserveAspectCrop Image filling that box is a plain rectangle, so its square corners sit past
// the rounded frame's arc and visually poke out of it at all four corners — PR #84 device-test
// complaint (2026-09-29), "the photos goes out of the rectangle". MultiEffect's mask is the only
// way to actually clip content to a rounded shape; factored here once since ProductPhotoGallery
// needs it at two call sites (confirmed tiles, queued tiles) — see qt-qml skill, "Extract on
// reuse".
Item {
    id: thumbRoot

    property alias source: img.source
    property alias status: img.status
    property int radius: 0
    property bool asynchronous: true
    property bool cache: true
    property int fillMode: Image.PreserveAspectCrop

    Image {
        id: img
        anchors.fill: parent
        visible: false
        asynchronous: thumbRoot.asynchronous
        cache: thumbRoot.cache
        fillMode: thumbRoot.fillMode
        sourceSize.width: thumbRoot.width
        sourceSize.height: thumbRoot.height
    }

    Rectangle {
        id: maskShape
        anchors.fill: parent
        radius: thumbRoot.radius
        visible: false
    }

    MultiEffect {
        anchors.fill: img
        source: img
        maskEnabled: true
        maskSource: maskShape
    }
}
