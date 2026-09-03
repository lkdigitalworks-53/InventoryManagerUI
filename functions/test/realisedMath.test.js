"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const RealisedMath = require("../lib/realisedMath");
const fixtures = require("./fixtures/realisedMathFixtures");

function _round2(x) { return Math.round(x * 100) / 100; }

function byName(name) {
    const f = fixtures.find((x) => x.name === name);
    assert.ok(f, "fixture not found: " + name);
    return f;
}

test("sale_plus_return_nets_down", () => {
    const f = byName("sale_plus_return_nets_down");
    const t = RealisedMath.totals(f.entries, f.scope, f.lookups);
    assert.equal(_round2(t.net), f.expected.totals.net);
    assert.equal(_round2(t.cogs), f.expected.totals.cogs);
    assert.equal(_round2(t.profit), f.expected.totals.profit);

    const m = RealisedMath.byDimension(f.expected.byDimension.field, f.entries, f.scope, f.lookups);
    const row = m[f.expected.byDimension.key];
    assert.ok(row, "expected key missing from byDimension result");
    assert.equal(_round2(row.revenue), f.expected.byDimension.revenue);
    assert.equal(_round2(row.profit), f.expected.byDimension.profit);
});

test("supplier_filter_includes_stamped_price_adjust", () => {
    const f = byName("supplier_filter_includes_stamped_price_adjust");

    const tS1 = RealisedMath.totals(f.entries, f.scopeSupplierS1, f.lookups);
    assert.equal(_round2(tS1.net), f.expected.filteredS1.net);
    assert.equal(_round2(tS1.discount), f.expected.filteredS1.discount);

    const tS2 = RealisedMath.totals(f.entries, f.scopeSupplierS2, f.lookups);
    assert.equal(_round2(tS2.net), f.expected.filteredS2.net);

    const tAll = RealisedMath.totals(f.entries, null, f.lookups);
    assert.equal(_round2(tAll.net), f.expected.unfiltered.net);
});

test("no_net_fails_closed", () => {
    const f = byName("no_net_fails_closed");
    const m = RealisedMath.byDimension(f.expected.byDimension.field, f.entries, f.scope, f.lookups);
    const row = m[f.expected.byDimension.key];
    assert.ok(row, "expected key missing from byDimension result");
    assert.equal(_round2(row.revenue), f.expected.byDimension.revenue);
    assert.equal(_round2(row.cogs), f.expected.byDimension.cogs);
});

test("price_adjust_discount_column", () => {
    const f = byName("price_adjust_discount_column");
    const m = RealisedMath.byDimension(f.expected.byDimension.field, f.entries, f.scope, f.lookups);
    const row = m[f.expected.byDimension.key];
    assert.ok(row, "expected key missing from byDimension result");
    assert.equal(_round2(row.revenue), f.expected.byDimension.revenue);
    assert.equal(_round2(row.discount), f.expected.byDimension.discount);
});

// Cross-check the core invariant (Skill 29): Sum byDimension(any field) == totals,
// on the richest fixture available (the sale+return scenario, which has both a
// sale and a return event).
test("invariant: sum(byDimension) == totals for every field", () => {
    const f = byName("sale_plus_return_nets_down");
    const t = RealisedMath.totals(f.entries, f.scope, f.lookups);
    const fields = ["productId", "supplierId", "category", "channel", "staffId"];
    for (const field of fields) {
        const m = RealisedMath.byDimension(field, f.entries, f.scope, f.lookups);
        let sumRevenue = 0, sumProfit = 0, sumCogs = 0;
        for (const k of Object.keys(m)) {
            sumRevenue += m[k].revenue;
            sumProfit += m[k].profit;
            sumCogs += m[k].cogs;
        }
        assert.equal(_round2(sumRevenue), _round2(t.net), "field=" + field + " revenue");
        assert.equal(_round2(sumProfit), _round2(t.profit), "field=" + field + " profit");
        assert.equal(_round2(sumCogs), _round2(t.cogs), "field=" + field + " cogs");
    }
});

// 2026-09-02 fix (SKILLS Skill 57): price_adjust events must contribute a
// proportional tax delta, not just revenue. Reproduces Taher's own bug
// numbers end to end through the Node port.
test("price_adjust_tax_share_no_scope_supplier_dimension", () => {
    const f = byName("price_adjust_tax_share_no_scope_supplier_dimension");
    const t = RealisedMath.totals(f.entries, f.scope, f.lookups);
    assert.equal(_round2(t.net), f.expected.totals.net, "net settles at the discounted 57");
    assert.equal(_round2(t.tax), f.expected.totals.tax,
        "THE bug: tax must move off the stale 3 to the discounted 2.85, not stay frozen");

    const m = RealisedMath.byDimension(f.expected.byDimension.field, f.entries, f.scope, f.lookups);
    const row = m[f.expected.byDimension.key];
    assert.ok(row, "expected key missing from byDimension result");
    assert.equal(_round2(row.revenue), f.expected.byDimension.revenue);
    assert.equal(_round2(row.tax), f.expected.byDimension.tax);
    assert.equal(_round2(row.discount), f.expected.byDimension.discount);
});

test("price_adjust_tax_share_supplier_filtered", () => {
    const f = byName("price_adjust_tax_share_supplier_filtered");

    const tS1 = RealisedMath.totals(f.entries, f.scopeSupplierS1, f.lookups);
    assert.equal(_round2(tS1.net), f.expected.filteredS1.net);
    assert.equal(_round2(tS1.tax), f.expected.filteredS1.tax,
        "supplier-filtered path (byDimension's OWN price_adjust branch) must also fold in tax");

    const tS2 = RealisedMath.totals(f.entries, f.scopeSupplierS2, f.lookups);
    assert.equal(_round2(tS2.net), f.expected.filteredS2.net, "unrelated supplier sees neither");
    assert.equal(_round2(tS2.tax), f.expected.filteredS2.tax);
});

test("price_adjust_tax_no_lineage_unknown_bucket", () => {
    const f = byName("price_adjust_tax_no_lineage_unknown_bucket");
    const m = RealisedMath.byDimension(f.expected.byDimension.field, f.entries, f.scope, f.lookups);
    const row = m[f.expected.byDimension.key];
    assert.ok(row, "expected key missing from byDimension result");
    // No supplier lineage -> the WHOLE event's tax lands unsplit in the ""
    // bucket, not proportioned (there's nothing to proportion it across).
    assert.equal(_round2(row.revenue), f.expected.byDimension.revenue);
    assert.equal(_round2(row.tax), f.expected.byDimension.tax);
});

// The reconciliation invariant must still hold with tax now flowing through
// price_adjust events too -- proves the fix didn't just move the number
// somewhere convenient, it kept byDimension summing to totals.
test("invariant: sum(byDimension) == totals for every field, with a taxable price_adjust present", () => {
    const f = byName("price_adjust_tax_share_no_scope_supplier_dimension");
    const t = RealisedMath.totals(f.entries, f.scope, f.lookups);
    const fields = ["productId", "supplierId", "category", "channel", "staffId"];
    for (const field of fields) {
        const m = RealisedMath.byDimension(field, f.entries, f.scope, f.lookups);
        let sumTax = 0;
        for (const k of Object.keys(m)) sumTax += m[k].tax;
        assert.equal(_round2(sumTax), _round2(t.tax), "field=" + field + " tax");
    }
});
