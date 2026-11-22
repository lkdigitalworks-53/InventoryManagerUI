"use strict";
// ToastLayout (qml/helper/ToastLayout.js). Cases TLY-01..14, plan:
// docs/superpowers/plans/2026-11-22-product-picker-v2-s5e2-toasthost-wrap.md. The QML twin
// tests/tst_ToastLayout.qml is derived from these bodies (PAIR-01 in pickerDormancy.test.js).
const test = require("node:test");
const { load } = require("./testSupport/qmlHelpers");
const { eq, ok, noThrow } = require("./testSupport/pickerSupport");
const TL = load("ToastLayout.js");

// QML-PRELUDE-BEGIN
function rng(seed) {
    var s = seed >>> 0;
    return function () { s = (s * 1664525 + 1013904223) >>> 0; return s / 4294967296; };
}
function junkPool() {
    return [undefined, null, NaN, Infinity, -Infinity, -1, 0, 0.5, 1, 2.9, 7, "", " ", "  x  ", "3",
            true, false, {}, [], [1], function () { return 1; }];
}
function rep(n) { var s = ""; for (var i = 0; i < n; ++i) s += "x"; return s; }
// QML-PRELUDE-END

test("TLY-01 the constants: 6 lines, 5 to 10 seconds, 2 s plus 60 ms a character", () => {
    eq(TL.MAX_LINES, 6);
    eq(TL.DISMISS_MIN_MS, 5000);
    eq(TL.DISMISS_MAX_MS, 10000);
    eq(TL.DISMISS_BASE_MS, 2000);
    eq(TL.DISMISS_PER_CHAR_MS, 60);
});

test("TLY-02 a short message gets the pill it needs: its one-line width, rounded up, 1 px slack, plus the padding", () => {
    eq(TL.pillWidth(100, 320, 32), 133);
    eq(TL.pillWidth(100.2, 320, 32), 134);
    eq(TL.pillWidth(0, 320, 32), 33);
});

test("TLY-03 a long message gets the widest pill allowed: the layer minus its margins, no wider", () => {
    eq(TL.pillWidth(900, 320, 32), 320);
    eq(TL.pillWidth(287, 320, 32), 320);
    eq(TL.pillWidth(286, 320, 32), 319);
});

test("TLY-04 junk in any argument of the sums never gives NaN, a negative or an infinite size", () => {
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
});

test("TLY-05 the wrapped text is never narrower than its own single line (no stray wrap from a rounding error)", () => {
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
});

test("TLY-06 at the cap the text gets the cap minus the padding; a layer narrower than the padding gives 0, not negative", () => {
    eq(TL.textWidth(320, 32), 288);
    eq(TL.textWidth(32, 32), 0);
    eq(TL.textWidth(20, 32), 0);
    eq(TL.textWidth(0, 32), 0);
    eq(TL.pillWidth(500, 10, 32), 10);
    eq(TL.textWidth(TL.pillWidth(500, 10, 32), 32), 0);
});

test("TLY-07 height: never under the old 40, otherwise the text plus the padding", () => {
    eq(TL.pillHeight(0, 40, 16), 40);
    eq(TL.pillHeight(17, 40, 16), 40);
    eq(TL.pillHeight(24, 40, 16), 40);
    eq(TL.pillHeight(25, 40, 16), 41);
    eq(TL.pillHeight(68, 40, 16), 84);
    eq(TL.pillHeight(6 * 17, 40, 16), 118);
});

test("TLY-08 dismiss time: 5 s for a short line, longer with the text, 10 s at most, whole milliseconds", () => {
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
});

test("TLY-09 a message that is not text counts as empty (5 s), it does not throw", () => {
    var pool = junkPool();
    for (var i = 0; i < pool.length; ++i) {
        if (typeof pool[i] === "string") continue;
        eq(TL.dismissMs(pool[i]), 5000);
    }
    noThrow(function () { TL.dismissMs(); });
});

test("TLY-10 resting place of a one-line pill is exactly where it always was (layer height minus 110) (regression)", () => {
    eq(TL.pillY(800, 1, 40, 110, 40), 690);
    eq(TL.pillY(600, 1, 40, 110, 40), 490);
    eq(TL.pillY(800, 0, 40, 110, 40), 800);
});

test("TLY-11 a taller pill keeps its BOTTOM edge in place and grows upward, at every height", () => {
    for (var h = 40; h <= 200; h += 7) {
        var y = TL.pillY(800, 1, h, 110, 40);
        eq(y + h, 730);
        ok(y <= 690, "never lower than the one-line pill at " + h);
    }
});

test("TLY-12 the pill follows a layer that changes height while it shows (keyboard, rotation), at rise 1 and mid-slide", () => {
    var rises = [0, 0.25, 0.5, 1];
    for (var i = 0; i < rises.length; ++i) {
        var a = TL.pillY(800, rises[i], 84, 110, 40);
        var b = TL.pillY(500, rises[i], 84, 110, 40);
        eq(a - b, 300);
    }
});

test("TLY-13 rise is clamped to 0..1: a slide that overshoots or is junk never puts the pill off its path", () => {
    eq(TL.pillY(800, -5, 40, 110, 40), 800);
    eq(TL.pillY(800, 7, 40, 110, 40), 690);
    eq(TL.pillY(800, NaN, 40, 110, 40), 800);
    eq(TL.pillY(800, undefined, 40, 110, 40), 800);
    eq(TL.pillY(800, "1", 40, 110, 40), 800);
});

test("TLY-14 monkey: 6000 random phones, fonts and messages keep every invariant", () => {
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
});
