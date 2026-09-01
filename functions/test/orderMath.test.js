"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const OrderMath = require("../lib/orderMath");
const fixtures = require("./fixtures/orderMathFixtures");

function _round2(x) { return Math.round(x * 100) / 100; }

function byName(list, name) {
    const f = list.find((x) => x.name === name);
    assert.ok(f, "fixture not found: " + name);
    return f;
}

test("lineTax: single_rate_matches_legacy", () => {
    const f = byName(fixtures.lineTax, "single_rate_matches_legacy");
    for (const c of f.cases) {
        assert.equal(_round2(OrderMath.lineTax(c.line, c.opts)), c.expected);
    }
});

test("lineTax: vintage_split", () => {
    const f = byName(fixtures.lineTax, "vintage_split");
    for (const c of f.cases) {
        assert.equal(_round2(OrderMath.lineTax(f.line, c.opts)), c.expected);
    }
    assert.equal(_round2(OrderMath.lineTax(f.extra.line, f.extra.opts)), f.extra.expected);
});

test("lineTax: zero_qty_guard", () => {
    const f = byName(fixtures.lineTax, "zero_qty_guard");
    assert.equal(OrderMath.lineTax(f.line, f.opts), f.expected);
});

test("lineTax: explicit_current_rate", () => {
    const f = byName(fixtures.lineTax, "explicit_current_rate");
    for (const c of f.cases) {
        assert.equal(_round2(OrderMath.lineTax(f.line, c.opts)), c.expected);
    }
    assert.equal(_round2(OrderMath.lineTax(f.extra.line, f.extra.opts)), f.extra.expected);
});

test("lineTax: percent_discount_type", () => {
    const f = byName(fixtures.lineTax, "percent_discount_type");
    for (const c of f.cases) {
        assert.equal(_round2(OrderMath.lineTax(c.line, c.opts)), c.expected);
    }
});

test("lineTax: flat_discount_clamps", () => {
    const f = byName(fixtures.lineTax, "flat_discount_clamps");
    for (const c of f.cases) {
        assert.equal(_round2(OrderMath.lineTax(c.line, c.opts)), c.expected);
    }
});

test("lineTax: null_line_and_non_numeric_price", () => {
    const f = byName(fixtures.lineTax, "null_line_and_non_numeric_price");
    for (const c of f.cases) {
        assert.equal(OrderMath.lineTax(c.line, c.opts), c.expected);
    }
});

test("lineTax: taxable_true_zero_rate", () => {
    const f = byName(fixtures.lineTax, "taxable_true_zero_rate");
    assert.equal(OrderMath.lineTax(f.line, f.opts), f.expected);
});

test("lineTax: negative_original_qty_clamps", () => {
    const f = byName(fixtures.lineTax, "negative_original_qty_clamps");
    assert.equal(_round2(OrderMath.lineTax(f.line, f.opts)), f.expected);
});

test("refundPerUnit: original_sale_event", () => {
    const f = byName(fixtures.refundPerUnit, "original_sale_event");
    assert.equal(_round2(OrderMath.refundPerUnit(f.saleEvent)), f.expected);
});

test("refundPerUnit: guards", () => {
    const f = byName(fixtures.refundPerUnit, "guards");
    for (const c of f.cases) {
        assert.equal(OrderMath.refundPerUnit(c.saleEvent), c.expected);
    }
});
