pragma Singleton
import QtQuick

// Device safe-area insets (px), bound once in Main.qml to Felgo's live
// app.safeAreaInsets. Chrome that touches a screen edge reads these instead of
// prop-drilling through every page. All 0 on desktop, so layouts are unchanged
// there. See docs/superpowers/specs/2026-06-11-android-shell-design.md.
QtObject {
    property real top: 0
    property real bottom: 0
    property real left: 0
    property real right: 0
}
