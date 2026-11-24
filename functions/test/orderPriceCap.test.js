"use strict";

// Atomic-ops NO3b (design 2026-11-24-no3b-order-price-cap-design.md): the New Order unit-price field. Runs the REAL body of
// NewOrderDialog._setLinePrice and InventoryStore.formatCurrency (extracted from the QML text and run in a vm) against the REAL
// OrderFlow.js, then pushes every price the dialog can commit through the REAL order normaliser and OrderPlan.build, so "the
// field accepts what the planner accepts, and refuses what it would refuse" is proven, not assumed (KNOWN-ISSUES 114).
// tests/tst_OrderFlow.qml carries the helper rows for CI's qmltestrunner; the dialog itself cannot load headless (Felgo).

const test = require("node:test");
const assert = require("node:assert/strict");
const vm = require("node:vm");
const { load, plain, extractFunction } = require("./testSupport/qmlHelpers");

const OF = load("OrderFlow.js");
const OP = load("OrderPlan.js");
const Keys = load("OperationKeys.js");
const RF = load("RestockFlow.js");
const MAX = RF.MAX_UNIT_COST;
const KEY = "createOrder:1781000000000-abcdefabcdef";
const ISO = "2026-06-15T12:00:00.000Z";

// The dialog's cart and its real price-commit function.
function dialog(lines) {
    const ctx = { OrderFlow: OF, Object, Number, String, Math, Intl, isNaN, isFinite, parseFloat, selectedProducts: lines };
    vm.createContext(ctx);
    vm.runInContext(extractFunction("model/InventoryStore.qml", "formatCurrency"), ctx);
    ctx.InventoryStore = { formatCurrency: ctx.formatCurrency };
    vm.runInContext(extractFunction("pages/NewOrderDialog.qml", "_setLinePrice"), ctx);
    return {
        set: (idx, text) => ctx._setLinePrice(idx, text),
        get lines() { return plain(ctx.selectedProducts); },
        get raw() { return ctx.selectedProducts; }
    };
}
const cart = () => [
    { name: "Tomato", qty: 3, price: 100, productId: "PRD-001", discountType: "flat", discountValue: 5 },
    { name: "Onion", qty: 1, price: 40.5, productId: "PRD-002", discountType: "percent", discountValue: 10 }
];

// The REAL order normaliser (same extraction createOrderPlan.test.js uses).
const store = {};
{
    const ctx = { InventoryStore: { getById: () => null }, Qt: { formatDate: () => "2026-06-15" }, Date };
    vm.createContext(ctx);
    for (const f of ["parseCurrency", "computeOrderTotals", "_normalizeOrder"]) vm.runInContext(extractFunction("model/OrdersStore.qml", f), ctx);
    store.normalize = (raw) => plain(ctx._normalizeOrder(raw));
}
function planWithPrice(price) {
    const line = { productId: "PRD-001", name: "Tomato", qty: 3, quantity: 3, price, taxable: true, taxPercent: 5, discountType: "flat", discountValue: 0 };
    const order = store.normalize({ orderId: "ORD-OLD", customer: "Asha", email: "", phone: "", status: "pending", date: "2026-06-15", notes: "",
        orderChannel: "Online", staffId: "S-1", updatedAt: ISO, products: [line], items: 0, total: 0 });
    return plain(OP.build({ key: KEY, order }));
}

test("P-1 a plain price is committed: the line changes, the other line and fields are untouched, and '' is returned", () => {
    const d = dialog(cart());
    const before = d.raw;
    assert.equal(d.set(0, "250.5"), "");
    assert.equal(d.lines[0].price, 250.5);
    assert.deepEqual(d.lines[0], Object.assign({}, cart()[0], { price: 250.5 }));
    assert.deepEqual(d.lines[1], cart()[1]);
    assert.notEqual(d.raw, before, "a NEW array, so the totals binding recomputes");
    assert.deepEqual(plain(before), cart(), "the old array was not mutated");
});

test("P-2 a refused entry returns its text and changes nothing: blank, junk, negative, exponent, comma, too large", () => {
    const cases = [["", "blank"], ["   ", "blank"], ["abc", "invalid"], ["-5", "invalid"], ["1e5", "invalid"], ["1,5", "invalid"], ["12abc", "invalid"],
        ["1.2.3", "invalid"], ["1000000000.01", "large"], ["9".repeat(60), "large"]];
    for (const [t, reason] of cases) {
        const d = dialog(cart()), before = d.raw;
        assert.equal(d.set(0, t), OF.priceText(reason), JSON.stringify(t));
        assert.equal(d.raw, before, "the array is the same object: nothing was replaced");
        assert.deepEqual(d.lines, cart());
    }
});

