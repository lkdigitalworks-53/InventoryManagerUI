"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const BreakdownMath = require("../lib/breakdownMath");
const fixtures = require("./fixtures/breakdownMathFixtures");

function byName(name) {
    const f = fixtures.find((x) => x.name === name);
    assert.ok(f, "fixture not found: " + name);
    return f;
}

test("sold_by_category_nets_returns", () => {
    const f = byName("sold_by_category_nets_returns");
    const byCat = BreakdownMath.breakdown({
        metric: "sold", dim: "category", entries: f.entries,
        window: null, channel: "", staffId: "", category: "", supplierId: "",
        productCategory: f.productCategory, supplierName: f.supplierName
    });
    assert.deepEqual(byCat, f.expected.byCategory);

    const bySup = BreakdownMath.breakdown({
        metric: "sold", dim: "supplier", entries: f.entries,
        window: null, channel: "", staffId: "", category: "", supplierId: "",
        productCategory: f.productCategory, supplierName: f.supplierName
    });
    assert.deepEqual(bySup, f.expected.bySupplier);
});

test("purchased_by_supplier", () => {
    const f = byName("purchased_by_supplier");
    const byCat = BreakdownMath.breakdown({
        metric: "purchased", dim: "category", entries: f.entries,
        window: null, channel: "", staffId: "", category: "", supplierId: "",
        productCategory: f.productCategory, supplierName: f.supplierName
    });
    assert.deepEqual(byCat, f.expected.byCategory);

    const bySup = BreakdownMath.breakdown({
        metric: "purchased", dim: "supplier", entries: f.entries,
        window: null, channel: "", staffId: "", category: "", supplierId: "",
        productCategory: f.productCategory, supplierName: f.supplierName
    });
    assert.deepEqual(bySup, f.expected.bySupplier);
});
