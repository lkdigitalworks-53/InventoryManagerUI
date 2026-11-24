"use strict";

// Atomic-ops NO3a: qml/helper/OrderFlow.js (texts, key, classify, one refusal text per planner reason). tests/tst_OrderFlow.qml
// carries the same rows for CI's qmltestrunner. Design: docs/superpowers/specs/2026-11-23-no3a-create-order-wire-design.md.

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { load, plain, HELPER_DIR } = require("./testSupport/qmlHelpers");

const OF = load("OrderFlow.js");
const OP = load("OrderPlan.js");
const Keys = load("OperationKeys.js");
const RF = load("RestockFlow.js");

test("F-1 newKey is a valid create key, unique per tap, and not another operation's key", () => {
    const a = OF.newKey(1781000000000, () => 0.25), b = OF.newKey(1781000000000, () => 0.75);
    assert.equal(Keys.isCreateOrderKey(a), true);
    assert.notEqual(a, b);
    assert.equal(Keys.isRestockKey(a) || Keys.isAddProductKey(a), false);
    assert.equal(Keys.isCreateOrderKey(OF.newKey(Date.now(), Math.random)), true);
});

test("F-2 localDay: a real Date gives its local yyyy-MM-dd; anything else gives '' (the planner, not this file, then decides)", () => {
    assert.equal(OF.localDay(new Date(2026, 0, 5, 23, 59, 59)), "2026-01-05");
    assert.equal(OF.localDay(new Date(2026, 11, 31)), "2026-12-31");
    for (const bad of [new Date(NaN), "2026-06-15", 0, null, undefined, {}, []]) assert.equal(OF.localDay(bad), "", String(bad));
});

test("F-3 classify is RestockFlow's: ok+queued, ok, pending, rejected, junk", () => {
    for (const r of [{ ok: true }, { ok: true, queued: true }, { ok: false, pending: true }, { ok: false }, null, undefined, 5, "x"]) assert.equal(OF.classify(r), RF.classify(r));
    assert.deepEqual([OF.classify({ ok: true }), OF.classify({ ok: true, queued: true }), OF.classify({ ok: false, pending: true }), OF.classify({ ok: false })], ["applied", "queued", "queued", "rejected"]);
});

test("F-4 refusalText: the person-fixable reasons have their own wording; a line names itself; everything else says it is an app problem", () => {
    assert.equal(OF.refusalText("bad-customer"), "Enter a valid customer name");
    assert.equal(OF.refusalText("too-large"), OF.TOO_LARGE_TEXT);
    for (const idx of [-1, undefined, null, "0", NaN]) assert.equal(OF.refusalText("bad-line", idx, ["A"]), "Add at least one product", String(idx));
    assert.match(OF.refusalText("bad-line", 0, ["Tomato"]), /^Line 1 \(Tomato\): the quantity must be a whole number of 1 or more, and the price, tax and discount must be valid\. A price can be at most 1000000000$/);
    assert.match(OF.refusalText("bad-line", 2, ["A", "B"]), /^Line 3: /, "a missing name leaves the number only");
    assert.match(OF.refusalText("bad-line", 0, [""]), /^Line 1: /);
    assert.match(OF.refusalText("bad-line", 0, undefined), /^Line 1: /);
    for (const r of ["bad-key", "bad-order", "bad-status", "bad-time", "bad-totals", "weird", undefined]) assert.match(OF.refusalText(r), /^Could not place the order \(.*\)\. Please report this$/, String(r));
});

test("F-5 drift: every reason OrderPlan.build can give has a non-empty text, and a person-fixable one never says 'report this'", () => {
    const reasons = new Set();
    const src = fs.readFileSync(path.join(HELPER_DIR, "OrderPlan.js"), "utf8");
    for (const m of src.matchAll(/_refuse\("([a-z-]+)"\)|reason: "([a-z-]+)"/g)) reasons.add(m[1] || m[2]);
    reasons.delete("malformed-results");   // reflect's, not build's: the store turns it into "unconfirmed" (W-10)
    assert.deepEqual([...reasons].sort(), ["bad-customer", "bad-key", "bad-line", "bad-order", "bad-status", "bad-time", "bad-totals", "too-large"]);
    for (const r of reasons) {
        const t = OF.refusalText(r, 0, ["X"]);
        assert.ok(t.length > 0);
        assert.equal(/report this/.test(t), !["bad-customer", "bad-line", "too-large"].includes(r), r);
    }
});

test("F-6 doneText: a toast only when the answer is not in yet or could not be read; an applied order needs none", () => {
    assert.equal(OF.doneText("queued"), OF.QUEUED_TEXT);
    assert.equal(OF.doneText("unconfirmed"), OF.UNCONFIRMED_TEXT);
    for (const s of ["applied", "", undefined, null, "x"]) assert.equal(OF.doneText(s), "");
    assert.match(OF.UNCONFIRMED_TEXT, /Check the order list before placing it again/);
    assert.match(OF.OFFLINE_TEXT, /internet connection/);
});

test("F-7 the fixed texts are plain (no brace placeholders, no trailing space) and distinct", () => {
    const t = [OF.OFFLINE_TEXT, OF.QUEUED_TEXT, OF.UNCONFIRMED_TEXT, OF.DISCARDED_TEXT, OF.TOO_LARGE_TEXT];
    assert.equal(new Set(t).size, t.length);
    for (const x of t) assert.ok(!/[{}]/.test(x) && x === x.trim() && x.length > 10);
});

