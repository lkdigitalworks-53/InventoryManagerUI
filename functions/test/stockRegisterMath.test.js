"use strict";

// P1 S4a: StockRegisterMath (opening / IN / OUT per kind / closing per product). Pure tests, no
// Firebase. Layers: unit (SR-01..), boundaries, skipped rows, cross-check, regression against
// the REAL server row builder (movementLogic), property tests (period chaining) and a seeded
// monkey run against a brute-force oracle.

const test = require("node:test");
const assert = require("node:assert/strict");

const Reg = require("../lib/stockRegisterMath");
const Movement = require("../lib/movementLogic");

const T0 = Date.parse("2026-04-01T00:00:00Z");
const DAY = 24 * 3600 * 1000;
const WIN = { fromMs: T0 + 10 * DAY, toMs: T0 + 20 * DAY }; // [day 10, day 20)

function row(productId, kind, qty, atMs, extra) {
    return Object.assign({ productId: productId, kind: kind, qty: qty, serverTimestamp: new Date(atMs) }, extra || {});
}
function inv(productId, stock, name) {
    return { productId: productId, name: name === undefined ? productId.toUpperCase() : name, stock: stock };
}
function find(reg, id) { return reg.products.find(function (p) { return p.productId === id; }); }

// ── toMillis ────────────────────────────────────────────────────────────────

test("SR-01 toMillis: Date, Firestore-like Timestamp, plain seconds/nanoseconds, _seconds, epoch ms, ISO with offset", () => {
    const d = new Date("2026-04-01T10:00:00Z");
    assert.equal(Reg.toMillis(d), d.getTime());
    assert.equal(Reg.toMillis({ toMillis: () => 5 }), 5);
    assert.equal(Reg.toMillis({ toDate: () => d }), d.getTime());
    assert.equal(Reg.toMillis({ seconds: 10, nanoseconds: 500000000 }), 10500);
    assert.equal(Reg.toMillis({ _seconds: 10, _nanoseconds: 1000000 }), 10001);
    assert.equal(Reg.toMillis({ seconds: 10 }), 10000);
    assert.equal(Reg.toMillis(1234), 1234);
    assert.equal(Reg.toMillis("2026-04-01T05:30:00+05:30"), Date.parse("2026-04-01T00:00:00Z"));
});

test("SR-02 toMillis: everything else is NaN (null, undefined, NaN, Infinity, junk strings, offset-less ISO, objects, booleans)", () => {
    for (const bad of [null, undefined, NaN, Infinity, -Infinity, "", "x", "2026-04-01", "2026-04-01T00:00:00", "1700000000000",
        {}, [], true, false, { seconds: "10" }, { seconds: NaN }, { toMillis: () => "x" }, { toDate: () => "x" }, () => 1]) {
        assert.ok(Number.isNaN(Reg.toMillis(bad)), "expected NaN for " + String(bad));
    }
});

// ── parseWindow ─────────────────────────────────────────────────────────────

test("SR-03 parseWindow: ms numbers and ISO strings with an offset, from < to", () => {
    const w = Reg.parseWindow("2026-04-01T00:00:00+05:30", "2026-05-01T00:00:00+05:30");
    assert.equal(w.ok, true);
    assert.equal(w.fromMs, Date.parse("2026-03-31T18:30:00Z"));
    assert.equal(w.toMs, Date.parse("2026-04-30T18:30:00Z"));
    assert.deepEqual(Reg.parseWindow(1, 2), { ok: true, fromMs: 1, toMs: 2 });
    assert.deepEqual(Reg.parseWindow(0, 1), { ok: true, fromMs: 0, toMs: 1 });
    assert.equal(Reg.parseWindow(-5, 5).ok, true);
});

test("SR-04 parseWindow: refuses missing, equal, reversed, junk, offset-less, out of range and wrong types", () => {
    const cases = [
        [undefined, 5], [5, undefined], [null, null], [5, 5], [6, 5], ["x", "y"], [NaN, 5], [1, Infinity],
        ["2026-04-01T00:00:00", "2026-05-01T00:00:00"], ["2026-04-01", "2026-05-01"],
        [9e15, 9.1e15], [-9e15, 0], [{}, {}], [[], []], [true, false], ["", ""], ["1", "2"],
        ["2026-05-01T00:00:00Z", "2026-04-01T00:00:00Z"], ["2026-13-45T00:00:00Z", "2026-14-45T00:00:00Z"]
    ];
    for (const c of cases) {
        assert.deepEqual(Reg.parseWindow(c[0], c[1]), { ok: false, error: "invalid-window" }, JSON.stringify(c));
    }
});

