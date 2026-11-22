"use strict";

// Toasts above dialogs (device report 2026-11-09: every toast was drawn UNDER an open dialog).
//
// Cause: dialogs and sheets are Popups, drawn in the window Overlay (z 1000001), above the whole item tree; ToastHost
// was an ordinary item in that tree, so no z could lift it over them. The fix moves the pill into the Overlay while a
// toast shows (ToastHost._showInternal) and back out when it is gone (ToastHost._release).
// ToastHost imports Felgo's dp()/sp() and cannot load under qmltestrunner, so the REAL bodies of the two functions are cut
// out of the .qml and run here in a vm with fakes (same technique as restockDialogConfirm.test.js).
//
//   TL-1..3   show: into the Overlay, fallback without one, empty text ignored
//   TL-4      release: back to the host
//   TL-5      the late-finish race (a new toast while the last one is leaving)
//   TL-6      the Overlay appears late or goes away
//   TL-7      monkey: 3000 random operations, invariants after each
//   TS-1..6   source shape: what the functions rely on is really declared
//   TS-7      no popup in the tree can out-rank the pill
//   TL-8..9   (S5e-2) the dismiss time follows the message, per toast, and an ignored toast leaves it alone
//   TS-8..17  (S5e-2) the wrap: slides animate `rise`, y is derived, the text wraps, the measure copy cannot loop,
//             every TL.* the file calls exists, the longest message fits the line cap, the corner radius is capped
//             and the text is plain (review sweep)

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");
const { extractFunction, load } = require("./testSupport/qmlHelpers");
const LAYOUT = load("ToastLayout.js");

const QML = path.join(__dirname, "..", "..", "qml");
const FILE = "components/ToastHost.qml";
const SRC = fs.readFileSync(path.join(QML, FILE), "utf8");
const SHOW = extractFunction(FILE, "_showInternal");
const RELEASE = extractFunction(FILE, "_release");

// One host, one pill. `log` records every effect in order; `pill.parent` is a setter so each assignment is visible.
function rig(layer) {
    const log = [];
    const host = { name: "host", _layer: layer };
    let parent = host;
    const pill = { opacity: 0 };
    Object.defineProperty(pill, "parent", {
        get() { return parent; },
        set(v) { parent = v; log.push("parent=" + (v && v.name)); }
    });
    const slideDown = {
        running: false,
        stop() { log.push("slideDown.stop"); this.running = false; },
        restart() { log.push("slideDown.restart"); this.running = true; },
        // A natural finish of the slide: only if it was still running, it hides the pill like onFinished does.
        finishIfRunning() { if (this.running) { this.running = false; ctx._release(); } }
    };
    const ctx = {
        host, pill, slideDown,
        pillText: { text: "" },
        slideUp: { restart() { log.push("slideUp.restart"); } },
        dismissTimer: { interval: 5000, restart() { log.push("timer.restart"); } },
        TL: LAYOUT
    };
    vm.createContext(ctx);
    vm.runInContext(SHOW + "\n" + RELEASE, ctx);
    return { ctx, log, host, pill, show: (m) => ctx._showInternal(m), release: () => ctx._release() };
}
const OVERLAY = { name: "overlay" };

// ------------------------------------------------------------------ show / release

test("TL-1 show with an Overlay: the pill moves into it, is lit, text set, slide and timer started, in that order", () => {
    const r = rig(OVERLAY);
    r.show("Restocked +10 units");
    assert.equal(r.pill.parent, OVERLAY);
    assert.equal(r.pill.opacity, 1);
    assert.equal(r.ctx.pillText.text, "Restocked +10 units");
    assert.deepEqual(r.log, ["slideDown.stop", "parent=overlay", "slideUp.restart", "timer.restart"]);
});

test("TL-2 show without an Overlay (window not ready): the pill stays in the host and is still shown", () => {
    for (const none of [null, undefined]) {
        const r = rig(none);
        r.show("hello");
        assert.equal(r.pill.parent, r.host);
        assert.equal(r.pill.opacity, 1);
        assert.equal(r.ctx.pillText.text, "hello");
        assert.ok(r.log.includes("slideUp.restart"));
    }
});

test("TL-3 empty, missing or non-string-empty text changes nothing at all", () => {
    for (const m of ["", null, undefined, 0, false]) {
        const r = rig(OVERLAY);
        r.show(m);
        assert.deepEqual(r.log, [], "no effect for " + String(m));
        assert.equal(r.pill.parent, r.host);
        assert.equal(r.pill.opacity, 0);
    }
});

