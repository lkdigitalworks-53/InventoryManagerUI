.pragma library

// WriteCoalescer — single-flight request coalescing for an async "push
// latest state" operation. Pure — no QML/singleton deps, unit-testable.
//
// THE BUG THIS FIXES: OrdersStore._commit() fired an independent,
// un-coordinated Firestore write on every mutation (_pushAllToFirebase()),
// with no coordination between calls. Completing an order typically fires
// two such writes back to back (e.g. add-order's "pending" write still in
// flight when complete-order's "completed" write goes out moments later).
// Over a real mobile network, response ordering is NOT guaranteed to match
// request ordering — the older "pending" write can arrive at the server
// AFTER the newer "completed" write and silently overwrite it. Because this
// write path bypasses DataModel entirely, none of the completion side
// effects (stock deduction reversal, sale/transaction records) run — the
// order's status field just reverts on its own. Re-approving it then reruns
// the full completion flow, double-booking stock and revenue.
//
// THE FIX: never allow more than one write in flight for the same resource.
// `trigger()` marks that a write is wanted; if one is already in flight, it
// just flags "pending" and returns — no second overlapping request is ever
// sent. When the in-flight write's callback fires, if another trigger()
// happened meanwhile, exactly ONE more write is sent, and it always reads
// the caller's CURRENT state at send time (never a stale snapshot captured
// earlier). This guarantees writes reach the server in the same order they
// were requested, and the last one sent is always the most current state —
// so an out-of-order network response can never revert newer data.
//
// `sendFn(done)` must perform the actual write and call `done(ok)` when
// finished. This util only guarantees ORDERING (at most one in flight, and
// writes always reflect the latest state) — it does not add retry/backoff;
// pair with Gateway/OutboxStore if durability is also needed.
function createCoalescedPusher(sendFn) {
    var inFlight = false;
    var pending = false;

    function trigger() {
        if (inFlight) {
            pending = true;
            return;
        }
        inFlight = true;
        pending = false;
        sendFn(function _onDone(ok) {
            inFlight = false;
            if (pending) {
                pending = false;
                trigger();
            }
        });
    }

    return {
        trigger: trigger,
        isInFlight: function() { return inFlight; },
        isPending: function() { return pending; }
    };
}
