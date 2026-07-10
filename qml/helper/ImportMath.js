.pragma library

// Pure helpers for the inventory CSV import. Extracted from InventoryStore so the
// operator-precedence-sensitive bits carry a headless test.

// Unique-SKU suffix for a "rename" conflict resolution. addedCount is the number
// of rows already added in this import (0-based), so the FIRST renamed row gets
// suffix -1. Parenthesised so "+" doesn't string-concatenate the counter before
// the increment: "ABC" + "-" + (0 + 1) === "ABC-1"  (NOT "ABC-01").
function renameSku(sku, addedCount) {
    return sku + "-" + (addedCount + 1)
}

// Parses a human-typed "Taxable" export/import cell into a boolean. Accepts
// "yes"/"true"/"1" case-insensitively (matches how the app writes the column
// on export: "Yes"/"No"). Blank or unrecognized values default to false —
// there is no "reject the row" behavior for this optional column.
function parseTaxableCell(raw) {
    var s = (raw === undefined || raw === null) ? "" : String(raw).trim().toLowerCase()
    return s === "yes" || s === "true" || s === "1"
}

// Parses the "Tax %" cell. When the row isn't taxable, the rate is always 0
// regardless of what's in the cell (matches AddProductDialog/EditProductDialog's
// own behavior: the Tax % input is disabled and zeroed when "Not taxable" is
// selected). When taxable, an unparseable value also falls back to 0 rather
// than rejecting the row — Taxable/Tax % are optional columns.
function parseTaxPercentCell(raw, taxable) {
    if (!taxable) return 0
    var n = parseFloat(raw)
    return isNaN(n) ? 0 : n
}