test("TL-4 release: hidden and back in the host (not left in the Overlay)", () => {
    const r = rig(OVERLAY);
    r.show("x");
    r.release();
    assert.equal(r.pill.opacity, 0);
    assert.equal(r.pill.parent, r.host);
});

test("TL-4b release when nothing is showing is harmless and idempotent", () => {
    const r = rig(OVERLAY);
    r.release(); r.release();
    assert.equal(r.pill.opacity, 0);
    assert.equal(r.pill.parent, r.host);
});

// ------------------------------------------------------------------ the race

test("TL-5 a toast arriving while the last one slides away is NOT hidden when that slide finishes", () => {
    const r = rig(OVERLAY);
    r.show("first");
    r.ctx.slideDown.restart();            // the dismiss timer fired: the first toast is leaving
    r.show("second");                     // new toast arrives mid-slide
    r.ctx.slideDown.finishIfRunning();    // the old slide would finish now
    assert.equal(r.pill.opacity, 1, "second toast still lit");
    assert.equal(r.pill.parent, OVERLAY, "and still above dialogs");
    assert.equal(r.ctx.pillText.text, "second");
});

test("TL-5b without a new toast the slide finish does release the pill", () => {
    const r = rig(OVERLAY);
    r.show("only");
    r.ctx.slideDown.restart();
    r.ctx.slideDown.finishIfRunning();
    assert.equal(r.pill.opacity, 0);
    assert.equal(r.pill.parent, r.host);
});

// ------------------------------------------------------------------ the Overlay comes and goes

test("TL-6 the Overlay appears after the first toast and goes away again: each show uses what exists at that moment", () => {
    const r = rig(null);
    r.show("early");
    assert.equal(r.pill.parent, r.host);
    r.host._layer = OVERLAY;
    r.show("later");
    assert.equal(r.pill.parent, OVERLAY);
    r.host._layer = null;                 // window torn down
    r.show("after");
    assert.equal(r.pill.parent, r.host, "never left parentless");
});

test("TL-6b two toasts in a row keep the pill in the Overlay and restart the timer each time", () => {
    const r = rig(OVERLAY);
    r.show("a"); r.show("b");
    assert.equal(r.pill.parent, OVERLAY);
    assert.equal(r.log.filter((l) => l === "timer.restart").length, 2);
    assert.equal(r.ctx.pillText.text, "b");
});

// ------------------------------------------------------------------ dismiss time (S5e-2)

test("TL-8 the dismiss time is set for THIS message before the timer starts, and is not left over from a longer one", () => {
    const r = rig(OVERLAY);
    r.show("x".repeat(134));
    assert.equal(r.ctx.dismissTimer.interval, 10000);
    r.show("Saved");
    assert.equal(r.ctx.dismissTimer.interval, 5000, "a short toast after a long one is short again");
    r.show("x".repeat(80));
    assert.equal(r.ctx.dismissTimer.interval, 6800);
});

test("TL-9 an ignored (empty) toast leaves the dismiss time and the timer alone", () => {
    const r = rig(OVERLAY);
    r.show("x".repeat(100));
    const before = r.ctx.dismissTimer.interval;
    r.log.length = 0;
    r.show("");
    assert.equal(r.ctx.dismissTimer.interval, before);
    assert.deepEqual(r.log, []);
});

// ------------------------------------------------------------------ monkey

test("TL-7 monkey: 3000 random operations never leave the pill parentless, wrongly parented or unlit", () => {
    let seed = 20261109;
    const rnd = () => { seed = (seed * 1664525 + 1013904223) >>> 0; return seed / 4294967296; };
    const r = rig(OVERLAY);
    for (let i = 0; i < 3000; i++) {
        const op = Math.floor(rnd() * 7);
        if (op === 0) r.show("m" + i);
        else if (op === 1) r.show("");
        else if (op === 2) r.release();
        else if (op === 3) r.host._layer = rnd() < 0.5 ? null : OVERLAY;
        else if (op === 4) r.ctx.slideDown.restart();
        else if (op === 5) r.ctx.slideDown.finishIfRunning();
        else r.show("n" + i);
        assert.ok(r.pill.parent === r.host || r.pill.parent === OVERLAY, "parent is host or Overlay, step " + i);
        if (op === 0 || op === 6) {
            assert.equal(r.ctx.dismissTimer.interval, LAYOUT.dismissMs(op === 0 ? "m" + i : "n" + i), "its own dismiss time, step " + i);
            assert.equal(r.pill.opacity, 1, "a shown toast is lit, step " + i);
            assert.equal(r.pill.parent, r.host._layer || r.host, "and drawn in the right layer, step " + i);
        }
        if (op === 2) { assert.equal(r.pill.opacity, 0); assert.equal(r.pill.parent, r.host); }
    }
});

