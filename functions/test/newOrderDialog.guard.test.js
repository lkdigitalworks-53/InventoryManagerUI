"use strict";

// Atomic-ops NO3a review sweep (2026-11-24). KNOWN-ISSUES 139: the real NewOrderDialog has no headless test (it imports Felgo),
// and tst_NewOrderDialogSubmitGuard.qml only tests a hand-written replica. This file pins the SOURCE of the three things that
// keep the "Place order" sheet from sticking on its busy overlay or from making a second order:
//   - trySubmit: `if (busy) return` first, `busy = true` before `orderCreated(` is emitted, no totals or status in the payload;
//   - the Connections block: each of the three answers (added, failed, deferred) is guarded by `dlg.busy`, clears it, and
//     "deferred" closes the sheet in a `finally` so a throwing toast cannot leave the overlay up;
//   - the routing: Logic declares the signal, DataModel emits it ONLY for queued and unconfirmed, and never auto-approves a replay.

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

const QML = path.join(__dirname, "..", "..", "qml");
const read = (p) => fs.readFileSync(path.join(QML, p), "utf8");
const DIALOG = read("pages/NewOrderDialog.qml");
const LOGIC = read("logic/Logic.qml");
const DATAMODEL = read("model/DataModel.qml");

function block(src, startNeedle) {
    const at = src.indexOf(startNeedle);
    assert.ok(at >= 0, "missing: " + startNeedle);
    const open = src.indexOf("{", at);
    let depth = 0, i = open;
    for (; i < src.length; i++) {
        if (src[i] === "{") depth++;
        else if (src[i] === "}" && --depth === 0) break;
    }
    return src.substring(at, i + 1);
}
const strip = (s) => s.replace(/\/\/[^\n]*/g, "");
// The whole `Connections { target: logic ... }` block (not just the first handler inside it).
function logicConnections() {
    const at = DIALOG.lastIndexOf("Connections {", DIALOG.indexOf("target: logic"));
    assert.ok(at >= 0, "no Connections block targeting logic");
    return strip(block(DIALOG.substring(at), "Connections {"));
}

test("D-1 trySubmit: the busy guard is the first statement and busy is set before the order is emitted", () => {
    const body = strip(block(DIALOG, "function trySubmit()"));
    const first = body.split("\n").map((l) => l.trim()).filter((l) => l.length > 0 && !l.startsWith("function"))[0];
    assert.equal(first, "if (busy) return");
    assert.ok(body.indexOf("busy = true") > 0 && body.indexOf("busy = true") < body.indexOf("orderCreated("), "busy first, then the emit");
});

test("D-2 the orderCreated payload carries no totals and no status (the store is their one author)", () => {
    const emit = block(strip(block(DIALOG, "function trySubmit()")), "orderCreated(");
    for (const banned of ["items:", "total:", "status:", "subtotal:"]) assert.ok(emit.indexOf(banned) < 0, "payload must not carry " + banned);
    for (const needed of ["customer:", "date:", "email:", "phone:", "products:", "orderChannel:", "staffId:"]) assert.ok(emit.indexOf(needed) >= 0, "payload lost " + needed);
});

test("D-3 every answer handler is guarded by busy and clears it, so a late or foreign signal changes nothing", () => {
    const conn = logicConnections();
    for (const h of ["onOrderAdded(orderId)", "onOrderCreationFailed(errorMessage)", "onOrderCreationDeferred(status)"]) {
        const body = block(conn, "function " + h);
        assert.ok(/if \(!dlg\.busy\) return/.test(body), h + " must start from the busy guard");
        assert.ok(body.indexOf("dlg.busy = false") > body.indexOf("if (!dlg.busy) return"), h + " must clear busy");
    }
    assert.equal((conn.match(/function on[A-Z]\w*\(/g) || []).length, 3, "a fourth handler needs its own busy rule here");
});

test("D-4 'deferred' shows the store's text for the status and closes in a finally (a throwing toast cannot leave the overlay up)", () => {
    const body = block(logicConnections(), "function onOrderCreationDeferred(status)");
    assert.ok(/try \{ Toast\.show\(OrdersStore\.createDoneMessage\(status\)\) \} finally \{ dlg\.close\(\) \}/.test(body));
    assert.ok(body.indexOf("dlg.busy = false") < body.indexOf("Toast.show("), "busy is cleared before anything that can throw");
});

test("D-5 Logic declares orderCreationDeferred(status) and addOrder without items, total or status", () => {
    assert.ok(/signal orderCreationDeferred\(string status\)/.test(LOGIC));
    assert.ok(/signal addOrder\(var customer, var date,\s*string email, string phone, var products,\s*string orderChannel, string staffId\)/.test(LOGIC));
});

test("D-6 DataModel.onAddOrder: deferred only for queued and unconfirmed; auto-approve never for a replay", () => {
    const body = strip(block(DATAMODEL, "function onAddOrder("));
    assert.ok(/if \(status === "queued" \|\| status === "unconfirmed"\) \{[\s\S]*?orderCreationDeferred\(status\)[\s\S]*?return\s*\}/.test(body));
    assert.ok(/if \(status !== "replayed"\) _autoApproveNewOrder\(newOrderId\)/.test(body));
    assert.ok(body.indexOf("orderAdded(newOrderId)") < body.indexOf("_autoApproveNewOrder("), "the sheet closes before an approval starts");
    assert.equal((body.match(/_autoApproveNewOrder\(/g) || []).length, 1, "one approval site, so one place to gate");
});
