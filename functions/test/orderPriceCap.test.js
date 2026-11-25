"use strict";

// Atomic-ops NO3b (design 2026-11-24-no3b-order-price-cap-design.md): the New Order unit-price field. Runs the REAL body of
// NewOrderDialog._setLinePrice and InventoryStore.formatCurrency (extracted from the QML text and run in a vm) against the REAL
// OrderFlow.js, then pushes every price the dialog can commit through the REAL order normaliser and OrderPlan.build, so "the
// field accepts what the planner accepts, and refuses what it would refuse" is proven, not assumed (KNOWN-ISSUES 114).
// tests/tst_OrderFlow.qml carries the helper rows for CI's qmltestrunner; the dialog itself cannot load headless (Felgo).

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");
const { load, plain, extractFunction } = require("./testSupport/qmlHelpers");

const OF = load("OrderFlow.js");
const OP = load("OrderPlan.js");
const Keys = load("OperationKeys.js");
const RF = load("RestockFlow.js");
const NP = load("NewOrderPicker.js");
const MAX = RF.MAX_UNIT_COST;
const KEY = "createOrder:1781000000000-abcdefabcdef";
const ISO = "2026-06-15T12:00:00.000Z";

// The dialog's cart and its real price-commit functions.
function dialog(lines) {
    const ctx = { OrderFlow: OF, Object, Number, String, Math, Intl, isNaN, isFinite, parseFloat, selectedProducts: lines, _priceErrors: {} };
    vm.createContext(ctx);
    vm.runInContext(extractFunction("model/InventoryStore.qml", "formatCurrency"), ctx);
    ctx.InventoryStore = { formatCurrency: ctx.formatCurrency };
    for (const f of ["_setLinePrice", "_setPriceError"]) vm.runInContext(extractFunction("pages/NewOrderDialog.qml", f), ctx);
    return {
        // -> what this one commit did: the refusal it recorded, "" when it replaced the price or cleared an older refusal, null when
        // it touched nothing.
        set: (idx, text) => {
            const cart = ctx.selectedProducts, errors = ctx._priceErrors;
            ctx._setLinePrice(idx, text);
            if (ctx.selectedProducts === cart && ctx._priceErrors === errors) return null;
            const line = ctx.selectedProducts[idx];
            return ctx._priceErrors[line.productId] || "";
        },
        error: (id) => ctx._priceErrors[id] || "",
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

test("P-1 a plain price is committed: the line changes, the other line and fields are untouched, and no refusal is left", () => {
    const d = dialog(cart());
    const before = d.raw;
    assert.equal(d.set(0, "250.5"), "");
    assert.equal(d.lines[0].price, 250.5);
    assert.deepEqual(d.lines[0], Object.assign({}, cart()[0], { price: 250.5 }));
    assert.deepEqual(d.lines[1], cart()[1]);
    assert.notEqual(d.raw, before, "a NEW array, so the totals binding recomputes");
    assert.deepEqual(plain(before), cart(), "the old array was not mutated");
});

test("P-2 a refused entry records its text for that line and changes no line: blank, junk, negative, exponent, comma, too large", () => {
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
    // a value equal to the stored one in another spelling is no price change, and it clears an older refusal
    const d = dialog(cart()), before = d.raw;
    d.set(0, "abc");
    assert.equal(d.set(0, "100.00"), "");
    assert.equal(d.error("PRD-001"), "");
    assert.equal(d.raw, before);
});

test("P-4 Enter fires accepted then editingFinished: the second call (text now the old price) touches nothing, so the refusal stays", () => {
    for (const second of ["100", "₹100"]) {
        const d = dialog(cart());
        assert.equal(d.set(0, "abc"), OF.priceText("invalid"));        // first call: refused
        assert.equal(d.set(0, second), null);                          // second call: the field was reset
        assert.equal(d.error("PRD-001"), OF.priceText("invalid"));
        assert.equal(d.error("PRD-002"), "", "the other line has no message");
    }
});

test("P-5 an index that is not a row of the cart changes nothing (a row removed while the field commits; NaN and strings too)", () => {
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
        if (n % 100 === 0) t = n % 200 === 0 ? "100" : "₹100";   // the unchanged branch, which random text almost never reaches
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
    assert.ok(sets > 200 && refused > 5000 && nulls >= 200, `the probe must reach every branch (sets ${sets}, refused ${refused}, nulls ${nulls})`);
});

// ---------------------------------------------------------------------------------------------------------------------
// Review sweep of PR 219: the flow around the commit. A stand-in Repeater builds one delegate per cart line and rebuilds them
// on every cart change, as Qt does; each delegate runs the REAL settlePrice, _commitPrice, onActiveFocusChanged and onTextEdited
// text, and the dialog runs the REAL trySubmit, _settlePriceEdit, _setLineDiscount and onSelectedProductsChanged. What stays
// unproven here is only which Qt event fires when: so both focus-loss orders and "no focus loss at all" are run.
// ---------------------------------------------------------------------------------------------------------------------

const DIALOG = fs.readFileSync(path.join(__dirname, "..", "..", "qml", "pages", "NewOrderDialog.qml"), "utf8");
function handler(needle) {
    const at = DIALOG.indexOf(needle);
    assert.ok(at > 0, needle);
    const from = at + needle.length;
    if (!/^\s*\{/.test(DIALOG.slice(from))) return DIALOG.slice(from, DIALOG.indexOf("\n", from));
    const open = DIALOG.indexOf("{", from);
    let depth = 0, i = open;
    for (; i < DIALOG.length; i++) { if (DIALOG[i] === "{") depth++; else if (DIALOG[i] === "}" && --depth === 0) break; }
    return DIALOG.substring(open + 1, i);
}
const FOCUS = handler("onActiveFocusChanged:");
const TYPED = handler("onTextEdited:");
const PRUNE = handler("onSelectedProductsChanged:");

function sheet(lines = cart()) {
    const sent = [];
    let rows = [], selected = [];
    const ctx = {
        OrderFlow: OF, Picker: NP, Object, Number, String, Math, Array, Intl, isNaN, isFinite, parseFloat,
        busy: false, _priceErrors: {}, _staffIds: [""],
        customerField: { text: "Asha" }, emailField: { text: "" }, phoneField: { text: "" }, errorLabel: { text: "" },
        channelCombo: { currentIndex: -1 }, staffCombo: { currentIndex: 0 }, OrderChannelStore: { channels: [] },
        orderCreated: (o) => sent.push(plain(o)),
        cartRepeater: { get count() { return rows.length; }, itemAt: (i) => rows[i] || null }
    };
    Object.defineProperty(ctx, "selectedProducts", { enumerable: true, get: () => selected, set: (v) => {
        selected = v;
        rows.forEach((r) => r.destroy());
        vm.runInContext(PRUNE, ctx);
        rows = selected.map((_, i) => delegate(i));
    } });
    vm.createContext(ctx);
    vm.runInContext(extractFunction("model/InventoryStore.qml", "formatCurrency"), ctx);
    ctx.InventoryStore = { formatCurrency: ctx.formatCurrency, getById: () => ({ stock: 1000, taxable: false }) };
    for (const f of ["_settlePriceEdit", "_setPriceError", "_setLineDiscount", "_setLinePrice", "changeQty", "trySubmit"])
        vm.runInContext(extractFunction("pages/NewOrderDialog.qml", f), ctx);

    function delegate(index) {
        const modelData = selected[index];
        const f = { dlg: ctx, index, modelData, InventoryStore: ctx.InventoryStore, String, activeFocus: false,
                    text: ctx.formatCurrency(modelData.price), selectAll: () => {} };
        vm.createContext(f);
        vm.runInContext(extractFunction("pages/NewOrderDialog.qml", "_commitPrice"), f);
        f.linePriceField = { get activeFocus() { return f.activeFocus; }, _commitPrice: () => f._commitPrice() };
        vm.runInContext(extractFunction("pages/NewOrderDialog.qml", "settlePrice"), f);
        return {
            field: f,
            settlePrice: () => f.settlePrice(),
            focus() { if (!f.activeFocus) { f.activeFocus = true; vm.runInContext(FOCUS, f); } },
            type(t) { f.text = t; vm.runInContext(TYPED, f); },
            enter() { f._commitPrice(); f._commitPrice(); },
            // `order`: which of editingFinished and the activeFocus handler Qt runs first
            blur(order = "finished-first") {
                if (!f.activeFocus) return;
                f.activeFocus = false;
                if (order === "finished-first") { f._commitPrice(); vm.runInContext(FOCUS, f); }
                else { vm.runInContext(FOCUS, f); f._commitPrice(); }
            },
            destroy() { f.activeFocus = false; }
        };
    }
    ctx.selectedProducts = lines;
    return {
        ctx, sent,
        row: (i) => rows[i],
        type(i, t) { rows[i].focus(); rows[i].type(t); },
        submit: () => ctx.trySubmit(),
        error: (id) => ctx._priceErrors[id] || "",
        get lines() { return plain(selected); },
        get prices() { return plain(selected.map((l) => l.price)); }
    };
}
const ORDERS = ["finished-first", "focus-first", "no-blur"];
// "Place order" is tapped with the field still in use: the button takes the focus first (either order), or it does not at all.
function tapPlaceOrder(s, i, order) { if (order !== "no-blur") s.row(i).blur(order); s.submit(); }

test("P-8 a price typed and not yet committed is the price ordered, however Qt orders the focus loss (or if there is none)", () => {
    for (const order of ORDERS) {
        const s = sheet();
        s.type(0, "250.5");
        tapPlaceOrder(s, 0, order);
        assert.equal(s.sent.length, 1, order);
        assert.deepEqual(s.sent[0].products.map((p) => p.price), [250.5, 40.5], order);
    }
});

test("P-9 a refused entry typed right before Place order sends NOTHING: the person is told which line and what it still costs", () => {
    for (const order of ORDERS) for (const bad of ["1,200", "abc", "", "-5", "1e5", "1000000001"]) {
        const s = sheet();
        s.type(0, bad);
        tapPlaceOrder(s, 0, order);
        assert.equal(s.sent.length, 0, order + " " + JSON.stringify(bad));
        assert.equal(s.ctx.busy, false);
        assert.equal(s.ctx.errorLabel.text, OF.priceBlockedText("Tomato", "₹100"));
        assert.notEqual(s.error("PRD-001"), "");
        s.submit();
        assert.equal(s.sent.length, 0, "a second tap is not an acknowledgement");
    }
});

test("P-10 tapping the field acknowledges the refusal; the order then goes with the price the field shows", () => {
    const s = sheet();
    s.type(0, "abc");
    tapPlaceOrder(s, 0, "finished-first");
    s.row(0).focus();
    assert.equal(s.error("PRD-001"), "");
    assert.equal(s.row(0).field.text, "100");
    tapPlaceOrder(s, 0, "finished-first");
    assert.deepEqual(s.sent.map((o) => o.products[0].price), [100]);
    assert.equal(s.ctx.errorLabel.text, "");
});

test("P-11 Enter on a refused entry keeps the focused field plain (never the formatted text, which typing would append to); retyping clears", () => {
    const s = sheet([{ name: "Gold", qty: 1, price: 120000, productId: "PRD-9", discountType: "flat", discountValue: 0 }]);
    s.type(0, "abc");
    s.row(0).enter();
    assert.equal(s.row(0).field.text, "120000");
    assert.equal(s.error("PRD-9"), OF.priceText("invalid"), "the second handler did not wipe it");
    s.row(0).type("1200005");
    assert.equal(s.error("PRD-9"), "", "typing again clears the old message");
    s.row(0).enter();
    assert.deepEqual(s.prices, [1200005]);
});

test("P-12 focus loss formats the untouched plain number, in both orders", () => {
    for (const order of ["finished-first", "focus-first"]) {
        const s = sheet();
        s.row(0).focus();
        s.row(0).blur(order);
        assert.equal(s.row(0).field.text, "₹100", order);
        assert.deepEqual(s.lines, cart());
        assert.equal(s.error("PRD-001"), "");
    }
    // and when no editingFinished comes at all, the focus handler alone puts the formatted text back
    const s = sheet();
    s.row(0).focus();
    s.row(0).field.activeFocus = false;
    vm.runInContext(FOCUS, s.row(0).field);
    assert.equal(s.row(0).field.text, "₹100");
});

test("P-13 a refusal survives the rows being rebuilt (quantity, another line's price), leaves with its line, and a new sheet starts clean", () => {
    const s = sheet();
    s.type(0, "abc");
    s.row(0).blur();
    s.ctx.selectedProducts = s.ctx.selectedProducts.map((l) => Object.assign({}, l, { qty: l.qty + 1 }));
    assert.equal(s.error("PRD-001"), OF.priceText("invalid"), "the old row-held message died here");
    s.type(1, "50");
    s.row(1).blur();
    assert.equal(s.error("PRD-001"), OF.priceText("invalid"));
    s.ctx.selectedProducts = [s.ctx.selectedProducts[1]];
    assert.equal(s.error("PRD-001"), "", "removed line");
    s.ctx.selectedProducts = cart();
    assert.equal(s.error("PRD-001"), "", "added again: no stale message");
    s.type(0, "abc");
    s.row(0).blur();
    s.ctx.selectedProducts = [];   // onOpened / onClosed
    assert.deepEqual(plain(s.ctx._priceErrors), {});
});

test("P-14 the discount pill (it takes no focus) commits the typed price before it rebuilds the rows", () => {
    const s = sheet();
    s.type(0, "250");
    s.ctx._setLineDiscount(0, "percent", 5);
    assert.deepEqual(s.prices, [250, 40.5]);
    assert.equal(s.lines[0].discountType, "percent");
    const r = sheet();
    r.type(1, "1,5");
    r.ctx._setLineDiscount(0, "percent", 5);
    assert.deepEqual(r.prices, [100, 40.5]);
    assert.equal(r.error("PRD-002"), OF.priceText("invalid"), "a refusal made by the pill's commit is kept and shown");
});

test("P-14b the quantity stepper commits the typed price too, and a refusal outlives the rebuild it causes", () => {
    const s = sheet();
    s.type(0, "250");
    s.ctx.changeQty(0, +1);
    assert.deepEqual(plain(s.lines.map((l) => [l.qty, l.price])), [[4, 250], [1, 40.5]]);
    s.type(0, "abc");
    s.ctx.changeQty(0, +1);
    assert.equal(s.lines[0].qty, 5);
    assert.equal(s.error("PRD-001"), OF.priceText("invalid"));
    s.ctx.changeQty(0, -5);   // the line leaves the cart, and its message with it
    assert.deepEqual(plain(s.ctx._priceErrors), {});
});

test("P-15 a busy sheet commits nothing and sends nothing", () => {
    const s = sheet();
    s.type(0, "250");
    s.ctx.busy = true;
    s.submit();
    assert.deepEqual(s.prices, [100, 40.5]);
    assert.equal(s.sent.length, 0);
});

test("P-16 monkey: 800 sessions of random typing, Enter, focus moves, pills and taps: never sends a price other than the cart's, never sends while a refusal stands", () => {
    let seed = 20261125, sentCount = 0, blocked = 0;
    const rnd = () => (seed = (seed * 1664525 + 1013904223) % 4294967296) / 4294967296;
    const pick = (a) => a[Math.floor(rnd() * a.length)];
    const texts = ["", "0", "5", "99.5", "100", "₹100", "1,200", "abc", "-5", "1e5", "1000000000", "1000000001", " 7 ", "."];
    for (let n = 0; n < 800; n++) {
        const s = sheet();
        for (let step = 0; step < 12; step++) {
            const i = Math.floor(rnd() * 2), r = s.row(i);
            // one field has the focus at a time
            const leave = () => { for (let k = 0; k < 2; k++) if (k !== i && s.row(k)) s.row(k).blur(pick(ORDERS.slice(0, 2))); };
            if (!r) continue;   // the stepper removed a line
            switch (pick(["type", "type", "enter", "blur", "focus", "pill", "step", "submit"])) {
            case "step": s.ctx.changeQty(i, pick([1, 1, -1])); break;
            case "type": leave(); s.type(i, pick(texts)); break;
            case "enter": if (r.field.activeFocus) r.enter(); break;
            case "blur": r.blur(pick(ORDERS.slice(0, 2))); break;
            case "focus": leave(); s.row(i).focus(); break;
            case "pill": s.ctx._setLineDiscount(i, pick(["flat", "percent"]), 1); break;
            case "submit": {
                if (rnd() < 0.5) for (let k = 0; k < 2; k++) if (s.row(k)) s.row(k).blur(pick(ORDERS.slice(0, 2)));
                const before = s.sent.length;
                s.submit();
                if (s.sent.length > before) {
                    sentCount++;
                    assert.deepEqual(plain(s.ctx._priceErrors), {}, "session " + n);
                    assert.deepEqual(s.sent[before].products.map((p) => p.price), s.prices, "session " + n);
                    s.ctx.busy = false;
                } else blocked++;
                break;
            }
            }
            for (const p of s.prices) assert.ok(Number.isFinite(p) && p >= 0 && p <= MAX, "session " + n);
        }
    }
    assert.ok(sentCount > 100 && blocked > 100, `both outcomes must be reached (sent ${sentCount}, blocked ${blocked})`);
});

