# Gateway stuck-write indicator Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Tell the user, persistently and per device, when queued writes keep failing server-side, without changing any retry, backoff or drop behaviour.

**Architecture:** A pure `.pragma library` helper (`StuckWrites.js`) counts server-side failures per outbox `requestId`. `Gateway` owns one state object, calls the helper beside every `OutboxStore.markFailed` in the three senders, and prunes it from the live outbox inside `_reschedule()`. `Main.qml` republishes `Gateway.stuckCount` as `syncStuckCount`; `GlassHeader`'s existing caption line shows it. Spec: `docs/superpowers/specs/2026-09-19-gateway-stuck-write-indicator-design.md`.

**Tech Stack:** Qt 6 / QML (Felgo `App` root), `qmltestrunner` (CI job `QML Tests`), plain JS helper, Node only as a local scratch harness for the helper's tests.

## Global Constraints

- Threshold: `StuckWrites.THRESHOLD = 5` server-side failures per `requestId` (about 3 minutes with backoff `[2s, 8s, 30s, 2m, 10m]`).
- Counts: `status >= 400` except 401 and 409. Status 0 and any success never count.
- Toast text, once when `stuckCount` goes 0 to 1: `Some changes aren't syncing. The app keeps retrying.`
- Header caption, when online and `syncStuckCount > 0`: `%n change(s) not syncing. Still retrying.` in `Constants.danger`. The offline message keeps precedence.
- Retry, backoff and drop behaviour: unchanged. No rollback, no parking, no server change.
- Hook all three senders: `_send`, `_sendBatch`, `_sendDelta`.
- Do not build or run the app. Do not install Qt tooling in the sandbox; CI is the only signal for QML.
- Branch `fix/2026-09-19-gateway-send-terminal-failure`, never `main`. Commit identity `Taher (via Claude session) <dextran52@gmail.com>`. Push after each task; never write the PAT into the repo.
- Every change: tests, a test plan from the template (Skill 49), and `SKILLS.md` / `AGENTS.md` / `README.md` updates as needed.

---

### Task 1: `StuckWrites` helper and its tests

**Files:**
- Create: `qml/helper/StuckWrites.js`
- Create: `tests/tst_StuckWrites.qml`
- Scratch, not committed: `/tmp/h/run.js`

**Interfaces:**
- Produces: `THRESHOLD` (number), `newState() -> {failures, stuck}`, `isStuckStatus(status) -> bool`, `noteFailure(state, requestId, status) -> bool` (true only for the tipping failure), `stuckCount(state) -> int`, `prune(state, liveIds) -> int`.

- [ ] **Step 1: Write the failing test**

Create `tests/tst_StuckWrites.qml`:

