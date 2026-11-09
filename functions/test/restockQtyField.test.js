"use strict";

// Review D-C (PR #188 sweep): RestockFlow.qtyFromField. The Add-quantity SpinBox is editable, and typed text
// only becomes its `value` on Enter or focus loss, so Confirm must read the text itself.
//   QF-1..4    the text wins over a stale committed value
//   QF-5..9    what is refused (empty, junk, fraction, out of range, parser throws), never clamped
//   QF-10..11  when the text cannot be read, the committed value is used (and checked the same way)
//   QF-12..13  odd inputs; the REAL dialog hands the field to this function
//   QF-14      a locale-aware parser is honoured (the SpinBox's own, not Number())

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { load, plain } = require("./testSupport/qmlHelpers");

const RF = load("RestockFlow.js");

// A fake of QtQuick.Controls SpinBox, as far as the helper looks at it. The default Qt parser is
// Number.fromLocaleString(locale, text), which THROWS on text that is not a number (modelled strictly:
// surrounding whitespace is not tolerated, so the trim in the helper is what makes QF-4 pass).
function spin(over) {
    const f = {
        value: 10, from: 1, to: 9999, locale: "en_IN",
        contentItem: { text: "10" },
        valueFromText(text) { const n = Number(text); if (text !== String(text).trim() || text === "" || isNaN(n)) throw new Error("not a number: " + text); return n; }
    };
    return Object.assign(f, over || {});
}
const qty = (f) => plain(RF.qtyFromField(f));

test("QF-1 typed text that was never committed wins over the stale value (the bug)", () => {
    assert.deepEqual(qty(spin({ value: 10, contentItem: { text: "25" } })), { ok: true, qty: 25 });
});

test("QF-2 text equal to the value is that value", () => {
    assert.deepEqual(qty(spin()), { ok: true, qty: 10 });
});

test("QF-3 the limits themselves are accepted", () => {
    assert.deepEqual(qty(spin({ contentItem: { text: "1" } })), { ok: true, qty: 1 });
    assert.deepEqual(qty(spin({ contentItem: { text: "9999" } })), { ok: true, qty: 9999 });
});

test("QF-4 surrounding whitespace is ignored", () => {
    assert.deepEqual(qty(spin({ contentItem: { text: "  42 \n" } })), { ok: true, qty: 42 });
});

test("QF-5 empty or blank text is refused, not read as the old value", () => {
    for (const t of ["", "   "]) {
        const r = qty(spin({ contentItem: { text: t } }));
        assert.equal(r.ok, false, JSON.stringify(t));
        assert.equal(r.message, "Enter a whole quantity from 1 to 9999");
    }
});

test("QF-6 junk is refused", () => {
    for (const t of ["abc", "12abc", "1e999", "--1", "1.2.3", "NaN", "Infinity", "-Infinity"])
        assert.equal(qty(spin({ contentItem: { text: t } })).ok, false, t);
});

test("QF-7 a fraction is refused, never rounded", () => {
    for (const t of ["2.5", "0.1", "9998.5"]) assert.equal(qty(spin({ contentItem: { text: t } })).ok, false, t);
});

test("QF-8 out of range is refused, never clamped (100000 is not silently booked as 9999)", () => {
    for (const t of ["0", "-5", "10000", "100000"]) assert.equal(qty(spin({ contentItem: { text: t } })).ok, false, t);
});

test("QF-9 a parser that throws is a refusal, not an exception", () => {
    const r = qty(spin({ valueFromText() { throw new Error("boom"); } }));
    assert.equal(r.ok, false);
});

test("QF-10 no readable text: the committed value is used", () => {
    assert.deepEqual(qty(spin({ contentItem: undefined, value: 7 })), { ok: true, qty: 7 });
    assert.deepEqual(qty(spin({ contentItem: {}, value: 7 })), { ok: true, qty: 7 });
    assert.deepEqual(qty(spin({ valueFromText: undefined, value: 7 })), { ok: true, qty: 7 });
});

test("QF-11 the committed value is checked the same way", () => {
    for (const v of [0, -1, 10000, 2.5, NaN, Infinity, undefined, "7"])
        assert.equal(qty(spin({ contentItem: undefined, value: v })).ok, false, String(v));
});

test("QF-12 the message names the field's own limits", () => {
    const r = qty(spin({ from: 5, to: 50, contentItem: { text: "1" } }));
    assert.equal(r.message, "Enter a whole quantity from 5 to 50");
});

test("QF-13 no field at all, or a non-object, is a refusal", () => {
    for (const f of [undefined, null, 5, "x"]) assert.equal(qty(f).ok, false, String(f));
});

test("QF-14 the SpinBox's own, locale-aware parser is the one asked", () => {
    const seen = [];
    const f = spin({ locale: "hi_IN", contentItem: { text: "१२" }, valueFromText(text, locale) { seen.push([text, locale]); return 12; } });
    assert.deepEqual(qty(f), { ok: true, qty: 12 });
    assert.deepEqual(seen, [["१२", "hi_IN"]]);
});

test("QF-15 the dialog reads the field through qtyFromField and no longer through qtyField.value alone", () => {
    const src = fs.readFileSync(path.join(__dirname, "..", "..", "qml", "pages", "RestockDialog.qml"), "utf8");
    assert.ok(src.includes("RestockFlow.qtyFromField(qtyField)"));
    assert.ok(!/var qty = qtyField\.value/.test(src), "the stale read must not come back");
});
