.pragma library

// Pure geometry, contrast and state classification for the failed-upload photo tile overlay
// (FailedTileOverlay.qml). No Qt types, no singletons -- everything testable stays in this file
// (same convention as PhotoQueueLogic.js / PhotoUrl.js). Tests: tests/tst_FailedTileGeometry.qml.
// Design: docs/superpowers/specs/2026-09-29-photo-gallery-failed-tile-actions-design.md
//
// All sizes are in "units" (pass dp(1) as `unit`, or 1 for plain pixels) so the numbers below read
// as the dp values in the design. A tile is BASE_TILE (72) units square; two touch targets have to
// fit inside it without overlapping, so on a SMALLER tile everything scales down proportionally
// (never overlaps), and on a LARGER tile the targets keep their size (never blow up).

var BASE_TILE = 72       // design tile edge
var RETRY_D = 36         // retry circle diameter (visual == hit)
var DISCARD_HIT = 28     // discard touch target (square, top-right corner of the tile)
var DISCARD_CHIP = 22    // discard visible chip, centred inside its hit square
var SCRIM_RGB = [15, 23, 42]   // slate-900, same base as Constants.borderSoft/shadowSoft
var SCRIM_ALPHA = 0.62
var CHIP_ALPHA = 0.22    // white wash of the discard chip on top of the scrim

function _size(v) {
    return (typeof v === "number" && isFinite(v) && v > 0) ? v : 0
}

// tileSize and unit in px; returns rects relative to the tile's top-left corner.
function layout(tileSize, unit) {
    var t = _size(tileSize)
    var u = _size(unit)
    var s = (t > 0 && u > 0) ? Math.min(1, t / (BASE_TILE * u)) : 0
    var d = RETRY_D * u * s
    var hit = DISCARD_HIT * u * s
    var chip = DISCARD_CHIP * u * s
    // Centred when there is room; pushed down just far enough to clear the discard hit box when not.
    var retryY = Math.max(hit, (t - d) / 2)
    return {
        scale: s,
        retry: { x: (t - d) / 2, y: retryY, width: d, height: d },
        discardHit: { x: t - hit, y: 0, width: hit, height: hit },
        discardChip: { x: t - hit + (hit - chip) / 2, y: (hit - chip) / 2, width: chip, height: chip }
    }
}

// What a tile shows on top of its thumbnail: "none" (confirmed photo), "busy" (queued, not given
// up yet -- spinner), "failed" (queued and gave up -- Retry/Discard overlay).
function overlayMode(kind, state) {
    if (kind !== "queued") return "none"
    return state === "failed" ? "failed" : "busy"
}

// WCAG relative luminance / contrast, so the scrim's "white text stays readable" claim is executable.
function _lin(c) {
    var v = c / 255
    return v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4)
}
function _lum(r, g, b) {
    return 0.2126 * _lin(r) + 0.7152 * _lin(g) + 0.0722 * _lin(b)
}
function _over(fg, a, bg) {
    return a * fg + (1 - a) * bg
}

// Contrast of a white glyph over the scrim, composited on a grey backdrop (0..255) -- i.e. the
// photo underneath. White backdrop (255) is the worst case.
function whiteContrastOverScrim(backdropGray, alpha) {
    var a = (alpha === undefined) ? SCRIM_ALPHA : alpha
    var r = _over(SCRIM_RGB[0], a, backdropGray)
    var g = _over(SCRIM_RGB[1], a, backdropGray)
    var b = _over(SCRIM_RGB[2], a, backdropGray)
    return 1.05 / (_lum(r, g, b) + 0.05)
}

// Same, for the white glyph inside the discard chip (scrim, then a white wash of CHIP_ALPHA).
function whiteContrastOverChip(backdropGray) {
    var r = _over(SCRIM_RGB[0], SCRIM_ALPHA, backdropGray)
    var g = _over(SCRIM_RGB[1], SCRIM_ALPHA, backdropGray)
    var b = _over(SCRIM_RGB[2], SCRIM_ALPHA, backdropGray)
    return 1.05 / (_lum(_over(255, CHIP_ALPHA, r), _over(255, CHIP_ALPHA, g), _over(255, CHIP_ALPHA, b)) + 0.05)
}