```qml
import QtQuick
import QtTest
import "../qml/helper/StuckWrites.js" as SW

// Headless tests for the bookkeeping behind Gateway.stuckCount. Pure JS, no
// singletons, so nothing here can be polluted by another test file.
// Design: docs/superpowers/specs/2026-09-19-gateway-stuck-write-indicator-design.md
TestCase {
    name: "StuckWrites"

    // Fails `id` `n` times with `status`; returns how many of those calls
    // reported "this failure tipped the item into stuck".
    function _fail(state, id, status, n) {
        var tipped = 0
        for (var i = 0; i < n; ++i)
            if (SW.noteFailure(state, id, status)) tipped++
        return tipped
    }

    // Small deterministic PRNG (LCG) so a failing monkey run reproduces from its seed.
    function _rng(seed) {
        var s = seed
        return function() {
            s = (s * 1664525 + 1013904223) % 4294967296
            return s / 4294967296
        }
    }

    // ── isStuckStatus ────────────────────────────────────────────────────────

    function test_isStuckStatus_counts_server_side_failures() {
        var counted = [400, 403, 404, 408, 422, 429, 500, 502, 503, 504, 599]
        for (var i = 0; i < counted.length; ++i)
            compare(SW.isStuckStatus(counted[i]), true, "status " + counted[i])
    }

    function test_isStuckStatus_ignores_offline_auth_conflict_and_success() {
        // 0 = offline / no response, 401 = token refresh, 409 = CAS conflict
        // (dropped elsewhere), 1xx-3xx = not a failure at all.
        var ignored = [0, 100, 200, 204, 299, 301, 399, 401, 409]
        for (var i = 0; i < ignored.length; ++i)
            compare(SW.isStuckStatus(ignored[i]), false, "status " + ignored[i])
    }

    function test_isStuckStatus_ignores_missing_or_non_numeric_status() {
        compare(SW.isStuckStatus(undefined), false)
        compare(SW.isStuckStatus(null), false)
        compare(SW.isStuckStatus(NaN), false)
    }

    function test_isStuckStatus_boundary_is_400() {
        compare(SW.isStuckStatus(399), false)
        compare(SW.isStuckStatus(400), true)
    }

    // ── noteFailure ──────────────────────────────────────────────────────────

    function test_threshold_is_five() {
        // Pinned on purpose: 5 server-side failures is about 3 minutes with
        // OutboxStore's backoff ([2s, 8s, 30s, 2m, 10m]). Changing it changes how
        // quickly the user is told, so it should be a deliberate edit.
        compare(SW.THRESHOLD, 5)
    }

    function test_failures_below_threshold_do_not_tip() {
        var state = SW.newState()
        compare(_fail(state, "a", 500, SW.THRESHOLD - 1), 0)
        compare(SW.stuckCount(state), 0)
    }

    function test_the_threshold_failure_tips_exactly_once() {
        var state = SW.newState()
        compare(_fail(state, "a", 500, SW.THRESHOLD), 1)
        compare(SW.stuckCount(state), 1)
        compare(_fail(state, "a", 500, 10), 0, "later failures of an already-stuck item must not tip again")
        compare(SW.stuckCount(state), 1)
    }

    function test_the_status_may_change_between_failures() {
        var state = SW.newState()
        var mix = [500, 503, 403, 404, 400]
        var tipped = 0
        for (var i = 0; i < mix.length; ++i)
            if (SW.noteFailure(state, "a", mix[i])) tipped++
        compare(tipped, 1)
        compare(SW.stuckCount(state), 1)
    }

    function test_offline_auth_and_conflict_failures_neither_count_nor_reset() {
        var state = SW.newState()
        _fail(state, "a", 500, SW.THRESHOLD - 1)
        compare(_fail(state, "a", 0, 50), 0)
        compare(_fail(state, "a", 401, 50), 0)
        compare(_fail(state, "a", 409, 50), 0)
        compare(SW.stuckCount(state), 0)
        compare(_fail(state, "a", 503, 1), 1, "the next server-side failure is still the 5th")
        compare(SW.stuckCount(state), 1)
    }

    function test_non_counting_statuses_leave_no_bookkeeping() {
        var state = SW.newState()
        _fail(state, "a", 0, 20)
        _fail(state, "a", 401, 20)
        _fail(state, "a", 409, 20)
        _fail(state, "a", 200, 20)
        compare(Object.keys(state.failures).length, 0)
        compare(Object.keys(state.stuck).length, 0)
    }

    function test_items_are_counted_independently() {
        var state = SW.newState()
        _fail(state, "a", 500, SW.THRESHOLD)
        _fail(state, "b", 500, SW.THRESHOLD - 1)
        compare(SW.stuckCount(state), 1)
        compare(_fail(state, "b", 500, 1), 1)
        compare(SW.stuckCount(state), 2)
    }

    function test_states_are_independent_of_each_other() {
        var s1 = SW.newState()
        var s2 = SW.newState()
        _fail(s1, "a", 500, SW.THRESHOLD)
        compare(SW.stuckCount(s1), 1)
        compare(SW.stuckCount(s2), 0)
    }

    // ── prune ────────────────────────────────────────────────────────────────

    function test_prune_keeps_stuck_items_still_in_the_outbox() {
        var state = SW.newState()
        _fail(state, "a", 500, SW.THRESHOLD)
        compare(SW.prune(state, { a: true }), 1)
        compare(state.stuck.a, true)
    }

    function test_prune_drops_items_that_left_the_outbox() {
        var state = SW.newState()
        _fail(state, "a", 500, SW.THRESHOLD)
        _fail(state, "b", 500, SW.THRESHOLD)
        compare(SW.prune(state, { a: true }), 1)
        compare(state.stuck.b, undefined)
        compare(state.failures.b, undefined)
    }

    function test_prune_forgets_partial_failure_counts() {
        var state = SW.newState()
        _fail(state, "a", 500, 3)
        SW.prune(state, {})
        compare(Object.keys(state.failures).length, 0)
        // Same id re-enqueued later starts from zero, not from 3.
        compare(_fail(state, "a", 500, 2), 0)
        compare(SW.stuckCount(state), 0)
    }

    function test_prune_with_an_empty_outbox_resets_everything() {
        var state = SW.newState()
        _fail(state, "a", 500, SW.THRESHOLD)
        _fail(state, "b", 500, 2)
        compare(SW.prune(state, {}), 0)
        compare(Object.keys(state.stuck).length, 0)
        compare(Object.keys(state.failures).length, 0)
    }

    function test_prune_is_idempotent() {
        var state = SW.newState()
        _fail(state, "a", 500, SW.THRESHOLD)
        _fail(state, "b", 500, SW.THRESHOLD)
        compare(SW.prune(state, { a: true }), 1)
        compare(SW.prune(state, { a: true }), 1)
    }

    function test_prune_on_a_fresh_state_is_a_no_op() {
        compare(SW.prune(SW.newState(), { a: true }), 0)
    }

    function test_an_id_can_go_stuck_again_after_it_was_pruned() {
        var state = SW.newState()
        _fail(state, "a", 500, SW.THRESHOLD)
        compare(SW.prune(state, {}), 0)
        compare(_fail(state, "a", 500, SW.THRESHOLD), 1)
        compare(SW.stuckCount(state), 1)
    }

    // ── monkey ───────────────────────────────────────────────────────────────

    // Random failures and prunes over a handful of ids, checked step by step
    // against an independently written reference model.
    function test_monkey_random_sequences_match_a_reference_model() {
        var statuses = [0, 200, 400, 401, 403, 404, 409, 500, 503]
        var ids = ["a", "b", "c", "d", "e", "f"]
        for (var seed = 1; seed <= 25; ++seed) {
            var rnd = _rng(seed)
            var state = SW.newState()
            var refCount = {}
            var refStuck = {}
            for (var step = 0; step < 400; ++step) {
                var where = "seed " + seed + " step " + step
                if (rnd() < 0.85) {
                    var id = ids[Math.floor(rnd() * ids.length)]
                    var st = statuses[Math.floor(rnd() * statuses.length)]
                    var expectTip = false
                    if (st >= 400 && st !== 401 && st !== 409) {
                        refCount[id] = (refCount[id] || 0) + 1
                        if (refCount[id] === 5) { refStuck[id] = true; expectTip = true }
                    }
                    compare(SW.noteFailure(state, id, st), expectTip, where + " noteFailure(" + id + "," + st + ")")
                } else {
                    var live = {}
                    for (var k = 0; k < ids.length; ++k)
                        if (rnd() < 0.5) live[ids[k]] = true
                    var pruned = SW.prune(state, live)
                    for (var rc in refCount) if (!live[rc]) delete refCount[rc]
                    for (var rs in refStuck) if (!live[rs]) delete refStuck[rs]
                    compare(pruned, Object.keys(refStuck).length, where + " prune")
                }
                compare(SW.stuckCount(state), Object.keys(refStuck).length, where + " stuckCount")
                for (var sid in state.stuck)
                    verify(state.failures[sid] >= SW.THRESHOLD, where + " stuck id " + sid + " has fewer failures than THRESHOLD")
            }
        }
    }

    // Whatever happened before, an empty outbox must always mean a clean slate.
    function test_monkey_pruning_everything_always_resets_to_zero() {
        var statuses = [0, 400, 401, 403, 409, 500, 503]
        for (var seed = 1; seed <= 25; ++seed) {
            var rnd = _rng(seed)
            var state = SW.newState()
            for (var step = 0; step < 200; ++step)
                SW.noteFailure(state, "id" + Math.floor(rnd() * 10), statuses[Math.floor(rnd() * statuses.length)])
            compare(SW.prune(state, {}), 0, "seed " + seed)
            compare(Object.keys(state.stuck).length, 0, "seed " + seed + " stuck")
            compare(Object.keys(state.failures).length, 0, "seed " + seed + " failures")
        }
    }
}
```

