"use strict";

// Atomic-ops AP3a review fix (PR #203, E2E 29 failures): the six e2e `_createProduct` helpers go "online" for the add
// (InventoryStore.addProduct refuses offline, D-AP-7). Going online runs AuthService.init() while AuthStore.isAuthenticated is
// false (the e2e files set idToken/uid/tenantId directly), and init() -> AuthStore.loadSession() -> clear() wipes them, so
// Gateway._sendOperation returns silently and the add callback never fires. The QML engine cannot run in this sandbox, so
// this pins the SOURCE of every helper: capture the fixture, flip online, put the fixture back, add, restore in `finally`.
// If a future edit drops the restore, this fails in the Functions Tests job (fast) instead of 29 E2E tests later.

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

const E2E_DIR = path.join(__dirname, "..", "..", "test", "e2e");
const FILES = ["InventoryE2E", "OrdersE2E", "ProductLegacyPhotoUrlE2E", "ProductPhotosE2E", "ReturnAfterMetadataEditE2E", "StockBatchStoreE2E"];

// The text of the `_createProduct*` function: from its declaration to the next top-level `    function ` (or end of file).
function helperBody(src) {
    // `_createProduct`, or `_createProductWithStock` in StockBatchStoreE2E.
    const m = /function _createProduct\w*\(/.exec(src);
    assert.ok(m, "no _createProduct helper");
    const start = m.index;
    const rest = src.slice(start + 1);
    const next = rest.search(/\n    function /);
    return next < 0 ? src.slice(start) : src.slice(start, start + 1 + next);
}

function at(body, needle) {
    const i = body.indexOf(needle);
    assert.ok(i >= 0, "missing: " + needle);
    return i;
}

for (const f of FILES) {
    const src = fs.readFileSync(path.join(E2E_DIR, `tst_${f}.qml`), "utf8");
    const body = helperBody(src);

    test(`E2E-G1 ${f}: the helper saves the fixture BEFORE going online and restores it right AFTER, before the add`, () => {
        const saved = at(body, "var savedAuth = { idToken: AuthStore.idToken, uid: AuthStore.uid, tenantId: AuthStore.tenantId }");
        const flip = at(body, "AuthService.isOnline = true");
        const restoreToken = at(body, "AuthStore.idToken = savedAuth.idToken");
        const restoreUid = at(body, "AuthStore.uid = savedAuth.uid");
        const restoreTenant = at(body, "AuthStore.tenantId = savedAuth.tenantId");
        const add = at(body, "InventoryStore.addProduct(");
        assert.ok(saved < flip, "the fixture must be captured before the flip");
        assert.ok(flip < restoreToken && flip < restoreUid && flip < restoreTenant, "the fixture must be restored after the flip");
        assert.ok(restoreToken < add && restoreUid < add && restoreTenant < add, "the fixture must be restored before the add is sent");
    });

    test(`E2E-G2 ${f}: online is put back in a finally, so a failed wait cannot leave the next test online`, () => {
        const wasOnline = at(body, "var wasOnline = AuthService.isOnline");
        const tryAt = at(body, "try {");
        const finallyAt = at(body, "} finally {");
        const back = at(body, "AuthService.isOnline = wasOnline");
        assert.ok(wasOnline < tryAt && tryAt < finallyAt && finallyAt < back);
    });

    test(`E2E-G3 ${f}: the helper still waits for the callback and checks the returned id (no silent pass)`, () => {
        assert.ok(body.includes('tryVerify(function() { return done }, 5000, "addProduct callback never fired")'));
        assert.ok(body.includes('"addProduct did not return a productId"'));
    });

    test(`E2E-G4 ${f}: the file points the operation URL at the emulator and restores the real one`, () => {
        assert.ok(src.includes('Gateway.operationFunctionUrl = emulatorFunctionsBase + "/recordOperation"'));
        assert.ok(src.includes("Gateway.operationFunctionUrl = realOperationFunctionUrl"));
    });
}

test("E2E-G5 the six files are exactly the ones that call InventoryStore.addProduct (a new e2e caller must join this guard)", () => {
    const callers = fs.readdirSync(E2E_DIR)
        .filter((n) => /^tst_.*\.qml$/.test(n))
        .filter((n) => fs.readFileSync(path.join(E2E_DIR, n), "utf8").includes("InventoryStore.addProduct("))
        .map((n) => n.replace(/^tst_/, "").replace(/\.qml$/, ""))
        .sort();
    assert.deepEqual(callers, FILES.slice().sort());
});
