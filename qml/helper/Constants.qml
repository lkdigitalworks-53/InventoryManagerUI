pragma Singleton

import QtQuick
import Felgo

Item {
    // ── Backend ──────────────────────────────────────────────────────────────
    readonly property string firebaseDatabaseUrl: "https://firestore.googleapis.com/v1/projects/inventorymanager-48392/databases/(default)/documents"

    // ── Brand palette (mobile redesign) ──────────────────────────────────────
    // Maps 1:1 to the prototype's --c-brand-* tokens.
    readonly property color brand1: "#6366f1"   // indigo
    readonly property color brand2: "#8b5cf6"   // violet
    readonly property color brand3: "#ec4899"   // pink
    readonly property color brand4: "#06b6d4"   // cyan
    readonly property color brand5: "#14b8a6"   // teal

    // Legacy aliases — kept so existing screens compile until they are reskinned.
    readonly property color primaryBlue:   brand1
    readonly property color primaryPurple: brand2
    readonly property color accentOrange:  "#ea580c"
    readonly property color accentGreen:   "#16a34a"
    readonly property color accentBlue:    "#2563eb"
    readonly property color accentPink:    brand3
    readonly property color accentCyan:    brand4

    // ── Semantic palette ─────────────────────────────────────────────────────
    readonly property color warn:    "#f59e0b"
    readonly property color danger:  "#ef4444"
    readonly property color success: "#10b981"

    // Status surfaces
    readonly property color pendingFill:    "#fef3c7"
    readonly property color pendingStroke:  "#f59e0b"
    readonly property color pendingText:    "#92400e"
    readonly property color processingFill: "#e0f2fe"
    readonly property color processingStroke: "#38bdf8"
    readonly property color processingText: "#075985"
    readonly property color completedFill:  "#dcfce7"
    readonly property color completedStroke: "#22c55e"
    readonly property color completedText:  "#166534"
    readonly property color cancelledFill:  "#fee2e2"
    readonly property color cancelledStroke: "#ef4444"
    readonly property color cancelledText:  "#991b1b"
    readonly property color outOfStockFill:   cancelledFill
    readonly property color outOfStockStroke: cancelledStroke
    readonly property color lowFill:        "#fee2e2"
    readonly property color lowText:        "#991b1b"

    // ── Surfaces ─────────────────────────────────────────────────────────────
    readonly property color appBg:      "#f4f5fb"
    readonly property color pageBg:     appBg          // legacy alias
    readonly property color screenBg:   "#ffffff"
    readonly property color cardBg:     "#ffffff"
    readonly property color elevatedBg: Qt.rgba(1, 1, 1, 0.72)
    readonly property color glassBg:    Qt.rgba(1, 1, 1, 0.55)
    readonly property color subtleBg:   "#f9fafb"

    readonly property color borderColor:   "#e5e7eb"
    readonly property color borderSoft:    Qt.rgba(0.058, 0.090, 0.165, 0.08) // ~slate-900 @ 8%
    readonly property color shadowSoft:    Qt.rgba(0.058, 0.090, 0.165, 0.10)
    readonly property color overlay:       Qt.rgba(0.008, 0.024, 0.090, 0.45)

    // ── Text ─────────────────────────────────────────────────────────────────
    readonly property color textPrimary:   "#0f172a"
    readonly property color textSecondary: "#475569"
    readonly property color textMuted:     "#94a3b8"
    readonly property color textOnBrand:   "#ffffff"

    // ── Layout / sizing ──────────────────────────────────────────────────────
    readonly property int compactBreakpoint: 520
    // Bottom space every scrollable page must leave so its content clears the
    // floating tabbar. Wrap with dp() at the consumer.
    readonly property int tabbarClearance: 110

    readonly property int radiusSm: 10
    readonly property int radius:   16
    readonly property int radiusLg: 22
    readonly property int radiusXl: 28
    readonly property int radiusPill: 999

    readonly property int space1: 4
    readonly property int space2: 8
    readonly property int space3: 12
    readonly property int space4: 16
    readonly property int space5: 20
    readonly property int space6: 24
    readonly property int space7: 32

    // Typography scale (matches prototype's 11/12/13/14/16/20/24/26/32 ladder)
    readonly property int fsCaption: 11
    readonly property int fsSmall:   12
    readonly property int fsBody:    13
    readonly property int fsBodyLg:  14
    readonly property int fsTitle:   16
    readonly property int fsH3:      18
    readonly property int fsH2:      20
    readonly property int fsH1:      24
    readonly property int fsDisplay: 32

    // Animation durations (ms)
    readonly property int durFast: 160
    readonly property int durMed:  240
    readonly property int durSlow: 420

    // ── Gradient stops (helpers for KPI cards / CTAs) ────────────────────────
    // Returned as { start, end } objects; consumers feed them into Gradient.
    readonly property var gradPrimary:    ({ start: brand1, end: brand2 })
    readonly property var gradAccent:     ({ start: brand2, end: brand3 })
    readonly property var gradWarm:       ({ start: "#f59e0b", end: "#ef4444" })
    readonly property var gradCool:       ({ start: brand4,  end: brand5 })
    readonly property var gradHero:       ({ start: brand1, mid: brand2, end: brand3 })

    // KPI variants (matching prototype .grad-1..4)
    readonly property var grad1: ({ start: "#6366f1", end: "#8b5cf6" })
    readonly property var grad2: ({ start: "#ec4899", end: "#f472b6" })
    readonly property var grad3: ({ start: "#f59e0b", end: "#ef4444" })
    readonly property var grad4: ({ start: "#06b6d4", end: "#14b8a6" })

    // ── Icon system ──────────────────────────────────────────────────────────
    // Semantic icon name → Felgo FontAwesome IconType string. The single
    // source of truth for every icon in the app. Add new icons here, never
    // inline a raw glyph in a Text element (breaks on Android — see
    // docs/superpowers/specs/2026-06-06-icon-emoji-rendering-design.md).
    readonly property var iconMap: ({
        "dropdown":  IconType.caretdown,
        "add":       IconType.plus,
        "remove":    IconType.minus,
        "close":     IconType.times,
        "check":     IconType.check,
        "edit":      IconType.pencil,
        "settings":  IconType.cog,
        "quick":     IconType.bolt,
        "import":    IconType.download,
        "export":    IconType.share,
        "back":      IconType.arrowleft,
        "chevron":   IconType.angleright,
        "star":      IconType.star,
        "warn":      IconType.exclamationtriangle,
        "search":    IconType.search,
        // Former emoji → monochrome
        "camera":    IconType.camera,
        "calendar":  IconType.calendar,
        "bell":      IconType.bell,
        "box":       IconType.archive,
        "empty-inbox": IconType.inbox,
        "celebrate": IconType.trophy,
        "staff":     IconType.users,
        "workspace": IconType.building,
        "analytics": IconType.barchart,
        "secure":    IconType.lock,
        "delete":    IconType.trash,
        "gallery":   IconType.image,
        "web":       IconType.globe,
        "clipboard": IconType.clipboard,
        "history":   IconType.filetext,
        "tag":       IconType.tag,
        "orders":     IconType.shoppingcart,
        "products":   IconType.archive,
        "analysis":   IconType.linechart,
        "report":     IconType.linechart,
        "profile":    IconType.user,
        "team":       IconType.users,
        "security":   IconType.lock,
        "appearance": IconType.paintbrush,
        "language":   IconType.globe,
        "currency":   IconType.exchange,
        "pause":      IconType.pause,
        "home":       IconType.home
        ,"created":          IconType.pluscircle
        ,"purchase":         IconType.download
        ,"sale":             IconType.upload
        ,"stock_adjustment": IconType.calculator
        ,"field_change":     IconType.pencil
        ,"photo_change":     IconType.image
        ,"pause-status":     IconType.pause
        // Activity feed kinds (final cleanup pass)
        ,"product-added":    IconType.plus
        ,"product-updated":  IconType.pencil
        ,"restocked":        IconType.refresh
        ,"staff-added":      IconType.user
        ,"staff-updated":    IconType.pencil
        ,"activity":         IconType.questioncircle  // generic "•" fallback
        ,"reveal":           IconType.eye
        ,"hide":             IconType.eyeslash
        ,"file":             IconType.file
    })

    // Resolve a semantic name to an IconType. Falls back to a visible
    // question-circle so a typo is obvious on-screen rather than blank.
    function icon(name) {
        return iconMap[name] !== undefined ? iconMap[name] : IconType.questioncircle
    }

    // ── Color icon set (full-color Twemoji SVG) ──────────────────────────────
    // Names in this set render as a color SVG image (assets/icons/<name>.svg)
    // instead of a tinted FontAwesome glyph. The `color` property has NO effect
    // on these — they are full-color artwork. Anything not listed here falls
    // through to iconMap (monochrome, tintable). See
    // docs/superpowers/specs/2026-06-08-colorful-svg-icons-design.md.
    readonly property var colorIconSet: ({
        "camera": true, "calendar": true, "bell": true,
        "box": true, "products": true,
        "empty-inbox": true, "celebrate": true,
        "staff": true, "team": true,
        "workspace": true, "analytics": true,
        "analysis": true, "report": true,
        "gallery": true, "photo_change": true,
        "web": true, "language": true,
        "clipboard": true, "history": true, "tag": true,
        "orders": true, "profile": true, "staff-added": true,
        "security": true, "secure": true,
        "appearance": true, "currency": true,
        "file": true, "delete": true, "home": true,
        "created": true, "purchase": true, "sale": true,
        "stock_adjustment": true, "product-added": true,
        "restocked": true, "activity": true,
        // Header/action chrome promoted to color (always on light glass/cards)
        "import": true, "export": true,
        "settings": true, "quick": true
    })

    // Is this semantic name a full-color SVG icon?
    function isColorIcon(name) {
        return colorIconSet[name] === true
    }

    // URL of the color SVG asset for a name. Resolved relative to THIS file
    // (qml/helper/), so it is correct regardless of which component calls it.
    function colorIconSource(name) {
        return Qt.resolvedUrl("../../assets/icons/" + name + ".svg")
    }
}