- [ ] **Step 2: Create the scratch Node harness and run it to verify the test fails**

CI's `qmltestrunner` cannot run in the sandbox, so run the same test bodies in Node. Create `/tmp/h/run.js`:

```js
// Scratch harness (NOT committed): runs tests/tst_StuckWrites.qml's test functions in Node against a helper file.
const fs = require('fs')
const [helperPath, qmlPath] = process.argv.slice(2)
const src = fs.readFileSync(helperPath, 'utf8').replace(/^\.pragma library\s*$/m, '')
const SW = {}
new Function('exports', src + '\nexports.THRESHOLD=THRESHOLD;exports.newState=newState;exports.isStuckStatus=isStuckStatus;exports.noteFailure=noteFailure;exports.stuckCount=stuckCount;exports.prune=prune;')(SW)
const qml = fs.readFileSync(qmlPath, 'utf8')
let body = qml.slice(qml.indexOf('TestCase {') + 'TestCase {'.length, qml.lastIndexOf('}'))
body = body.replace(/^\s*name:.*$/m, '')
const names = [...body.matchAll(/function (test_\w+)\(/g)].map(m => m[1])
const compare = (a, b, msg) => { if (!(a === b || (Number.isNaN(a) && Number.isNaN(b)))) throw new Error(`compare failed: ${JSON.stringify(a)} !== ${JSON.stringify(b)} ${msg || ''}`) }
const verify = (c, msg) => { if (!c) throw new Error(`verify failed ${msg || ''}`) }
const suite = new Function('SW', 'compare', 'verify', body + '\nreturn {' + names.map(n => `${n}:${n}`).join(',') + '}')(SW, compare, verify)
let pass = 0, fail = 0
for (const n of names) { try { suite[n](); pass++ } catch (e) { fail++; console.log('FAIL', n, '-', e.message.slice(0, 160)) } }
console.log(`${pass} passed, ${fail} failed, ${names.length} test functions`)
process.exit(fail ? 1 : 0)
```

Run: `node /tmp/h/run.js qml/helper/StuckWrites.js tests/tst_StuckWrites.qml`
Expected: FAIL (the helper file does not exist yet, `ENOENT`).

- [ ] **Step 3: Write the minimal implementation**

Create `qml/helper/StuckWrites.js`:

```js
.pragma library

// Pure bookkeeping behind Gateway's "stuck write" indicator. Design:
// docs/superpowers/specs/2026-09-19-gateway-stuck-write-indicator-design.md
//
// Gateway owns one state object and calls these functions; nothing here touches
// QML, the outbox or the network, so it has a headless test
// (tests/tst_StuckWrites.qml).
//
// A queued write is "stuck" once it has failed THRESHOLD times with a
// server-side status. Offline (status 0), 401 (token refresh) and 409 (CAS
// conflict, dropped elsewhere) never count: they resolve on their own or the
// write leaves the outbox. Retry, backoff and dropping are not decided here.

// 5 server-side failures is about 3 minutes with OutboxStore's backoff
// ([2s, 8s, 30s, 2m, 10m]): long enough to ride out a deploy blip.
var THRESHOLD = 5

// state = { failures: { requestId: count }, stuck: { requestId: true } }
function newState() { return { failures: {}, stuck: {} } }

function isStuckStatus(status) {
    return status >= 400 && status !== 401 && status !== 409
}

// Records one failed send. Returns true only for the failure that tips the item
// over THRESHOLD, so the caller can react once per item.
function noteFailure(state, requestId, status) {
    if (!isStuckStatus(status)) return false
    var n = (state.failures[requestId] || 0) + 1
    state.failures[requestId] = n
    if (n !== THRESHOLD) return false
    state.stuck[requestId] = true
    return true
}

function stuckCount(state) { return Object.keys(state.stuck).length }

// Forgets every requestId that has left the outbox (sent, dropped, coalesced,
// signed out). liveIds = { requestId: true }. Returns the new stuck count.
function prune(state, liveIds) {
    var id
    for (id in state.stuck) if (!liveIds[id]) delete state.stuck[id]
    for (id in state.failures) if (!liveIds[id]) delete state.failures[id]
    return stuckCount(state)
}
```

- [ ] **Step 4: Run the test to verify it passes, then mutation-check it**

Run: `node /tmp/h/run.js qml/helper/StuckWrites.js tests/tst_StuckWrites.qml`
Expected: `21 passed, 0 failed, 21 test functions`.

Then apply each mutation to a scratch copy of the helper and re-run; every one must FAIL: tipping on `n > THRESHOLD`, dropping the `409` exclusion, dropping the `401` exclusion, `THRESHOLD = 4`, `prune` not deleting stale `failures`, `prune` not deleting stale `stuck`, boundary `>= 399`, and counting status 0 (`status >= 0`). A surviving mutation means a missing test.

- [ ] **Step 5: Commit**

```bash
git add qml/helper/StuckWrites.js tests/tst_StuckWrites.qml
git commit -m "feat(gateway): StuckWrites helper counts server-side failures per queued write"
```

---

### Task 2: Wire the helper into `Gateway`

**Files:**
- Modify: `qml/model/Gateway.qml` (imports, `stuckCount`, `_stuckState`, `_noteFailure`, `_pruneStuck`, `_reschedule`, `clear`, three sender hooks)
- Modify: `tests/tst_Gateway.qml` (import, `SignalSpy`, `init()` reset, ten new tests)

**Interfaces:**
- Consumes: Task 1's `newState`, `noteFailure`, `stuckCount`, `prune`.
- Produces: `Gateway.stuckCount` (int property), `Gateway._noteFailure(item, status)`, `Gateway._pruneStuck()`.

- [ ] **Step 1: Write the failing tests**

Apply this change to `tests/tst_Gateway.qml`:

```diff
diff --git a/tests/tst_Gateway.qml b/tests/tst_Gateway.qml
index 8e1c78c..0ee840b 100644
--- a/tests/tst_Gateway.qml
+++ b/tests/tst_Gateway.qml
@@ -1,6 +1,7 @@
 import QtQuick
 import QtTest
 import "../qml/model"
+import "../qml/components"
 
 // Regression tests for the P0 compliance gateway's client bridge.
 //
@@ -36,6 +37,9 @@ import "../qml/model"
 TestCase {
     name: "Gateway"
 
+    // Counts Toast.show() calls (the stuck-write indicator toasts once).
+    SignalSpy { id: toastSpy; target: Toast; signalName: "showRequested" }
+
     function init() {
         // Force "direct" for every case below so these tests stay isolated
         // from whatever the real production default is (see Gateway.qml —
@@ -51,6 +55,8 @@ TestCase {
         // that inspects the deployed app, not this per-case-reset TestCase.
         Gateway.mode = "direct"
         OutboxStore.clear()
+        Gateway.clear() // also resets the stuck-write bookkeeping and stops the drain timer
+        toastSpy.clear()
         AuthStore.idToken = "" // keep the _send/_sendBatch guard closed (see header)
         // In-memory reset alone isn't enough: Gateway.drainNow() itself
         // triggers AuthService's first-ever lazy construction (only real
@@ -622,4 +628,140 @@ TestCase {
         var result = Gateway._classifyBatchMutationFailure(400, JSON.stringify({ ok: false, error: "some-future-error" }))
         compare(result.terminal, false)
     }
+
+    // ── stuck-write indicator (StuckWrites bookkeeping, wired in Gateway) ────
+    //
+    // The three XHR handlers that CALL _noteFailure cannot run under
+    // qmltestrunner (no mock HTTP layer, see the scope note at the top of this
+    // file), so these drive _noteFailure / _pruneStuck directly with real
+    // OutboxStore items. The pure counting rules are covered exhaustively in
+    // tst_StuckWrites.qml.
+
+    function _queueWrite(entityId) {
+        Gateway.mode = "gateway"
+        var requestId = Gateway.recordMutation("order", entityId, "update", null, { status: "pending" })
+        return OutboxStore.items.filter(function(i) { return i.requestId === requestId })[0]
+    }
+
+    function _failTimes(item, status, n) {
+        for (var i = 0; i < n; ++i) Gateway._noteFailure(item, status)
+    }
+
+    function test_stuckCount_starts_at_zero() {
+        compare(Gateway.stuckCount, 0)
+    }
+
+    function test_failures_below_the_threshold_do_not_flag_a_write() {
+        var item = _queueWrite("o1")
+        _failTimes(item, 500, 4)
+        compare(Gateway.stuckCount, 0)
+        compare(toastSpy.count, 0)
+    }
+
+    function test_the_fifth_server_failure_flags_the_write_and_toasts_once() {
+        var item = _queueWrite("o1")
+        _failTimes(item, 500, 5)
+        compare(Gateway.stuckCount, 1)
+        compare(toastSpy.count, 1)
+        _failTimes(item, 500, 5)
+        compare(Gateway.stuckCount, 1, "already stuck: must not be counted twice")
+        compare(toastSpy.count, 1, "already stuck: must not toast again")
+    }
+
+    function test_a_second_stuck_write_raises_the_count_but_not_another_toast() {
+        var a = _queueWrite("o1")
+        var b = _queueWrite("o2")
+        _failTimes(a, 500, 5)
+        _failTimes(b, 503, 5)
+        compare(Gateway.stuckCount, 2)
+        compare(toastSpy.count, 1)
+    }
+
+    function test_offline_auth_and_conflict_failures_never_flag_a_write() {
+        var item = _queueWrite("o1")
+        _failTimes(item, 0, 20)
+        _failTimes(item, 401, 20)
+        _failTimes(item, 409, 20)
+        compare(Gateway.stuckCount, 0)
+        compare(toastSpy.count, 0)
+    }
+
+    function test_the_count_drops_when_a_stuck_write_leaves_the_outbox() {
+        var item = _queueWrite("o1")
+        _failTimes(item, 500, 5)
+        compare(Gateway.stuckCount, 1)
+        OutboxStore.markSent(item.requestId)
+        Gateway._reschedule() // the real pruning trigger, as every sender handler ends with it
+        compare(Gateway.stuckCount, 0)
+    }
+
+    function test_only_the_writes_that_left_the_outbox_are_dropped() {
+        var a = _queueWrite("o1")
+        var b = _queueWrite("o2")
+        _failTimes(a, 500, 5)
+        _failTimes(b, 500, 5)
+        compare(Gateway.stuckCount, 2)
+        OutboxStore.markSent(a.requestId)
+        Gateway._pruneStuck()
+        compare(Gateway.stuckCount, 1)
+    }
+
+    function test_the_toast_fires_again_after_the_count_returned_to_zero() {
+        var a = _queueWrite("o1")
+        _failTimes(a, 500, 5)
+        OutboxStore.markSent(a.requestId)
+        Gateway._reschedule()
+        compare(Gateway.stuckCount, 0)
+        var b = _queueWrite("o2")
+        _failTimes(b, 500, 5)
+        compare(Gateway.stuckCount, 1)
+        compare(toastSpy.count, 2)
+    }
+
+    function test_clear_resets_the_indicator_and_the_failure_counts() {
+        var item = _queueWrite("o1")
+        _failTimes(item, 500, 5)
+        compare(Gateway.stuckCount, 1)
+        Gateway.clear()
+        compare(Gateway.stuckCount, 0)
+        var again = _queueWrite("o1")
+        _failTimes(again, 500, 4)
+        compare(Gateway.stuckCount, 0, "counting starts from zero after clear()")
+    }
+
+    // Random queue / fail / send / clear steps against the real OutboxStore,
+    // checked step by step against a reference count of live items that have
+    // had 5 or more server-side failures.
+    function test_monkey_stuckCount_always_matches_the_live_stuck_items() {
+        var statuses = [0, 200, 401, 403, 404, 409, 500, 503]
+        for (var seed = 1; seed <= 10; ++seed) {
+            Gateway.clear()
+            var s = seed
+            var rnd = function() { s = (s * 1664525 + 1013904223) % 4294967296; return s / 4294967296 }
+            var live = {} // entityId -> { item, failures }
+            for (var step = 0; step < 150; ++step) {
+                var roll = rnd()
+                var entityId = "m" + Math.floor(rnd() * 6)
+                if (roll < 0.15) {
+                    if (!live[entityId]) live[entityId] = { item: _queueWrite(entityId), failures: 0 }
+                } else if (roll < 0.30) {
+                    if (live[entityId]) {
+                        OutboxStore.markSent(live[entityId].item.requestId)
+                        delete live[entityId]
+                        Gateway._reschedule()
+                    }
+                } else if (roll < 0.32) {
+                    Gateway.clear()
+                    live = {}
+                } else if (live[entityId]) {
+                    var st = statuses[Math.floor(rnd() * statuses.length)]
+                    Gateway._noteFailure(live[entityId].item, st)
+                    if (st >= 400 && st !== 401 && st !== 409) live[entityId].failures++
+                }
+                var expected = 0
+                for (var k in live) if (live[k].failures >= 5) expected++
+                compare(Gateway.stuckCount, expected, "seed " + seed + " step " + step)
+            }
+        }
+    }
 }
```

