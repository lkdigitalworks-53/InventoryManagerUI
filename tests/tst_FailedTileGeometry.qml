import QtQuick
import QtTest
import "../qml/helper/FailedTileGeometry.js" as Geo

// Headless tests for the failed-upload tile overlay's pure geometry / contrast / state logic
// (qml/helper/FailedTileGeometry.js). FailedTileOverlay.qml itself imports Felgo-provided dp()/sp()/Icon
// and can't load under qmltestrunner (same limit as ProductPhotoGallery.qml) -- so everything with a
// right/wrong answer lives in the helper and is tested for real here; rendering, gradient and press
// feel are on-device only (see the test plan).
// Design: docs/superpowers/specs/2026-09-29-photo-gallery-failed-tile-actions-design.md
// NOT RUN IN THIS SANDBOX under qmltestrunner (no Qt toolchain, standing instruction) -- CI is the proof.
TestCase {
    name: "FailedTileGeometry"

    readonly property var units: [1, 1.5, 2, 2.625, 3, 3.5]   // realistic dp scales

    function near(a, b) { return Math.abs(a - b) < 1e-9 }
    function overlaps(a, b) {
        return a.x < b.x + b.width && a.x + a.width > b.x && a.y < b.y + b.height && a.y + a.height > b.y
    }
    function inside(r, t) {
        return r.x >= -1e-9 && r.y >= -1e-9 && r.x + r.width <= t + 1e-9 && r.y + r.height <= t + 1e-9
    }
    function allFinite(g) {
        var rects = [g.retry, g.discardHit, g.discardChip]
        for (var i = 0; i < rects.length; ++i) {
            var r = rects[i]
            if (!isFinite(r.x) || !isFinite(r.y) || !isFinite(r.width) || !isFinite(r.height)) return false
            if (r.width < 0 || r.height < 0) return false
        }
        return true
    }

    // ── Happy path: the design's own numbers at the design tile ───────────
    function test_design_tile_72_exact_numbers() {
        var g = Geo.layout(72, 1)
        compare(g.scale, 1)
        verify(near(g.retry.width, 36) && near(g.retry.height, 36))
        verify(near(g.retry.x, 18) && near(g.retry.y, 28))
        verify(near(g.discardHit.width, 28) && near(g.discardHit.height, 28))
        verify(near(g.discardHit.x, 44) && near(g.discardHit.y, 0))
        verify(near(g.discardChip.width, 22))
    }

    function test_retry_is_horizontally_centred_at_every_scale() {
        for (var i = 0; i < units.length; ++i) {
            var u = units[i], t = 72 * u
            var g = Geo.layout(t, u)
            verify(near(g.retry.x * 2 + g.retry.width, t), "unit " + u)
        }
    }

    function test_discard_chip_is_centred_inside_its_hit_square() {
        for (var i = 0; i < units.length; ++i) {
            var g = Geo.layout(72 * units[i], units[i])
            verify(near(g.discardChip.x - g.discardHit.x, g.discardHit.x + g.discardHit.width - g.discardChip.x - g.discardChip.width))
            verify(near(g.discardChip.y - g.discardHit.y, g.discardHit.y + g.discardHit.height - g.discardChip.y - g.discardChip.height))
        }
    }

    // ── The load-bearing guarantee: two targets in one tile never overlap ─
    function test_hit_boxes_never_overlap_at_the_design_tile_for_every_dp_scale() {
        for (var i = 0; i < units.length; ++i) {
            var g = Geo.layout(72 * units[i], units[i])
            verify(!overlaps(g.retry, g.discardHit), "unit " + units[i])
        }
    }

    function test_everything_stays_inside_the_tile() {
        for (var i = 0; i < units.length; ++i) {
            var t = 72 * units[i]
            var g = Geo.layout(t, units[i])
            verify(inside(g.retry, t) && inside(g.discardHit, t) && inside(g.discardChip, t), "unit " + units[i])
        }
    }

    // ── Touch-target floors (WCAG 2.2 minimum 24 CSS px; design 36 / 28) ──
    function test_target_sizes_meet_the_floor_at_and_above_the_design_tile() {
        var tiles = [72, 80, 96, 120, 200]
        for (var i = 0; i < tiles.length; ++i) {
            var g = Geo.layout(tiles[i], 1)
            verify(g.retry.width >= 36 - 1e-9, "retry at tile " + tiles[i])
            verify(g.discardHit.width >= 28 - 1e-9, "discard at tile " + tiles[i])
            verify(g.discardHit.width >= 24 && g.retry.width >= 24, "WCAG 2.2 minimum at tile " + tiles[i])
        }
    }

    function test_larger_tile_keeps_target_size_and_centres_retry_vertically() {
        var g = Geo.layout(120, 1)
        compare(g.scale, 1)
        verify(near(g.retry.width, 36))
        verify(near(g.retry.y, (120 - 36) / 2))
        verify(!overlaps(g.retry, g.discardHit))
    }

    function test_mid_size_tile_pushes_retry_down_just_enough_to_clear_discard() {
        var g = Geo.layout(80, 1)   // (80-36)/2 = 22 < 28 -> pushed to 28
        verify(near(g.retry.y, 28))
        verify(!overlaps(g.retry, g.discardHit))
    }

    // ── Edge: smaller tile scales everything down, still disjoint ─────────
    function test_smaller_tile_scales_proportionally() {
        var g = Geo.layout(36, 1)
        verify(near(g.scale, 0.5))
        verify(near(g.retry.width, 18))
        verify(near(g.discardHit.width, 14))
        verify(!overlaps(g.retry, g.discardHit))
        verify(inside(g.retry, 36) && inside(g.discardHit, 36))
    }

    function test_tiny_tile_still_valid() {
        var g = Geo.layout(1, 1)
        verify(allFinite(g))
        verify(!overlaps(g.retry, g.discardHit))
    }

    // ── Negative: garbage in, harmless zero rects out (never throws) ──────
    function test_invalid_inputs_give_zero_size_rects() {
        var bad = [0, -5, NaN, Infinity, undefined, null, "72", {}]
        for (var i = 0; i < bad.length; ++i) {
            var g = Geo.layout(bad[i], 1)
            verify(allFinite(g), "tileSize " + bad[i])
            compare(g.retry.width, 0)
            compare(g.discardHit.width, 0)
            g = Geo.layout(72, bad[i])
            verify(allFinite(g), "unit " + bad[i])
            compare(g.retry.width, 0)
        }
    }

    // ── overlayMode: which of none / busy / failed a tile shows ───────────
    function test_confirmed_photo_never_shows_an_overlay() {
        compare(Geo.overlayMode("confirmed", undefined), "none")
        compare(Geo.overlayMode("confirmed", "failed"), "none")   // a stray state field must not matter
    }

    function test_queued_failed_shows_the_failed_overlay() {
        compare(Geo.overlayMode("queued", "failed"), "failed")
    }

    function test_queued_in_flight_states_show_the_spinner() {
        var states = ["enqueued", "uploading", "retrying"]
        for (var i = 0; i < states.length; ++i)
            compare(Geo.overlayMode("queued", states[i]), "busy", states[i])
    }

    function test_queued_with_unknown_or_missing_state_falls_back_to_spinner_not_failed() {
        compare(Geo.overlayMode("queued", undefined), "busy")
        compare(Geo.overlayMode("queued", null), "busy")
        compare(Geo.overlayMode("queued", ""), "busy")
        compare(Geo.overlayMode("queued", "Failed"), "busy")   // case-sensitive, matches the queue's own states
        compare(Geo.overlayMode("queued", "bogus"), "busy")
    }

    function test_unknown_kind_shows_nothing() {
        compare(Geo.overlayMode(undefined, "failed"), "none")
        compare(Geo.overlayMode(null, "failed"), "none")
        compare(Geo.overlayMode("", "uploading"), "none")
    }

    // ── Contrast: the scrim keeps white glyphs readable over ANY photo ────
    function test_white_on_scrim_meets_aa_text_contrast_over_every_backdrop() {
        for (var g = 0; g <= 255; g += 5)
            verify(Geo.whiteContrastOverScrim(g) >= 4.5, "backdrop " + g + " -> " + Geo.whiteContrastOverScrim(g))
    }

    function test_worst_case_backdrop_is_white() {
        var worst = Geo.whiteContrastOverScrim(255)
        for (var g = 0; g < 255; g += 15)
            verify(Geo.whiteContrastOverScrim(g) >= worst - 1e-9, "backdrop " + g)
    }

    function test_contrast_check_actually_bites_a_too_weak_scrim() {
        verify(Geo.whiteContrastOverScrim(255, 0.3) < 4.5, "a 30% scrim must FAIL the check, or the check proves nothing")
    }

    function test_white_glyph_on_discard_chip_meets_non_text_contrast_over_every_backdrop() {
        for (var g = 0; g <= 255; g += 5)
            verify(Geo.whiteContrastOverChip(g) >= 3, "backdrop " + g + " -> " + Geo.whiteContrastOverChip(g))
    }

    // ── Monkey: deterministic pseudo-random sizes/scales, invariants must always hold ──
    function test_monkey_random_tile_sizes_and_scales_keep_every_invariant() {
        var seed = 12345
        function rnd() { seed = (seed * 1103515245 + 12345) % 2147483648; return seed / 2147483648 }
        for (var i = 0; i < 1000; ++i) {
            var u = 0.5 + rnd() * 4          // 0.5 .. 4.5 dp scale
            var t = rnd() * 400              // 0 .. 400 px
            var g = Geo.layout(t, u)
            verify(allFinite(g), "iteration " + i)
            verify(!overlaps(g.retry, g.discardHit), "overlap at iteration " + i + " t=" + t + " u=" + u)
            verify(inside(g.retry, t) && inside(g.discardHit, t) && inside(g.discardChip, t), "bounds at iteration " + i + " t=" + t + " u=" + u)
            verify(g.scale >= 0 && g.scale <= 1, "scale at iteration " + i)
            if (t >= 72 * u) verify(g.retry.width >= 36 * u - 1e-9 && g.discardHit.width >= 28 * u - 1e-9, "floor at iteration " + i)
        }
    }

    function test_monkey_random_kind_state_pairs_only_ever_return_a_known_mode() {
        var kinds = ["confirmed", "queued", "", undefined, null, "x"]
        var states = ["enqueued", "uploading", "retrying", "failed", "", undefined, null, "y"]
        for (var i = 0; i < kinds.length; ++i)
            for (var j = 0; j < states.length; ++j) {
                var m = Geo.overlayMode(kinds[i], states[j])
                verify(m === "none" || m === "busy" || m === "failed", kinds[i] + "/" + states[j])
                if (m === "failed") verify(kinds[i] === "queued" && states[j] === "failed")
            }
    }
}
