import QtQuick
import Felgo

Item {
    id: theme

    // Header gradient colors
    property color headerGradientStart: "#3158ff"
    property color headerGradientEnd: "#6b41ff"

    // Navigation tab colors
    property color ordersTabColor: "#ea580c"
    property color inventoryTabColor: "#16a34a"
    property color salesTabColor: "#2563eb"
    property color staffTabColor: "#2563eb"

    // Text colors
    property color darkTextColor: "#111827"
    property color mediumTextColor: "#6b7280"
    property color lightTextColor: "#ffffff"

    // Card styling
    property color cardBackground: "#ffffff"
    property color cardBorder: "#e5e7eb"
    property int cardRadius: 12
}
