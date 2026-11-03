.pragma library

// Shared fixtures for the product-picker helper tests (design 2026-11-03). The same file is loaded by
// the Node tests (functions/test/picker*.test.js) and imported by the QML twins (tests/tst_Product*.qml,
// tests/tst_PickerDraft.qml), so both engines run the same data through the same canonical comparison.

function P(productId, name, sku, category) {
    return { productId: productId, name: name, sku: sku, category: category }
}

var CATALOG = [
    P("PRD-001", "Cherry Tomato", "TOM-CH", "Vegetables"),
    P("PRD-002", "Tomato", "TOM-01", "Vegetables"),
    P("PRD-003", "Matcha", "MAT-01", "Tea")
]

function ids(list) {
    var out = []
    for (var i = 0; i < list.length; ++i) out.push(list[i].productId)
    return out
}

// Canonical text of any value: sorted object keys, NaN and undefined spelled out. Both engines compare
// these strings, so "equal" means the same in Node and in QML and a failure prints something readable.
function canon(v) {
    if (v === undefined) return "undefined"
    if (v === null) return "null"
    if (typeof v === "number") return isNaN(v) ? "NaN" : String(v)
    if (typeof v === "string") return JSON.stringify(v)
    if (typeof v === "boolean") return String(v)
    if (typeof v === "function") return "function"
    var parts = []
    var i
    if (Array.isArray(v)) {
        for (i = 0; i < v.length; ++i) parts.push(canon(v[i]))
        return "[" + parts.join(",") + "]"
    }
    var keys = Object.keys(v).sort()
    for (i = 0; i < keys.length; ++i) parts.push(JSON.stringify(keys[i]) + ":" + canon(v[keys[i]]))
    return "{" + parts.join(",") + "}"
}

function freeze(v) {
    if (v && typeof v === "object" && !Object.isFrozen(v)) {
        Object.freeze(v)
        var keys = Object.keys(v)
        for (var i = 0; i < keys.length; ++i) freeze(v[keys[i]])
    }
    return v
}

// Seeded LCG so a monkey run is reproducible.
function rng(seed) {
    var s = seed
    return function() {
        s = (s * 1664525 + 1013904223) % 4294967296
        return s / 4294967296
    }
}
