"use strict";

// Review (PR #188 sweep): a caller's callback that throws must not stop the Gateway's own bookkeeping.
// The REAL bodies of Gateway.qml's _callSafely, _finishOperation, _answerDeltaCallbacks and recordOperation
// run in a vm with fake collaborators (same technique as restockDialogConfirm.test.js).
//   GI-1..4  _finishOperation: other waiters, the signal, and the result of the failing waiter's siblings
//   GI-5..6  _answerDeltaCallbacks: callbacks after a throwing one are still answered
//   GI-7..8  recordOperation: a throw in the not-awaiting callback still enqueues, drains and returns the key
//   GI-9     the throw is logged, not swallowed silently
//   GI-10    source shape: no raw caller callback call is left in these functions

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");
const { extractFunction } = require("./testSupport/qmlHelpers");

const FILE = "model/Gateway.qml";
const NAMES = ["_callSafely", "_finishOperation", "_answerDeltaCallbacks", "recordOperation"];
const SRC = NAMES.map((n) => extractFunction(FILE, n)).join("\n");

function rig(over) {
    const log = { applied: [], rejected: [], drained: 0, enqueued: [], warns: [], timersStopped: 0 };
    const timer = () => ({ stop() { log.timersStopped++; }, destroy() {} });
    const ctx = {
        console: { warn() { log.warns.push(Array.from(arguments)); } },
        _operationWaiters: {}, _deltaCallbacks: {},
        maxOperationOps: 50,
        AuthService: { isOnline: false },
        OutboxStore: { enqueueOperation(o) { log.enqueued.push(o); return o; } },
        drainNow() { log.drained++; },
        _addOperationWaiter() {},
        operationApplied() { log.applied.push(Array.from(arguments)); },
        operationRejected() { log.rejected.push(Array.from(arguments)); }
    };
    Object.assign(ctx, over || {});
    vm.createContext(ctx);
    vm.runInContext(SRC, ctx);
    ctx._timer = timer;
    return { ctx, log };
}
const waiter = (ctx, fn) => ({ fn, timer: ctx._timer() });
const ITEM = { requestId: "k1", opType: "restock" };

test("GI-1 a throwing waiter does not skip the next waiter", () => {
    const { ctx } = rig();
    const got = [];
    ctx._operationWaiters = { k1: [waiter(ctx, () => { throw new Error("first"); }), waiter(ctx, (r) => got.push(r))] };
    ctx._finishOperation(ITEM, { ok: true, results: [] });
    assert.equal(got.length, 1);
});

test("GI-2 a throwing waiter does not skip the operationApplied signal", () => {
    const { ctx, log } = rig();
    ctx._operationWaiters = { k1: [waiter(ctx, () => { throw new Error("boom"); })] };
    ctx._finishOperation(ITEM, { ok: true, results: [1], idempotentReplay: true });
    assert.equal(log.applied.length, 1);
    assert.deepEqual(JSON.parse(JSON.stringify(log.applied[0])), ["k1", "restock", [1], true]);
});

test("GI-3 a throwing waiter does not skip the operationRejected signal", () => {
    const { ctx, log } = rig();
    ctx._operationWaiters = { k1: [waiter(ctx, () => { throw new Error("boom"); })] };
    ctx._finishOperation(ITEM, { ok: false, error: "x" });
    assert.equal(log.rejected.length, 1);
    assert.equal(log.applied.length, 0);
});

test("GI-4 the waiter map is cleared and every waiter's timer stopped, throw or not", () => {
    const { ctx, log } = rig();
    ctx._operationWaiters = { k1: [waiter(ctx, () => { throw new Error("a"); }), waiter(ctx, () => {})], other: [waiter(ctx, () => {})] };
    ctx._finishOperation(ITEM, { ok: true, results: [] });
    assert.deepEqual(Object.keys(ctx._operationWaiters), ["other"]);
    assert.equal(log.timersStopped, 2);
});

test("GI-5 delta callbacks after a throwing one are still answered", () => {
    const { ctx } = rig();
    const got = [];
    ctx._deltaCallbacks = { k1: [() => { throw new Error("a"); }, (r) => got.push(["b", r]), (r) => got.push(["c", r])] };
    ctx._answerDeltaCallbacks("k1", { ok: true });
    assert.equal(got.length, 2);
});

test("GI-6 delta callbacks: the key is forgotten, and no callbacks is a no-op", () => {
    const { ctx } = rig();
    ctx._deltaCallbacks = { k1: [() => { throw new Error("a"); }], k2: [() => {}] };
    ctx._answerDeltaCallbacks("k1", { ok: true });
    assert.deepEqual(Object.keys(ctx._deltaCallbacks), ["k2"]);
    ctx._answerDeltaCallbacks("none", { ok: true });
    assert.deepEqual(Object.keys(ctx._deltaCallbacks), ["k2"]);
});

test("GI-7 recordOperation: a throw in the not-awaiting callback still drains and returns the key", () => {
    const { ctx, log } = rig();
    const key = ctx.recordOperation("restock", [{ kind: "mint" }], "k9", { awaitServer: false }, () => { throw new Error("toast failed"); });
    assert.equal(key, "k9");
    assert.equal(log.enqueued.length, 1, "queued");
    assert.equal(log.drained, 1, "drained");
});

test("GI-8 recordOperation: the not-awaiting callback still gets { ok, queued }", () => {
    const { ctx } = rig();
    let got;
    ctx.recordOperation("restock", [{ kind: "mint" }], "k9", {}, (r) => { got = JSON.parse(JSON.stringify(r)); });
    assert.deepEqual(got, { ok: true, queued: true, requestId: "k9" });
});

test("GI-9 a throw is logged with the request id, not swallowed silently", () => {
    const { ctx, log } = rig();
    ctx._operationWaiters = { k1: [waiter(ctx, () => { throw new Error("boom"); })] };
    ctx._finishOperation(ITEM, { ok: true, results: [] });
    assert.equal(log.warns.length, 1);
    assert.equal(log.warns[0][1], "k1");
    assert.match(String(log.warns[0][2]), /boom/);
});

test("GI-10 no raw caller callback is invoked in these functions any more", () => {
    assert.ok(!/waiters\[i\]\.fn\(result\)/.test(SRC));
    assert.ok(!/callbacks\[i\]\(result\)/.test(SRC.replace(/_callSafely\(callbacks\[i\], result, requestId\)/, "")));
    assert.ok(!/else callback\(\{ ok: true, queued: true/.test(SRC));
});

test("GI-11 a normal (non-throwing) path behaves as before: waiter result is the very object passed", () => {
    const { ctx } = rig();
    let seen;
    const result = { ok: true, results: [] };
    ctx._operationWaiters = { k1: [waiter(ctx, (r) => { seen = r; })] };
    ctx._finishOperation(ITEM, result);
    assert.equal(seen, result);
});
