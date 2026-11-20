import QtQuick
import QtTest
import "../qml/helper/AddProductFlow.js" as AF

// Headless tests for the Add Product sheet's pure form decisions (atomic-ops AP3b). Pure JS, no singletons.
// Design: docs/superpowers/specs/2026-11-20-ap3b-add-product-dialog-design.md
// Test plan: docs/superpowers/test-plans/2026-11-20-ap3b-add-product-dialog-test-plan.md
// The same cases run in Node against the REAL planner and server in functions/test/addProductForm.test.js; this file is the
// qmltestrunner copy, so a QML-engine difference (regex, Number(), toFixed, string methods) cannot hide.
// NOT RUN IN THIS SANDBOX: no Qt/qmltestrunner toolchain here. CI is the oracle.
TestCase {
    name: "AddProductForm"

    readonly property var ids: ["", "SUP-009"]

    function _form(over) {
        var base = { name: "Tomato", sku: "TO-2026-001", size: "", description: "Red", category: "Veg", categoryIndex: 0, unit: "Kg",
                     costText: "20", priceText: "30", markup: false, stockText: "5", minStockText: "2", taxable: false, taxPercentText: "0",
                     pendingPartyText: "", newSupplierName: "", partyIndex: 0, supplierIds: ids }
        for (var k in over) base[k] = over[k]
        return base
    }
    function _run(over) { return AF.fromForm(_form(over)) }
    function _errs(over) {
        var r = _run(over)
        verify(r.ok === false, "must be refused: " + JSON.stringify(over))
        return r.errors.join("|")
    }
    function _rep(ch, n) { var s = ""; for (var i = 0; i < n; ++i) s += ch; return s }

    // ── parsers ───────────────────────────────────────────────────────────
    function test_moneyFromText_accepts_plain_decimals_only() {
        var good = [["20", 20], ["0", 0], ["0.5", 0.5], [".5", 0.5], ["5.", 5], [" 12 ", 12], ["007", 7], ["1000000000", 1000000000]]
        for (var i = 0; i < good.length; ++i) compare(AF.moneyFromText(good[i][0]), good[i][1], good[i][0])
        var bad = ["", " ", "abc", "12abc", "1,5", "1e3", "-1", "+1", "0x10", "Infinity", "1.2.3", ".", "1000000000.01", _rep("9", 400)]
        for (var j = 0; j < bad.length; ++j) verify(isNaN(AF.moneyFromText(bad[j])), "must refuse '" + bad[j] + "'")
        verify(isNaN(AF.moneyFromText(null)))
        verify(isNaN(AF.moneyFromText(undefined)))
        verify(isNaN(AF.moneyFromText(12)))
    }
    function test_wholeFromText_never_cuts_a_fraction() {
        var good = [["5", 5], ["0", 0], ["007", 7], [" 5 ", 5], ["1000000", 1000000]]
        for (var i = 0; i < good.length; ++i) compare(AF.wholeFromText(good[i][0]), good[i][1], good[i][0])
        var bad = ["", "2.5", "5.", ".5", "-1", "1e3", "abc", "5 pcs", "1,000", "1000001", _rep("9", 400)]
        for (var j = 0; j < bad.length; ++j) verify(isNaN(AF.wholeFromText(bad[j])), "must refuse '" + bad[j] + "'")
    }

    // ── fromForm ──────────────────────────────────────────────────────────
    function test_fromForm_happy_path_shape() {
        var r = _run({ name: "  Tomato ", sku: " TO-1 ", size: " M ", category: " Veg ", taxable: true, taxPercentText: "5", minStockText: "" })
        verify(r.ok)
        compare(r.args.name, "Tomato"); compare(r.args.sku, "TO-1"); compare(r.args.size, "M"); compare(r.args.category, "Veg")
        compare(r.args.price, 20); compare(r.args.unitCost, 20); compare(r.args.sellingPrice, 30); compare(r.args.stock, 5)
        compare(r.args.minStock, 0); compare(r.args.taxable, true); compare(r.args.taxPercent, 5); compare(r.args.party, "")
        compare(_run({ taxable: false, taxPercentText: "junk" }).args.taxPercent, 0)
    }
    function test_fromForm_each_field_has_its_own_refusal() {
        var stockText = "Enter the opening stock as a whole number (0 if none)"
        var table = [
            [{ name: "" }, "Enter a valid product name"], [{ name: "A" }, "Enter a valid product name"], [{ sku: " " }, "SKU required (tap Gen)"],
            [{ categoryIndex: -1 }, "Select a category"], [{ costText: "" }, "Enter a valid cost"], [{ costText: "12abc" }, "Enter a valid cost"],
            [{ costText: "1e3" }, "Enter a valid cost"], [{ priceText: "0" }, "Enter a valid price"], [{ priceText: "x" }, "Enter a valid price"],
            [{ priceText: "10" }, "Price < cost"], [{ stockText: "" }, stockText], [{ stockText: "2.5" }, stockText], [{ stockText: "-1" }, stockText],
            [{ minStockText: "abc" }, "Reorder level must be a whole number"], [{ minStockText: "1.5" }, "Reorder level must be a whole number"],
            [{ taxable: true, taxPercentText: "" }, "Enter a valid tax % (0\u2013100)"], [{ taxable: true, taxPercentText: "100.01" }, "Enter a valid tax % (0\u2013100)"],
            [{ taxable: true, taxPercentText: "5%" }, "Enter a valid tax % (0\u2013100)"]
        ]
        for (var i = 0; i < table.length; ++i) compare(_errs(table[i][0]), table[i][1], JSON.stringify(table[i][0]))
    }
    function test_fromForm_lists_every_problem_in_field_order() {
        var r = _run({ name: "", sku: "", categoryIndex: -1, costText: "x", priceText: "y", stockText: "z", minStockText: "q", taxable: true, taxPercentText: "w",
                       size: _rep("s", 41), pendingPartyText: "Acme" })
        verify(!r.ok)
        compare(r.errors.length, 10)
        compare(r.errors[0], "Enter a valid product name")
        compare(r.errors[9], "You typed a new supplier name. Tap Use to add it, or clear the field")
    }
    function test_fromForm_markup_mode_matches_the_pill() {
        compare(_run({ markup: true, costText: "20", priceText: "50" }).args.sellingPrice, 30)
        compare(_run({ markup: true, costText: "33", priceText: "10" }).args.sellingPrice, 36)
        compare(_run({ markup: true, costText: "33", priceText: "10" }).args.price, 33)
        compare(_errs({ markup: true, costText: "x", priceText: "50" }), "Enter a valid cost|Enter a valid price")
        compare(_errs({ markup: true, costText: "1000000000", priceText: "100" }), "Markup is too high. The selling price must be at most 1000000000")
        compare(_errs({ markup: true, costText: "0", priceText: "20" }), "A markup needs a cost above 0")
        compare(_run({ markup: true, costText: "0.4", priceText: "0" }).args.sellingPrice, 0.4)
    }
    function test_fromForm_limits_are_on_trimmed_text_at_the_edge() {
        verify(_run({ name: _rep("x", 100) }).ok)
        compare(_errs({ name: _rep("x", 101) }), "Product name is too long. Use at most 100 characters")
        verify(_run({ name: "  " + _rep("x", 100) + "  " }).ok)
        verify(_run({ sku: _rep("x", 40) }).ok)
        compare(_errs({ sku: _rep("x", 41) }), "SKU is too long. Use at most 40 characters")
        compare(_errs({ size: _rep("x", 41) }), "Size is too long. Use at most 40 characters")
        verify(_run({ description: _rep("x", 500) }).ok)
        compare(_errs({ description: _rep("x", 501) }), "Description is too long. Use at most 500 characters")
        verify(_run({ stockText: "1000000", costText: "1000000000", priceText: "1000000000" }).ok)
    }
    function test_fromForm_supplier_rules() {
        compare(_run().args.party, "")
        compare(_run({ partyIndex: 1 }).args.party, "SUP-009")
        compare(_run({ partyIndex: 99 }).args.party, "")
        compare(_run({ newSupplierName: "Acme" }).args.party.newName, "Acme")
        compare(_run({ newSupplierName: "Acme", partyIndex: 1 }).args.party.newName, "Acme")
        compare(_errs({ pendingPartyText: "Acme" }), "You typed a new supplier name. Tap Use to add it, or clear the field")
        verify(_run({ pendingPartyText: "\u200b \u200b" }).ok)
    }
    function test_fromForm_never_throws_on_hostile_input() {
        var hostile = [undefined, null, 5, "x", [], {}]
        for (var i = 0; i < hostile.length; ++i) {
            var r = AF.fromForm(hostile[i])
            verify(r.ok === false)
            verify(r.errors.length > 0)
        }
    }

    // ── priceSummary ──────────────────────────────────────────────────────
    function test_priceSummary_uses_the_same_parsing_as_save() {
        compare(AF.priceSummary("20", "30", false), "Markup 50%   \u00b7   profit \u20b910.00")
        compare(AF.priceSummary("20", "50", true), "Selling price \u20b930   \u00b7   profit \u20b910.00")
        compare(AF.priceSummary("", "30", false), "Markup \u2014")
        compare(AF.priceSummary("0", "30", false), "Markup \u2014")
        compare(AF.priceSummary("20", "1e3", true), "Selling price \u2014")
        compare(AF.priceSummary("12abc", "30", false), "Markup \u2014")
        // review sweep 1 of PR 207: the pill never shows a price Save refuses
        compare(AF.priceSummary("1000", "100000000", true), "Selling price \u2014")
        compare(AF.priceSummary("10", "0", false), "Markup \u2014")
        compare(AF.priceSummary("10.40", "0", true), "Selling price \u20b910.4   \u00b7   profit \u20b90.00")
    }
    function test_too_large_is_not_reported_as_invalid() {
        compare(_errs({ costText: "2000000000" }), "Cost is too large. Use at most 1000000000")
        compare(_errs({ priceText: "2000000000" }), "Price is too large. Use at most 1000000000")
        compare(_errs({ stockText: "1000001" }), "Opening stock is too large. Use at most 1000000")
        compare(_errs({ minStockText: "1000001" }), "Reorder level is too large. Use at most 1000000")
        compare(_errs({ costText: _rep("9", 400) }), "Cost is too large. Use at most 1000000000")
        verify(_run({ costText: "1000000000", priceText: "1000000000", stockText: "1000000", minStockText: "1000000" }).ok)
    }
    function test_markup_price_is_never_below_the_cost() {
        compare(_run({ markup: true, costText: "10.40", priceText: "0" }).args.sellingPrice, 10.4)
        compare(_run({ markup: true, costText: "100.4", priceText: "0.05" }).args.sellingPrice, 100.4)
        compare(_run({ markup: true, costText: "33", priceText: "10" }).args.sellingPrice, 36)
    }
}
