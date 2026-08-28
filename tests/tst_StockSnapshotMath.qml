import QtQuick
import QtTest
import "../qml/helper/StockSnapshotMath.js" as SSM

// Bug found in review of pr_taher_bug_fixes (2026-08-21): SalesPage.qml's
// "Current stock snapshot" export added a leading "Product ID" column plus
// three trailing ones (Cost Price / Selling Price / Tax%) to snapHeaders
// without updating every snapRows push to match:
//   - the non-supplier-view data row kept its OLD 6 fields against a NEW
//     7-column header, shifting every value one column left (Name lands
//     under "Product ID", ..., Status column ends up empty).
//   - both views' Total rows were short several trailing columns.
// XlsxService.cpp's renderAnalysisSections() writes
// `for (col = 0; col < headers.size() && col < line.size(); ++col)` — a
// short row doesn't crash or fail anywhere, it just silently produces a
// wrong spreadsheet. Nothing existing caught this: SalesPage.qml (a UI
// page) isn't otherwise unit tested, matching this codebase's convention
// (see other qml/helper/*.js modules) — this file exists specifically so
// the header/row column-count contract has a test at all.
TestCase {
    name: "StockSnapshotMath"

    function _product(overrides) {
        var p = { productId: "PRD-001", name: "Widget", sku: "SKU-1",
                  category: "General", stock: 10, minStock: 2,
                  price: 100, sellingPrice: 120, taxPercent: 18 }
        if (overrides) for (var k in overrides) p[k] = overrides[k]
        return p
    }

    function test_columnCount_matches_SalesPage_snapHeaders_supplier_view() {
        // SalesPage.qml's showSup header: Product ID, Name, SKU, Category,
        // Supplier, Stock, Min stock, Cost Price, Selling Price, Status, Tax%
        compare(SSM.columnCount(true), 11)
    }

    function test_columnCount_matches_SalesPage_snapHeaders_non_supplier_view() {
        // SalesPage.qml's non-showSup header: Product ID, Name, SKU,
        // Category, Stock, Min stock, Status
        compare(SSM.columnCount(false), 7)
    }

    function test_buildRow_supplier_view_has_exactly_one_cell_per_header_column() {
        var row = SSM.buildRow(_product(), true, "Acme Supplies", "In stock")
        compare(row.length, SSM.columnCount(true))
    }

    function test_buildRow_non_supplier_view_has_exactly_one_cell_per_header_column() {
        var row = SSM.buildRow(_product(), false, "Acme Supplies", "In stock")
        compare(row.length, SSM.columnCount(false))
    }

    function test_buildRow_non_supplier_view_leads_with_productId() {
        // This is the exact regression: the non-supplier row used to omit
        // productId entirely even though the header gained a "Product ID"
        // leading column, shifting every subsequent value one column left.
        var row = SSM.buildRow(_product({ productId: "PRD-777" }), false, "", "In stock")
        compare(row[0], "PRD-777")
        compare(row[1], "Widget", "Name must stay under the Name column, not shift into Product ID's slot")
    }

    function test_buildRow_supplier_view_column_order() {
        var row = SSM.buildRow(_product(), true, "Acme Supplies", "Low")
        compare(row[0], "PRD-001") // Product ID
        compare(row[1], "Widget")  // Name
        compare(row[2], "SKU-1")   // SKU
        compare(row[3], "General") // Category
        compare(row[4], "Acme Supplies") // Supplier
        compare(row[5], 10)        // Stock
        compare(row[6], 2)         // Min stock
        compare(row[7], 100)       // Cost Price
        compare(row[8], 120)       // Selling Price
        compare(row[9], "Low")     // Status
        compare(row[10], 18)       // Tax%
    }

    function test_buildTotalRow_supplier_view_has_exactly_one_cell_per_header_column() {
        var row = SSM.buildTotalRow(true, "Total", 42)
        compare(row.length, SSM.columnCount(true))
    }

    function test_buildTotalRow_non_supplier_view_has_exactly_one_cell_per_header_column() {
        var row = SSM.buildTotalRow(false, "Total", 42)
        compare(row.length, SSM.columnCount(false))
    }

    function test_buildTotalRow_supplier_view_places_label_and_total_under_supplier_and_stock() {
        var row = SSM.buildTotalRow(true, "Total", 42)
        compare(row[4], "Total") // Supplier column
        compare(row[5], 42)      // Stock column
    }

    function test_buildTotalRow_non_supplier_view_places_label_and_total_under_category_and_stock() {
        var row = SSM.buildTotalRow(false, "Total", 42)
        compare(row[3], "Total") // Category column (Stock's immediate predecessor)
        compare(row[4], 42)      // Stock column
    }

    function test_buildRow_falls_back_to_price_when_sellingPrice_missing() {
        var row = SSM.buildRow(_product({ sellingPrice: undefined }), true, "", "In stock")
        compare(row[8], 100, "Selling Price cell should fall back to cost price when unset")
    }

    function test_buildRow_handles_zero_stock_and_missing_minStock() {
        var row = SSM.buildRow(_product({ stock: 0, minStock: undefined }), false, "", "Out of stock")
        compare(row[4], 0) // Stock
        compare(row[5], 0) // Min stock defaults to 0, not undefined
    }
}
