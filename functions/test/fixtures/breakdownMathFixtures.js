"use strict";

// Parity fixtures for BreakdownMath -- proves the Node port
// (functions/lib/breakdownMath.js) agrees with the QML original
// (qml/helper/BreakdownMath.js) on the same inputs.
//
// PAIRED FILE: tests/tst_BreakdownMathParityFixtures.qml holds the SAME
// literal scenario data (manually mirrored -- see the note in
// realisedMathFixtures.js for why this isn't a shared loaded file).

module.exports = [
    {
        name: "sold_by_category_nets_returns",
        entries: [
            { kind: "sale", productId: "P1", quantity: 5, date: "2026-06-20",
              consumption: [{ supplierId: "S1", qtyConsumed: 5 }] },
            { kind: "sale", productId: "P2", quantity: 3, date: "2026-06-20",
              consumption: [{ supplierId: "S2", qtyConsumed: 3 }] },
            { kind: "return", productId: "P1", quantity: -2, date: "2026-06-21",
              consumption: [{ supplierId: "S1", qtyConsumed: -2 }] }
        ],
        productCategory: { P1: "Drinks", P2: "Snacks" },
        supplierName: { S1: "Acme", S2: "Beta" },
        expected: {
            byCategory: { Drinks: 3, Snacks: 3 },
            bySupplier: { Acme: 3, Beta: 3 }
        }
    },
    {
        name: "purchased_by_supplier",
        entries: [
            { kind: "purchase", productId: "P1", quantity: 20, date: "2026-06-15", party: "S1" },
            { kind: "purchase", productId: "P2", quantity: 10, date: "2026-06-16", party: "S2" },
            { kind: "created", productId: "P1", quantity: 5, date: "2026-06-01",
              snapshot: { supplierId: "S1" } }
        ],
        productCategory: { P1: "Drinks", P2: "Snacks" },
        supplierName: { S1: "Acme", S2: "Beta" },
        expected: {
            byCategory: { Drinks: 25, Snacks: 10 },
            bySupplier: { Acme: 25, Beta: 10 }
        }
    }
];
