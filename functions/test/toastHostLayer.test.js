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

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");
const { extractFunction } = require("./testSupport/qmlHelpers");

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
        dismissTimer: { restart() { log.push("timer.restart"); } }
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
    const z = Number((SRC.match(/id: pill\s*\n[^\n]*\n\s+z: (\d+)/) || [])[1]);
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
    const pillZ = Number((SRC.match(/id: pill\s*\n[^\n]*\n\s+z: (\d+)/) || [])[1]);
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
