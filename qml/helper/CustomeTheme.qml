import QtQuick
import Felgo

// Theme is intentionally a thin pass-through to Constants.qml so we have ONE
// source of truth. Existing call sites (e.g. theme.headerGradientStart) keep
// working — they now resolve through the brand tokens.
Item {
    id: theme

    // ── Header / hero gradient ──
    property color headerGradientStart: Constants.brand1
    property color headerGradientEnd:   Constants.brand2

    // ── Per-tab accents (legacy — not used by the new tabbar) ──
    property color ordersTabColor:    Constants.brand3
    property color inventoryTabColor: Constants.brand4
    property color salesTabColor:     Constants.brand1
    property color staffTabColor:     Constants.brand2

    // ── Text ──
    property color darkTextColor:   Constants.textPrimary
    property color mediumTextColor: Constants.textSecondary
    property color lightTextColor:  Constants.textOnBrand

    // ── Cards ──
    property color cardBackground: Constants.cardBg
    property color cardBorder:     Constants.borderColor
    property int   cardRadius:     Constants.radius
}
