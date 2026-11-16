"use strict";

// R5b: ActivityLog.adopt (qml/model/ActivityLog.qml). The real function body runs in a sandbox with the two
// properties and the prune hook it touches. tests/tst_ActivityLog.qml carries the same cases for CI's qmltestrunner.

const test = require("node:test");
const assert = require("node:assert/strict");
const vm = require("node:vm");
const { plain, extractFunction } = require("./testSupport/qmlHelpers");

function sandbox(entries) {
    const ctx = { entries: entries, revision: 0, pruned: 0, _pruneOldEntries() { ctx.pruned++; } };
    vm.runInNewContext(extractFunction("model/ActivityLog.qml", "adopt"), ctx);
    // runInNewContext evaluates a function declaration into ctx; `entries` etc. are the context's globals
    return ctx;
}
const row = (id, ts) => ({ id, kind: "product_restocked", title: "t", subtitle: "s", entityId: "p1", timestamp: ts, read: false, dismissed: false, actorUid: "u" });
const ids = (ctx) => plain(ctx.entries).map((e) => e.id);
const ts = (n) => "2026-06-15T12:00:" + String(n).padStart(2, "0") + ".000Z";

test("AD-1 a new row goes where its timestamp says: newest first, middle, oldest", () => {
    const ctx = sandbox([row("a3", ts(30)), row("a1", ts(10))]);
    assert.equal(ctx.adopt(row("a2", ts(20))), true);
    assert.deepEqual(ids(ctx), ["a3", "a2", "a1"]);
    assert.equal(ctx.adopt(row("a4", ts(40))), true);
    assert.equal(ctx.adopt(row("a0", ts(5))), true);
    assert.deepEqual(ids(ctx), ["a4", "a3", "a2", "a1", "a0"]);
    assert.equal(ctx.revision, 3);
    assert.equal(ctx.pruned, 3, "the Firestore 50-cap prune runs after each adopted row");
});

test("AD-2 into an empty list; an equal timestamp goes after the row already there", () => {
    const ctx = sandbox([]);
    assert.equal(ctx.adopt(row("a1", ts(10))), true);
    assert.equal(ctx.adopt(row("a2", ts(10))), true);
    assert.deepEqual(ids(ctx), ["a1", "a2"]);
});

test("AD-3 a row already held (same id) is ignored: no change, no revision, no prune", () => {
    const ctx = sandbox([row("a1", ts(10))]);
    assert.equal(ctx.adopt(row("a1", ts(99))), false);
    assert.deepEqual(plain(ctx.entries), [row("a1", ts(10))]);
    assert.equal(ctx.revision, 0);
    assert.equal(ctx.pruned, 0);
});

test("AD-4 anything that is not a feed row is refused and changes nothing", () => {
    const ctx = sandbox([row("a1", ts(10))]);
    for (const bad of [null, undefined, 5, "x", [], {}, { id: "" , timestamp: ts(1) }, { id: "a2" }, { id: "a2", timestamp: 5 }, { id: 7, timestamp: ts(1) }])
        assert.equal(ctx.adopt(bad), false, JSON.stringify(bad));
    assert.deepEqual(ids(ctx), ["a1"]);
    assert.equal(ctx.revision, 0);
});

test("AD-5 the list stays at 50: a newer row pushes the oldest out, a row older than all 50 is not added", () => {
    const full = []; for (let i = 0; i < 50; i++) full.push(row("e" + i, ts(59 - i)));     // 59 down to 10
    const ctx = sandbox(full);
    assert.equal(ctx.adopt(row("old", ts(1))), false);
    assert.equal(ctx.entries.length, 50);
    assert.equal(ctx.adopt(row("new", "2026-06-15T13:00:00.000Z")), true);
    assert.equal(ctx.entries.length, 50);
    assert.equal(ctx.entries[0].id, "new");
    assert.equal(ctx.entries[49].id, "e48", "the oldest (e49) was dropped");
});

test("AD-6 the array it was given is not changed in place (a binding needs a new array)", () => {
    const before = [row("a1", ts(10))];
    const ctx = sandbox(before);
    ctx.adopt(row("a2", ts(20)));
    assert.equal(before.length, 1);
    assert.notEqual(ctx.entries, before);
});

test("AD-7 a list that is not set yet (undefined) behaves like an empty one", () => {
    const ctx = sandbox(undefined);
    assert.equal(ctx.adopt(row("a1", ts(1))), true);
    assert.deepEqual(ids(ctx), ["a1"]);
});

test("AD-8 (PR #197 sweep 2) a held id BELOW the insertion point is still found: a newer copy of a held row is ignored, not added twice", () => {
    const ctx = sandbox([row("a3", ts(30)), row("a1", ts(10))]);
    assert.equal(ctx.adopt(row("a1", ts(50))), false);      // would sort first (50 > 30), but a1 is held further down
    assert.deepEqual(ids(ctx), ["a3", "a1"]);
    assert.equal(ctx.revision, 0);
    assert.equal(ctx.pruned, 0);
});