// ── roles ───────────────────────────────────────────────────────────────────

test("SR-05 canViewRegister: owner, admin, manager yes; staff and anything else no", () => {
    for (const r of ["owner", "admin", "manager"]) assert.equal(Reg.canViewRegister(r), true);
    for (const r of ["staff", "", "Owner", "viewer", null, undefined, 7, {}]) assert.equal(Reg.canViewRegister(r), false);
});

// ── accumulator: the arithmetic ─────────────────────────────────────────────

test("SR-06 opening = rows before from, IN/OUT per kind inside, closing = opening + net, rows after to ignored", () => {
    const rows = [
        row("p1", "receipt", 100, T0 + 1 * DAY),          // before: opening 100
        row("p1", "sale", -30, T0 + 5 * DAY),             // before: opening 70
        row("p1", "receipt", 50, T0 + 12 * DAY),          // in window
        row("p1", "sale", -20, T0 + 13 * DAY),            // in window
        row("p1", "sales_return", 5, T0 + 14 * DAY),      // in window
        row("p1", "loss", -2, T0 + 15 * DAY),             // in window
        row("p1", "sale", -9, T0 + 25 * DAY)              // after: not in closing
    ];
    const reg = Reg.buildRegister(rows, [inv("p1", 94)], WIN);
    const p = find(reg, "p1");
    assert.equal(p.opening, 70);
    assert.deepEqual(p.kinds.receipt, { in: 50, out: 0 });
    assert.deepEqual(p.kinds.sale, { in: 0, out: 20 });
    assert.deepEqual(p.kinds.sales_return, { in: 5, out: 0 });
    assert.deepEqual(p.kinds.loss, { in: 0, out: 2 });
    assert.equal(p.inTotal, 55);
    assert.equal(p.outTotal, 22);
    assert.equal(p.closing, 103);
    assert.equal(p.ledgerStock, 94); // 70 + 33 - 9
    assert.equal(p.currentStock, 94);
    assert.equal(p.reconciles, true);
    assert.equal(p.movementCount, 7);
    assert.equal(reg.counts.rowsSeen, 7);
    assert.equal(reg.counts.rowsInWindow, 4);
});

test("SR-07 every kind is present in every product row, zero when unused (fixed columns for the UI)", () => {
    const reg = Reg.buildRegister([row("p1", "receipt", 1, WIN.fromMs + 1)], [inv("p1", 1)], WIN);
    assert.deepEqual(Object.keys(find(reg, "p1").kinds), Movement.MOVEMENT_KINDS);
    assert.deepEqual(reg.kinds, Movement.MOVEMENT_KINDS);
    assert.deepEqual(find(reg, "p1").kinds.gift, { in: 0, out: 0 });
});

test("SR-08 adjustment counts IN when positive and OUT when negative, both in one period", () => {
    const rows = [row("p1", "adjustment", 7, WIN.fromMs + 5), row("p1", "adjustment", -3, WIN.fromMs + 9)];
    const p = find(Reg.buildRegister(rows, [inv("p1", 4)], WIN), "p1");
    assert.deepEqual(p.kinds.adjustment, { in: 7, out: 3 });
    assert.equal(p.closing, 4);
});

test("SR-09 period boundaries: from is inclusive, to is exclusive; one instant is never counted twice or skipped", () => {
    const rows = [
        row("p1", "receipt", 1, WIN.fromMs - 1),   // opening
        row("p1", "receipt", 10, WIN.fromMs),      // inside (from inclusive)
        row("p1", "receipt", 100, WIN.toMs - 1),   // inside
        row("p1", "receipt", 1000, WIN.toMs)       // outside (to exclusive)
    ];
    const p = find(Reg.buildRegister(rows, [inv("p1", 1111)], WIN), "p1");
    assert.equal(p.opening, 1);
    assert.equal(p.inTotal, 110);
    assert.equal(p.closing, 111);
});

