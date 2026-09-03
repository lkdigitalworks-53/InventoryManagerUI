"use strict";

// Parity fixtures for RealisedMath -- proves the Node port
// (functions/lib/realisedMath.js) agrees with the QML original
// (qml/helper/RealisedMath.js) on the same inputs.
//
// PAIRED FILE: tests/tst_RealisedMathParityFixtures.qml holds the SAME
// literal scenario data (manually mirrored, not loaded from this file --
// QML has no established pattern in this repo for reading an external JSON
// file synchronously in a test, so the two copies are kept in sync by
// discipline, not tooling). If you change a scenario here, change it there
// too, and vice versa.
//
// Every scenario/expected value here is copied from an existing, already-
// verified case in tests/tst_RealisedMath.qml (not invented fresh) --
// specifically the four whose entries are already fully stamped (no
// OrderMath.allocate derivation step needed), so they translate directly
// into static data:
//   - test_sale_plus_return_nets_down
//   - test_supplier_filter_includes_stamped_price_adjust
//   - test_no_net_fails_closed
//   - test_price_adjust_discount_column

module.exports = [
    {
        name: "sale_plus_return_nets_down",
        entries: [
            {
                kind: "sale", timestamp: "2026-06-20T10:00:00Z", productId: "P1", quantity: 4,
                unitPrice: 100, net: 400, tax: 0, discountShare: 0,
                consumption: [{ batchId: "B1", supplierId: "S1", qtyConsumed: 4, unitCost: 60 }]
            },
            {
                kind: "return", timestamp: "2026-06-21T10:00:00Z", productId: "P1", quantity: -1,
                unitPrice: 100, net: -100, tax: 0, discountShare: 0,
                consumption: [{ batchId: "B1", supplierId: "S1", qtyConsumed: -1, unitCost: 60 }]
            }
        ],
        scope: null,
        lookups: {},
        expected: {
            totals: { net: 300, cogs: 180, profit: 120 },
            byDimension: { field: "supplierId", key: "S1", revenue: 300, profit: 120 }
        }
    },
    {
        name: "supplier_filter_includes_stamped_price_adjust",
        entries: [
            {
                kind: "sale", timestamp: "2026-06-20T10:00:00Z", productId: "P1", quantity: 2,
                unitPrice: 100, net: 200, tax: 0, discountShare: 0, orderChannel: "online",
                consumption: [{ batchId: "B1", supplierId: "S1", qtyConsumed: 2, unitCost: 60 }]
            },
            {
                kind: "price_adjust", timestamp: "2026-06-20T11:00:00Z", productId: "P1",
                total: -20, reason: "discount", orderChannel: "online",
                supplierSlices: [{ key: "S1", amount: -20 }]
            }
        ],
        scopeSupplierS1: { supplierId: "S1" },
        scopeSupplierS2: { supplierId: "S2" },
        lookups: {},
        expected: {
            filteredS1: { net: 180, discount: 20 },
            filteredS2: { net: 0 },
            unfiltered: { net: 180 }
        }
    },
    {
        name: "no_net_fails_closed",
        entries: [
            {
                kind: "sale", timestamp: "2026-06-20T10:00:00Z", productId: "P1", quantity: 2,
                unitPrice: 100, // net DELIBERATELY absent (legacy/un-stamped)
                consumption: [{ batchId: "B1", supplierId: "S1", qtyConsumed: 2, unitCost: 40 }]
            }
        ],
        scope: null,
        lookups: {},
        expected: {
            byDimension: { field: "supplierId", key: "S1", revenue: 0, cogs: 80 }
        }
    },
    {
        name: "price_adjust_discount_column",
        entries: [
            {
                kind: "sale", timestamp: "2026-06-20T10:00:00Z", productId: "P1", quantity: 2,
                unitPrice: 100, net: 200, tax: 0, discountShare: 0,
                consumption: [{ batchId: "B1", supplierId: "S1", qtyConsumed: 2, unitCost: 60 }]
            },
            {
                kind: "price_adjust", timestamp: "2026-06-20T11:00:00Z", productId: "P1",
                total: -20, reason: "discount",
                supplierSlices: [{ key: "S1", amount: -20 }]
            }
        ],
        scope: null,
        lookups: {},
        expected: {
            byDimension: { field: "supplierId", key: "S1", revenue: 180, discount: 20 }
        }
    },
    // 2026-09-02 fix (SKILLS Skill 57): a price_adjust event now carries a
    // signed `tax` delta (TransactionStore.recordPriceAdjust), and
    // byDimension/totals must fold it in proportionally to each revenue
    // slice, not just leave it at 0. Reproduces Taher's own bug numbers:
    // cp 50 / sp 60 / tax 5%, 1 unit sold (net 60, tax 3), then a 5% discount
    // edit (price_adjust total -3, tax -0.15) -- expected net 57 / tax 2.85.
    {
        name: "price_adjust_tax_share_no_scope_supplier_dimension",
        entries: [
            {
                kind: "sale", timestamp: "2026-09-02T10:00:00Z", productId: "P1", quantity: 1,
                unitPrice: 60, net: 60, tax: 3, discountShare: 0,
                consumption: [{ batchId: "B1", supplierId: "S1", qtyConsumed: 1, unitCost: 50 }]
            },
            {
                kind: "price_adjust", timestamp: "2026-09-02T11:00:00Z", productId: "P1",
                total: -3, tax: -0.15, reason: "discount",
                supplierSlices: [{ key: "S1", amount: -3 }]
            }
        ],
        scope: null,
        lookups: {},
        expected: {
            totals: { net: 57, tax: 2.85 },
            byDimension: { field: "supplierId", key: "S1", revenue: 57, tax: 2.85, discount: 3 }
        }
    },
    // Same scenario, filtered by the supplier -- exercises byDimension's OWN
    // scope-filtered price_adjust branch (_priceAdjustSupplierAmount +
    // _priceAdjustTaxShare), a different code path from the unfiltered
    // _accumulatePriceAdjust branch the fixture above exercises.
    {
        name: "price_adjust_tax_share_supplier_filtered",
        entries: [
            {
                kind: "sale", timestamp: "2026-09-02T10:00:00Z", productId: "P1", quantity: 1,
                unitPrice: 60, net: 60, tax: 3, discountShare: 0, orderChannel: "online",
                consumption: [{ batchId: "B1", supplierId: "S1", qtyConsumed: 1, unitCost: 50 }]
            },
            {
                kind: "price_adjust", timestamp: "2026-09-02T11:00:00Z", productId: "P1",
                total: -3, tax: -0.15, reason: "discount", orderChannel: "online",
                supplierSlices: [{ key: "S1", amount: -3 }]
            }
        ],
        scopeSupplierS1: { supplierId: "S1" },
        scopeSupplierS2: { supplierId: "S2" },
        lookups: {},
        expected: {
            filteredS1: { net: 57, tax: 2.85 },
            filteredS2: { net: 0, tax: 0 }
        }
    },
    // No supplierSlices AND no orderLookup match (legacy/pre-FIFO event) ->
    // falls to the "Unknown" ("") bucket, which assigns the WHOLE e.tax
    // unsplit (there's nothing to proportion it across) -- a structurally
    // different branch from the two sliced cases above, worth its own case.
    {
        name: "price_adjust_tax_no_lineage_unknown_bucket",
        entries: [
            {
                kind: "sale", timestamp: "2026-09-02T10:00:00Z", productId: "P1", quantity: 1,
                unitPrice: 60, net: 60, tax: 3, discountShare: 0,
                consumption: [{ batchId: "B1", supplierId: "S1", qtyConsumed: 1, unitCost: 50 }]
            },
            {
                kind: "price_adjust", timestamp: "2026-09-02T11:00:00Z", productId: "P1",
                total: -3, tax: -0.15, reason: "discount"
                // no supplierSlices, and lookups.orderLookup below returns null
                // -> _accumulatePriceAdjust's field==="supplierId" branch can't
                // derive lineage either, so this falls to the "" bucket.
            }
        ],
        scope: null,
        lookups: {},
        expected: {
            byDimension: { field: "supplierId", key: "", revenue: -3, tax: -0.15 }
        }
    }
];