// ---------------------------------------------------------------------------------------------------------------------
// NO3b: the unit-price field (design 2026-11-24-no3b-order-price-cap-design.md). priceEdit / priceText.
// ---------------------------------------------------------------------------------------------------------------------

const MAX = RF.MAX_UNIT_COST;

test("F-8 priceEdit: a plain decimal in 0..MAX is a price (leading zeros, '5.', '.5', padding all read as typed)", () => {
    const rows = [["250", 250], ["0", 0], ["007", 7], ["19.99", 19.99], [".5", 0.5], ["5.", 5], ["  42  ", 42], ["0.0", 0], ["1000000000", MAX], ["999999999.99", 999999999.99]];
    for (const [t, n] of rows) assert.deepEqual(plain(OF.priceEdit(t, 1, "₹1")), { kind: "set", price: n }, t);
});

test("F-9 priceEdit: junk is refused as 'invalid' and never read as a different number (the old parser read these as 5, 15, 12, 1.2, 15)", () => {
    for (const t of ["-5", "+5", "1e5", "1E5", "12abc", "1.2.3", "1,5", "1,200", "abc", "--1", "Infinity", "NaN", "0x10", "٣٣", "5 0", "₹120x", "1_000", "."])
        assert.deepEqual(plain(OF.priceEdit(t, 1, "₹1")), { kind: "refused", reason: "invalid" }, JSON.stringify(t));
});

test("F-10 priceEdit: blank and non-string text are 'blank'; above the limit (and an overflowing paste) are 'large'", () => {
    for (const t of ["", "   ", "\n\t", undefined, null, 5, {}, []]) assert.deepEqual(plain(OF.priceEdit(t, 1, "₹1")), { kind: "refused", reason: "blank" }, String(t));
    for (const t of ["1000000000.01", "1000000001", "99999999999999999999", "9".repeat(400), "1" + "0".repeat(30) + ".5"])
        assert.deepEqual(plain(OF.priceEdit(t, 1, "₹1")), { kind: "refused", reason: "large" }, t.slice(0, 20));
});

test("F-11 priceEdit: text that is what the field already shows is 'unchanged' (no parse, no message), including the formatted display", () => {
    assert.deepEqual(plain(OF.priceEdit("120", 120, "₹120")), { kind: "unchanged" });
    assert.deepEqual(plain(OF.priceEdit("  120 ", 120, "₹120")), { kind: "unchanged" });
    assert.deepEqual(plain(OF.priceEdit("₹1,20,000", 120000, "₹1,20,000")), { kind: "unchanged" });
    assert.deepEqual(plain(OF.priceEdit("19.99", 19.99, "₹20")), { kind: "unchanged" });
    // the formatted text of ANOTHER price is not "unchanged": it is junk
    assert.deepEqual(plain(OF.priceEdit("₹1,20,000", 5, "₹5")), { kind: "refused", reason: "invalid" });
    // a non-string `shown` is ignored, never matched against
    for (const shown of [undefined, null, 5, {}]) assert.deepEqual(plain(OF.priceEdit("7", 1, shown)), { kind: "set", price: 7 }, String(shown));
    // `shown` is compared trimmed, like the typed text (a padded display still reads back as unchanged)
    assert.deepEqual(plain(OF.priceEdit("₹120", 120, "  ₹120 ")), { kind: "unchanged" });
    // a typed value equal to the stored one in another spelling is a set (the dialog then sees no change)
    assert.deepEqual(plain(OF.priceEdit("120.0", 120, "₹120")), { kind: "set", price: 120 });
});

test("F-12 priceText: one wording per reason, the limit comes from RestockFlow, an unknown reason is ''", () => {
    assert.equal(OF.priceText("blank"), "Enter the price of one unit, 0 or more");
    assert.equal(OF.priceText("invalid"), "Price must be a plain number, like 120 or 99.5");
    assert.equal(OF.priceText("large"), "Price is too large. Enter the price of ONE unit, up to " + MAX);
    for (const r of ["x", "", undefined, null, 5, "bad-line", "set", "unchanged"]) assert.equal(OF.priceText(r), "", String(r));
    const t = ["blank", "invalid", "large"].map(OF.priceText);
    assert.equal(new Set(t).size, 3);
    for (const x of t) assert.ok(!/[{}]/.test(x) && x === x.trim() && x.length > 10);
});

test("F-13 priceEdit never throws and always answers one of three kinds, for any value", () => {
    for (const t of [undefined, null, 0, NaN, Infinity, true, {}, [], () => 1, Symbol.iterator.toString(), "\u0000", "\uD800"])
        for (const cur of [undefined, null, NaN, 0, "x", {}]) for (const shown of [undefined, null, "", "₹0", 7]) {
            const r = plain(OF.priceEdit(t, cur, shown));
            assert.ok(["unchanged", "set", "refused"].includes(r.kind));
            if (r.kind === "set") assert.ok(Number.isFinite(r.price) && r.price >= 0 && r.price <= MAX);
            if (r.kind === "refused") assert.ok(["blank", "invalid", "large"].includes(r.reason));
        }
});
