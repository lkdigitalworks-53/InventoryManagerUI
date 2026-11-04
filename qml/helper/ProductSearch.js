.pragma library

// Pure search over the product catalog for the order picker (design 2026-11-03). No QML or singleton
// deps, so it is unit-testable headless (functions/test/pickerSearch.test.js, tests/tst_ProductSearch.qml).

var MAX_QUERY = 200   // nobody types more; also bounds the work

function _text(v) {
    var s = (v === undefined || v === null) ? "" : String(v)
    if (typeof s.normalize === "function") s = s.normalize("NFC")
    return s.toLowerCase()
}

// "  Red  Tomato " -> ["red", "tomato"]
function tokenize(query) {
    var parts = _text(query).substring(0, MAX_QUERY).split(/\s+/)
    var out = []
    for (var i = 0; i < parts.length; ++i)
        if (parts[i].length > 0) out.push(parts[i])
    return out
}

// A product is a plain object with a non-empty STRING productId (every store and PickerDraft key by string
// ids). Arrays, id-less objects and numeric or empty ids are junk, never matches: a row the draft would
// silently refuse to step is worse than a missing row.
function _isProduct(p) {
    return !!p && typeof p === "object" && typeof p.productId === "string" && p.productId.length > 0
}

function _fields(p) {
    return { id: _text(p.productId), sku: _text(p.sku), name: _text(p.name), category: _text(p.category) }
}

// Best score of one token against one product, or -1 when it appears nowhere.
function _tokenScore(f, t) {
    if (f.id === t || f.sku === t) return 100
    if (f.id.indexOf(t) === 0 || f.sku.indexOf(t) === 0) return 60
    if ((" " + f.name).indexOf(" " + t) >= 0) return 40            // a word of the name starts with t
    if (f.name.indexOf(t) >= 0 || f.category.indexOf(t) >= 0) return 10
    if (f.id.indexOf(t) >= 0 || f.sku.indexOf(t) >= 0) return 5
    return -1
}

// products: catalog array. opts: { category } ("" or "All" = every category).
// Empty query keeps catalog order; otherwise best score first, then name, then catalog order.
function filter(products, query, opts) {
    if (!Array.isArray(products)) return []
    var category = (opts && typeof opts.category === "string") ? opts.category : ""
    if (category === "All") category = ""
    var tokens = tokenize(query)
    var hits = []
    for (var i = 0; i < products.length; ++i) {
        var p = products[i]
        if (!_isProduct(p)) continue
        if (category !== "" && _text(p.category) !== _text(category)) continue
        var score = 0
        if (tokens.length > 0) {
            var f = _fields(p)
            for (var k = 0; k < tokens.length; ++k) {
                var s = _tokenScore(f, tokens[k])
                if (s < 0) { score = -1; break }
                score += s
            }
            if (score < 0) continue
        }
        hits.push({ p: p, score: score, name: _text(p.name), at: i })
    }
    if (tokens.length > 0) {
        hits.sort(function(a, b) {
            if (a.score !== b.score) return b.score - a.score
            if (a.name !== b.name) return a.name < b.name ? -1 : 1
            return a.at - b.at
        })
    }
    var out = []
    for (var j = 0; j < hits.length; ++j) out.push(hits[j].p)
    return out
}