- [ ] **Step 2: Confirm they fail without the implementation**

They call `Gateway._noteFailure`, `Gateway._pruneStuck` and read `Gateway.stuckCount`, none of which exist yet, so `qmltestrunner` reports them as failing in CI. (No Qt toolchain in the sandbox; do not install one.)

- [ ] **Step 3: Implement**

Apply this change to `qml/model/Gateway.qml`:

```diff
diff --git a/qml/model/Gateway.qml b/qml/model/Gateway.qml
index 82cb201..0925027 100644
--- a/qml/model/Gateway.qml
+++ b/qml/model/Gateway.qml
@@ -1,5 +1,7 @@
 pragma Singleton
 import QtQuick
+import "../components"
+import "../helper/StuckWrites.js" as StuckWrites
 
 // Compliance gateway client (P0). Single entry point for every books-of-
 // account mutation in P0 scope (inventory + stock). Stores call
@@ -99,6 +101,13 @@ QtObject {
 
     property int inFlight: 0
 
+    // Queued writes that have failed StuckWrites.THRESHOLD times with a
+    // server-side status. Main.qml republishes it as syncStuckCount and
+    // GlassHeader shows a persistent "not syncing" line while it is above 0.
+    // This only REPORTS: retry, backoff and dropping are decided elsewhere.
+    property int stuckCount: 0
+    property var _stuckState: StuckWrites.newState()
+
     // Pending recordDelta callbacks, keyed by outbox requestId — NOT
     // persisted (callbacks are JS functions, can't survive relaunch or
     // coalescing-across-restart anyway). One requestId can map to MULTIPLE
@@ -344,7 +353,27 @@ QtObject {
         _reschedule()
     }
 
+    // Called beside every OutboxStore.markFailed. Toasts once, when the first
+    // write becomes stuck; the header line stays up until the count drops again.
+    function _noteFailure(item, status) {
+        if (!StuckWrites.noteFailure(_stuckState, item.requestId, status)) return
+        var wasQuiet = stuckCount === 0
+        stuckCount = StuckWrites.stuckCount(_stuckState)
+        if (wasQuiet)
+            Toast.show(qsTr("Some changes aren't syncing. The app keeps retrying."))
+    }
+
+    // Forgets anything that has left the outbox, however it left (sent,
+    // conflict, permanent drop, coalesce, sign-out). Runs from _reschedule().
+    function _pruneStuck() {
+        var live = {}
+        var queued = OutboxStore.items
+        for (var i = 0; i < queued.length; ++i) live[queued[i].requestId] = true
+        stuckCount = StuckWrites.prune(_stuckState, live)
+    }
+
     function _reschedule() {
+        _pruneStuck()
         if (!_drainTimer) {
             _drainTimer = Qt.createQmlObject(
                 'import QtQuick; Timer { repeat: false }', root, "GatewayDrainTimer")
@@ -466,6 +495,7 @@ QtObject {
                     console.warn("[Gateway] recordMutation failed", "raw-status:", xhr.status, "effective-status:", effStatus,
                                  "statusText:", xhr.statusText, item.entity, item.entityId, effResponseText, "headers:", headersSeen)
                     OutboxStore.markFailed(item.requestId)
+                    _noteFailure(item, effStatus)
                 }
             }
             OutboxStore.clearInFlight(item)
@@ -588,6 +618,7 @@ QtObject {
                         console.warn("[Gateway] recordMutationsBatch failed", "raw-status:", xhr.status, "effective-status:", effStatus,
                                      item.entity, item.items.length, effResponseText)
                         OutboxStore.markFailed(item.requestId)
+                        _noteFailure(item, effStatus)
                     }
                 }
             }
@@ -670,6 +701,7 @@ QtObject {
                 console.warn("[Gateway] recordDelta failed", "raw-status:", xhr.status, "effective-status:", effStatus,
                              item.entity, item.entityId, effResponseText)
                 OutboxStore.markFailed(item.requestId)
+                _noteFailure(item, effStatus)
             }
             OutboxStore.clearInFlight(item)
 
@@ -786,6 +818,8 @@ QtObject {
     function clear() {
         OutboxStore.clear()
         _deltaCallbacks = ({})
+        _stuckState = StuckWrites.newState()
+        stuckCount = 0
         if (_drainTimer) _drainTimer.stop()
     }
 }
```