test("SR-10 two adjacent periods chain: closing of the first equals opening of the second, and nothing is lost", () => {
    const mid = T0 + 15 * DAY;
    const rows = [];
    for (let i = 0; i < 40; i++) rows.push(row("p1", i % 3 === 0 ? "sale" : "receipt", i % 3 === 0 ? -(i + 1) : i + 1, T0 + i * DAY * 0.5));
    const a = find(Reg.buildRegister(rows, [], { fromMs: T0 - DAY, toMs: mid }), "p1");
    const b = find(Reg.buildRegister(rows, [], { fromMs: mid, toMs: T0 + 100 * DAY }), "p1");
    assert.equal(a.closing, b.opening);
    assert.equal(b.closing, a.ledgerStock);
    assert.equal(b.closing, b.ledgerStock);
});

test("SR-11 fractional quantities: float noise is rounded away (0.1 + 0.2), no -0", () => {
    const rows = [row("p1", "receipt", 0.1, WIN.fromMs + 1), row("p1", "receipt", 0.2, WIN.fromMs + 2), row("p1", "sale", -0.3, WIN.fromMs + 3)];
    const p = find(Reg.buildRegister(rows, [inv("p1", 0)], WIN), "p1");
    assert.equal(p.closing, 0);
    assert.ok(Object.is(p.closing, 0), "closing must be +0, not -0");
    assert.equal(p.inTotal, 0.3);
    assert.equal(p.outTotal, 0.3);
    assert.equal(p.reconciles, true);
});

test("SR-11b float noise that sums to a tiny NEGATIVE number rounds to +0, never -0", () => {
    assert.ok(Object.is(Reg.round9(-1e-12), 0));
    assert.ok(Object.is(Reg.round9(-0), 0));
    const rows = [row("p1", "receipt", 0.3, WIN.fromMs + 1), row("p1", "sale", -0.1, WIN.fromMs + 2), row("p1", "sale", -0.2, WIN.fromMs + 3)];
    const p = find(Reg.buildRegister(rows, [inv("p1", 0)], WIN), "p1");
    assert.ok(Object.is(p.closing, 0), "closing " + String(p.closing));
    assert.ok(Object.is(p.ledgerStock, 0));
    assert.equal(p.reconciles, true);
});

test("SR-12 large and tiny quantities keep their sign and magnitude", () => {
    const rows = [row("p1", "receipt", 1e9, WIN.fromMs + 1), row("p1", "sale", -1e-6, WIN.fromMs + 2)];
    const p = find(Reg.buildRegister(rows, [inv("p1", 1e9 - 1e-6)], WIN), "p1");
    assert.equal(p.kinds.sale.out, 1e-6);
    assert.equal(p.closing, round(1e9 - 1e-6));
});
function round(x) { return Reg.round9(x); }

// ── accumulator: which products appear, names, order ────────────────────────

test("SR-13 products: ledger-only product is marked deleted with no name and currentStock 0", () => {
    const rows = [row("gone", "receipt", 5, T0), row("gone", "adjustment", -5, T0 + 1000)];
    const reg = Reg.buildRegister(rows, [], WIN);
    const p = find(reg, "gone");
    assert.equal(p.deleted, true);
    assert.equal(p.name, null);
    assert.equal(p.currentStock, 0);
    assert.equal(p.ledgerStock, 0);
    assert.equal(p.reconciles, true, "delete derives a row taking stock to 0, so a deleted product reconciles");
});

test("SR-14 a product holding stock with NO ledger row appears, does not reconcile, and counts as a mismatch", () => {
    const reg = Reg.buildRegister([], [inv("legacy", 12), inv("empty", 0)], WIN);
    assert.equal(reg.products.length, 1, "a zero-stock product with no rows is noise");
    const p = find(reg, "legacy");
    assert.equal(p.opening, 0);
    assert.equal(p.closing, 0);
    assert.equal(p.ledgerStock, 0);
    assert.equal(p.currentStock, 12);
    assert.equal(p.reconciles, false);
    assert.equal(reg.counts.mismatches, 1);
});

test("SR-15 a ledger that disagrees with the inventory stock is flagged and the BALANCES still come from the ledger", () => {
    const rows = [row("p1", "receipt", 10, WIN.fromMs + 1)];
    const p = find(Reg.buildRegister(rows, [inv("p1", 99)], WIN), "p1");
    assert.equal(p.closing, 10, "closing is the ledger's, not the inventory doc's");
    assert.equal(p.currentStock, 99);
    assert.equal(p.reconciles, false);
});