test("P-3 text the field already shows is 'nothing to commit' (null): the plain price, the formatted display, padding", () => {
    for (const t of ["100", " 100 ", "₹100"]) {
        const d = dialog(cart()), before = d.raw;
        assert.equal(d.set(0, t), null, JSON.stringify(t));
        assert.equal(d.raw, before);
    }
    const big = dialog([{ name: "Gold", qty: 1, price: 120000, productId: "PRD-9", discountType: "flat", discountValue: 0 }]);
    assert.equal(big.set(0, "₹1,20,000"), null, "the formatted display is read back on focus loss and must not be refused");
    // a value equal to the stored one in another spelling is not a change either
    const d = dialog(cart()), before = d.raw;
    assert.equal(d.set(0, "100.00"), null);
    assert.equal(d.raw, before);
});

test("P-4 Enter fires accepted then editingFinished: the second call (text now the formatted old price) is null, never a message", () => {
    const d = dialog(cart());
    assert.equal(d.set(0, "abc"), OF.priceText("invalid"));        // first call: refused
    assert.equal(d.set(0, d.lines[0].price === 100 ? "₹100" : "?"), null);   // second call: the field was reset to the display
});

test("P-5 an index that is not a row of the cart is null and changes nothing (a row removed while the field commits; NaN and strings too)", () => {
    for (const idx of [-1, 2, 99, NaN, undefined, null, "0", 0.5, Infinity, -Infinity, {}]) {
        const d = dialog(cart()), before = d.raw;
        assert.equal(d.set(idx, "5"), null, String(idx));
        assert.equal(d.raw, before, String(idx));
    }
    const empty = dialog([]);
    assert.equal(empty.set(0, "5"), null);
});

test("P-6 the limit is the planner's: the highest price the field commits is planned, the first price above it is refused by both", () => {
    const top = dialog(cart());
    assert.equal(top.set(0, String(MAX)), "");
    assert.equal(top.lines[0].price, MAX);
    assert.equal(planWithPrice(MAX).ok, true);
    const over = dialog(cart());
    assert.equal(over.set(0, "1000000000.01"), OF.priceText("large"));
    assert.deepEqual(planWithPrice(MAX + 0.01), { ok: false, reason: "bad-line", index: 0 });
    assert.equal(planWithPrice(0).ok, true, "a price of 0 is allowed by both (a free line); see KNOWN-ISSUES, Q-NO3b-1");
});

test("P-7 monkey: 20000 random texts never throw, never change a refused or unchanged entry, and every committed price is plannable", () => {
    let seed = 20261124;
    const rnd = () => (seed = (seed * 1664525 + 1013904223) % 4294967296) / 4294967296;
    const alphabet = "0123456789012345678901234567890123456789....,,--++eE₹ abcxX_٣​\t";
    let sets = 0, refused = 0, nulls = 0;
    for (let n = 0; n < 20000; n++) {
        let t = ""; const len = Math.floor(rnd() * 13);
        for (let i = 0; i < len; i++) t += alphabet[Math.floor(rnd() * alphabet.length)];
        const d = dialog(cart()), before = d.raw;
        const r = d.set(0, t);
        if (r === null) { nulls++; assert.equal(d.raw, before, JSON.stringify(t)); continue; }
        if (r !== "") {
            refused++;
            assert.ok(["blank", "invalid", "large"].map(OF.priceText).includes(r), JSON.stringify(t));
            assert.equal(d.raw, before, JSON.stringify(t));
            continue;
        }
        sets++;
        const p = d.lines[0].price;
        assert.ok(Number.isFinite(p) && p >= 0 && p <= MAX && p !== 100, JSON.stringify(t));
        assert.ok(/^(\d+\.?\d*|\.\d+)$/.test(t.trim()) && Number(t.trim()) === p, JSON.stringify(t));
        assert.deepEqual(d.lines[1], cart()[1]);
        assert.equal(planWithPrice(p).ok, true, "a price the field committed must be plannable: " + JSON.stringify(t));
    }
    assert.ok(sets > 200 && refused > 5000 && nulls >= 0, `the probe must reach every branch (sets ${sets}, refused ${refused}, nulls ${nulls})`);
});
