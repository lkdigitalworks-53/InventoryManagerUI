.pragma library

// Pure column/row shaping for the Sales page's "Current stock snapshot"
// export (SalesPage.qml, the CURRENT-mode branch of its export builder).
// Deliberately free of qsTr()/singleton lookups — same convention as the
// other qml/helper/*.js modules (ImportMath, OrderMath, ...) — so the
// header/row column-count contract can be unit tested directly instead of
// only by inspection.
//
// Bug this guards against (found in review, 2026-08-21): a "Product ID"
// column and three more (Cost Price / Selling Price / Tax%) were added to
// snapHeaders without updating every snapRows push to match, so the
// non-supplier row was short by exactly the leading column (shifting every
// value one column left, e.g. Name landing under the "Product ID" header)
// and both branches' totals rows were short trailing columns.
// XlsxService.cpp's renderAnalysisSections() writes
// `for (col = 0; col < headers.size() && col < line.size(); ++col)` — a
// row shorter than its header silently drops/shifts columns instead of
// throwing, so this produces a wrong spreadsheet with no crash and (until
// now) no test anywhere in the pipeline to catch it.
//
// buildRow()/buildTotalRow()'s return length MUST equal columnCount() for
// the same `showSup` value, which must in turn equal SalesPage.qml's
// snapHeaders literal length for that branch — there's no compiler check
// tying these together, only tst_StockSnapshotMath.qml. Re-verify all
// three any time any of them changes.

function columnCount(showSup) {
    return showSup ? 11 : 7;
}

// supplierName/status are passed in already-resolved (supplier-id lookup
// and stock-threshold classification are page/singleton concerns) so this
// stays a pure function of its arguments.
function buildRow(p, showSup, supplierName, status) {
    var stock = p.stock || 0;
    var minStock = p.minStock || 0;
    if (showSup) {
        return [p.productId, p.name || "", p.sku || "", p.category || "",
                supplierName || "", stock, minStock,
                p.price || 0, p.sellingPrice || p.price, status, p.taxPercent || 0];
    }
    return [p.productId, p.name || "", p.sku || "", p.category || "",
            stock, minStock, status];
}

// Total label / grandTotal land one column before, and exactly at, the
// "Stock" column respectively — matching the pre-existing (pre-"Product
// ID") layout convention — everything else stays blank.
function buildTotalRow(showSup, totalLabel, grandTotal) {
    if (showSup) {
        return ["", "", "", "", totalLabel, grandTotal, "", "", "", "", ""];
    }
    return ["", "", "", totalLabel, grandTotal, "", ""];
}