- [ ] **Step 4: Verify what can be verified locally**

Run a per-function brace-balance check on each function this task touched (`_noteFailure`, `_pruneStuck`, `_reschedule`, `clear`) and a whole-file balance comparison against `HEAD` for `Gateway.qml` and `tst_Gateway.qml`. Expected: balances unchanged. Push and read the `QML Tests` job in Task 5 for the real result.

- [ ] **Step 5: Commit**

```bash
git add qml/model/Gateway.qml tests/tst_Gateway.qml
git commit -m "feat(gateway): report writes stuck behind server-side failures via stuckCount"
```

---

### Task 3: Show it in `GlassHeader`

**Files:**
- Modify: `qml/Main.qml` (one property)
- Modify: `qml/components/GlassHeader.qml` (caption `Text`)

**Interfaces:**
- Consumes: Task 2's `Gateway.stuckCount`.
- Produces: `app.syncStuckCount` (readonly int on the `Main.qml` root).

- [ ] **Step 1: Implement**

```diff
diff --git a/qml/Main.qml b/qml/Main.qml
index 9ff5a8c..a6d07fb 100644
--- a/qml/Main.qml
+++ b/qml/Main.qml
@@ -21,6 +21,10 @@ App {
     property string memberErrorMessage: ""
     property string successMessage: ""
 
+    // Queued writes stuck behind a server-side failure (Gateway.stuckCount).
+    // GlassHeader reads it as app.syncStuckCount, the same way it reads app.isOnline.
+    readonly property int syncStuckCount: Gateway.stuckCount
+
     // Consume the Android Back event so it does NOT propagate to the OS (which
     // would background/exit the app). "AutoAccept" = mark the event accepted;
     // true keeps the app open and lets our _handleBack router do the navigation
diff --git a/qml/components/GlassHeader.qml b/qml/components/GlassHeader.qml
index 5402b91..c8d1d7f 100644
--- a/qml/components/GlassHeader.qml
+++ b/qml/components/GlassHeader.qml
@@ -75,10 +75,16 @@ Rectangle {
             }
 
             Text {
-                visible: !app.isOnline || (root.subtitle.length > 0 && root.greeting.length === 0)
-                text: app.isOnline ? root.subtitle : qsTr("App is offline, no operation allowed.")
+                // Online, but queued writes keep failing server-side (Gateway.stuckCount,
+                // republished by Main.qml). The offline message keeps precedence.
+                readonly property bool _stuck: app.isOnline && app.syncStuckCount > 0
+
+                visible: !app.isOnline || _stuck || (root.subtitle.length > 0 && root.greeting.length === 0)
+                text: !app.isOnline ? qsTr("App is offline, no operation allowed.")
+                    : _stuck ? qsTr("%n change(s) not syncing. Still retrying.", "", app.syncStuckCount)
+                    : root.subtitle
                 font.pixelSize: sp(Constants.fsCaption)
-                color: app.isOnline ? Constants.textSecondary : Constants.danger
+                color: (!app.isOnline || _stuck) ? Constants.danger : Constants.textSecondary
                 elide: Text.ElideRight
                 Layout.fillWidth: true
             }
```

- [ ] **Step 2: Verify locally**

Brace balance unchanged against `HEAD` for both files. No automated test is possible: `GlassHeader` needs Felgo `dp()` / `sp()` and the `app` root, which `qmltestrunner` on CI does not provide. Coverage is the on-device plan (Task 4).

- [ ] **Step 3: Commit**

```bash
git add qml/Main.qml qml/components/GlassHeader.qml
git commit -m "feat(ui): GlassHeader caption shows how many changes are not syncing"
```

---

### Task 4: Documentation and test plan

**Files:**
- Create: `docs/superpowers/test-plans/2026-09-19-gateway-stuck-write-indicator-test-plan.md` (Skill 49 structure: 1 Unit, 2 Functional / E2E, 3 Regression, 4 Firestore rules, then On-Device with Happy Path, Negative Cases, Edge Cases, Affected Areas, Regression Tests)
- Modify: `docs/superpowers/test-plans/README.md` (index row, newest first)
- Modify: `SKILLS.md` (append Skill 66)
- Modify: `AGENTS.md` (list `qml/helper/StuckWrites.js` next to `PagingHelper.js`)
- Modify: `README.md` (append an "Update 2026-09-19" paragraph after the 2026-09-14 one)
- Modify: `docs/superpowers/KNOWN-ISSUES.md` (status note on the `_send` black-hole entry)
- Modify: `docs/superpowers/DELETE-FEATURE-ROADMAP.md` (status note on item 1)
- Modify: `CHECKPOINT.md`