// ------------------------------------------------------------------ source shape

test("TS-1 ToastHost imports Controls under the alias the file uses", () => {
    assert.match(SRC, /^import QtQuick\.Controls as QQC$/m);
});

test("TS-2 the layer is the window Overlay, read on the host (which never moves)", () => {
    assert.match(SRC, /^    readonly property Item _layer: QQC\.Overlay\.overlay$/m);
});

test("TS-3 the slide finishing calls _release, and nothing else hides the pill", () => {
    assert.match(SRC, /id: slideDown[\s\S]*?onFinished: host\._release\(\)/);
    assert.equal((SRC.match(/pill\.opacity = 0/g) || []).length, 1, "one place sets opacity 0");
});

test("TS-4 the pill is centred by a binding, not an anchor (an anchor to parent breaks on reparent)", () => {
    const pill = SRC.substring(SRC.indexOf("id: pill"), SRC.indexOf("Behavior on opacity")).replace(/\/\/.*$/gm, "");
    assert.match(pill, /^\s+x: parent \? \(parent\.width - width\) \/ 2 : 0$/m);
    assert.doesNotMatch(pill, /anchors\./);
});

test("TS-5 the pill outranks popups: z is a number above every popup z in the tree", () => {
    const z = Number((SRC.match(/id: pill\b[\s\S]*?\n\s+z: (\d+)/) || [])[1]);
    assert.ok(z >= 1000, "pill z is set (" + z + ")");
});

