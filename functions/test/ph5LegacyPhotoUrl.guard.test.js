"use strict";
// PH5 (2026-10-08) source guards. The product `photoUrl` / `photoUpdatedAt` fields are gone from
// the client and from the spreadsheet export. QML/C++ cannot be exercised in the sandbox or by
// `qmltestrunner` for the dialog/page/exporter, so these tests read the source text.
// Design: docs/superpowers/specs/2026-10-08-photos-ph5-legacy-removal-design.md
// Test plan: docs/superpowers/test-plans/2026-10-08-photos-ph5-test-plan.md (G01-G11).
const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

const ROOT = path.join(__dirname, "..", "..");
const read = (rel) => fs.readFileSync(path.join(ROOT, rel), "utf8");

// Case-SENSITIVE on purpose: the capital-P module alias `PhotoUrl` (PhotoUrl.js) is allowed.
function legacyTokens(src) {
    return src.match(/\bphotoUrl\b|photoUpdatedAt/g) || [];
}

function between(src, startMarker, endMarker) {
    const i = src.indexOf(startMarker);
    assert.ok(i >= 0, "marker not found: " + startMarker);
    const j = src.indexOf(endMarker, i + startMarker.length);
    assert.ok(j > i, "end marker not found: " + endMarker);
    return src.slice(i, j);
}

const NO_TOKEN_FILES = [
    ["G01", "qml/model/InventoryStore.qml"],
    ["G02", "qml/pages/EditProductDialog.qml"],
    ["G03", "qml/pages/InventoryPage.qml"],
    ["G04", "qml/pages/ImportPreviewDialog.qml"],
    ["G05", "qml/model/StorageService.qml"]
];
for (const [id, rel] of NO_TOKEN_FILES) {
    test(`${id} ${rel} has no legacy photoUrl/photoUpdatedAt token`, () => {
        assert.deepEqual(legacyTokens(read(rel)), []);
    });
}

test("G02b EditProductDialog has no legacy migration button or clearLegacyPhotoUrl call", () => {
    const src = read("qml/pages/EditProductDialog.qml");
    assert.ok(!/clearLegacyPhotoUrl/.test(src));
    assert.ok(!/Sync old photo to the cloud/.test(src));
});

const xlsx = read("src/XlsxService.cpp");
const productsSheet = between(xlsx, "void writeProductsSheet", "void writeOrdersSheet");

test("G06 kProductHeaders has exactly 14 entries and no Photo URL", () => {
    const body = between(xlsx, "kProductHeaders = {", "};");
    const names = body.match(/"[^"]+"/g) || [];
    assert.equal(names.length, 14);
    assert.ok(!names.includes('"Photo URL"'));
});

function contiguousColumns(matches) {
    const cols = matches.map((m) => Number(m[1]));
    assert.deepEqual(cols, Array.from({ length: cols.length }, (_, i) => i + 1));
    return cols.length;
}

test("G07 writeProductsSheet writes exactly 14 contiguous columns", () => {
    const n = contiguousColumns([...productsSheet.matchAll(/doc\.write\(row,\s*(\d+),/g)]);
    assert.equal(n, 14);
});

test("G08 writeProductsSheet sets exactly 14 contiguous column widths", () => {
    const n = contiguousColumns([...productsSheet.matchAll(/doc\.setColumnWidth\((\d+),/g)]);
    assert.equal(n, 14);
});

test("G09 product template lists exactly 14 columns and no Photo URL row", () => {
    const tpl = between(xlsx, 'if (kind == "products") {', "} else {");
    const rows = tpl.match(/^\s*\{"/gm) || [];
    assert.equal(rows.length, 14);
    assert.ok(!/Photo URL/.test(tpl));
    assert.ok(!/photo/i.test(productsSheet) && !/photoUrl/.test(xlsx));
});

test("G10 REGRESSION: profile photoUrl (AuthStore/AuthService) is untouched", () => {
    assert.ok(legacyTokens(read("qml/model/AuthStore.qml")).length > 0);
    assert.ok(legacyTokens(read("qml/model/AuthService.qml")).length > 0);
    assert.ok(/photoUrl/.test(read("qml/pages/ProfilePage.qml")) || /AuthStore\.photoUrl/.test(read("qml/pages/ProfilePage.qml")));
});

test("G11 MONKEY scanner self-test: flags real uses, ignores the PhotoUrl alias, survives odd text", () => {
    const flagged = [
        "photoUrl", 'p.photoUrl || ""', "photoUrl:", '"photoUrl"', "photoUpdatedAt",
        "a\r\nphotoUrl\r\n", "\tphotoUrl\t", "// photoUrl in a comment", "/* photoUpdatedAt */"
    ];
    for (const t of flagged) assert.ok(legacyTokens(t).length >= 1, JSON.stringify(t));
    const ignored = [
        'import "../helper/PhotoUrl.js" as PhotoUrl', "PhotoUrl.toFileUrl(x)", "photoDownloadUrl(a)",
        "photoUrlsList", "myphotoUrl", "", "   ", "\n\n"
    ];
    for (const t of ignored) assert.deepEqual(legacyTokens(t), [], JSON.stringify(t));
    // pseudo-random junk never throws and never reports a token unless one was planted
    let seed = 7;
    const rnd = () => (seed = (seed * 1103515245 + 12345) & 0x7fffffff) / 0x7fffffff;
    const alphabet = "abcdefgPhotoUrl \n\t{}()\":;.,/*";
    for (let k = 0; k < 200; k++) {
        let s = "";
        for (let i = 0, n = Math.floor(rnd() * 80); i < n; i++) s += alphabet[Math.floor(rnd() * alphabet.length)];
        const planted = /\bphotoUrl\b|photoUpdatedAt/.test(s);
        assert.equal(legacyTokens(s).length > 0, planted);
    }
});
