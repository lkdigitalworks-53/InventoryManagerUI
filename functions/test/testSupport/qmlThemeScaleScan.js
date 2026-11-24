"use strict";
// Picker v2 S5e-3c. Source scans for the two things a phone can change under the app: the system font scale (`sp()` follows it, a bare number
// does not) and the system theme (a colour left to the palette follows it, a `Constants` token does not). qmltestrunner cannot load Felgo pages,
// so the repo reads source (same rules as qmlButtonScan: depth-1 properties only, comments and strings never code).
const fs = require("node:fs");
const path = require("node:path");
const { stripComments, blankStrings, scanInstances, qmlFiles } = require("./qmlButtonScan");

const COLOR = /(^|[\s;{])color\s*:/;
const idOf = (own) => { const m = /(^|[\s;{])id\s*:\s*(\w+)/.exec(own); return m ? m[2] : null; };
const rel = (root, f) => path.relative(root, f).split(path.sep).join("/");

// Every instance of `types` (e.g. TextField) with whether its OWN depth-1 block sets `color`. `QQC.TextField` matches: `\b` sits after the dot.
function scanColors(root, types) {
    const out = [];
    for (const f of qmlFiles(path.join(root, "qml"))) {
        const src = fs.readFileSync(f, "utf8");
        for (const type of types)
            for (const i of scanInstances(src, type))
                out.push({ file: rel(root, f), line: i.line, type, id: idOf(i.ownSrc), colored: COLOR.test(i.ownSrc),
                           hidden: /(^|[\s;{])visible\s*:\s*false\b/.test(i.ownSrc), own: i.ownSrc });
    }
    return out;
}

// Every `pixelSize:` line. `raw` = a bare number (never scales); `scaled` = goes through sp() or dp(); else a reference (a property, `root._font`).
function scanPixelSizes(root) {
    const out = [];
    for (const f of qmlFiles(path.join(root, "qml"))) {
        const code = blankStrings(stripComments(fs.readFileSync(f, "utf8"))).split("\n");
        code.forEach((l, n) => {
            const m = /\bpixelSize\s*:\s*([^;}\n]+)/.exec(l);
            if (!m) return;
            const expr = m[1].trim();
            out.push({ file: rel(root, f), line: n + 1, expr, raw: /^\d+(\.\d+)?$/.test(expr), scaled: /\b(sp|dp)\s*\(/.test(expr) });
        });
    }
    return out;
}

// Colour literals written inside a file (`"#rrggbb"`), per file. Constants.qml is the one place they belong.
function scanHex(root) {
    const out = {};
    for (const f of qmlFiles(path.join(root, "qml"))) {
        const n = (stripComments(fs.readFileSync(f, "utf8")).match(/"#[0-9a-fA-F]{3,8}"/g) || []).length;
        if (n) out[rel(root, f)] = n;
    }
    return out;
}

// WCAG 2.x relative luminance and contrast ratio of two `#rrggbb` strings.
function luminance(hex) {
    const h = hex.replace("#", ""), c = [0, 2, 4].map((i) => parseInt(h.slice(i, i + 2), 16) / 255)
        .map((v) => (v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4)));
    return 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2];
}
function contrast(a, b) { const [x, y] = [luminance(a), luminance(b)].sort((p, q) => q - p); return (x + 0.05) / (y + 0.05); }

// `readonly property color name: "#rrggbb"` of Constants.qml as { name: "#rrggbb" } (aliases and Qt.rgba() are skipped on purpose).
function colorTokens(constantsSrc) {
    const t = {}, re = /readonly\s+property\s+color\s+(\w+)\s*:\s*"(#[0-9a-fA-F]{6})"/g;
    let m;
    while ((m = re.exec(stripComments(constantsSrc)))) t[m[1]] = m[2];
    return t;
}

// Rows with a FIXED height (`height`, `implicitHeight`, `Layout.preferredHeight`, `Layout.maximumHeight` = `dp(N)`) that hold a `Text`. At a big font
// the words get taller than the row; `Layout.minimumHeight` grows and is not listed. `allElide` = every Text inside has `elide` or `maximumLineCount`.
function scanFixedHeightText(root, relFiles) {
    const out = [], types = ["Rectangle", "Item", "Row", "RowLayout", "ColumnLayout", "Column", "AbstractButton", "Button", "ItemDelegate", "MouseArea"];
    const HEIGHT = /(^|[\s;{])(Layout\.preferredHeight|Layout\.maximumHeight|implicitHeight|height)\s*:\s*(dp\(\s*\d+\s*\))\s*(?:$|;|\/\/)/m;
    for (const r of relFiles) {
        const src = fs.readFileSync(path.join(root, r), "utf8");
        for (const type of types)
            for (const i of scanInstances(src, type)) {
                const m = HEIGHT.exec(i.ownSrc), kids = scanInstances(i.body, "Text");
                if (m && kids.length) out.push({ file: r, type, line: i.line, prop: m[2], expr: m[3], texts: kids.length,
                    allElide: kids.every((k) => /(^|[\s;{])(elide|maximumLineCount)\s*:/.test(k.ownSrc)) });
            }
    }
    return out;
}

module.exports = { scanColors, scanPixelSizes, scanHex, scanFixedHeightText, luminance, contrast, colorTokens };