test("SR-16 a product with rows only AFTER the period still appears (opening 0, closing 0) and reconciles on its ledger total", () => {
    const p = find(Reg.buildRegister([row("p1", "receipt", 4, WIN.toMs + 5)], [inv("p1", 4)], WIN), "p1");
    assert.equal(p.opening, 0);
    assert.equal(p.closing, 0);
    assert.equal(p.ledgerStock, 4);
    assert.equal(p.reconciles, true);
});

test("SR-17 order: named products by name case-insensitively, deleted ones last, product id as tie-break; deterministic", () => {
    const rows = [row("z9", "receipt", 1, WIN.fromMs + 1), row("a1", "receipt", 1, WIN.fromMs + 1),
        row("gone2", "receipt", 1, WIN.fromMs + 1), row("gone1", "receipt", 1, WIN.fromMs + 1),
        row("t1", "receipt", 1, WIN.fromMs + 1), row("t2", "receipt", 1, WIN.fromMs + 1)];
    const products = [inv("z9", 1, "apple"), inv("a1", 1, "Banana"), inv("t1", 1, "Twin"), inv("t2", 1, "twin")];
    const ids = Reg.buildRegister(rows, products, WIN).products.map((p) => p.productId);
    assert.deepEqual(ids, ["z9", "a1", "t1", "t2", "gone1", "gone2"]);
    const again = Reg.buildRegister(rows.slice().reverse(), products.slice().reverse(), WIN).products.map((p) => p.productId);
    assert.deepEqual(again, ids, "input order must not change the output order");
});

test("SR-18 inventory doc without a string name keeps the product, name null but deleted false", () => {
    const p = find(Reg.buildRegister([row("p1", "receipt", 1, WIN.fromMs)], [{ productId: "p1", stock: 1 }], WIN), "p1");
    assert.equal(p.name, null);
    assert.equal(p.deleted, false);
});

test("SR-19 inventory docs: junk entries and duplicate ids are tolerated, first duplicate wins", () => {
    const rows = [row("p1", "receipt", 3, WIN.fromMs)];
    const products = [null, undefined, 5, "x", {}, { productId: "" }, { productId: 7 }, inv("p1", 3, "First"), inv("p1", 99, "Second")];
    const p = find(Reg.buildRegister(rows, products, WIN), "p1");
    assert.equal(p.name, "First");
    assert.equal(p.currentStock, 3);
    assert.equal(p.reconciles, true);
});

test("SR-20 stock that is absent or non-numeric on the inventory doc counts as 0 (same rule as the server's stockOf)", () => {
    const rows = [row("p1", "receipt", 3, WIN.fromMs), row("p1", "adjustment", -3, WIN.fromMs + 1)];
    for (const stock of [undefined, null, "5", NaN, Infinity]) {
        const p = find(Reg.buildRegister(rows, [{ productId: "p1", name: "P", stock: stock }], WIN), "p1");
        assert.equal(p.currentStock, 0);
        assert.equal(p.reconciles, true);
    }
});

// ── skipped rows ────────────────────────────────────────────────────────────

test("SR-21 unclassifiable rows are skipped, counted by reason, and never folded into a balance", () => {
    const good = row("p1", "receipt", 10, WIN.fromMs + 1);
    const rows = [
        good,
        null, undefined, 5, "row", {},                                              // noProduct
        row("", "receipt", 1, WIN.fromMs), { kind: "receipt", qty: 1, serverTimestamp: new Date(WIN.fromMs) },
        row("p1", "bogus", 1, WIN.fromMs), row("p1", undefined, 1, WIN.fromMs),     // badKind
        row("p1", "receipt", 0, WIN.fromMs), row("p1", "receipt", "5", WIN.fromMs), // badQty
        row("p1", "receipt", NaN, WIN.fromMs), row("p1", "receipt", Infinity, WIN.fromMs),
        row("p1", "sale", 4, WIN.fromMs), row("p1", "receipt", -4, WIN.fromMs),     // against the kind's direction
        { productId: "p1", kind: "receipt", qty: 1 },                               // badTime
        { productId: "p1", kind: "receipt", qty: 1, serverTimestamp: "yesterday" },
        { productId: "p1", kind: "receipt", qty: 1, serverTimestamp: null }
    ];
    const reg = Reg.buildRegister(rows, [inv("p1", 10)], WIN);
    assert.equal(find(reg, "p1").closing, 10);
    assert.equal(find(reg, "p1").movementCount, 1);
    assert.deepEqual(reg.counts.skipped, { noProduct: 7, badKind: 2, badQty: 6, badTime: 3 });
    assert.equal(reg.counts.rowsSeen, rows.length);
    assert.equal(reg.counts.rowsInWindow, 1);
});