**Content requirements (each one is a checkable line):**

- Test plan sections 1-3: the 21 `tst_StuckWrites.qml` cases and the 10 new `tst_Gateway.qml` cases, split into unit / regression / monkey, each saying whether it was genuinely run and where (Node harness for the helper: 21/21 and 8/8 mutations killed; QML: CI result from Task 5). Section 2: no E2E added, with the reason. Section 4: not applicable, no rules change.
- On-device Happy Path: (1) healthy backend, ordinary edits: no toast and no caption line; (2) make writes fail with 403 by removing the test user's tenant membership in the emulator, edit a product, wait about 3 minutes: one toast, then the caption "1 change not syncing. Still retrying." on every page that has a `GlassHeader`; (3) restore membership: the next retry succeeds and the caption disappears.
- On-device Negative: airplane mode for 10 minutes with pending edits shows only the existing offline message; an expired token (401) never shows the line; a two-device CAS conflict shows only the existing conflict toast; signing out while stuck and signing in as another account shows no leftover count.
- On-device Edge: two stuck writes show "2 changes not syncing." with a single toast; restarting the app clears the line and it returns about 3 minutes later if still failing; a stuck delete shows the line while the row stays gone locally (known divergence, unchanged); offline while stuck shows the offline message and the stuck line returns online; a narrow width elides the caption without overlap; a stuck CSV-import batch and a stuck order completion (`recordDelta`) both raise it; list which pages have no `GlassHeader` and therefore no line.
- Affected Areas table: `Gateway.qml` (helper + `_noteFailure` / `_pruneStuck` / `clear` covered; the three sender call sites not), `StuckWrites.js` (unit + monkey), `Main.qml` (on-device), `GlassHeader.qml` (on-device), `tests/tst_Gateway.qml`, `tests/tst_StuckWrites.qml`.
- On-device Regression: the offline caption still shows and wins over the stuck line; the subtitle shows again when nothing is stuck; conflict and permanent-batch-failure flows behave as before.
- `SKILLS.md` Skill 66 records: retry-forever is correct offline and the defect is silence; the server's blanket 500 forces count-based detection; deriving state from the live outbox instead of clearing at six exit sites; check for an existing surface before building UI (and why `ActivityLog` was rejected); running QML test bodies in Node with a stripped `TestCase` wrapper plus a mutation check as real evidence in a no-Qt sandbox.
- `KNOWN-ISSUES.md` / roadmap: the silent half is fixed; the diverged half remains; follow-ups B (park + Retry/Discard) and C (server maps Firestore errors to distinct statuses).

- [ ] **Step 1: Write each document to the requirements above**
- [ ] **Step 2: Count instead of trusting** the new-test numbers with `grep -oE "function test_[a-zA-Z0-9_]+" tests/tst_StuckWrites.qml tests/tst_Gateway.qml` and compare with `git show HEAD:tests/tst_Gateway.qml` (Skill 49's lesson: recount, do not carry a number forward).
- [ ] **Step 3: Commit**

```bash
git add SKILLS.md AGENTS.md README.md docs CHECKPOINT.md
git commit -m "docs: stuck-write indicator test plan, skill 66, README/AGENTS/KNOWN-ISSUES/roadmap updates"
```

---

### Task 5: Push and read the CI result

- [ ] **Step 1: Push with the token passed as a one-off header (never stored in git config)**

```bash
AUTH="Authorization: Basic $(printf 'x-access-token:%s' "$PAT" | base64 -w0)"
git -c http.extraHeader="$AUTH" push origin fix/2026-09-19-gateway-send-terminal-failure
```

- [ ] **Step 2: Poll the check runs for the pushed commit**

```bash
curl -s -H "Authorization: token $PAT" \
  "https://api.github.com/repos/lkdigitalworks-53/InventoryManagerUI/commits/$(git rev-parse HEAD)/check-runs" \
  | python3 -c "import sys,json; [print(c['name'], c['status'], c['conclusion']) for c in json.load(sys.stdin)['check_runs']]"
```

Expected: `QML Tests`, `Functions Tests`, `Firestore Rules Tests`, `E2E Tests` all `completed success`.

- [ ] **Step 3: If anything fails**, read the failing job's annotations (`check-runs/{id}/annotations`), fix the test or the code, re-run Task 5. Do not claim success before the check runs say so.

---

## Self-review

- **Spec coverage:** detection (Tasks 1-2), all three senders (Task 2 hooks), pruning and `clear()` (Task 2), surface (Task 3), tests and their stated limits (Tasks 1, 2, 4), not-fixed list (Task 4 docs). No gaps found.
- **Placeholder scan:** none; every code step shows the code, and each documentation item states the content it must contain.
- **Type consistency:** `noteFailure(state, requestId, status)`, `prune(state, liveIds)`, `stuckCount(state)`, `Gateway._noteFailure(item, status)`, `Gateway._pruneStuck()`, `Gateway.stuckCount` and `app.syncStuckCount` are spelled identically in every task.
