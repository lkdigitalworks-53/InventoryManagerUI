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
    assert.ok(/allow read: if isMember\(tenantId\)/.test(m[1]));
    assert.ok(/allow write: if false/.test(m[1]));
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
