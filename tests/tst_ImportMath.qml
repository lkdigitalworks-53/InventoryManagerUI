import QtQuick
import QtTest
import "../qml/helper/ImportMath.js" as IM

// Bug E: the SKU rename suffix was string-concatenated as
//   sku + "-" + counts.added + 1
// which, by left-associativity, is ((sku + "-" + counts.added) + 1) →
// "ABC-" + 0 + 1 = "ABC-01". The fix parenthesises the increment.
TestCase {
    name: "ImportMath"

    function test_rename_first_added_is_dash_one() {
        compare(IM.renameSku("ABC", 0), "ABC-1")   // NOT "ABC-01"
    }

    function test_rename_uses_incremented_counter() {
        compare(IM.renameSku("ABC", 4), "ABC-5")   // NOT "ABC-41"
    }

    function test_rename_double_digit() {
        compare(IM.renameSku("SKU", 11), "SKU-12")
    }

    function test_taxable_yes_is_true() {
        compare(IM.parseTaxableCell("Yes"), true)
    }

    function test_taxable_case_insensitive() {
        compare(IM.parseTaxableCell("yES"), true)
        compare(IM.parseTaxableCell("TRUE"), true)
        compare(IM.parseTaxableCell("1"), true)
    }

    function test_taxable_no_is_false() {
        compare(IM.parseTaxableCell("No"), false)
    }

    function test_taxable_blank_is_false() {
        compare(IM.parseTaxableCell(""), false)
        compare(IM.parseTaxableCell(undefined), false)
    }

    function test_taxable_unrecognized_defaults_false() {
        compare(IM.parseTaxableCell("maybe"), false)
    }

    function test_taxable_trims_whitespace() {
        compare(IM.parseTaxableCell("  Yes  "), true)
    }

    function test_taxpercent_zero_when_not_taxable() {
        compare(IM.parseTaxPercentCell("18", false), 0)
    }

    function test_taxpercent_parses_number_when_taxable() {
        compare(IM.parseTaxPercentCell("18", true), 18)
    }

    function test_taxpercent_blank_when_taxable_is_zero() {
        compare(IM.parseTaxPercentCell("", true), 0)
    }

    function test_taxpercent_invalid_when_taxable_is_zero() {
        compare(IM.parseTaxPercentCell("not a number", true), 0)
    }

    // --- findOrderLineByProductId -------------------------------------
    // Regression coverage for the d915a7b bug: `if (...) x = y; break` —
    // the break wasn't inside the if, so the search always stopped after
    // checking index 0. These tests specifically target a match past the
    // first element so that bug can never silently come back.

    function test_findLine_matches_first_element() {
        var products = [{ productId: "P1", quantity: 5 }, { productId: "P2", quantity: 9 }]
        compare(IM.findOrderLineByProductId(products, "P1").quantity, 5)
    }

    function test_findLine_matches_non_first_element() {
        var products = [{ productId: "P1", quantity: 5 }, { productId: "P2", quantity: 9 }, { productId: "P3", quantity: 2 }]
        var line = IM.findOrderLineByProductId(products, "P3")
        verify(line !== null)
        compare(line.quantity, 2)
    }

    function test_findLine_no_match_returns_null() {
        var products = [{ productId: "P1", quantity: 5 }]
        compare(IM.findOrderLineByProductId(products, "P9"), null)
    }

    function test_findLine_null_products_returns_null() {
        compare(IM.findOrderLineByProductId(null, "P1"), null)
    }

    function test_findLine_empty_products_returns_null() {
        compare(IM.findOrderLineByProductId([], "P1"), null)
    }

    function test_findLine_falsy_pid_never_matches_a_line_also_missing_productId() {
        // Hardening: a line with no productId (legacy pre-productId data)
        // must never spuriously match a falsy lookup argument.
        var lines = [{ productId: undefined, name: "Legacy Widget" }]
        compare(IM.findOrderLineByProductId(lines, undefined), null)
        compare(IM.findOrderLineByProductId(lines, ""), null)
    }

    // --- checkOrderLineStock --------------------------------------------
    // Regression coverage for the d915a7b crash: calling this with
    // existingLineQty === null (a brand-new order/line) must never throw,
    // unlike the old `existingById[grp.key].products.length` access.

    function test_stock_not_completing_always_passes_through() {
        // Not a "completed" import row — stock is never checked, mirroring
        // how pending/processing orders don't reserve stock elsewhere in the app.
        var r = IM.checkOrderLineStock(null, /*currentStock*/ 2, /*importedQty*/ 100, /*isCompleting*/ false)
        compare(r.qty, 100)
        compare(r.reject, false)
        compare(r.issue, null)
    }

    function test_stock_new_line_sufficient_stock() {
        var r = IM.checkOrderLineStock(null, 10, 7, true)
        compare(r.qty, 7)
        compare(r.reject, false)
        compare(r.issue, null)
    }

    function test_stock_new_line_insufficient_stock_is_rejected() {
        var r = IM.checkOrderLineStock(null, 5, 7, true)
        compare(r.reject, true)
        compare(r.issue, "insufficient stock")
    }

    function test_stock_new_line_exact_stock_is_allowed() {
        var r = IM.checkOrderLineStock(null, 7, 7, true)
        compare(r.reject, false)
        compare(r.issue, null)
    }

    function test_stock_existing_line_increase_fits() {
        // 3 already booked, current stock is 10, row asks for 5 → delta of 2
        // must fit in the 10 on hand.
        var r = IM.checkOrderLineStock(3, 10, 5, true)
        compare(r.qty, 5)
        compare(r.reject, false)
        compare(r.issue, null)
    }

    function test_stock_existing_line_increase_does_not_fit_clamps_back() {
        // 3 already booked (already deducted from stock previously), only 1
        // unit currently on hand, row asks to raise it to 8 (delta of 5) —
        // can't be funded, so the line is kept at its current booked qty.
        var r = IM.checkOrderLineStock(3, 1, 8, true)
        compare(r.qty, 3)
        compare(r.reject, false)
        compare(r.issue, "insufficient stock")
    }

    function test_stock_existing_line_decrease_never_checks_stock() {
        // Lowering an existing line's quantity always succeeds regardless of
        // current stock — it releases stock, it doesn't consume it.
        var r = IM.checkOrderLineStock(9, 0, 2, true)
        compare(r.qty, 2)
        compare(r.reject, false)
        compare(r.issue, null)
    }

    function test_stock_existing_line_unchanged_never_checks_stock() {
        var r = IM.checkOrderLineStock(4, 0, 4, true)
        compare(r.qty, 4)
        compare(r.reject, false)
        compare(r.issue, null)
    }

    // --- findDuplicateProductRows -------------------------------------
    // Bug found on-device: two rows in ONE import file with the same
    // Product ID but different details silently let the second row clobber
    // the first (or, if neither pre-existed, silently drop the second with
    // no explanation). This is the pure dedup/conflict-detection logic used
    // to catch that at validation time instead.

    property var pFields: ["name", "price", "sellingPrice", "stock", "taxable", "taxPercent"]

    function test_dup_no_duplicates_is_a_noop() {
        var records = [
            { row: 2, productId: "PRD-001", name: "A", price: 10 },
            { row: 3, productId: "PRD-002", name: "B", price: 20 }
        ]
        var r = IM.findDuplicateProductRows(records, pFields)
        compare(r.dropIndexes.length, 0)
        compare(r.conflicts.length, 0)
    }

    function test_dup_blank_productId_rows_never_grouped() {
        // Two continuation/blank-id rows must never be treated as
        // duplicates of each other.
        var records = [
            { row: 2, productId: "", name: "A", price: 10 },
            { row: 3, productId: "", name: "B", price: 20 }
        ]
        var r = IM.findDuplicateProductRows(records, pFields)
        compare(r.dropIndexes.length, 0)
        compare(r.conflicts.length, 0)
    }

    function test_dup_identical_rows_keep_first_drop_rest() {
        var records = [
            { row: 2, productId: "PRD-001", name: "Widget", price: 10, sellingPrice: 15, stock: 5, taxable: false, taxPercent: 0 },
            { row: 3, productId: "PRD-001", name: "Widget", price: 10, sellingPrice: 15, stock: 5, taxable: false, taxPercent: 0 }
        ]
        var r = IM.findDuplicateProductRows(records, pFields)
        compare(r.dropIndexes, [1])
        compare(r.conflicts.length, 0)
    }

    function test_dup_three_identical_rows_drops_all_but_first() {
        var records = [
            { row: 2, productId: "PRD-001", name: "Widget", price: 10, sellingPrice: 15, stock: 5, taxable: false, taxPercent: 0 },
            { row: 3, productId: "PRD-001", name: "Widget", price: 10, sellingPrice: 15, stock: 5, taxable: false, taxPercent: 0 },
            { row: 4, productId: "PRD-001", name: "Widget", price: 10, sellingPrice: 15, stock: 5, taxable: false, taxPercent: 0 }
        ]
        var r = IM.findDuplicateProductRows(records, pFields)
        compare(r.dropIndexes, [1, 2])
        compare(r.conflicts.length, 0)
    }

    function test_dup_conflicting_price_is_reported_not_guessed() {
        var records = [
            { row: 2, productId: "PRD-001", name: "Widget", price: 10, sellingPrice: 15, stock: 5, taxable: false, taxPercent: 0 },
            { row: 3, productId: "PRD-001", name: "Widget", price: 12, sellingPrice: 15, stock: 5, taxable: false, taxPercent: 0 }
        ]
        var r = IM.findDuplicateProductRows(records, pFields)
        compare(r.dropIndexes.length, 0)
        compare(r.conflicts.length, 1)
        compare(r.conflicts[0].productId, "PRD-001")
        compare(r.conflicts[0].rows, [2, 3])
    }

    function test_dup_conflicting_stock_is_reported() {
        var records = [
            { row: 2, productId: "PRD-001", name: "Widget", price: 10, sellingPrice: 15, stock: 5, taxable: false, taxPercent: 0 },
            { row: 3, productId: "PRD-001", name: "Widget", price: 10, sellingPrice: 15, stock: 9, taxable: false, taxPercent: 0 }
        ]
        var r = IM.findDuplicateProductRows(records, pFields)
        compare(r.conflicts.length, 1)
    }

    // --- mergeOrderLines -------------------------------------------------
    // Bug found on-device: two rows in one imported ORDER for the same
    // product create two order lines with the same productId — which
    // silently breaks OrderAdjust.diffLines and every productId-keyed
    // lookup in OrderDetailDialog the moment that order is later edited
    // (both explicitly assume order lines are unique per productId).
    // mergeOrderLines enforces that invariant at the one entry point that
    // doesn't already go through NewOrderDialog/OrderDetailDialog's own
    // merge-on-duplicate "add product" behavior.

    function test_merge_no_duplicates_passes_through_unchanged() {
        var lines = [
            { productId: "PRD-001", name: "A", quantity: 2, price: 10, taxable: false, taxPercent: 0, discountType: "flat", discountValue: 0 },
            { productId: "PRD-002", name: "B", quantity: 1, price: 20, taxable: false, taxPercent: 0, discountType: "flat", discountValue: 0 }
        ]
        var r = IM.mergeOrderLines(lines)
        compare(r.conflict, null)
        compare(r.lines.length, 2)
    }

    function test_merge_same_price_sums_quantity() {
        var lines = [
            { productId: "PRD-001", name: "Widget", quantity: 2, price: 100, taxable: false, taxPercent: 0, discountType: "flat", discountValue: 0 },
            { productId: "PRD-001", name: "Widget", quantity: 3, price: 100, taxable: false, taxPercent: 0, discountType: "flat", discountValue: 0 }
        ]
        var r = IM.mergeOrderLines(lines)
        compare(r.conflict, null)
        compare(r.lines.length, 1)
        compare(r.lines[0].quantity, 5)
        compare(r.lines[0].price, 100)
    }

    function test_merge_three_same_price_lines_sums_all() {
        var lines = [
            { productId: "PRD-001", name: "Widget", quantity: 1, price: 100, taxable: false, taxPercent: 0, discountType: "flat", discountValue: 0 },
            { productId: "PRD-001", name: "Widget", quantity: 2, price: 100, taxable: false, taxPercent: 0, discountType: "flat", discountValue: 0 },
            { productId: "PRD-001", name: "Widget", quantity: 3, price: 100, taxable: false, taxPercent: 0, discountType: "flat", discountValue: 0 }
        ]
        var r = IM.mergeOrderLines(lines)
        compare(r.conflict, null)
        compare(r.lines.length, 1)
        compare(r.lines[0].quantity, 6)
    }

    function test_merge_different_price_is_a_conflict_not_a_guess() {
        // This is the EXACT scenario reported: same product, same order,
        // different selling prices. Must not silently pick either price.
        var lines = [
            { productId: "PRD-001", name: "Widget", quantity: 2, price: 100, taxable: false, taxPercent: 0, discountType: "flat", discountValue: 0 },
            { productId: "PRD-001", name: "Widget", quantity: 3, price: 150, taxable: false, taxPercent: 0, discountType: "flat", discountValue: 0 }
        ]
        var r = IM.mergeOrderLines(lines)
        verify(r.conflict !== null)
        compare(r.lines, null)
    }

    function test_merge_different_tax_is_a_conflict() {
        var lines = [
            { productId: "PRD-001", name: "Widget", quantity: 2, price: 100, taxable: true, taxPercent: 5, discountType: "flat", discountValue: 0 },
            { productId: "PRD-001", name: "Widget", quantity: 3, price: 100, taxable: true, taxPercent: 12, discountType: "flat", discountValue: 0 }
        ]
        var r = IM.mergeOrderLines(lines)
        verify(r.conflict !== null)
    }

    function test_merge_different_discount_is_a_conflict() {
        var lines = [
            { productId: "PRD-001", name: "Widget", quantity: 2, price: 100, taxable: false, taxPercent: 0, discountType: "flat", discountValue: 0 },
            { productId: "PRD-001", name: "Widget", quantity: 3, price: 100, taxable: false, taxPercent: 0, discountType: "percent", discountValue: 10 }
        ]
        var r = IM.mergeOrderLines(lines)
        verify(r.conflict !== null)
    }

    function test_merge_preserves_line_order_for_non_duplicates() {
        var lines = [
            { productId: "PRD-001", name: "A", quantity: 1, price: 10, taxable: false, taxPercent: 0, discountType: "flat", discountValue: 0 },
            { productId: "PRD-002", name: "B", quantity: 1, price: 20, taxable: false, taxPercent: 0, discountType: "flat", discountValue: 0 },
            { productId: "PRD-001", name: "A", quantity: 4, price: 10, taxable: false, taxPercent: 0, discountType: "flat", discountValue: 0 }
        ]
        var r = IM.mergeOrderLines(lines)
        compare(r.conflict, null)
        compare(r.lines.length, 2)
        compare(r.lines[0].productId, "PRD-001")
        compare(r.lines[0].quantity, 5)
        compare(r.lines[1].productId, "PRD-002")
    }

    // --- checkOrderLineStockAcrossBatch: the cross-order-batch-aware wrapper ---
    // (existingLineQty, fullStock, remainingStock, importedQty, isCompleting)

    function test_acrossBatch_new_line_fits_both_full_and_remaining() {
        var r = IM.checkOrderLineStockAcrossBatch(null, 10, 10, 5, true)
        compare(r.qty, 5)
        compare(r.reject, false)
        compare(r.issue, null)
        compare(r.crossOrder, false)
        compare(r.netNew, 5)
    }

    function test_acrossBatch_new_line_fits_full_not_remaining_is_cross_order() {
        // The EXACT scenario the whole fix exists for: three orders in one
        // import file each want 5 units of a product with 10 in stock. By the
        // time this (the 2nd or 3rd) row is checked, remainingStock has
        // already been claimed by an earlier row — it would fit against the
        // product's real stock (10), just not what's left (3).
        var r = IM.checkOrderLineStockAcrossBatch(null, 10, 3, 5, true)
        compare(r.qty, 5)
        compare(r.reject, true)
        compare(r.issue, "insufficient stock")
        compare(r.crossOrder, true)
        compare(r.netNew, 0)
    }

    function test_acrossBatch_new_line_does_not_fit_even_at_full_stock() {
        var r = IM.checkOrderLineStockAcrossBatch(null, 3, 3, 5, true)
        compare(r.reject, true)
        compare(r.crossOrder, false)
        compare(r.netNew, 0)
    }

    function test_acrossBatch_existing_line_increase_fits_netNew_is_delta_not_full_qty() {
        var r = IM.checkOrderLineStockAcrossBatch(3, 10, 10, 5, true)
        compare(r.qty, 5)
        compare(r.reject, false)
        compare(r.netNew, 2)
    }

    function test_acrossBatch_existing_line_increase_clamped_by_remaining_is_cross_order() {
        var r = IM.checkOrderLineStockAcrossBatch(3, 10, 1, 5, true)
        compare(r.qty, 3)
        compare(r.issue, "insufficient stock")
        compare(r.crossOrder, true)
        compare(r.netNew, 0)
    }

    function test_acrossBatch_existing_line_increase_does_not_fit_even_at_full() {
        var r = IM.checkOrderLineStockAcrossBatch(3, 1, 1, 5, true)
        compare(r.crossOrder, false)
        compare(r.netNew, 0)
    }

    function test_acrossBatch_existing_line_decrease_frees_up_the_pool() {
        // netNew is negative here — a decrease should INCREASE what's left
        // for later rows in the same batch, not just no-op.
        var r = IM.checkOrderLineStockAcrossBatch(10, 0, 0, 3, true)
        compare(r.qty, 3)
        compare(r.reject, false)
        compare(r.netNew, -7)
    }

    function test_acrossBatch_existing_line_unchanged_netNew_is_zero() {
        var r = IM.checkOrderLineStockAcrossBatch(5, 0, 0, 5, true)
        compare(r.netNew, 0)
    }

    function test_acrossBatch_non_completing_never_decrements() {
        var r = IM.checkOrderLineStockAcrossBatch(null, 1, 1, 100, false)
        compare(r.reject, false)
        compare(r.netNew, 0)
    }
}
