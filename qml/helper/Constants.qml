pragma Singleton

import QtQuick

Item {
    // Firestore REST API base URL
    readonly property string firebaseDatabaseUrl: "https://firestore.googleapis.com/v1/projects/inventorymanager-48392/databases/(default)/documents"

    // Color palette
    readonly property color primaryBlue: "#3158ff"
    readonly property color primaryPurple: "#6b41ff"
    readonly property color accentOrange: "#ea580c"
    readonly property color accentGreen: "#16a34a"
    readonly property color accentBlue: "#2563eb"

    // Status colors
    readonly property color pendingFill: "#fef3c7"
    readonly property color pendingStroke: "#f59e0b"
    readonly property color completedFill: "#dcfce7"
    readonly property color completedStroke: "#22c55e"
    readonly property color processingFill: "#e0f2fe"
    readonly property color processingStroke: "#38bdf8"
    readonly property color outOfStockFill: "#fee2e2"
    readonly property color outOfStockStroke: "#ef4444"

    // Layout breakpoints
    readonly property int compactBreakpoint: 520

    // Background colors
    readonly property color pageBg: "#f0f2f5"
    readonly property color cardBg: "#ffffff"
    readonly property color borderColor: "#e5e7eb"
}
