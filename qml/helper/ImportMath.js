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
