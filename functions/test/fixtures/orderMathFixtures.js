"use strict";

// Parity fixtures for OrderMath.lineTax / OrderMath.refundPerUnit -- proves
// the Node port (functions/lib/orderMath.js) agrees with the QML original
// (qml/helper/OrderMath.js) on the same inputs. Scoped to these two
// functions only (the roadmap item's identified gap) -- allocate/
// spreadOrderDelta/spreadLineDeltaBySupplier/eventProfit are out of scope
// here; their own coverage state is unrelated to this fixture file.
//
// PAIRED FILE: tests/tst_OrderMathParityFixtures.qml holds the SAME literal
// scenario data (manually mirrored -- same convention as
// realisedMathFixtures.js/tst_RealisedMathParityFixtures.qml). If you change
// a scenario here, change it there too, and vice versa.
//
// Every scenario's inputs/expected values are copied from an existing,
// already-verified case in tests/tst_OrderMath.qml (not invented fresh) --
// the "new" ones below (percent-discount-type, discount clamps, null-line,
// taxable-zero-rate, negative-originalQty) were added to tst_OrderMath.qml
// in this same change specifically because they were the branches this
// coverage push found missing, then sourced from there like every other
// scenario in this file.

module.exports = {
    lineTax: [
        {
            name: "single_rate_matches_legacy",
            cases: [
                { line: { quantity: 2, price: 20, taxable: true, taxPercent: 10,
                           discountType: "flat", discountValue: 0 },
                  opts: undefined, expected: 4 },
                { line: { quantity: 2, price: 20, taxable: false, taxPercent: 10 },
                  opts: undefined, expected: 0 },
                { line: { quantity: 2, price: 20, taxable: true, taxPercent: 10,
                           discountType: "flat", discountValue: 5 },
                  opts: undefined, expected: 3.5 }
            ]
        },
        {
            name: "vintage_split",
            // All five share the same base line; only opts differ.
            line: { quantity: 2, price: 20, taxable: true, taxPercent: 10,
                     discountType: "flat", discountValue: 0 },
            cases: [
                { opts: { originalQty: 1, bookedRate: 0 }, expected: 2 },
                { opts: { originalQty: 2, bookedRate: 0 }, expected: 0 },
                { opts: { originalQty: 5, bookedRate: 0 }, expected: 0 },
                { opts: { originalQty: 1, bookedRate: 5 }, expected: 3 },
                { opts: { originalQty: 0, bookedRate: 5 }, expected: 4 }
            ],
            // Same opts as the first case above, different line (discount 10 flat).
            extra: {
                line: { quantity: 2, price: 20, taxable: true, taxPercent: 10,
                         discountType: "flat", discountValue: 10 },
                opts: { originalQty: 1, bookedRate: 0 },
                expected: 1.5
            }
        },
        {
            name: "zero_qty_guard",
            line: { quantity: 0, price: 20, taxable: true, taxPercent: 10 },
            opts: { originalQty: 0, bookedRate: 0 },
            expected: 0
        },
        {
            name: "explicit_current_rate",
            line: { quantity: 2, price: 20, taxable: false, taxPercent: 0,
                     discountType: "flat", discountValue: 0 },
            cases: [
                { opts: { originalQty: 1, bookedRate: 0 }, expected: 0 },
                { opts: { originalQty: 1, bookedRate: 0, currentRate: 10 }, expected: 2 },
                { opts: { originalQty: 1, bookedRate: 0, currentRate: 0 }, expected: 0 }
            ],
            extra: {
                line: { quantity: 2, price: 20, taxable: false, taxPercent: 0,
                         discountType: "flat", discountValue: 2 },
                opts: { originalQty: 1, bookedRate: 0, currentRate: 10 },
                expected: 1.9
            }
        },
        {
            name: "percent_discount_type",
            cases: [
                { line: { quantity: 2, price: 100, taxable: true, taxPercent: 10,
                           discountType: "percent", discountValue: 15 },
                  opts: undefined, expected: 17 },
                { line: { quantity: 2, price: 100, taxable: true, taxPercent: 10,
                           discountType: "percent", discountValue: -5 },
                  opts: undefined, expected: 20 },
                { line: { quantity: 2, price: 100, taxable: true, taxPercent: 10,
                           discountType: "percent", discountValue: 150 },
                  opts: undefined, expected: 0 },
                { line: { quantity: 2, price: 100, taxable: true, taxPercent: 10,
                           discountType: "percent" },
                  opts: undefined, expected: 20 }
            ]
        },
        {
            name: "flat_discount_clamps",
            cases: [
                { line: { quantity: 2, price: 100, taxable: true, taxPercent: 10,
                           discountType: "flat", discountValue: -10 },
                  opts: undefined, expected: 20 },
                { line: { quantity: 2, price: 100, taxable: true, taxPercent: 10,
                           discountType: "flat", discountValue: 500 },
                  opts: undefined, expected: 0 }
            ]
        },
        {
            name: "null_line_and_non_numeric_price",
            cases: [
                { line: null, opts: undefined, expected: 0 },
                { line: undefined, opts: undefined, expected: 0 },
                { line: { quantity: 3, taxable: true, taxPercent: 10 }, opts: undefined, expected: 0 }
            ]
        },
        {
            name: "taxable_true_zero_rate",
            line: { quantity: 2, price: 20, taxable: true, taxPercent: 0,
                     discountType: "flat", discountValue: 0 },
            opts: undefined,
            expected: 0
        },
        {
            name: "negative_original_qty_clamps",
            line: { quantity: 2, price: 20, taxable: true, taxPercent: 10,
                     discountType: "flat", discountValue: 0 },
            opts: { originalQty: -3, bookedRate: 0 },
            expected: 4
        }
    ],
    refundPerUnit: [
        {
            name: "original_sale_event",
            saleEvent: { kind: "sale", productId: "P1", quantity: 4, net: 360, tax: 36,
                         consumption: [{ batchId: "B1", supplierId: "S1", qtyConsumed: 4, unitCost: 50 }] },
            expected: 99
        },
        {
            name: "guards",
            cases: [
                { saleEvent: null, expected: 0 },
                { saleEvent: { quantity: 0, net: 100, tax: 0 }, expected: 0 },
                { saleEvent: { quantity: 2 }, expected: 0 }
            ]
        }
    ]
};
