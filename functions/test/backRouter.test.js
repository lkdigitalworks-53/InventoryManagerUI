"use strict";
// BackRouter (qml/helper/BackRouter.js). Cases BR-01..11, plan:
// docs/superpowers/plans/2026-11-20-product-picker-v2-s5c-touch-back-toggle.md. The QML twin
// tests/tst_BackRouter.qml is derived from these bodies (PAIR-01 in pickerDormancy.test.js).
const test = require("node:test");
const { load } = require("./testSupport/qmlHelpers");
const { FX, eq, ok, noThrow } = require("./testSupport/pickerSupport");
const BR = load("BackRouter.js");
// QML-PRELUDE-BEGIN
// A dialog double that records what the router did to it.
function dlg(opened, extra) {
    var d = { opened: opened, closed: 0, close: function() { d.closed += 1 } };
    var keys = extra ? Object.keys(extra) : [];
    for (var i = 0; i < keys.length; ++i) d[keys[i]] = extra[keys[i]];
    return d;
}
// QML-PRELUDE-END

test("BR-01 no dialog, an empty list or junk: nothing open, the caller carries on", () => {
    eq(BR.route([]), "none");
    eq(BR.route(undefined), "none");
    eq(BR.route(null), "none");
    eq(BR.route("x"), "none");
    eq(BR.route([null, undefined, 0]), "none");
});
test("BR-02 closed dialogs are skipped and never touched", () => {
    const a = dlg(false), b = dlg(false, { busy: true });
    eq(BR.route([a, b]), "none");
    eq(a.closed + b.closed, 0);
});
test("BR-03 the first open dialog is closed, exactly as before", () => {
    const a = dlg(false), b = dlg(true), c = dlg(true);
    eq(BR.route([a, b, c]), "closed");
    eq([a.closed, b.closed, c.closed], [0, 1, 0]);
});
test("BR-04 a busy dialog swallows Back: it stays open and nothing behind it reacts", () => {
    const a = dlg(true, { busy: true }), b = dlg(true);
    eq(BR.route([a, b]), "swallowed");
    eq(a.closed + b.closed, 0);
});
test("BR-05 a dialog that consumes Back stays open and the press stops there", () => {
    let asked = 0;
    const a = dlg(true, { consumeBack: function() { asked += 1; return true } }), b = dlg(true);
    eq(BR.route([a, b]), "consumed");
    eq(asked, 1);
    eq(a.closed + b.closed, 0);
});
test("BR-06 a dialog that does not consume Back is closed", () => {
    const a = dlg(true, { consumeBack: function() { return false } });
    eq(BR.route([a]), "closed");
    eq(a.closed, 1);
});
test("BR-07 only exactly true counts as consumed", () => {
    const answers = [undefined, null, 0, 1, "true", {}, []];
    for (let i = 0; i < answers.length; ++i) {
        const a = dlg(true, { consumeBack: function() { return answers[i] } });
        eq(BR.route([a]), "closed");
        eq(a.closed, 1);
    }
});
test("BR-08 a consumeBack that throws is a broken hook: the dialog closes as before", () => {
    const a = dlg(true, { consumeBack: function() { throw new Error("boom") } });
    eq(BR.route([a]), "closed");
    eq(a.closed, 1);
});
test("BR-09 consumeBack is optional and ignored when it is not a function", () => {
    const a = dlg(true, { consumeBack: "yes" });
    eq(BR.route([a]), "closed");
    eq(a.closed, 1);
});
test("BR-10 a busy dialog is not asked: busy wins over consumeBack", () => {
    let asked = 0;
    const a = dlg(true, { busy: true, consumeBack: function() { asked += 1; return true } });
    eq(BR.route([a]), "swallowed");
    eq(asked, 0);
});
test("BR-11 the dialog under a consuming one is not touched, and a later press reaches it once the first stops consuming", () => {
    let up = true;
    const under = dlg(true), top = dlg(true, { consumeBack: function() { return up } });
    eq(BR.route([top, under]), "consumed");
    up = false;
    eq(BR.route([top, under]), "closed");
    eq([top.closed, under.closed], [1, 0]);
});
