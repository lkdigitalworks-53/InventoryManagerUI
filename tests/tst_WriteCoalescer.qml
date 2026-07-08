import QtQuick
import QtTest
import "../qml/helper/WriteCoalescer.js" as WriteCoalescer

// Regression test for: a completed order's Firestore document silently
// reverting to "pending" with none of the completion side effects (stock
// reversal / transaction / analytics). Root cause: OrdersStore._commit()
// fired an independent, un-coordinated Firestore write on every mutation.
// Completing an order fires two such writes close together (the "pending"
// write from adding the order, then the "completed" write from completing
// it); over a real mobile network the older write's response can arrive
// AFTER the newer one and silently overwrite it server-side. WriteCoalescer
// fixes this by never allowing more than one write in flight.
TestCase {
    name: "WriteCoalescer"

    // Reproduces the exact race from the bug report using a controllable
    // fake transport: two writes are triggered close together, and the
    // FIRST one's response is resolved LAST (out-of-order network delivery).
    // Asserts the coalescer never sends a second overlapping request, and
    // that the write actually applied last always reflects the latest
    // state — not a stale one arriving late.
    function test_out_of_order_response_never_reverts_newer_state() {
        var applied = [];       // payload values in the order they "landed" at the fake server
        var captured = [];      // [{payload, done}] — requests captured but not yet resolved
        var state = "pending";

        var pusher = WriteCoalescer.createCoalescedPusher(function(done) {
            captured.push({ payload: state, done: done }); // snapshot state at send time
        });

        // 1) Order added -> commit -> write A queued (payload "pending").
        pusher.trigger();
        compare(captured.length, 1, "first trigger must send immediately");

        // 2) Order completed moments later, while write A is still in flight.
        state = "completed";
        pusher.trigger();
        compare(captured.length, 1,
                "a commit while a write is in flight must NOT fire a second overlapping request");
        verify(pusher.isPending());

        // 3) Write A (the OLDER, "pending" snapshot) finally resolves late —
        //    this is the out-of-order network delivery from the real bug.
        var writeA = captured.shift();
        compare(writeA.payload, "pending");
        applied.push(writeA.payload);
        writeA.done(true);

        // Because a commit happened while A was in flight, exactly one
        // follow-up write must now be sent, reading the CURRENT state —
        // never a stale resend of "pending".
        compare(captured.length, 1,
                "coalescer must send exactly one follow-up write after the in-flight one finishes");
        var writeB = captured.shift();
        compare(writeB.payload, "completed");
        applied.push(writeB.payload);
        writeB.done(true);

        // The correct causal order was preserved end to end, and nothing is
        // left outstanding.
        compare(applied, ["pending", "completed"]);
        verify(!pusher.isInFlight());
        verify(!pusher.isPending());
    }

    // Structural guarantee: no matter how many commits happen in a burst,
    // the coalescer never has more than one write in flight at a time — so
    // out-of-order resolution at the transport layer can never apply to two
    // overlapping requests for the same resource.
    function test_never_more_than_one_write_in_flight() {
        var maxConcurrent = 0;
        var concurrent = 0;
        var sends = 0;

        var pusher = WriteCoalescer.createCoalescedPusher(function(done) {
            sends++;
            concurrent++;
            maxConcurrent = Math.max(maxConcurrent, concurrent);
            done(true);
            concurrent--;
        });

        for (var i = 0; i < 5; ++i)
            pusher.trigger();

        compare(maxConcurrent, 1, "at most one write must ever be in flight");
        verify(sends >= 1 && sends <= 5);
    }

    // A single trigger() with nothing else happening must still send.
    function test_single_trigger_sends() {
        var sent = 0;
        var pusher = WriteCoalescer.createCoalescedPusher(function(done) {
            sent++;
            done(true);
        });
        pusher.trigger();
        compare(sent, 1);
        verify(!pusher.isInFlight());
        verify(!pusher.isPending());
    }
}