test("SR-22 adjustment is direction-free: a positive and a negative one are both accepted", () => {
    const reg = Reg.buildRegister([row("p1", "adjustment", 2, WIN.fromMs), row("p1", "adjustment", -1, WIN.fromMs)], [inv("p1", 1)], WIN);
    assert.deepEqual(reg.counts.skipped, { noProduct: 0, badKind: 0, badQty: 0, badTime: 0 });
});

test("SR-23 object keys that look like prototype pollution are ordinary product ids", () => {
    const rows = [row("__proto__", "receipt", 1, WIN.fromMs), row("constructor", "receipt", 2, WIN.fromMs), row("toString", "receipt", 3, WIN.fromMs)];
    const reg = Reg.buildRegister(rows, [], WIN);
    assert.equal(reg.products.length, 3);
    assert.equal(find(reg, "__proto__").closing, 1);
    assert.equal(find(reg, "constructor").closing, 2);
    assert.equal(find(reg, "toString").closing, 3);
    assert.equal(({}).polluted, undefined);
});

test("SR-24 empty ledger and empty inventory: an empty, well-formed register", () => {
    const reg = Reg.buildRegister([], [], WIN);
    assert.deepEqual(reg.products, []);
    assert.deepEqual(reg.counts, { products: 0, rowsSeen: 0, rowsInWindow: 0, mismatches: 0, skipped: { noProduct: 0, badKind: 0, badQty: 0, badTime: 0 } });
    const reg2 = Reg.buildRegister(undefined, undefined, WIN);
    assert.deepEqual(reg2.products, []);
});

test("SR-25 the accumulator is streaming: add() row by row equals buildRegister, and finish() does not mutate its inputs", () => {
    const rows = [row("p1", "receipt", 10, WIN.fromMs), row("p2", "sale", -1, WIN.fromMs + 1)];
    const products = [inv("p1", 10), inv("p2", -1)];
    const frozenRows = JSON.stringify(rows);
    const frozenProducts = JSON.stringify(products);
    const acc = Reg.createAccumulator(WIN);
    for (const r of rows) acc.add(r);
    const streamed = acc.finish(products);
    assert.deepEqual(streamed, Reg.buildRegister(rows, products, WIN));
    assert.equal(JSON.stringify(rows), frozenRows);
    assert.equal(JSON.stringify(products), frozenProducts);
});

test("SR-26 Firestore-Timestamp-shaped serverTimestamp values classify exactly like Dates", () => {
    const at = WIN.fromMs + 1000;
    const shapes = [new Date(at), { toMillis: () => at }, { seconds: Math.floor(at / 1000), nanoseconds: 0 }, { _seconds: Math.floor(at / 1000), _nanoseconds: 0 }, at];
    for (const ts of shapes) {
        const p = find(Reg.buildRegister([{ productId: "p1", kind: "receipt", qty: 3, serverTimestamp: ts }], [], WIN), "p1");
        assert.equal(p.inTotal, 3, JSON.stringify(ts));
    }
});

// ── regression against the REAL server row builder ──────────────────────────