test("TS-6 one ToastHost in Main, driven only by the Toast singleton", () => {
    const main = fs.readFileSync(path.join(QML, "Main.qml"), "utf8");
    assert.equal((main.match(/^\s*ToastHost \{/gm) || []).length, 1);
    assert.match(SRC, /Connections \{\s*target: Toast\s*function onShowRequested\(msg\) \{ host\._showInternal\(msg\) \}/);
});

function walk(dir, out) {
    for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
        const p = path.join(dir, e.name);
        if (e.isDirectory()) walk(p, out); else if (e.name.endsWith(".qml")) out.push(p);
    }
    return out;
}

test("TS-7 no popup in the tree sets its own z at the root, so none can out-rank the pill", () => {
    const pillZ = Number((SRC.match(/id: pill\b[\s\S]*?\n\s+z: (\d+)/) || [])[1]);
    const popupRoot = /^(QQC\.Dialog|QQC\.Popup|Dialog|Popup|BottomSheet|ConfirmDialog|AlertDialog) \{/m;
    let seen = 0;
    for (const f of walk(QML, [])) {
        const src = fs.readFileSync(f, "utf8");
        if (!popupRoot.test(src)) continue;
        seen++;
        const m = src.match(/^    z: (-?\d+(\.\d+)?)\s*$/m);
        if (m) assert.ok(Number(m[1]) < pillZ, path.basename(f) + " root z " + m[1] + " must stay below the pill " + pillZ);
    }
    assert.ok(seen >= 20, "the scan found the popup files (" + seen + ")");
});

// ------------------------------------------------------------------ the wrap (S5e-2, KNOWN-ISSUES 26)

const CODE = SRC.replace(/\/\/.*$/gm, "");
const block = (from, to) => CODE.substring(CODE.indexOf(from), CODE.indexOf(to, CODE.indexOf(from)));

test("TS-8 the slides animate `rise` (no binding on it), never y; up goes to 1, down to 0 and releases", () => {
    assert.doesNotMatch(CODE, /property:\s*"y"/, "nothing animates y any more");
    assert.match(block("id: slideUp", "NumberAnimation {\n            id: slideDown"), /property: "rise"\s+to: 1\b/);
    assert.match(block("id: slideDown", "Text {"), /property: "rise"\s+to: 0\b[\s\S]*onFinished: host\._release\(\)/);
    assert.match(CODE, /property real rise: 0\b/, "rise is a plain property with a constant start");
});

test("TS-9 y is derived from rise and the pill's own height by TL.pillY, and nothing else writes y", () => {
    assert.match(CODE, /^\s+y: parent \? TL\.pillY\(parent\.height, rise, height, dp\(Constants\.tabbarClearance\), _minHeight\) : 600$/m);
    assert.doesNotMatch(CODE, /\b(pill\.)?y\s*=[^=]/, "no imperative y write");
});

test("TS-10 width and height come from TL: no fixed 40 dp height is left, and the old one-line height is the floor", () => {
    assert.match(CODE, /^\s+width: TL\.pillWidth\(measure\.implicitWidth, parent \? parent\.width - dp\(40\) : dp\(360\), dp\(32\)\)$/m);
    assert.match(CODE, /^\s+height: TL\.pillHeight\(pillText\.contentHeight, _minHeight, dp\(16\)\)$/m);
    assert.match(CODE, /readonly property real _minHeight: dp\(40\)/);
    assert.doesNotMatch(CODE, /^\s+height: dp\(40\)/m);
});

test("TS-11 the text wraps at the pill's inner width, at most TL.MAX_LINES, then an ellipsis, centred", () => {
    const t = block("id: pillText", "\n        }\n    }");
    assert.match(t, /width: TL\.textWidth\(pill\.width, dp\(32\)\)/);
    assert.match(t, /wrapMode: Text\.Wrap\b/, "Text.Wrap, not WordWrap: one long unbroken name must still break");
    assert.match(t, /maximumLineCount: TL\.MAX_LINES/);
    assert.match(t, /elide: Text\.ElideRight/);
    assert.match(t, /horizontalAlignment: Text\.AlignHCenter/);
    assert.match(t, /anchors\.centerIn: parent/);
});

test("TS-12 no binding loop: the measure copy is hidden and unwrapped, the pill width reads only it, the text never reads its own size", () => {
    const m = block("id: measure", "Text {\n            id: pillText");
    assert.match(m, /visible: false/);
    assert.match(m, /text: pillText\.text/);
    assert.match(m, /font: pillText\.font/);
    assert.doesNotMatch(m, /wrapMode|width:|height:|anchors|elide|maximumLineCount/, "the copy must stay one free line");
    const pill = block("id: pill", "Behavior on opacity");
    assert.doesNotMatch(pill, /pillText\.(implicit|content)Width/, "pill width must not read the wrapped text's width");
    const t = block("id: pillText", "\n        }\n    }");
    assert.doesNotMatch(t, /implicit|content(Width|Height)|pill\.height/, "the text must not read its own size or the pill height");
});

test("TS-13 _showInternal sets the dismiss time from the message, then restarts the timer, and only there", () => {
    assert.match(SHOW, /dismissTimer\.interval = TL\.dismissMs\(msg\);?\s*\n\s*dismissTimer\.restart\(\)/);
    assert.equal((CODE.match(/dismissTimer\.interval\s*=/g) || []).length, 1);
});

test("TS-14 every TL.* the file calls exists in ToastLayout.js, and the import is the one tested", () => {
    assert.match(SRC, /^import "\.\.\/helper\/ToastLayout\.js" as TL$/m);
    const used = new Set([...CODE.matchAll(/\bTL\.(\w+)/g)].map((m) => m[1]));
    assert.ok(used.size >= 7, "pillY pillWidth pillHeight pillRadius textWidth dismissMs MAX_LINES: " + [...used]);
    for (const name of used) assert.ok(name in LAYOUT, "TL." + name + " is not defined in ToastLayout.js");
});

test("TS-15 the longest toast in the app wraps inside the line cap on a 360 dp phone at normal and 1.3x font (glyph width estimated at 0.52 em, the sums are the real ones)", () => {
    // 134 chars is the longest literal today (OrdersStore import message). Average glyph = 0.52 em at 13 sp.
    for (const scale of [1, 1.3]) {
        const glyph = 13 * 0.52 * scale;
        const textW = LAYOUT.textWidth(LAYOUT.pillWidth(134 * glyph, 360 - 40, 32), 32);
        const lines = Math.ceil((134 * glyph) / textW);
        assert.ok(lines <= LAYOUT.MAX_LINES, "lines " + lines + " at scale " + scale);
    }
});

test("TS-16 the corner radius is capped at half the one-line height, never the bare 999 token (a tall pill would cut its text corners)", () => {
    assert.match(CODE, /^\s+radius: TL\.pillRadius\(dp\(Constants\.radiusPill\), _minHeight\)$/m);
    assert.doesNotMatch(CODE, /radius: dp\(Constants\.radiusPill\)/, "the bare token is the old, clipping radius");
    assert.equal((CODE.match(/\bradius:/g) || []).length, 1, "one radius in the file");
});

test("TS-17 both texts are PLAIN: a server or proxy error body such as <html>... must show as text, and the measure copy must agree with the pill", () => {
    const m = block("id: measure", "Text {\n            id: pillText");
    const t = block("id: pillText", "\n        }\n    }");
    assert.match(m, /textFormat: Text\.PlainText/);
    assert.match(t, /textFormat: Text\.PlainText/);
    assert.equal((CODE.match(/textFormat:/g) || []).length, 2, "exactly the two texts, same format");
});
