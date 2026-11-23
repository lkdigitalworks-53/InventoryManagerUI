"use strict";
// Picker v2 S5e-3a. A depth-aware scan for raw buttons in QML text (qmltestrunner cannot load Felgo pages, so the repo
// reads source). The S5e-1 scan counted any `text:` line in a block, so a `ToolTip.text:` hid two unnamed buttons.
// Here only the button's OWN depth-1 properties count, and strings and comments are skipped when matching braces.
const fs = require("node:fs");
const path = require("node:path");

const HEAD = /\b(?:QQC\.)?(AbstractButton|ToolButton|RoundButton|Button)\s*\{/g;

// Comments become spaces (newlines kept, so line numbers stay true); string contents are kept but never scanned for braces.
function stripComments(src) {
    let out = "", i = 0, q = null;
    while (i < src.length) {
        const c = src[i], n = src[i + 1];
        if (q) {
            out += c;
            if (c === "\\") { out += n === undefined ? "" : n; i += 2; continue; }
            if (c === q) q = null;
            i++;
        } else if (c === '"' || c === "'" || c === "`") { q = c; out += c; i++; }
        else if (c === "/" && n === "/") { while (i < src.length && src[i] !== "\n") { out += " "; i++; } }
        else if (c === "/" && n === "*") {
            while (i < src.length && !(src[i] === "*" && src[i + 1] === "/")) { out += src[i] === "\n" ? "\n" : " "; i++; }
            out += "  "; i += 2;
        } else { out += c; i++; }
    }
    return out;
}

// String contents become `x` (same length, quotes kept): a brace, `text:` or `Text {` inside a string is not code.
function blankStrings(src) {
    let out = "", q = null;
    for (let i = 0; i < src.length; i++) {
        const c = src[i];
        if (q) {
            if (c === "\\") { out += "xx"; i++; } else if (c === q) { q = null; out += c; } else out += c === "\n" ? "\n" : "x";
        } else { if (c === '"' || c === "'" || c === "`") q = c; out += c; }
    }
    return out;
}

// Index of the `}` that closes the `{` at `open` (text already string-blanked); -1 when unbalanced.
function matchBrace(t, open) {
    let d = 0;
    for (let i = open; i < t.length; i++) {
        if (t[i] === "{") d++;
        else if (t[i] === "}" && --d === 0) return i;
    }
    return -1;
}

// The block's depth-1 text: every nested `{...}` emptied. `mask` decides the depth (string-blanked), `text` is what is returned.
function flatten(mask, text) {
    let out = "", d = 0;
    for (let i = 0; i < mask.length; i++) {
        const c = mask[i];
        if (c === "{") { if (d === 0) out += "{}"; d++; continue; }
        if (c === "}") { d--; continue; }
        if (d === 0) out += (text || mask)[i];
    }
    return out;
}

function scanButtons(src) {
    const s = stripComments(src), t = blankStrings(s);
    const found = [];
    HEAD.lastIndex = 0;
    let m;
    while ((m = HEAD.exec(t))) {
        const open = m.index + m[0].length - 1;
        const close = matchBrace(t, open);
        const line = t.slice(0, m.index).split("\n").length;
        if (close < 0) throw new Error("unbalanced braces after " + m[0] + " at line " + line);
        const bodyT = t.slice(open + 1, close), body = s.slice(open + 1, close);
        const own = flatten(bodyT);
        // root object of the file: nothing before it at depth 0 but imports and pragmas
        let depth = 0;
        for (let i = 0; i < m.index; i++) { if (t[i] === "{") depth++; else if (t[i] === "}") depth--; }
        found.push({
            type: m[1],
            line,
            root: depth === 0,
            named: /(^|[\s;{])Accessible\.name\s*:/.test(own),
            ownText: /(^|[\s;{])text\s*:/.test(own),
            hasTextChild: /\b(Text|Label)\s*\{/.test(bodyT),
            body,
            ownSrc: flatten(bodyT, body),
        });
        HEAD.lastIndex = open + 1; // nested buttons are found too
    }
    return found;
}

// Instances of a WRAPPER component (`IconActionButton { ... }`): the raw-button scan cannot see these, because the wrapper's own root is the
// raw button and is skipped. Same depth-1 rules; `ignored` is the "an accessible wrapper above speaks for it" escape (RefreshAction).
function scanInstances(src, typeName) {
    const s = stripComments(src), t = blankStrings(s), re = new RegExp("\\b" + typeName + "\\s*\\{", "g");
    const found = [];
    let m;
    while ((m = re.exec(t))) {
        const open = m.index + m[0].length - 1, close = matchBrace(t, open);
        const line = t.slice(0, m.index).split("\n").length;
        if (close < 0) throw new Error("unbalanced braces after " + m[0] + " at line " + line);
        const bodyT = t.slice(open + 1, close), body = s.slice(open + 1, close), own = flatten(bodyT);
        found.push({
            line,
            body,
            ownSrc: flatten(bodyT, body),
            labelled: /(^|[\s;{])label\s*:/.test(own),
            ignored: /(^|[\s;{])Accessible\.ignored\s*:\s*true/.test(own),
        });
        re.lastIndex = open + 1;
    }
    return found;
}

function qmlFiles(dir) {
    const out = [];
    for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
        const p = path.join(dir, e.name);
        if (e.isDirectory()) out.push(...qmlFiles(p));
        else if (e.name.endsWith(".qml")) out.push(p);
    }
    return out.sort();
}

// Every non-root raw button of the tree with no spoken name and no own text, split by what is drawn inside.
function scanTree(root) {
    const iconOnly = [], textChild = [];
    for (const f of qmlFiles(path.join(root, "qml"))) {
        const rel = path.relative(root, f).split(path.sep).join("/");
        for (const b of scanButtons(fs.readFileSync(f, "utf8"))) {
            if (b.root || b.named || b.ownText) continue;
            (b.hasTextChild ? textChild : iconOnly).push({ file: rel, line: b.line, type: b.type });
        }
    }
    return { iconOnly, textChild };
}

module.exports = { stripComments, blankStrings, matchBrace, flatten, scanButtons, scanInstances, qmlFiles, scanTree };
