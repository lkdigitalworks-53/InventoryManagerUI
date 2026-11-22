import QtQuick
import QtTest
import "../qml/helper/ToastLayout.js" as TL
import "pickerFixtures.js" as FX

// DERIVED FILE, do not edit. Rebuilt from functions/test/toastLayout.test.js by
// functions/test/testSupport/pickerTwin.js (node functions/test/testSupport/pickerTwin.js --write);
// functions/test/pickerDormancy.test.js (PAIR-01) fails if this file differs from that output.
// NOT RUN IN THIS SANDBOX (no Qt toolchain): CI's qmltestrunner is the signal. The same bodies run in Node.
// Plan: docs/superpowers/test-plans/2026-11-03-product-picker-v2-test-plan.md
TestCase {
    name: "ToastLayout"

    function eq(actual, expected) { compare(FX.canon(actual), FX.canon(expected)) }
    function ok(cond, msg) { verify(cond, msg) }
    function noThrow(fn) { try { fn() } catch (e) { fail("threw: " + e) } }

    function rng(seed) {
        var s = seed >>> 0;
        return function () { s = (s * 1664525 + 1013904223) >>> 0; return s / 4294967296; };
    }
    function junkPool() {
        return [undefined, null, NaN, Infinity, -Infinity, -1, 0, 0.5, 1, 2.9, 7, "", " ", "  x  ", "3",
                true, false, {}, [], [1], function () { return 1; }];
    }
    function rep(n) { var s = ""; for (var i = 0; i < n; ++i) s += "x"; return s; }

    function test_TLY_01_the_constants_6_lines_5_to_10_seconds_2_s_plus_60_ms_a_chara() {
        eq(TL.MAX_LINES, 6);
        eq(TL.DISMISS_MIN_MS, 5000);
        eq(TL.DISMISS_MAX_MS, 10000);
        eq(TL.DISMISS_BASE_MS, 2000);
        eq(TL.DISMISS_PER_CHAR_MS, 60);
    }

    function test_TLY_02_a_short_message_gets_the_pill_it_needs_its_one_line_width_ro() {
        eq(TL.pillWidth(100, 320, 32), 133);
        eq(TL.pillWidth(100.2, 320, 32), 134);
        eq(TL.pillWidth(0, 320, 32), 33);
    }

    function test_TLY_03_a_long_message_gets_the_widest_pill_allowed_the_layer_minus_() {
        eq(TL.pillWidth(900, 320, 32), 320);
        eq(TL.pillWidth(287, 320, 32), 320);
        eq(TL.pillWidth(286, 320, 32), 319);
    }

    function test_TLY_04_junk_in_any_argument_of_the_sums_never_gives_nan_a_negative_() {
        var pool = junkPool();
        for (var a = 0; a < pool.length; ++a) {
            for (var b = 0; b < pool.length; ++b) {
                var w = TL.pillWidth(pool[a], pool[b], 32);
                ok(isFinite(w) && w >= 0, "pillWidth " + a + "," + b);
                ok(w <= (typeof pool[b] === "number" && isFinite(pool[b]) && pool[b] > 0 ? pool[b] : 0), "capped " + a + "," + b);
                var t = TL.textWidth(pool[a], pool[b]);
                ok(isFinite(t) && t >= 0, "textWidth " + a + "," + b);
                var h = TL.pillHeight(pool[a], pool[b], 16);
                ok(isFinite(h) && h >= 0, "pillHeight " + a + "," + b);
                var y = TL.pillY(pool[a], pool[b], 40, 110, 40);
                ok(isFinite(y), "pillY " + a + "," + b);
            }
            var d = TL.dismissMs(pool[a]);
            ok(d >= 5000 && d <= 10000, "dismissMs " + a);
        }
    }

    function test_TLY_05_the_wrapped_text_is_never_narrower_than_its_own_single_line_() {
        var r = rng(20261122);
        for (var i = 0; i < 4000; ++i) {
            var natural = r() * 280;
            var pad = (r() < 0.5) ? 32 : 32 * (1 + r() * 2.5);
            var layer = 600;
            var pw = TL.pillWidth(natural, layer, pad);
            var tw = TL.textWidth(pw, pad);
            ok(tw >= natural, "text " + tw + " fits natural " + natural + " pad " + pad);
            ok(tw < natural + 2.0000001, "and is only ~1 px roomier, not a different layout " + tw + " vs " + natural);
        }
    }

    function test_TLY_06_at_the_cap_the_text_gets_the_cap_minus_the_padding_a_layer_n() {
        eq(TL.textWidth(320, 32), 288);
        eq(TL.textWidth(32, 32), 0);
        eq(TL.textWidth(20, 32), 0);
        eq(TL.textWidth(0, 32), 0);
        eq(TL.pillWidth(500, 10, 32), 10);
        eq(TL.textWidth(TL.pillWidth(500, 10, 32), 32), 0);
    }

    function test_TLY_07_height_never_under_the_old_40_otherwise_the_text_plus_the_pa() {
        eq(TL.pillHeight(0, 40, 16), 40);
        eq(TL.pillHeight(17, 40, 16), 40);
        eq(TL.pillHeight(24, 40, 16), 40);
        eq(TL.pillHeight(25, 40, 16), 41);
        eq(TL.pillHeight(68, 40, 16), 84);
        eq(TL.pillHeight(6 * 17, 40, 16), 118);
    }

    function test_TLY_08_dismiss_time_5_s_for_a_short_line_longer_with_the_text_10_s_() {
        eq(TL.dismissMs(""), 5000);
        eq(TL.dismissMs(rep(44)), 5000);
        eq(TL.dismissMs(rep(50)), 5000);
        eq(TL.dismissMs(rep(51)), 5060);
        eq(TL.dismissMs(rep(80)), 6800);
        eq(TL.dismissMs(rep(133)), 9980);
        eq(TL.dismissMs(rep(134)), 10000);
        eq(TL.dismissMs(rep(5000)), 10000);
        var last = 0;
        for (var n = 0; n <= 300; ++n) {
            var ms = TL.dismissMs(rep(n));
            ok(ms >= last, "never shorter for a longer message at " + n);
            ok(ms === Math.floor(ms), "whole ms at " + n);
            last = ms;
        }
    }

    function test_TLY_09_a_message_that_is_not_text_counts_as_empty_5_s_it_does_not_t() {
        var pool = junkPool();
        for (var i = 0; i < pool.length; ++i) {
            if (typeof pool[i] === "string") continue;
            eq(TL.dismissMs(pool[i]), 5000);
        }
        noThrow(function () { TL.dismissMs(); });
    }

    function test_TLY_10_resting_place_of_a_one_line_pill_is_exactly_where_it_always_() {
        eq(TL.pillY(800, 1, 40, 110, 40), 690);
        eq(TL.pillY(600, 1, 40, 110, 40), 490);
        eq(TL.pillY(800, 0, 40, 110, 40), 800);
    }

    function test_TLY_11_a_taller_pill_keeps_its_bottom_edge_in_place_and_grows_upwar() {
        for (var h = 40; h <= 200; h += 7) {
            var y = TL.pillY(800, 1, h, 110, 40);
            eq(y + h, 730);
            ok(y <= 690, "never lower than the one-line pill at " + h);
        }
    }

    function test_TLY_12_the_pill_follows_a_layer_that_changes_height_while_it_shows_() {
        var rises = [0, 0.25, 0.5, 1];
        for (var i = 0; i < rises.length; ++i) {
            var a = TL.pillY(800, rises[i], 84, 110, 40);
            var b = TL.pillY(500, rises[i], 84, 110, 40);
            eq(a - b, 300);
        }
    }

    function test_TLY_13_rise_is_clamped_to_0_1_a_slide_that_overshoots_or_is_junk_ne() {
        eq(TL.pillY(800, -5, 40, 110, 40), 800);
        eq(TL.pillY(800, 7, 40, 110, 40), 690);
        eq(TL.pillY(800, NaN, 40, 110, 40), 800);
        eq(TL.pillY(800, undefined, 40, 110, 40), 800);
        eq(TL.pillY(800, "1", 40, 110, 40), 800);
    }

    function test_TLY_14_monkey_6000_random_phones_fonts_and_messages_keep_every_inva() {
        var r = rng(1122);
        for (var i = 0; i < 6000; ++i) {
            var dpr = 0.75 + r() * 3.25;
            var layerW = 200 * dpr + r() * 200 * dpr;
            var layerH = 400 * dpr + r() * 500 * dpr;
            var natural = r() < 0.2 ? r() * 4000 : r() * 300 * dpr;
            var contentH = r() * 8 * 20 * dpr;
            var pad = 32 * dpr;
            var maxW = layerW - 40 * dpr;
            var pw = TL.pillWidth(natural, maxW, pad);
            ok(pw >= 0 && pw <= maxW, "width in range " + i);
            var tw = TL.textWidth(pw, pad);
            ok(tw >= 0 && tw <= pw, "text width in range " + i);
            if (natural + 1 + pad < maxW - 1) ok(tw >= natural, "no stray wrap " + i);
            var ph = TL.pillHeight(contentH, 40 * dpr, 16 * dpr);
            ok(ph >= 40 * dpr, "height floor " + i);
            var rise = r();
            var y = TL.pillY(layerH, rise, ph, 110 * dpr, 40 * dpr);
            var top = TL.pillY(layerH, 1, ph, 110 * dpr, 40 * dpr);
            ok(y <= layerH && y >= top - 1e-9, "y between parked and resting " + i);
            ok(Math.abs(top + ph - (layerH - 70 * dpr)) < 1e-6, "bottom edge fixed " + i);
            var ms = TL.dismissMs(rep(Math.floor(r() * 400)));
            ok(ms >= 5000 && ms <= 10000, "dismiss in range " + i);
        }
    }
}
