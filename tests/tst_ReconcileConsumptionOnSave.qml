import QtQuick
import QtTest
import "../qml/helper/OrderAdjust.js" as OA

// Dedicated, exhaustive coverage for OrderAdjust.reconcileConsumptionOnSave —
// the fix for the returns/analysis-revenue bug found by Taher 2026-08-19/20
// (device repro + TEMPDBGLogs.txt). Full root-cause writeup: SKILLS.md
// Skill 42, docs/superpowers/specs/2026-08-19-return-analysis-revenue-bug-
// CHECKPOINT.md (archived session checkpoint).
//
// Bug in one line: OrderDetailDialog._save() rebuilds a product-lines array
// from editable UI state that never carries consumption[] (FIFO batch
// lineage stamped at completion — not a user-editable field). For a
// COMPLETED order with unchanged lines (a pure metadata edit — customer/
// email/phone/status/channel/staff), that array went straight to
// OrdersStore.updateOrder(...), which does a full, unconditional products
// replace — silently wiping consumption off every line, on ANY such edit.
// A later return then read an empty consumption[], and RealisedMath.
// byDimension/totals (which need it to attribute a row's revenue/profit)
// counted the return as zero, while every other analysis view (bucketsFor,
// which only sums quantity) stayed correct.
//
// This file tests ONLY the pure fix function in isolation. See
// tests/tst_OrderMetadataEditPreservesConsumption.qml for the DataModel/
// OrdersStore integration-level test (the fix wired into the real
// save-then-return flow) and test/e2e/tst_ReturnAfterMetadataEditE2E.qml
// for the full emulator-backed end-to-end scenario.
//
// NOT RUN IN THIS SANDBOX — no Qt/qmltestrunner toolchain available. Every
// case here WAS run and passed against the actual (`.pragma`/`.import`-
// stripped) OrderAdjust.js via a Node.js `vm` harness — see the fix commit's
// message for the RED→GREEN trail. Needs a real qmltestrunner pass before
// merge, same status as every other client-side test this session.
TestCase {
    name: "ReconcileConsumptionOnSave"

    // ── happy path ───────────────────────────────────────────────────────

    function test_surviving_line_keeps_original_consumption() {
        var newLines = [{ productId: "P1", name: "Widget", price: 100, quantity: 1 }]
        var origLines = [{ productId: "P1", name: "Widget", price: 100, quantity: 1,
                            consumption: [{ batchId: "B1", supplierId: "S1", qtyConsumed: 1, unitCost: 50 }] }]
        var out = OA.reconcileConsumptionOnSave(newLines, origLines)
        compare(out.length, 1)
        compare(out[0].consumption.length, 1)
        compare(out[0].consumption[0].batchId, "B1")
        compare(out[0].consumption[0].supplierId, "S1")
        compare(out[0].consumption[0].qtyConsumed, 1)
        compare(out[0].consumption[0].unitCost, 50)
    }

    function test_multiple_lines_match_independently_by_productId() {
        var newLines = [{ productId: "P1", name: "Widget", price: 100, quantity: 1 },
                         { productId: "P2", name: "Gadget", price: 50, quantity: 2 },
                         { productId: "P3", name: "Gizmo", price: 20, quantity: 5 }]
        var origLines = [
            { productId: "P1", name: "Widget", price: 100, quantity: 1,
              consumption: [{ batchId: "B1", supplierId: "S1", qtyConsumed: 1, unitCost: 50 }] },
            { productId: "P2", name: "Gadget", price: 50, quantity: 2,
              consumption: [{ batchId: "B2", supplierId: "S2", qtyConsumed: 2, unitCost: 20 }] },
            { productId: "P3", name: "Gizmo", price: 20, quantity: 5,
              consumption: [{ batchId: "B3", supplierId: "S3", qtyConsumed: 5, unitCost: 8 }] }
        ]
        var out = OA.reconcileConsumptionOnSave(newLines, origLines)
        compare(out.length, 3)
        compare(out[0].consumption[0].batchId, "B1")
        compare(out[1].consumption[0].batchId, "B2")
        compare(out[2].consumption[0].batchId, "B3")
    }

    function test_multi_batch_consumption_carried_over_in_full() {
        // A line split across two FIFO batches at completion — the whole
        // array must survive, not just the first entry.
        var newLines = [{ productId: "P1", name: "Widget", price: 100, quantity: 5 }]
        var origLines = [{ productId: "P1", name: "Widget", price: 100, quantity: 5,
                            consumption: [
                                { batchId: "B1", supplierId: "S1", qtyConsumed: 2, unitCost: 10 },
                                { batchId: "B2", supplierId: "S2", qtyConsumed: 3, unitCost: 12 }
                            ] }]
        var out = OA.reconcileConsumptionOnSave(newLines, origLines)
        compare(out[0].consumption.length, 2)
        compare(out[0].consumption[0].batchId, "B1")
        compare(out[0].consumption[0].qtyConsumed, 2)
        compare(out[0].consumption[1].batchId, "B2")
        compare(out[0].consumption[1].qtyConsumed, 3)
    }

    function test_order_of_output_matches_order_of_newLines() {
        // Downstream code (OrdersStore._normalizeOrder etc.) doesn't
        // guarantee it re-sorts by productId — position must be stable.
        var newLines = [{ productId: "P3", name: "Gizmo", price: 20, quantity: 1 },
                         { productId: "P1", name: "Widget", price: 100, quantity: 1 }]
        var origLines = [
            { productId: "P1", name: "Widget", price: 100, quantity: 1,
              consumption: [{ batchId: "B1", supplierId: "S1", qtyConsumed: 1, unitCost: 50 }] },
            { productId: "P3", name: "Gizmo", price: 20, quantity: 1,
              consumption: [{ batchId: "B3", supplierId: "S3", qtyConsumed: 1, unitCost: 8 }] }
        ]
        var out = OA.reconcileConsumptionOnSave(newLines, origLines)
        compare(out[0].productId, "P3")
        compare(out[0].consumption[0].batchId, "B3")
        compare(out[1].productId, "P1")
        compare(out[1].consumption[0].batchId, "B1")
    }

    // ── negative / regression cases ─────────────────────────────────────

    function test_unmatched_new_line_gets_empty_consumption_not_undefined() {
        var newLines = [{ productId: "P2", name: "New Product", price: 50, quantity: 1 }]
        var origLines = [{ productId: "P1", name: "Widget", price: 100, quantity: 1,
                            consumption: [{ batchId: "B1", supplierId: "S1", qtyConsumed: 1, unitCost: 50 }] }]
        var out = OA.reconcileConsumptionOnSave(newLines, origLines)
        verify(Array.isArray(out[0].consumption), "must be an array, not undefined — downstream " +
               "code does out[i].consumption.slice()/length without a null check")
        compare(out[0].consumption.length, 0)
    }

    function test_original_line_with_no_consumption_field_is_safe() {
        // A pending order's lines never had FIFO consumption stamped —
        // this is the normal, expected shape for a never-completed order.
        var newLines = [{ productId: "P1", name: "Widget", price: 100, quantity: 1 }]
        var origLines = [{ productId: "P1", name: "Widget", price: 100, quantity: 1 }]
        var out = OA.reconcileConsumptionOnSave(newLines, origLines)
        compare(out[0].consumption.length, 0)
    }

    function test_original_consumption_not_an_array_falls_back_to_empty() {
        // Defensive: a malformed/corrupted document shouldn't throw.
        var newLines = [{ productId: "P1", name: "Widget", price: 100, quantity: 1 }]
        var origLines = [{ productId: "P1", name: "Widget", price: 100, quantity: 1, consumption: "not-an-array" }]
        var out = OA.reconcileConsumptionOnSave(newLines, origLines)
        compare(out[0].consumption.length, 0)
    }

    function test_original_line_with_empty_consumption_array_stays_empty() {
        var newLines = [{ productId: "P1", name: "Widget", price: 100, quantity: 1 }]
        var origLines = [{ productId: "P1", name: "Widget", price: 100, quantity: 1, consumption: [] }]
        var out = OA.reconcileConsumptionOnSave(newLines, origLines)
        verify(Array.isArray(out[0].consumption))
        compare(out[0].consumption.length, 0)
    }

    // ── edge cases: empty / null / missing inputs ───────────────────────

    function test_empty_newLines_returns_empty_array() {
        compare(OA.reconcileConsumptionOnSave([], []).length, 0)
    }

    function test_null_newLines_returns_empty_array_not_throw() {
        compare(OA.reconcileConsumptionOnSave(null, []).length, 0)
    }

    function test_undefined_newLines_returns_empty_array_not_throw() {
        compare(OA.reconcileConsumptionOnSave(undefined, []).length, 0)
    }

    function test_null_originalLines_is_safe_every_line_gets_empty_consumption() {
        var newLines = [{ productId: "P1", name: "Widget", price: 100, quantity: 1 },
                         { productId: "P2", name: "Gadget", price: 50, quantity: 2 }]
        var out = OA.reconcileConsumptionOnSave(newLines, null)
        compare(out.length, 2)
        compare(out[0].consumption.length, 0)
        compare(out[1].consumption.length, 0)
    }

    function test_undefined_originalLines_is_safe() {
        var out = OA.reconcileConsumptionOnSave([{ productId: "P1", quantity: 1 }], undefined)
        compare(out[0].consumption.length, 0)
    }

    function test_both_null_returns_empty_array_not_throw() {
        compare(OA.reconcileConsumptionOnSave(null, null).length, 0)
    }

    function test_empty_originalLines_every_new_line_gets_empty_consumption() {
        var newLines = [{ productId: "P1", name: "Widget", price: 100, quantity: 1 }]
        var out = OA.reconcileConsumptionOnSave(newLines, [])
        compare(out[0].consumption.length, 0)
    }

    // ── matching-key edge cases (mirrors diffLines' own productId||name fallback) ──

    function test_falls_back_to_name_match_when_productId_missing_on_both_sides() {
        var newLines = [{ name: "Legacy Widget", price: 100, quantity: 1 }]
        var origLines = [{ name: "Legacy Widget", price: 100, quantity: 1,
                            consumption: [{ batchId: "B1", supplierId: "S1", qtyConsumed: 1, unitCost: 50 }] }]
        var out = OA.reconcileConsumptionOnSave(newLines, origLines)
        compare(out[0].consumption.length, 1)
        compare(out[0].consumption[0].batchId, "B1")
    }

    function test_empty_string_productId_falls_back_to_name_and_does_not_match_wrong_line() {
        var newLines = [{ productId: "", name: "Widget", price: 100, quantity: 1 }]
        var origLines = [{ productId: "", name: "Gadget", price: 50, quantity: 1,
                            consumption: [{ batchId: "WRONG", supplierId: "S1", qtyConsumed: 1, unitCost: 50 }] }]
        var out = OA.reconcileConsumptionOnSave(newLines, origLines)
        // Different names, both empty productId — must NOT cross-match on the
        // shared empty-string key. This is the sharpest edge of the
        // productId||name fallback and the case most likely to silently
        // attribute the wrong batch lineage to the wrong line.
        verify(out[0].consumption.length === 0,
               "lines with different names must not share consumption via an empty-productId collision")
    }

    // ── purity / no-mutation guarantees ──────────────────────────────────

    function test_does_not_mutate_the_input_newLines_array() {
        var newLines = [{ productId: "P1", name: "Widget", price: 100, quantity: 1 }]
        var origLines = [{ productId: "P1", name: "Widget", price: 100, quantity: 1,
                            consumption: [{ batchId: "B1", supplierId: "S1", qtyConsumed: 1, unitCost: 50 }] }]
        OA.reconcileConsumptionOnSave(newLines, origLines)
        verify(newLines[0].consumption === undefined,
               "the function must return a NEW array/objects — the caller's original " +
               "newLines entries must be untouched")
    }

    function test_does_not_mutate_the_input_originalLines_array() {
        var newLines = [{ productId: "P1", name: "Widget", price: 100, quantity: 1 }]
        var origConsumption = [{ batchId: "B1", supplierId: "S1", qtyConsumed: 1, unitCost: 50 }]
        var origLines = [{ productId: "P1", name: "Widget", price: 100, quantity: 1, consumption: origConsumption }]
        var out = OA.reconcileConsumptionOnSave(newLines, origLines)
        out[0].consumption.push({ batchId: "INJECTED", supplierId: "X", qtyConsumed: 99, unitCost: 1 })
        compare(origConsumption.length, 1,
                "mutating the RETURNED consumption array must not leak back into the " +
                "original order's stored consumption — the function must .slice(), not alias")
    }

    function test_other_fields_from_newLines_pass_through_unchanged() {
        // The fix must ONLY add/replace consumption — every other field the
        // caller sent (an actual, legitimate edit) must survive untouched.
        var newLines = [{ productId: "P1", name: "Widget", price: 90, quantity: 1,
                           discountType: "flat", discountValue: 5, taxable: true, taxPercent: 18 }]
        var origLines = [{ productId: "P1", name: "Widget", price: 100, quantity: 1,
                            consumption: [{ batchId: "B1", supplierId: "S1", qtyConsumed: 1, unitCost: 50 }] }]
        var out = OA.reconcileConsumptionOnSave(newLines, origLines)
        compare(out[0].price, 90)
        compare(out[0].discountType, "flat")
        compare(out[0].discountValue, 5)
        compare(out[0].taxable, true)
        compare(out[0].taxPercent, 18)
    }
}
