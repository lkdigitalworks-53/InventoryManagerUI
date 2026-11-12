"use strict";

// P1 S4a source guards for the stock register. These pin facts that a behavioural test cannot
// see: the module stays pure, the endpoint stays read-only, and the lists the register copies
// from other places cannot drift.

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

const Reg = require("../lib/stockRegisterMath");
const Movement = require("../lib/movementLogic");

const root = path.join(__dirname, "..");
const mathSrc = fs.readFileSync(path.join(root, "lib/stockRegisterMath.js"), "utf8");
const indexSrc = fs.readFileSync(path.join(root, "index.js"), "utf8");

function handlerBlock() {
    const start = indexSrc.indexOf("exports.computeStockRegister");
    assert.ok(start > 0, "handler not found");
    const end = indexSrc.indexOf("// Product photos (2026-09-21)", start);
    assert.ok(end > start, "end marker not found");
    return indexSrc.slice(start, end);
}

test("SRG-01 stockRegisterMath is pure: it requires only movementLogic, no Firebase, no fs, no network", () => {
    const requires = Array.from(mathSrc.matchAll(/require\(\s*["']([^"']+)["']\s*\)/g)).map((m) => m[1]);
    assert.deepEqual(requires, ["./movementLogic"]);
    assert.ok(!/\bDate\.now\b|\bnew Date\(\)/.test(mathSrc), "no clock inside the math: time is an input");
});

test("SRG-02 the endpoint is read-only: no write, transaction, batch or delete call inside the handler", () => {
    const block = handlerBlock();
    for (const forbidden of [".set(", ".update(", ".delete(", ".create(", "runTransaction", "batch(", "bulkWriter", "FieldValue", "txn."]) {
        assert.ok(block.indexOf(forbidden) < 0, "handler must not contain " + forbidden);
    }
});

test("SRG-03 the endpoint reads the ledger by streaming (no in-memory copy of every row) and has a row cap", () => {
    const block = handlerBlock();
    assert.ok(/streamAllPaged\(\s*db,\s*tenantRoot \+ "\/stock_movements"/.test(block));
    assert.ok(/REGISTER_MAX_LEDGER_ROWS/.test(block));
    assert.ok(!/readAllPaged\(\s*db,\s*tenantRoot \+ "\/stock_movements"/.test(block), "the ledger must never be materialised whole");
});

test("SRG-04 the role gate comes after the tenant context and before any read", () => {
    const block = handlerBlock();
    const ctx = block.indexOf("deriveContext(");
    const gate = block.indexOf("canViewRegister(");
    const win = block.indexOf("parseWindow(");
    const read = block.indexOf("streamAllPaged(");
    assert.ok(ctx > 0 && ctx < gate && gate < win && win < read, "order: context, role, window, read");
});

test("SRG-05 the register's kinds are the server's kinds (no copy to drift) and the role list is owner/admin/manager", () => {
    assert.equal(Reg.KINDS, Movement.MOVEMENT_KINDS);
    assert.deepEqual(Reg.REGISTER_ROLES, ["owner", "admin", "manager"]);
    const validRoles = indexSrc.match(/const VALID_ROLES = (\[[^\]]*\])/);
    assert.ok(validRoles, "VALID_ROLES not found");
    const valid = JSON.parse(validRoles[1]);
    for (const r of Reg.REGISTER_ROLES) assert.ok(valid.indexOf(r) >= 0, r + " must be a valid member role");
    assert.deepEqual(valid.filter((r) => Reg.REGISTER_ROLES.indexOf(r) < 0), ["staff"], "only staff is refused");
});

test("SRG-06 every ledger row field the register reads is a field the server writes", () => {
    const ctx = { baseId: "b", productId: "p", actorUid: "u", actorRole: "owner", serverTimestamp: 1, clientTimestamp: 1, requestId: "r" };
    const built = Movement.buildRows(Movement.deriveMovement(-1, "sale"), ctx)[0].data;
    // D-R2: productName is read through cleanProductName, so the register and the writer clean it alike.
    const named = Movement.buildRows(Movement.deriveMovement(-1, "sale"), Object.assign({ productName: "Rice" }, ctx))[0].data;
    assert.equal(named.productName, "Rice");
    assert.ok(mathSrc.indexOf("row.productName") >= 0, "register no longer reads productName");
    assert.ok(mathSrc.indexOf("cleanProductName") >= 0, "register must clean the ledger name like the writer");
    for (const field of ["productId", "kind", "qty", "serverTimestamp"]) {
        assert.ok(Object.prototype.hasOwnProperty.call(built, field), "server rows no longer carry " + field);
        assert.ok(mathSrc.indexOf("row." + field) >= 0, "register no longer reads " + field);
    }
});

test("SRG-07 the response and error codes the client will rely on are all in the handler", () => {
    const block = handlerBlock();
    for (const code of ["method-not-allowed", "missing-token", "invalid-token", "no-tenant-context", "role-not-allowed", "ledger-too-large", "ledger-scan-timeout", "compute-failed"]) {
        assert.ok(block.indexOf('"' + code + '"') >= 0, code);
    }
    assert.ok(/error: win\.error/.test(block), "invalid-window comes from parseWindow");
    assert.equal(Reg.parseWindow(2, 1).error, "invalid-window");
});

test("SRG-08 no client-writable path: the ledger collection is still write-denied in firestore.rules", () => {
    const rules = fs.readFileSync(path.join(root, "..", "firestore.rules"), "utf8");
    const m = rules.match(/match \/stock_movements\/\{docId\} \{([^}]*)\}/);
    assert.ok(m, "stock_movements rule not found");
    assert.ok(/allow write: if false/.test(m[1]));
});

