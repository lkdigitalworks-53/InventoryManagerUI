"use strict";

// Drift guard (PR #181 review, finding F3): every error code the server's operation / delta / mutation /
// movement validators can answer must be CLASSIFIED in qml/helper/FailureCause.js. A new server code that
// is neither a cause a person can act on nor listed as an app bug would silently show "The server rejected
// this change" with no hint that retrying cannot help. The helper runs here with its REAL text.

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { load, plain } = require("./testSupport/qmlHelpers");

const FC = load("FailureCause.js");
const LIB = path.join(__dirname, "..", "lib");

function serverCodes() {
    const set = new Set();
    for (const f of ["operationLogic.js", "gatewayLogic.js", "movementLogic.js"]) {
        const src = fs.readFileSync(path.join(LIB, f), "utf8");
        for (const m of src.matchAll(/error:\s*"([a-z][a-z-]*)"/g)) set.add(m[1]);
        for (const m of src.matchAll(/_fail\("([a-z][a-z-]*)"\)/g)) set.add(m[1]);
    }
    return set;
}

// The causes a person can act on, and the kind each one is shown as (forRejection = order completion).
const COMPLETION_KIND = {
    "insufficient-quantity": "stock", "conflict": "conflict", "not-found": "missing",
    "operation-too-large": "limit", "request-id-in-use": "duplicate"
};

test("C-1 the scan finds the codes it should (so a regex that stops matching cannot pass silently)", () => {
    const codes = serverCodes();
    assert.ok(codes.size >= 30, String(codes.size));
    for (const c of ["not-found", "conflict", "mint-exhausted", "unbound-placeholder", "invalid-movement-qty", "invalid-delta-value", "unsupported-entity"])
        assert.ok(codes.has(c), c);
});

test("C-2 every server code is a known person-facing cause or an app bug, for completion and for restock", () => {
    for (const code of serverCodes()) {
        const comp = plain(FC.forRejection({ error: code }, "P"));
        const rest = plain(FC.forRestock({ error: code }, "P"));
        assert.ok(comp.text && rest.text, code);
        if (Object.prototype.hasOwnProperty.call(COMPLETION_KIND, code)) {
            assert.equal(comp.kind, COMPLETION_KIND[code], "completion " + code);
        } else if (code === "mint-exhausted") {
            // only a restock mints; forRejection has no wording for it on purpose
            assert.equal(rest.kind, "limit", code);
        } else {
            assert.equal(comp.kind, "bug", "completion: " + code + " must be a bug code, not '" + comp.kind + "'");
            assert.equal(rest.kind, "bug", "restock: " + code + " must be a bug code, not '" + rest.kind + "'");
            assert.ok(comp.text.indexOf("(" + code + ")") > 0, "the code is shown so a report can name it");
        }
    }
});

test("C-3 a code the server does not have is still 'unknown' (the bug list is not a catch-all)", () => {
    for (const code of ["brand-new-code", "toString", "", undefined, null, 5, "<b>x</b>"]) {
        assert.equal(plain(FC.forRejection({ error: code })).kind, "unknown", String(code));
        assert.equal(plain(FC.forRestock({ error: code })).kind, "unknown", String(code));
    }
});