test("SR-27 rows built by the real movementLogic (derive + buildRows) flow into the register with the right kinds", () => {
    const ctx = { productId: "p1", actorUid: "u", actorRole: "owner", serverTimestamp: new Date(WIN.fromMs + 100), clientTimestamp: 1, requestId: "r" };
    const rows = [];
    function put(movs, baseId) { for (const r of Movement.buildRows(movs, Object.assign({ baseId: baseId }, ctx))) rows.push(r.data); }
    put(Movement.deriveForMutation("create", null, { stock: 40 }), "a");                 // create with stock -> receipt
    put(Movement.deriveMovement(-12, "sale"), "b");                                      // completeOrder -> sale
    put(Movement.deriveMovement(3, "sale"), "c");                                        // sale on an increase -> adjustment
    put(Movement.deriveForMutation("update", { stock: 31 }, { stock: 30 }), "d");        // edit -> adjustment -1
    put(Movement.validateMovements([{ kind: "sales_return", qty: 2 }, { kind: "loss", qty: -1, reason: "x" }]).movements, "e");
    put(Movement.deriveForMutation("delete", { stock: 31 }, null), "f");                 // delete -> adjustment to 0
    const reg = Reg.buildRegister(rows, [], WIN);
    const p = find(reg, "p1");
    assert.deepEqual(reg.counts.skipped, { noProduct: 0, badKind: 0, badQty: 0, badTime: 0 }, "the server never writes a row the register cannot read");
    assert.deepEqual(p.kinds.receipt, { in: 40, out: 0 });
    assert.deepEqual(p.kinds.sale, { in: 0, out: 12 });
    assert.deepEqual(p.kinds.sales_return, { in: 2, out: 0 });
    assert.deepEqual(p.kinds.loss, { in: 0, out: 1 });
    assert.deepEqual(p.kinds.adjustment, { in: 3, out: 1 + 31 });
    assert.equal(p.closing, 40 - 12 + 3 - 1 + 2 - 1 - 31);
    assert.equal(p.closing, 0);
    assert.equal(p.reconciles, true, "a product created, sold, edited and deleted ends at 0 with no inventory doc");
});

// ── seeded monkey vs a brute-force oracle ───────────────────────────────────

function lcg(seed) { let s = seed >>> 0; return function () { s = (Math.imul(s, 1664525) + 1013904223) >>> 0; return s / 4294967296; }; }

test("SR-28 monkey: 300 random ledgers x random windows agree with a brute-force oracle; shuffling rows changes nothing", () => {
    const rnd = lcg(20261111);
    const kinds = Movement.MOVEMENT_KINDS;
    for (let run = 0; run < 300; run++) {
        const n = Math.floor(rnd() * 60);
        const pids = ["a", "b", "c", "d"];
        const rows = [];
        for (let i = 0; i < n; i++) {
            const kind = kinds[Math.floor(rnd() * kinds.length)];
            const dir = Movement.KIND_DIRECTION[kind] || (rnd() < 0.5 ? 1 : -1);
            const qty = dir * (Math.floor(rnd() * 50) + 1);
            rows.push(row(pids[Math.floor(rnd() * pids.length)], kind, qty, T0 + Math.floor(rnd() * 40 * DAY)));
        }
        const a = T0 + Math.floor(rnd() * 30 * DAY);
        const win = { fromMs: a, toMs: a + 1 + Math.floor(rnd() * 15 * DAY) };
        const reg = Reg.buildRegister(rows, [], win);
        for (const pid of pids) {
            const mine = rows.filter((r) => r.productId === pid);
            if (mine.length === 0) { assert.equal(find(reg, pid), undefined); continue; }
            const opening = mine.filter((r) => r.serverTimestamp.getTime() < win.fromMs).reduce((s, r) => s + r.qty, 0);
            const inside = mine.filter((r) => r.serverTimestamp.getTime() >= win.fromMs && r.serverTimestamp.getTime() < win.toMs);
            const p = find(reg, pid);
            assert.equal(p.opening, opening);
            assert.equal(p.closing, opening + inside.reduce((s, r) => s + r.qty, 0));
            assert.equal(p.inTotal, inside.filter((r) => r.qty > 0).reduce((s, r) => s + r.qty, 0));
            assert.equal(p.outTotal, 0 - inside.filter((r) => r.qty < 0).reduce((s, r) => s + r.qty, 0));
            assert.equal(p.ledgerStock, mine.reduce((s, r) => s + r.qty, 0));
            assert.equal(p.movementCount, mine.length);
            // identity: closing = opening + IN - OUT
            assert.equal(p.closing, p.opening + p.inTotal - p.outTotal);
        }
        const shuffled = rows.slice().sort(() => rnd() - 0.5);
        assert.deepEqual(Reg.buildRegister(shuffled, [], win), reg);
    }
});

// ── review sweep of PR #193: calendar-impossible instants ────────────────────

