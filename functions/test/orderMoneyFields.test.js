"use strict";

// Atomic-ops NO3c (design 2026-11-26-no3c-edit-order-money-fields-design.md): the price and discount fields of BOTH order sheets.
// Runs the REAL dialog functions and the REAL delegate handlers (extracted from the QML text) over stand-in rows: New Order
// rebuilds a row on every cart change, Edit Order updates its ListModel rows in place. What stays unproven: which Qt event fires
// when (so both focus-loss orders and "no focus loss" are run), painting, TalkBack. Those are device checks.

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");
const { load, plain, extractFunction } = require("./testSupport/qmlHelpers");

const OF = load("OrderFlow.js");
const NP = load("NewOrderPicker.js");
const EP = load("EditOrderPicker.js");
const OA = load("OrderAdjust.js");

const SHEETS = {
    newOrder: { file: "NewOrderDialog.qml", price: "linePriceField", disc: "lineDiscField" },
    edit: { file: "OrderDetailDialog.qml", price: "priceField", disc: "lineDiscountField" }
};
const read = (f) => fs.readFileSync(path.join(__dirname, "..", "..", "qml", "pages", f), "utf8");
function braceBody(src, open) {
    let depth = 0, i = open;
    for (; i < src.length; i++) { if (src[i] === "{") depth++; else if (src[i] === "}" && --depth === 0) break; }
    return src.substring(open + 1, i);
}
// The code of the handler `name` inside the object with `id: <id>`.
function handler(src, id, name) {
    const start = src.search(new RegExp("id: " + id + "\\b"));
    assert.ok(start > 0, id);
    const body = braceBody(src, src.lastIndexOf("{", start));
    const at = body.indexOf(name + ":");
    assert.ok(at >= 0, id + "." + name);
    const rest = body.slice(at + name.length + 1);
    if (/^\s*(function[^{]*)?\{/.test(rest)) return braceBody(rest, rest.indexOf("{"));
    return rest.slice(0, rest.indexOf("\n"));
}
// A function declared inside the object with `id: <id>` (both fields have a _commit function).
function fieldFunction(src, id, name) {
    const start = src.search(new RegExp("id: " + id + "\\b"));
    const body = braceBody(src, src.lastIndexOf("{", start));
    const at = body.indexOf("function " + name + "(");
    assert.ok(at >= 0, id + "." + name);
    return body.substring(at, body.indexOf("{", at)) + "{" + braceBody(body, body.indexOf("{", at)) + "}";
}
const formatCtx = { Intl, Number, String, Math, isNaN, isFinite, parseFloat };
vm.createContext(formatCtx);
vm.runInContext(extractFunction("model/InventoryStore.qml", "formatCurrency"), formatCtx);
const money = formatCtx.formatCurrency;

const baseLines = () => [
    { productId: "P1", name: "Tomato", price: 100, quantity: 3, discountType: "flat", discountValue: 5, taxable: false, taxPercent: 0 },
    { productId: "P2", name: "Onion", price: 40, quantity: 1, discountType: "percent", discountValue: 10, taxable: false, taxPercent: 0 }
];

// One sheet. `kind` "newOrder" | "edit".
function sheet(kind, opts = {}) {
    const spec = SHEETS[kind], src = read(spec.file), edit = kind === "edit";
    const lines = opts.lines || baseLines();
    const sent = [];
    let rows = [];
    const ctx = {
        OrderFlow: OF, Picker: NP, NP, Edit: EP, OrderAdjust: OA, Object, Number, String, Math, Array, JSON, Intl, isNaN, isFinite, parseFloat,
        busy: false, recomputes: 0
    };
    const InventoryStore = { formatCurrency: money, getById: () => ({ stock: 100000, taxable: false }) };
    ctx.InventoryStore = InventoryStore;
    ctx.OrdersStore = { formatCurrency: money };
    vm.createContext(ctx);
    const load_ = (names) => names.forEach((f) => vm.runInContext(extractFunction("pages/" + spec.file, f), ctx));

    function delegate(index) {
        const f = {
            dlg: ctx, InventoryStore, OrdersStore: ctx.OrdersStore, String, products: ctx.products
        };
        vm.createContext(f);
        const field = (id, initial) => {
            const o = { activeFocus: false, text: initial, selectAll: () => {} };
            const proxy = new Proxy({}, {
                has: () => true,
                get: (_, k) => k in o ? o[k] : k === Symbol.unscopables ? undefined : f[k] !== undefined ? f[k] : globalThis[k],
                set: (_, k, v) => { if (k in o) o[k] = v; else f[k] = v; return true; }
            });
            const compile = (code) => { const fn = new Function("__s", "with (__s) { " + code + " }"); return () => fn(proxy); };
            return { o, compile };
        };
        const row = {};
        const cur = () => edit ? ctx.products.get(f.row.rowIdx) : ctx.selectedProducts[index];
        if (edit) {
            f.row = row;
            Object.defineProperties(row, {
                rowIdx: { get: () => ctx.products.rows.indexOf(rows[index].modelRef) },
                lineDiscValue: { get: () => rows[index].modelRef.discountValue || 0 },
                lineDiscType: { get: () => rows[index].modelRef.discountType }
            });
            Object.defineProperty(f, "model", { get: () => rows[index].modelRef });
        } else {
            f.index = index;
            f.modelData = ctx.selectedProducts[index];
        }
        const initial = edit ? ctx.products.get(index) : ctx.selectedProducts[index];
        const parts = {};
        for (const [key, id, commit, text] of [["price", spec.price, "_commitPrice", money(initial.price)],
            ["disc", spec.disc, "_commitDiscount", String(initial.discountValue || 0)]]) {
            const { o, compile } = field(id, text);
            const source = fieldFunction(src, id, commit);
            const body = source.slice(source.indexOf("{") + 1, source.lastIndexOf("}"));
            o[commit] = compile(body);
            parts[key] = {
                o,
                commit: o[commit],
                focusChanged: compile(handler(src, id, "onActiveFocusChanged")),
                typed: compile(handler(src, id, "onTextEdited"))
            };
            f[id] = o;
        }
        const settle = fieldFunction(src, edit ? "row" : "cartRow", "settleField");
        vm.runInContext(settle, f);
        const api = (p) => ({
            get text() { return p.o.text; },
            get focused() { return p.o.activeFocus; },
            focus() { if (!p.o.activeFocus) { p.o.activeFocus = true; p.focusChanged(); } },
            type(t) { this.focus(); p.o.text = t; p.typed(); },
            enter() { p.commit(); p.commit(); },
            blur(order = "finished-first") {
                if (!p.o.activeFocus) return;
                p.o.activeFocus = false;
                if (order === "finished-first") { p.commit(); p.focusChanged(); } else { p.focusChanged(); p.commit(); }
            }
        });
        return {
            price: api(parts.price), disc: api(parts.disc),
            settleField: () => f.settleField(),
            pill(type) {
                const code = handler(src, edit ? "lineDiscountTypeToggle" : "cartRow", "onSegmentSelected");
                const scope = { dlg: ctx, row: f.row, index, idx: type === "percent" ? 1 : 0, label: "", String,
                    lineDiscField: parts.disc.o, lineDiscountField: parts.disc.o };
                vm.runInNewContext(code, scope);
            },
            destroy() { parts.price.o.activeFocus = false; parts.disc.o.activeFocus = false; },
            get line() { return cur(); }
        };
    }

    if (edit) {
        const data = lines.map((l) => Object.assign({ priceError: "", discountError: "" }, l));
        ctx.products = {
            rows: data, get count() { return data.length; }, get: (i) => data[i],
            setProperty: (i, k, v) => { assert.ok(data[i] && k in data[i], "setProperty on a missing row or role: " + i + " " + k); data[i][k] = v; }
        };
        ctx._originalLines = opts.saved || [];
        ctx.recomputeSubtotal = () => { ctx.recomputes++; };
        ctx.lineRepeater = { get count() { return rows.length; }, itemAt: (i) => rows[i] || null };
        load_(["_settleFieldEdit", "_setRowError", "_setLinePrice", "_setLineDiscountValue", "_setLineDiscountType", "_lineProblems", "_lineItemArray"]);
        data.forEach((d, i) => {
            rows[i] = { modelRef: d };                       // delegate(i) reads its model through this
            const made = delegate(i);
            Object.defineProperty(made, "modelRef", { value: d });
            rows[i] = made;
        });
    } else {
        Object.assign(ctx, {
            _priceErrors: {}, _discountErrors: {}, _staffIds: [""], customerField: { text: "Asha" }, emailField: { text: "" },
            phoneField: { text: "" }, errorLabel: { text: "" }, channelCombo: { currentIndex: -1 }, staffCombo: { currentIndex: 0 },
            OrderChannelStore: { channels: [] }, orderCreated: (o) => sent.push(plain(o)),
            cartRepeater: { get count() { return rows.length; }, itemAt: (i) => rows[i] || null }
        });
        let selected = [];
        const prune = handler(src, "dlg", "onSelectedProductsChanged");
        Object.defineProperty(ctx, "selectedProducts", { enumerable: true, get: () => selected, set: (v) => {
            selected = v;
            rows.forEach((r) => r.destroy());
            vm.runInContext(prune, ctx);
            rows = [];
            selected.forEach((_, i) => { rows[i] = delegate(i); });
        } });
        load_(["_settleFieldEdit", "_setPriceError", "_setDiscountError", "_replaceLine", "_setLineDiscountValue",
            "_setLineDiscountType", "_setLinePrice", "trySubmit"]);
        ctx.selectedProducts = lines.map((l) => ({ productId: l.productId, name: l.name, price: l.price, qty: l.quantity,
            discountType: l.discountType, discountValue: l.discountValue }));
    }
    const lineNow = (i) => edit ? ctx.products.get(i) : ctx.selectedProducts[i];
    return {
        ctx, sent,
        row: (i) => rows[i],
        line: (i) => plain(lineNow(i)),
        error: (i, which) => edit ? lineNow(i)[which + "Error"]
            : (which === "price" ? ctx._priceErrors : ctx._discountErrors)[lineNow(i).productId] || "",
        // Save / Place order -> the problems that stop it ([] = it goes). Edit: the settle + problems half of _save, which the
        // wiring test M-12 pins inside _save itself.
        submit() {
            if (edit) { ctx._settleFieldEdit(); return plain(ctx._lineProblems()); }
            const before = sent.length;
            ctx.errorLabel.text = "";
            ctx.trySubmit();
            if (sent.length > before) { ctx.busy = false; return []; }
            return [ctx.errorLabel.text];
        }
    };
}
const KINDS = Object.keys(SHEETS);
const ORDERS = ["finished-first", "focus-first", "no-blur"];
const leave = (field, order) => { if (order !== "no-blur") field.blur(order); };

for (const kind of KINDS) {
    test(`M-1 ${kind}: a typed discount is stored only when it is a plain number inside the limit; otherwise the old one stays and the row says why`, () => {
        const s = sheet(kind);
        s.row(0).disc.type("12.5"); s.row(0).disc.blur();
        assert.equal(s.line(0).discountValue, 12.5);
        assert.equal(s.error(0, "discount"), "");
        for (const [t, reason] of [["-5", "invalid"], ["1e2", "invalid"], ["1,5", "invalid"], ["abc", "invalid"], ["301", "amount"]]) {
            s.row(0).disc.type(t); s.row(0).disc.blur();
            assert.equal(s.line(0).discountValue, 12.5, t);
            assert.equal(s.error(0, "discount"), OF.discountText(reason, money(300)), t);
            assert.equal(s.row(0).disc.text, "12.5", "the field shows what is stored");
        }
        s.row(1).disc.type("101"); s.row(1).disc.blur();
        assert.equal(s.line(1).discountValue, 10);
        assert.equal(s.error(1, "discount"), OF.discountText("percent", ""));
        s.row(1).disc.type(""); s.row(1).disc.blur();
        assert.equal(s.line(1).discountValue, 0, "blank = no discount");
        assert.equal(s.error(1, "discount"), "");
    });

    test(`M-2 ${kind}: Enter keeps the message (second commit is unchanged); tapping or typing acknowledges it`, () => {
        const s = sheet(kind);
        s.row(0).disc.type("abc"); s.row(0).disc.enter();
        assert.ok(s.error(0, "discount"));
        s.row(0).disc.type("7");
        assert.equal(s.error(0, "discount"), "", "typing");
        s.row(0).disc.blur();
        s.row(0).disc.type("abc"); s.row(0).disc.blur();
        s.row(0).disc.focus();
        assert.equal(s.error(0, "discount"), "", "tapping");
    });

    test(`M-3 ${kind}: a typed, uncommitted discount is what Save / Place order sends, however Qt orders the focus loss`, () => {
        for (const order of ORDERS) {
            const s = sheet(kind);
            s.row(0).disc.type("40"); leave(s.row(0).disc, order);
            assert.deepEqual(s.submit(), [], order);
            assert.equal(s.line(0).discountValue, 40, order);
            if (kind === "newOrder") assert.equal(s.sent[0].products[0].discountValue, 40, order);
        }
    });

    test(`M-4 ${kind}: a refused entry typed right before Save / Place order stops it, for both fields and both lines`, () => {
        for (const order of ORDERS) for (const [i, which, bad] of [[0, "disc", "-5"], [0, "disc", "999"], [1, "disc", "101"], [0, "price", "1e5"], [1, "price", ""]]) {
            const s = sheet(kind);
            s.row(i)[which].type(bad); leave(s.row(i)[which], order);
            const p = s.submit();
            assert.ok(p.length >= 1 && p.join(" ").includes(s.line(i).name), JSON.stringify([order, i, which, bad, p]));
            assert.equal(s.sent.length, 0);
            s.row(i)[which].blur(); s.row(i)[which].focus(); s.row(i)[which].blur();
            assert.deepEqual(s.submit(), [], "acknowledged: it goes with what the field shows");
        }
    });

    test(`M-5 ${kind}: the free-line bug: flat 150 switched to % is NOT stored as 150%: it becomes 0, says so, and stops the submit until seen`, () => {
        const s = sheet(kind);
        s.row(0).disc.type("150"); s.row(0).disc.blur();
        s.row(0).pill("percent");
        assert.equal(s.line(0).discountType, "percent");
        assert.equal(s.line(0).discountValue, 0);
        assert.ok(s.error(0, "discount").endsWith("It is now 0"));
        assert.equal(s.row(0).disc.text, "0");
        assert.equal(s.submit().length, 1);
        s.row(0).disc.focus(); s.row(0).disc.blur();
        assert.deepEqual(s.submit(), []);
    });

    test(`M-6 ${kind}: pill with the text still in the field reads it under the NEW type`, () => {
        const s = sheet(kind);
        s.row(0).disc.type("15");
        s.row(0).pill("percent");
        assert.deepEqual([s.line(0).discountType, s.line(0).discountValue, s.error(0, "discount")], ["percent", 15, ""]);
        const r = sheet(kind, { lines: [Object.assign(baseLines()[0], { price: 10, quantity: 1, discountType: "percent", discountValue: 5 })] });
        r.row(0).disc.type("50");
        r.row(0).pill("flat");
        assert.deepEqual([r.line(0).discountType, r.line(0).discountValue], ["flat", 0]);
        assert.ok(r.error(0, "discount").includes(money(10)));
    });

    test(`M-7 ${kind}: tapping the selected side does nothing to the line or to the text being typed`, () => {
        const s = sheet(kind);
        s.row(0).disc.type("15");
        s.row(0).pill("flat");
        assert.equal(s.line(0).discountValue, 5);
        if (kind === "newOrder") assert.equal(s.row(0).disc.text, "15");
        assert.deepEqual(s.submit(), []);
        if (kind === "newOrder") assert.equal(s.line(0).discountValue, 15);
    });

    test(`M-8 ${kind}: a pill on one row commits the field in use on another row first`, () => {
        const s = sheet(kind);
        s.row(1).price.type("55");
        s.row(0).pill("percent");
        assert.equal(s.line(1).price, 55);
        assert.equal(s.line(0).discountType, "percent");
    });

    test(`M-9 ${kind}: lowering the price under a flat discount stops the submit and names the limit`, () => {
        const s = sheet(kind);
        s.row(0).disc.type("200"); s.row(0).disc.blur();
        s.row(0).price.type("50"); s.row(0).price.blur();
        const p = s.submit();
        assert.equal(p.length, 1);
        assert.ok(p[0].includes(money(150)) && p[0].includes("Tomato"), p[0]);
        s.row(0).disc.type("150"); s.row(0).disc.blur();
        assert.deepEqual(s.submit(), []);
    });

    test(`M-10 ${kind}: monkey: 600 sessions of typing, Enter, focus moves, pills and submits: whatever goes out is inside the limits and no refusal stands`, () => {
        let seed = 20261127, went = 0, stopped = 0;
        const rnd = () => (seed = (seed * 1664525 + 1013904223) % 4294967296) / 4294967296;
        const pick = (a) => a[Math.floor(rnd() * a.length)];
        const texts = ["", "0", "5", "99.5", "100", "101", "300", "301", "1,5", "abc", "-5", "1e2", "1000000001", " 7 ", "."];
        for (let n = 0; n < 600; n++) {
            const s = sheet(kind);
            for (let step = 0; step < 14; step++) {
                const i = Math.floor(rnd() * 2), which = pick(["price", "disc"]);
                const others = () => { for (let k = 0; k < 2; k++) for (const w of ["price", "disc"]) if (k !== i || w !== which) s.row(k)[w].blur(pick(ORDERS.slice(0, 2))); };
                switch (pick(["type", "type", "type", "enter", "blur", "focus", "pill", "submit"])) {
                case "type": others(); s.row(i)[which].type(pick(texts)); break;
                case "enter": if (s.row(i)[which].focused) s.row(i)[which].enter(); break;
                case "blur": s.row(i)[which].blur(pick(ORDERS.slice(0, 2))); break;
                case "focus": others(); s.row(i)[which].focus(); break;
                case "pill": s.row(i).pill(pick(["flat", "percent"])); break;
                case "submit": {
                    const p = s.submit();
                    if (p.length) { stopped++; break; }
                    went++;
                    for (let k = 0; k < 2; k++) {
                        const l = s.line(k), qty = l.quantity !== undefined ? l.quantity : l.qty;
                        assert.ok(l.price >= 0 && l.price <= 1e9, "price " + n);
                        assert.ok(OF.discountFits(l.discountValue, l.discountType, l.price * qty), "session " + n + " " + JSON.stringify(l));
                        assert.equal(s.error(k, "price") + s.error(k, "discount"), "", "session " + n);
                    }
                }
                }
                for (let k = 0; k < 2; k++) assert.ok(Number.isFinite(s.line(k).price) && s.line(k).discountValue >= 0, "session " + n);
            }
        }
        assert.ok(went > 50 && stopped > 50, `both outcomes must be reached (went ${went}, stopped ${stopped})`);
    });
}

// ---- Edit Order only ----------------------------------------------------------------------------------------------------
test("M-11 edit: the price field reads like New Order's: a bad entry keeps the price, says why, and recomputes nothing", () => {
    const s = sheet("edit");
    for (const [t, reason] of [["-5", "invalid"], ["1e5", "invalid"], ["1,5", "invalid"], ["", "blank"], ["9".repeat(20), "large"]]) {
        s.row(0).price.type(t); s.row(0).price.blur();
        assert.equal(s.line(0).price, 100, t);
        assert.equal(s.error(0, "price"), OF.priceText(reason), t);
        assert.equal(s.row(0).price.text, money(100), t);
    }
    assert.equal(s.ctx.recomputes, 0);
    s.row(0).price.type("80"); s.row(0).price.blur();
    assert.equal(s.line(0).price, 80);
    assert.equal(s.ctx.recomputes, 1);
    for (const order of ["finished-first", "focus-first"]) {
        s.row(0).price.type("90"); s.row(0).price.blur(order);
        assert.equal(s.line(0).price, 90, order);
        s.row(0).price.type("100"); s.row(0).price.blur();
    }
    // Enter commits with the field still focused: plain number, never the formatted text (typing would append to it)
    for (const [t, kept] of [["70", "70"], ["abc", "70"]]) {
        s.row(0).price.type(t); s.row(0).price.enter();
        assert.equal(s.row(0).price.text, kept, t);
    }
});

test("M-12 edit: _save settles the field first, blocks on the line problems before anything is sent, and both row roles are seeded and never saved", () => {
    const src = read("OrderDetailDialog.qml");
    const save = extractFunction("pages/OrderDetailDialog.qml", "_save");
    const at = (n) => { const i = save.indexOf(n); assert.ok(i >= 0, n); return i; };
    assert.ok(at("if (busy) return") < at("_settleFieldEdit()"));
    assert.ok(at("_settleFieldEdit()") < at("_lockState !== \"granted\""));
    assert.ok(at("_settleFieldEdit()") < at("products.get(i)"));
    assert.ok(at("_lineProblems().concat(_stockErrors())") < at("adjustRequested("));
    assert.ok(at("_lineProblems().concat(_stockErrors())") < at("logic.updateOrder("));
    assert.ok(!/priceError|discountError/.test(save), "the message roles are not part of a saved line");
    assert.match(extractFunction("pages/OrderDetailDialog.qml", "openFor"), /priceError: "",\s*discountError: ""/);
    const s = sheet("edit");
    assert.deepEqual(Object.keys(s.ctx._lineItemArray()[0]).filter((k) => /Error/.test(k)), []);
    assert.match(src, /id: lineRepeater\s+model: products/);
    for (const role of ["priceError", "discountError"]) {
        assert.match(src, new RegExp("property string " + role + ": model\\." + role));
        assert.match(src, new RegExp("visible: row\\." + role + "\\.length > 0\\s+text: row\\." + role + "\\s+color: Constants\\.danger[\\s\\S]{0,120}wrapMode: Text\\.Wrap"));
        assert.match(src, new RegExp("Accessible\\.description: row\\." + role));
        assert.match(src, new RegExp("border\\.color: row\\." + role + "\\.length > 0 \\? Constants\\.danger"));
    }
});

test("M-13 neither sheet reads typed text leniently any more", () => {
    for (const spec of Object.values(SHEETS)) {
        const src = read(spec.file);
        assert.ok(!/replace\(\/\[\^0-9\.\]\/g/.test(src), spec.file);
        assert.ok(!/parseFloat\(\s*String\(text\)/.test(src), spec.file);
    }
    const nd = read("NewOrderDialog.qml");
    assert.match(nd, /visible: cartRow\.discountError\.length > 0\s+text: cartRow\.discountError\s+color: Constants\.danger/);
    assert.match(nd, /Accessible\.description: cartRow\.discountError/);
});

test("M-14 edit: a saved line with an odd discount does not block a save; changing it does", () => {
    const odd = { productId: "P1", name: "Tomato", price: 100, quantity: 1, discountType: "flat", discountValue: 150, taxable: false, taxPercent: 0 };
    const s = sheet("edit", { lines: [Object.assign({}, odd)], saved: [Object.assign({}, odd)] });
    assert.deepEqual(s.submit(), []);
    s.row(0).price.type("99"); s.row(0).price.blur();
    assert.equal(s.submit().length, 1);
    const fresh = sheet("edit", { lines: [Object.assign({}, odd)], saved: [] });
    assert.equal(fresh.submit().length, 1);
});

test("M-15 edit: a field that commits after its row was removed changes nothing and does not throw", () => {
    const s = sheet("edit");
    const row = s.row(0);
    row.price.type("70"); row.disc.focus();
    s.ctx.products.rows.splice(0, 1);
    row.price.blur(); row.disc.blur();
    row.pill("percent");
    assert.equal(s.ctx.products.count, 1);
    assert.deepEqual([s.line(0).price, s.line(0).discountType, s.line(0).discountValue], [40, "percent", 10]);
});
