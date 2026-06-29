import QtQuick
import QtQuick.Controls as QQC

// Page scroll container used across every full-screen page.
//
// Why this exists: QQC.ScrollView enables flicking on touch devices but
// disables it for a mouse (see Qt's ScrollView "Touch vs. Mouse Interaction").
// Its auto-created internal Flickable defaults to DragAndOvershootBounds, so on
// Android the user can press-and-hold anywhere and free-drag / rubber-band the
// whole page even when the content already fits — desktop never showed this
// because a mouse can't flick. Pinning the internal Flickable to StopAtBounds
// removes the free-drag/overshoot while still allowing genuine scrolling when
// content overflows. boundsBehavior is not exposed on ScrollView itself; the
// only handle is contentItem (the internal Flickable), so we set it there.
QQC.ScrollView {
    id: control

    clip: true
    QQC.ScrollBar.horizontal.policy: QQC.ScrollBar.AlwaysOff

    function _pinBounds() {
        if (contentItem && contentItem.boundsBehavior !== undefined)
            contentItem.boundsBehavior = Flickable.StopAtBounds
    }

    // contentItem is assigned when ScrollView wraps a non-flickable child in
    // its internal Flickable; catch both that moment and final completion.
    onContentItemChanged: _pinBounds()
    Component.onCompleted: _pinBounds()
}
