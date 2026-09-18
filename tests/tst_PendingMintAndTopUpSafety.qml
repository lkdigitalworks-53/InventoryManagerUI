import QtQuick
import QtTest

// Regression coverage for docs/superpowers/E2E-TESTING-ROADMAP.md item 1's two
// 2026-09-14 decisions, confirmed on-device by Taher (restock +10, dropped
// connectivity right after submit -- batch silently lost; completing a 3-unit
// order then silently rewrote the ORIGINAL batch's own received-quantity to
// cover it).
//
// Same technique as tst_TenantContextRaceGuard.qml / tst_ResetPendingGuard.qml:
// a minimal plain-JS model of the real control flow, not the real singleton --
// StockBatchStore's `function addBatch(...)`/`function topUpOldest(...)` are
// read-only methods on a pragma Singleton (same class of limitation confirmed
// for FirebaseService.query earlier this session), so they can't be
// exercised deterministically from a test. On-device/CI confirmation that
// the real store matches this model is still the one thing this file can't
// substitute for.
TestCase {
    name: "PendingMintAndTopUpSafety"

    // Mirrors StockBatchStore's addBatch/_queuePendingMint/retryPendingMints/
    // hasPendingMint and the new always-synthesize topUpOldest. `mintOutcome`
    // is a queue of true/false the test controls, consumed one per
    // nextBatchId() call, so mint success/failure is deterministic instead
    // of a real network race.
    function makeStore() {
        return {
            batches: [],
            _pendingMints: [],
            _pendingMintsInFlight: ({}),
            mintOutcome: [],   // shift() one per nextBatchId() call; true = mint succeeds
            _nextId: 1,
            createdCount: 0,

            _nextBatchId: function() {
                var ok = this.mintOutcome.length > 0 ? this.mintOutcome.shift() : true
                return ok ? ("BAT-" + (this._nextId++)) : ""
            },

            addBatch: function(productId, supplierId, qty, unitCost, note) {
                var id = this._nextBatchId()
                if (!id) {
                    this._queuePendingMint(productId, supplierId, qty, unitCost, note)
                    return null
                }
                var doc = { batchId: id, productId: productId, supplierId: supplierId || "",
                           qtyReceived: qty, qtyRemaining: qty, unitCost: unitCost, note: note || "" }
                this.batches.push(doc)
                this.createdCount++
                return doc
            },

            _queuePendingMint: function(productId, supplierId, qty, unitCost, note) {
                this._pendingMints.push({ id: "p" + this._pendingMints.length + "_" + Date.now(),
                                          productId: productId, supplierId: supplierId, qty: qty,
                                          unitCost: unitCost, note: note })
            },

            hasPendingMint: function(productId) {
                for (var i = 0; i < this._pendingMints.length; ++i)
                    if (this._pendingMints[i].productId === productId) return true
                return false
            },

            retryPendingMints: function() {
                var self = this
                var snapshot = this._pendingMints.slice()
                for (var i = 0; i < snapshot.length; ++i) {
                    var item = snapshot[i]
                    if (this._pendingMintsInFlight[item.id]) continue
                    this._pendingMintsInFlight[item.id] = true
                    ;(function(it) {
                        var id = self._nextBatchId()
                        delete self._pendingMintsInFlight[it.id]
                        if (!id) return
                        self.batches.push({ batchId: id, productId: it.productId, supplierId: it.supplierId || "",
                                            qtyReceived: it.qty, qtyRemaining: it.qty, unitCost: it.unitCost, note: it.note })
                        self.createdCount++
                        self._pendingMints = self._pendingMints.filter(function(x) { return x.id !== it.id })
                    })(item)
                }
            },

            // 2026-09-14: always synthesizes a new batch -- never mutates an
            // existing one's qtyReceived/qtyRemaining, regardless of whether
            // other batches already exist for the product.
            topUpOldest: function(productId, deficit) {
                if (!productId || !deficit || deficit <= 0) return
                this.addBatch(productId, "", deficit, 0, "Adjustment (drift repair)")
            }
        }
    }

    // ── Decision 1: pending-mint retry queue ────────────────────────────────

    function test_failed_mint_is_queued_not_dropped() {
        var store = makeStore()
        store.mintOutcome = [false]
        var doc = store.addBatch("P1", "S1", 10, 5, "Restock")

        compare(doc, null, "no batch created yet -- the caller gets null, same as before, no error surfaced")
        compare(store.hasPendingMint("P1"), true)
        compare(store.batches.length, 0)
    }

    function test_reconnect_with_mint_still_failing_stays_queued() {
        var store = makeStore()
        store.mintOutcome = [false]
        store.addBatch("P1", "S1", 10, 5, "Restock")

        store.mintOutcome = [false]
        store.retryPendingMints()

        compare(store.hasPendingMint("P1"), true, "still failing -- stays queued for the next reconnect")
        compare(store.batches.length, 0)
    }

    function test_reconnect_with_mint_now_succeeding_creates_the_batch() {
        var store = makeStore()
        store.mintOutcome = [false]
        store.addBatch("P1", "S1", 10, 5, "Restock")
        compare(store.hasPendingMint("P1"), true)

        store.mintOutcome = [true]
        store.retryPendingMints()

        compare(store.hasPendingMint("P1"), false, "resolved -- product is orderable again")
        compare(store.batches.length, 1)
        compare(store.batches[0].productId, "P1")
        compare(store.batches[0].qtyReceived, 10)
        compare(store.batches[0].supplierId, "S1", "the retry preserves the ORIGINAL restock's supplier/cost -- it's the same request replayed, not a guess")
        compare(store.batches[0].unitCost, 5)
    }

    function test_pending_mints_for_different_products_are_independent() {
        var store = makeStore()
        store.mintOutcome = [false]
        store.addBatch("P1", "S1", 10, 5, "Restock")
        store.mintOutcome = [false]
        store.addBatch("P2", "S1", 3, 2, "Restock")

        store.mintOutcome = [true, false]   // P1 succeeds this round, P2 still fails
        store.retryPendingMints()

        compare(store.hasPendingMint("P1"), false)
        compare(store.hasPendingMint("P2"), true, "P2's own failure is unaffected by P1's success in the same retry pass")
        compare(store.batches.length, 1)
    }

    function test_overlapping_retry_calls_do_not_double_process_the_same_item() {
        // Models isOnline flapping true/false/true faster than a mint
        // round-trip resolves -- retryPendingMints() firing again while the
        // first attempt for the same item is still "in flight" should skip
        // it, not retry it twice.
        var store = makeStore()
        store.mintOutcome = [false]
        store.addBatch("P1", "S1", 10, 5, "Restock")

        // Manually mark it in-flight (simulating a retry already underway)
        // before calling retryPendingMints() again.
        var pendingId = store._pendingMints[0].id
        store._pendingMintsInFlight[pendingId] = true
        store.mintOutcome = [true]
        store.retryPendingMints()

        compare(store.hasPendingMint("P1"), true, "skipped -- already in flight, not retried a second time concurrently")
        compare(store.batches.length, 0)
    }

    // ── Decision 2: topUpOldest always synthesizes, never mutates ──────────

    function test_topUp_with_existing_batches_creates_new_one_untouched_originals() {
        var store = makeStore()
        store.batches = [{ batchId: "BAT-orig", productId: "P1", supplierId: "S-original",
                          qtyReceived: 1, qtyRemaining: 1, unitCost: 100, note: "" }]

        store.topUpOldest("P1", 2)   // shortfall of 2 to cover a 3-unit sale against 1 available

        compare(store.batches.length, 2, "a NEW batch, not a mutation of the existing one")
        var orig = store.batches[0]
        compare(orig.batchId, "BAT-orig")
        compare(orig.qtyReceived, 1, "REGRESSION GUARD: this is exactly the bug -- the original batch's own received history must never change")
        compare(orig.supplierId, "S-original")
        compare(orig.unitCost, 100)

        var adjustment = store.batches[1]
        compare(adjustment.qtyReceived, 2)
        compare(adjustment.note, "Adjustment (drift repair)")
        compare(adjustment.supplierId, "", "honestly unknown, not inherited from the original batch's supplier")
        compare(adjustment.unitCost, 0, "honestly unknown, not inherited from the original batch's cost")
    }

    // ── nextBatchId's timeout-race safety net (2026-09-14, on-device) ──────
    // Standalone from makeStore() above -- this models JUST the timeout-vs-
    // mint race nextBatchId() now runs internally, not the full addBatch/
    // pending-queue flow (already covered above). The real function starts
    // a 15s Timer and calls FirebaseService.mintCounterValue at the same
    // time, guarded by a `settled` flag so whichever resolves first wins and
    // the other is discarded. This model lets the test choose which "arm"
    // resolves and when, instead of waiting on a real timer or a real
    // network hang.
    function makeMintRace() {
        return {
            settled: false,
            callback: null,
            calls: 0,   // how many times callback actually fired -- should never exceed 1

            start: function(callback) {
                this.settled = false
                this.callback = callback
                this.calls = 0
            },
            fireTimeout: function() {
                if (this.settled) return
                this.settled = true
                this.calls++
                this.callback("")
            },
            resolveMint: function(id) {
                if (this.settled) return
                this.settled = true
                this.calls++
                this.callback(id)
            }
        }
    }

    function test_mintRace_resolves_normally_when_mint_answers_first() {
        var race = makeMintRace()
        var got = "unset"
        race.start(function(id) { got = id })
        race.resolveMint("BAT-1")
        compare(got, "BAT-1")
        compare(race.calls, 1)
    }

    function test_mintRace_timeout_fires_when_mint_never_answers() {
        // The exact scenario from Taher's on-device report: the underlying
        // request never comes back at all.
        var race = makeMintRace()
        var got = "unset"
        race.start(function(id) { got = id })
        race.fireTimeout()
        compare(got, "", "treated as a failed mint, same as any other addBatch() failure")
        compare(race.calls, 1)
    }

    function test_mintRace_late_mint_after_timeout_is_discarded_not_double_fired() {
        var race = makeMintRace()
        var callCount = 0
        var lastValue = null
        race.start(function(id) { callCount++; lastValue = id })
        race.fireTimeout()
        race.resolveMint("BAT-1")   // the original request finally answers, too late
        compare(callCount, 1, "the late answer must NOT fire the callback a second time")
        compare(lastValue, "", "the timeout's result stands -- not silently overwritten by the late one")
    }

    function test_mintRace_timeout_after_mint_already_answered_is_a_noop() {
        var race = makeMintRace()
        var callCount = 0
        race.start(function(id) { callCount++ })
        race.resolveMint("BAT-1")
        race.fireTimeout()   // fires after the real answer already arrived
        compare(callCount, 1, "the timeout must not fire again once the real mint already settled it")
    }

    function test_topUp_with_zero_existing_batches_still_synthesizes_one() {
        var store = makeStore()
        store.topUpOldest("P1", 5)

        compare(store.batches.length, 1)
        compare(store.batches[0].qtyReceived, 5)
        compare(store.batches[0].note, "Adjustment (drift repair)")
    }

    function test_topUp_zero_deficit_is_a_no_op() {
        var store = makeStore()
        store.batches = [{ batchId: "BAT-orig", productId: "P1", qtyReceived: 1, qtyRemaining: 1 }]
        store.topUpOldest("P1", 0)
        compare(store.batches.length, 1, "no new batch, nothing touched")
    }

    // ── The two decisions interacting: a top-up itself can fail to mint ────

    function test_topUp_whose_own_mint_fails_is_also_queued_not_lost() {
        var store = makeStore()
        store.batches = [{ batchId: "BAT-orig", productId: "P1", qtyReceived: 1, qtyRemaining: 1 }]
        store.mintOutcome = [false]

        store.topUpOldest("P1", 2)

        compare(store.batches.length, 1, "no new batch yet")
        compare(store.hasPendingMint("P1"), true, "the adjustment itself is durable too -- same queue, same retry path")
    }
}
