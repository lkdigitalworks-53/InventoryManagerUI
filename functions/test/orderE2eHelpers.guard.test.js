"use strict";

// Atomic-ops NO3a: OrdersStore.addOrder refuses offline and is ONE awaited operation, so the three e2e files that create orders
// run every add inside `_withOnline`. Same trap as AP3a (PR #203): going "online" runs AuthService.init() -> loadSession() ->
// clear(), which wipes the fixture token and tenant these files set by hand, and the add callback then never fires. The QML
// engine cannot run in this sandbox, so this pins the SOURCE: capture the fixture, flip online, put the fixture back, run, restore
// in `finally`; and every addOrder call sits inside the wrapper, with the operation URL pointed at the emulator.

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

const E2E_DIR = path.join(__dirname, "..", "..", "test", "e2e");

function fnBody(src, name) {
    const at = src.indexOf("    function " + name + "(");
    assert.ok(at >= 0, "no " + name);
    const next = src.slice(at + 1).search(/\n    function /);
    return next < 0 ? src.slice(at) : src.slice(at, at + 1 + next);
}
const index = (body, needle) => { const i = body.indexOf(needle); assert.ok(i >= 0, "missing: " + needle); return i; };

for (const f of ["OrdersE2E", "OrdersStoreE2E", "ReturnAfterMetadataEditE2E"]) {
    const src = fs.readFileSync(path.join(E2E_DIR, `tst_${f}.qml`), "utf8");

    test(`O-1 ${f}: _withOnline captures the fixture BEFORE the flip, restores it right AFTER, and puts online back in a finally`, () => {
        const b = fnBody(src, "_withOnline");
        const saved = index(b, "var savedAuth = { idToken: AuthStore.idToken, uid: AuthStore.uid, tenantId: AuthStore.tenantId }");
        const flip = index(b, "AuthService.isOnline = true");
        const rt = index(b, "AuthStore.idToken = savedAuth.idToken"), ru = index(b, "AuthStore.uid = savedAuth.uid"), rn = index(b, "AuthStore.tenantId = savedAuth.tenantId");
        const tryAt = index(b, "try { return fn() }"), back = index(b, "AuthService.isOnline = wasOnline");
        assert.ok(index(b, "var wasOnline = AuthService.isOnline") < flip);
        assert.ok(saved < flip && flip < rt && flip < ru && flip < rn && Math.max(rt, ru, rn) < tryAt && tryAt < back);
        assert.ok(b.includes("finally"));
    });

    test(`O-2 ${f}: every OrdersStore.addOrder call is inside a _withOnline callback, with the new argument shape`, () => {
        const calls = [...src.matchAll(/OrdersStore\.addOrder\(/g)].map((m) => m.index);
        assert.ok(calls.length >= 1);
        for (const at of calls) {
            const before = src.slice(0, at);
            const open = before.lastIndexOf("_withOnline(function() {");
            assert.ok(open >= 0, "addOrder outside _withOnline at offset " + at);
            // no function-level close between the wrapper's opening and the call: the call belongs to that callback
            assert.ok(!/\n    function \w+\(/.test(before.slice(open)), "the wrapper belongs to another function");
            const tail = src.slice(at, at + 220);
            assert.match(tail, /addOrder\(\s*"[^"]*"|addOrder\(\s*customer,/);
            assert.ok(!/"pending", new Date\(\)/.test(tail), "the old (items, total, status) arguments are gone");
        }
        assert.ok(!/totals\.itemCount, totals\.total/.test(src));
    });

    test(`O-3 ${f}: the wait for the callback is inside the online window and still fails loudly`, () => {
        assert.ok(/tryVerify\(function\(\) \{ return (done|firstDone && secondDone) \}, \d+,\s*"[^"]*callback[^"]*never fired"\)\s*\n\s*\}\)/.test(src));
    });
}

test("O-4 OrdersStoreE2E points the operation URL at the emulator and restores it (the other two already did)", () => {
    const src = fs.readFileSync(path.join(E2E_DIR, "tst_OrdersStoreE2E.qml"), "utf8");
    assert.ok(src.includes('Gateway.operationFunctionUrl = emulatorFunctionsBase + "/recordOperation"'));
    assert.ok(src.includes("Gateway.operationFunctionUrl = realOperationFunctionUrl"));
    assert.ok(src.includes('readonly property string realOperationFunctionUrl: "https://asia-south1-inventorymanager-48392.cloudfunctions.net/recordOperation"'));
    for (const f of ["OrdersE2E", "ReturnAfterMetadataEditE2E"]) {
        const s = fs.readFileSync(path.join(E2E_DIR, `tst_${f}.qml`), "utf8");
        assert.ok(s.includes('Gateway.operationFunctionUrl = emulatorFunctionsBase + "/recordOperation"'), f);
    }
});
