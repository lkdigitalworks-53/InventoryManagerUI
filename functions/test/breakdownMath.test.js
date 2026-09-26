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

    const byNameResult = BreakdownMath.breakdown({
        metric: "sold", dim: "name", entries: f.entries,
        window: null, channel: "", staffId: "", category: "", supplierId: "",
        productCategory: f.productCategory, supplierName: f.supplierName,
        productName: f.productName
    });
    assert.deepEqual(byNameResult, f.expected.byName);
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

    const byNameResult = BreakdownMath.breakdown({
        metric: "purchased", dim: "name", entries: f.entries,
        window: null, channel: "", staffId: "", category: "", supplierId: "",
        productCategory: f.productCategory, supplierName: f.supplierName,
        productName: f.productName
    });
    assert.deepEqual(byNameResult, f.expected.byName);
});

// ── DELETED-PRODUCT FALLBACK (DELETE-FEATURE-ROADMAP item 3, 2026-09-26) ──
// Mirrors qml/tests/tst_BreakdownMath.qml's matching cases -- keeps the QML
// and Node ports proven in lockstep. Inline fixtures (not the shared
// fixtures file) since these are regression cases for one specific bug, not
// general-shape coverage.
test("purchased_by_category_deleted_product_uses_stamped_value", () => {
    const entries = [
        { kind: "purchase", timestamp: "2026-06-15T10:00:00", productId: "P9", party: "S1", quantity: 4, category: "Beverages" }
    ];
    const byCat = BreakdownMath.breakdown({
        metric: "purchased", dim: "category", entries, window: null,
        channel: "", staffId: "", category: "", supplierId: "",
        productCategory: { P1: "Drinks" }, supplierName: {}
    });
    assert.equal(byCat["Beverages"], 4);
    assert.equal(byCat["(uncategorised)"], undefined);
});

test("purchased_by_name_deleted_product_uses_stamped_value", () => {
    const entries = [
        { kind: "purchase", timestamp: "2026-06-15T10:00:00", productId: "P9", party: "S1", quantity: 4, productName: "Discontinued Widget" }
    ];
    const byName = BreakdownMath.breakdown({
        metric: "purchased", dim: "name", entries, window: null,
        channel: "", staffId: "", category: "", supplierId: "",
        productCategory: {}, supplierName: {}, productName: { P1: "Cola" }
    });
    assert.equal(byName["Discontinued Widget"], 4);
    assert.equal(byName["P9"], undefined);
});

test("sold_by_category_deleted_product_uses_stamped_value", () => {
    const entries = [
        { kind: "sale", timestamp: "2026-06-15T10:00:00", productId: "P9", quantity: 6,
          orderChannel: "", staffId: "", category: "Beverages",
          consumption: [{ supplierId: "S1", qtyConsumed: 6 }] }
    ];
    const byCat = BreakdownMath.breakdown({
        metric: "sold", dim: "category", entries, window: null,
        channel: "", staffId: "", category: "", supplierId: "",
        productCategory: {}, supplierName: {}
    });
    assert.equal(byCat["Beverages"], 6);
});

test("live_product_current_category_wins_over_stale_stamped_value", () => {
    // Regression guard: P1 still exists -- its CURRENT live category must
    // keep winning over whatever happened to be stamped on an old entry.
    const entries = [
        { kind: "purchase", timestamp: "2026-06-15T10:00:00", productId: "P1", party: "S1", quantity: 4, category: "OldCategoryAtSaleTime" }
    ];
    const byCat = BreakdownMath.breakdown({
        metric: "purchased", dim: "category", entries, window: null,
        channel: "", staffId: "", category: "", supplierId: "",
        productCategory: { P1: "Drinks" }, supplierName: {}
    });
    assert.equal(byCat["Drinks"], 4);
    assert.equal(byCat["OldCategoryAtSaleTime"], undefined);
});