test("SR-29 an impossible calendar date is refused, never rolled over to the next month (2026-02-30 is not 2 March)", () => {
    const impossible = [
        "2026-02-30T00:00:00Z", "2026-02-29T00:00:00Z", "2026-04-31T00:00:00+05:30", "2026-06-31T00:00:00Z",
        "2026-09-31T00:00:00Z", "2026-11-31T00:00:00Z", "2026-01-32T00:00:00Z", "2026-00-10T00:00:00Z",
        "2026-13-01T00:00:00Z", "2026-04-00T00:00:00Z", "1900-02-29T00:00:00Z", "2100-02-29T00:00:00Z"
    ];
    for (const s of impossible) {
        assert.ok(Number.isNaN(Reg.toMillis(s)), "toMillis must refuse " + s);
        assert.equal(Reg.parseWindow(s, "2027-01-01T00:00:00Z").ok, false, "from " + s);
        assert.equal(Reg.parseWindow("2020-01-01T00:00:00Z", s).ok, false, "to " + s);
    }
});

test("SR-30 leap days are accepted exactly in leap years (2024, 2000, year 0), refused in 1900, 2100, 2026", () => {
    assert.equal(Reg.toMillis("2024-02-29T00:00:00Z"), Date.UTC(2024, 1, 29));
    assert.equal(Reg.toMillis("2000-02-29T00:00:00Z"), Date.UTC(2000, 1, 29));
    assert.ok(Number.isFinite(Reg.toMillis("0000-02-29T00:00:00Z")), "year 0 is a leap year");
    for (const y of ["1900", "2100", "2026", "2025"]) assert.ok(Number.isNaN(Reg.toMillis(y + "-02-29T00:00:00Z")), y);
    for (const [m, last] of [["01", 31], ["03", 31], ["04", 30], ["06", 30], ["09", 30], ["11", 30], ["12", 31]]) {
        assert.ok(Number.isFinite(Reg.toMillis("2026-" + m + "-" + last + "T00:00:00Z")), m + "-" + last);
        assert.ok(Number.isNaN(Reg.toMillis("2026-" + m + "-" + (last + 1) + "T00:00:00Z")), m + "-" + (last + 1));
    }
});

test("SR-31 clock and zone fields are range checked: hour 24 (next midnight), minute/second 60, zone hour 24, zone minute 60", () => {
    for (const s of ["2026-04-01T24:00:00Z", "2026-04-01T24:00Z", "2026-04-01T23:60:00Z", "2026-04-01T23:59:60Z",
        "2026-04-01T00:00:00+24:00", "2026-04-01T00:00:00+05:60", "2026-04-01T00:00:00-99:99"]) {
        assert.ok(Number.isNaN(Reg.toMillis(s)), s);
    }
    assert.equal(Reg.toMillis("2026-04-30T23:59:59.999999999Z"), Date.UTC(2026, 3, 30, 23, 59, 59, 999));
    assert.equal(Reg.toMillis("2026-04-01T00:00+05:30"), Date.UTC(2026, 2, 31, 18, 30));
    assert.equal(Reg.toMillis("2026-12-31T23:59:59-23:59"), Date.UTC(2027, 0, 1, 23, 58, 59));
});

test("SR-32 monkey: 3000 random Y-M-D strings are accepted exactly when the calendar date exists (oracle: Date round trip)", () => {
    let seed = 20261111;
    function rnd(n) { seed = (seed * 1664525 + 1013904223) >>> 0; return seed % n; }
    let accepted = 0;
    let refused = 0;
    for (let i = 0; i < 3000; i++) {
        const y = 1900 + rnd(250);
        const m = 1 + rnd(14); // 13 and 14 are impossible months
        const d = rnd(34);     // 0 and 32..33 are impossible days
        const str = String(y).padStart(4, "0") + "-" + String(m).padStart(2, "0") + "-" + String(d).padStart(2, "0") + "T00:00:00Z";
        const dt = new Date(Date.UTC(y, m - 1, d));
        const exists = m >= 1 && m <= 12 && d >= 1 && dt.getUTCFullYear() === y && dt.getUTCMonth() === m - 1 && dt.getUTCDate() === d;
        const got = Reg.toMillis(str);
        if (exists) { assert.equal(got, Date.UTC(y, m - 1, d), str); accepted++; }
        else { assert.ok(Number.isNaN(got), "must refuse " + str); refused++; }
    }
    assert.ok(accepted > 1000 && refused > 200, "the run exercised both sides: " + accepted + "/" + refused);
});