test("SRG-08b D-R1: stock_movements read uses isLedgerReader, whose role list equals REGISTER_ROLES, and only it uses it", () => {
    const rules = fs.readFileSync(path.join(root, "..", "firestore.rules"), "utf8");
    const m = rules.match(/match \/stock_movements\/\{docId\} \{([^}]*)\}/);
    assert.ok(/allow read: if isLedgerReader\(tenantId\);/.test(m[1]), "stock_movements read must be isLedgerReader");
    assert.equal((rules.match(/isLedgerReader\(tenantId\)/g) || []).length, 2, "defined once, used once");
    const fn = rules.match(/function isLedgerReader\(tenantId\) \{([^}]*)\}/);
    assert.ok(fn, "isLedgerReader not found");
    assert.ok(/isMember\(tenantId\)\s*&&/.test(fn[1]), "an active member with a valid role first");
    const list = fn[1].match(/myRole\(tenantId\) in \[([^\]]*)\]/);
    assert.ok(list, "role list not found");
    const roles = list[1].split(",").map((r) => r.trim().replace(/'/g, ""));
    assert.deepEqual(roles, Reg.REGISTER_ROLES, "firestore.rules and REGISTER_ROLES must not drift");
});

test("SRG-08e D-R1: the generic fallback's READ carves stock_movements out (Firestore ORs every matching rule: without it every member reads the ledger)", () => {
    const rules = fs.readFileSync(path.join(root, "..", "firestore.rules"), "utf8");
    const m = rules.match(/match \/\{collection\}\/\{docId\} \{([\s\S]*?)\n      \}/);
    assert.ok(m, "generic fallback block not found");
    const read = m[1].match(/allow read: if ([^;]*);/);
    assert.ok(read, "fallback read rule not found");
    assert.ok(/collection != 'stock_movements'/.test(read[1]), "the fallback read must exclude stock_movements");
    assert.ok(/!isServerOnlyCollection\(collection\)/.test(read[1]), "the server-only carve-out must stay");
    // Any OTHER match block that would also catch stock_movements for reads must not exist.
    assert.equal((rules.match(/match \/stock_movements\//g) || []).length, 1, "exactly one stock_movements block");
});

test("SRG-08c D-R1: audit_log, transactions and stock_batches were NOT narrowed (stock_batches is KNOWN-ISSUES item 19)", () => {
    const rules = fs.readFileSync(path.join(root, "..", "firestore.rules"), "utf8");
    for (const c of ["audit_log", "transactions", "stock_batches"]) {
        const m = rules.match(new RegExp("match \\/" + c + "\\/\\{docId\\} \\{([^}]*)\\}"));
        assert.ok(m, c);
        assert.ok(/allow read: if isMember\(tenantId\);/.test(m[1]), c + " read changed");
        assert.ok(/allow write: if false/.test(m[1]), c);
    }
});

test("SRG-08d D-R1: the app never reads stock_movements directly (a client read would break for staff)", () => {
    // A plain fs walk, not a shell grep: a missing folder or a missing grep must FAIL here, never pass vacuously.
    const repo = path.join(root, "..");
    const hits = [];
    const walk = (p) => {
        if (fs.statSync(p).isDirectory()) {
            for (const name of fs.readdirSync(p)) walk(path.join(p, name));
        } else if (fs.readFileSync(p, "utf8").indexOf("stock_movements") >= 0) {
            hits.push(path.relative(repo, p));
        }
    };
    for (const target of ["qml", "src", "main.cpp"]) {
        assert.ok(fs.existsSync(path.join(repo, target)), target + " not found: the guard would pass without looking");
        walk(path.join(repo, target));
    }
    assert.deepEqual(hits, [], "a client read of stock_movements needs a role-aware UI");
});

test("SRG-09 the scan budget always ends well before the function timeout, and the stream gets page size + deadline", () => {
    const block = handlerBlock();
    const budget = indexSrc.match(/const REGISTER_SCAN_BUDGET_MS = (\d+);/);
    const pageSize = indexSrc.match(/const REGISTER_PAGE_SIZE = (\d+);/);
    const timeout = block.match(/timeoutSeconds: (\d+)/);
    assert.ok(budget && pageSize && timeout, "budget, page size and timeout constants must exist");
    // At least 10 s must remain after the last page starts: one slow page + the answer.
    assert.ok(Number(budget[1]) <= Number(timeout[1]) * 1000 - 10000, "scan budget must leave 10 s before the platform timeout");
    assert.ok(Number(pageSize[1]) >= 500 && Number(pageSize[1]) <= 5000, "page size sane");
    assert.ok(/streamAllPaged\([^)]*REGISTER_PAGE_SIZE,\s*deadlineMs\)/s.test(block), "stream must get page size and deadline");
    assert.ok(/deadlineMs !== undefined && Date\.now\(\) > deadlineMs/.test(indexSrc), "stream must check the deadline per page");
});

test("SRG-11 the count pre-check sits before the stream, uses the SAME cap constant with a strict >, and a failed count falls through", () => {
    const block = handlerBlock();
    const c = block.indexOf(".count().get()");
    const st = block.indexOf("streamAllPaged(");
    assert.ok(c > 0 && st > c, "count() must run before the stream");
    assert.ok(/ledgerCount > REGISTER_MAX_LEDGER_ROWS/.test(block), "pre-check must use the shared cap with a strict >");
    assert.ok(/typeof ledgerCount === "number"/.test(block), "a junk count must be ignored");
    const catchAt = block.indexOf("catch (countErr)");
    assert.ok(catchAt > c && catchAt < st, "count() failure must be caught locally and fall through");
    assert.ok(/streamAllPaged\(db, tenantRoot \+ "\/stock_movements", acc\.add, REGISTER_MAX_LEDGER_ROWS/.test(block), "the in-stream cap (backstop) is still the same constant");
});

test("SRG-12 the count timeout is a constant well under the scan budget, wraps count().get(), and is cleared in a finally", () => {
    const t = indexSrc.match(/const REGISTER_COUNT_TIMEOUT_MS = (\d+);/);
    const b = indexSrc.match(/const REGISTER_SCAN_BUDGET_MS = (\d+);/);
    assert.ok(t && b, "constants not found");
    assert.ok(Number(t[1]) >= 5000, "a count may take a few seconds on a big ledger");
    assert.ok(Number(t[1]) * 4 <= Number(b[1]), "the count must leave most of the scan budget to the stream");
    assert.ok(/withTimeout\(db\.collection\(tenantRoot \+ "\/stock_movements"\)\.count\(\)\.get\(\),\s*REGISTER_COUNT_TIMEOUT_MS/.test(handlerBlock()), "count().get() must go through withTimeout");
    assert.ok(/\.finally\(\(\) => clearTimeout\(timer\)\)/.test(indexSrc), "the timer must always be cleared");
});
