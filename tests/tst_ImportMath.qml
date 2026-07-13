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
}
