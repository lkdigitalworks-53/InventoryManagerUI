import QtQuick
import QtTest
import "../../qml/model"
import "E2EHelpers.js" as E2EHelpers

// StockBatchStore E2E — last of the four backlog conflict tests (see
// tst_StaffStoreE2E.qml's header for the shared rationale). This one is
// shaped differently from the other three, and that's deliberate, not an
// oversight — worth reading before touching this file:
//
// StockBatchStore's own numeric mutations (consumeFifo/topUpOldest/
// restoreFifo) all go through Gateway.recordDelta, NOT recordMutation —
// confirmed by reading the whole file, not assumed. recordDelta's
// server-side atomic floor/clamp semantics make a CAS conflict structurally
// impossible for those call sites: there's no "before must match current"
// check to violate. The ONLY Gateway.recordMutation call anywhere in this
// store is addBatch's "create" action. (StockBatchStore._onMutationConflicted
// does exist and is wired up — its own comment claims a "genuine two-devices
// race" can hit it via "qtyRemaining via plain recordMutation", but that
// doesn't match the current code: worth flagging to Taher as a likely-stale
// comment from before a recordDelta conversion, not fixed here since it's
// out of this backlog item's scope.)
//
// So this test exercises the one path that's actually reachable: a
// duplicate "create" collision (client A's create succeeds; client B
// attempts to create the same batchId, unaware it already exists) rather
// than an "update" collision. To make the reconciliation assertion
// meaningful (current actually differing from the second client's stale
// local cache, not just echoing back what it already expected), a direct
// Gateway "update" call changes the batch server-side in between — StockBatchStore
// itself never does this in production, but it's a legitimate way to prove
// the RECONCILIATION HANDLER works correctly when a conflict does occur,
// which is this backlog item's actual goal, independent of how rare the
// triggering scenario is in practice today.
//
// NOT RUN IN THIS SANDBOX before its first real CI attempt.

TestCase {
    name: "StockBatchStoreE2E"

    // DataModel is NOT a pragma Singleton (Main.qml instantiates it), so its Gateway
    // Connections only exist if a test declares one, same as tst_OrdersE2E.qml. The BC2
    // 409 test below relies on DataModel.onMutationConflicted re-reading the batches that
    // deleteProduct hid locally; without this instance that resync never runs (CI failure
    // on PR #119: "did not bring the hidden batches back by re-read").
    DataModel { id: dm }

    readonly property string emulatorFirestoreHost: "http://127.0.0.1:8080"
    readonly property string emulatorFunctionsBase: "http://127.0.0.1:5001/inventorymanager-48392/asia-south1"
    readonly property string realFunctionUrl: "https://asia-south1-inventorymanager-48392.cloudfunctions.net/recordMutation"
    readonly property string fixtureUrl: Qt.resolvedUrl("../../test/e2e/.fixture.json")

    property var fixture: null
    property var lastConflict: null

    function _loadFixture() {
        return E2EHelpers.loadFixture(this, fixtureUrl)
    }

    function _onMutationConflicted(entity, entityId, current) {
        lastConflict = { entity: entity, entityId: entityId, current: current }
    }

    function _pollEmulatorDoc(docPath, entityId, predicateFn, timeoutMs, message) {
        return E2EHelpers.pollEmulatorDoc(this, emulatorFirestoreHost, docPath, entityId,
                                           predicateFn, timeoutMs, message)
    }

    function initTestCase() {
        fixture = _loadFixture()
        AuthService.ensureFreshToken()

        var result = E2EHelpers.postDirect(this, emulatorFunctionsBase + "/recordMutation", {
            env: "prd", entity: "stock_batch", entityId: "warmup-batch-" + Date.now(),
            action: "create", before: null,
            after: { batchId: "warmup-batch-" + Date.now(), productId: "warmup-product", qtyReceived: 1, qtyRemaining: 1 },
            requestId: "warmup-batch-req-" + Date.now(),
            clientTimestamp: new Date().toISOString()
        }, 15000, "Cloud Functions emulator never responded to the recordMutation warm-up call")
        compare(result.status, 200,
                "warm-up recordMutation call was rejected — response body: " + result.text)
    }

    function init() {
        fixture = _loadFixture()
        FirebaseService.emulatorHost = emulatorFirestoreHost
        Gateway.functionUrl = emulatorFunctionsBase + "/recordMutation"
        Gateway.mode = "gateway"
        AuthStore.idToken = fixture.idToken
        AuthStore.tenantId = fixture.tenantId
        // NOT []. As of 2026-08-27, StockBatchStore.nextBatchId() now
        // mints off a REAL Firestore counter ("counters/stockBatches-
        // <year>"), same shape as SupplierStore.nextSupplierId() -- see
        // this file's header and docs/superpowers/specs/
        // 2026-08-27-async-stock-batch-id-minting-design.md. That closes
        // the actual production race this comment used to describe
        // (concurrent mints from incomplete local caches), but the LOCAL
        // seedMax scan (nextBatchId's floor against the counter doc not
        // existing yet) still matters here for the exact reason
        // SupplierStore's init() seeds its fixture: any product created
        // with stock > 0 anywhere in this qmltestrunner process
        // (InventoryStore.addProduct()'s companion "Initial stock" batch,
        // e.g. tst_InventoryE2E.qml's first test) already advanced the
        // real counter for this year -- resetting to [] here wouldn't
        // cause a collision any more (the counter, not this array, is now
        // the source of truth for "next"), but it WOULD leave this file's
        // own local cache stale relative to what the counter already
        // reflects, which is exactly the kind of drift
        // syncFromFirebase() exists to avoid. Syncing for real (matching
        // what the real app always does before minting) stays the most
        // robust choice regardless of what else has run earlier in the
        // same process.
        StockBatchStore.syncFromFirebase()
        tryVerify(function() { return !StockBatchStore.loadingMore && !StockBatchStore.hasMore }, 5000,
                  "StockBatchStore never finished syncing from the emulator before this test's init()")
        OutboxStore.clear()
        lastConflict = null
        Gateway.mutationConflicted.connect(_onMutationConflicted)
    }

    function cleanup() {
        Gateway.mutationConflicted.disconnect(_onMutationConflicted)
        FirebaseService.emulatorHost = ""
        Gateway.functionUrl = realFunctionUrl
        AuthStore.idToken = ""
        AuthStore.tenantId = ""
    }

    // addBatch is async now (mints its own batchId via a real Firestore
    // counter -- see StockBatchStore.nextBatchId) -- same
    // callback-plus-tryVerify pattern tst_SupplierStoreE2E.qml's
    // _createSupplier helper already establishes for the same reason.
    function _createBatch(productId, supplierId, qty, unitCost, note) {
        var createdDoc = null
        var done = false
        StockBatchStore.addBatch(productId, supplierId, qty, unitCost, note, false,
            function(doc) { done = true; createdDoc = doc })
        tryVerify(function() { return done }, 5000, "addBatch callback never fired")
        return createdDoc
    }

    function test_addBatch_creates_real_emulator_doc() {
        var doc = _createBatch("prod-e2e-1", "sup-e2e-1", 10, 5, "E2E test batch")
        verify(doc !== null, "addBatch did not return a created record")
        var docPath = "tenants/" + fixture.tenantId + "/stock_batches/" + doc.batchId
        var serverDoc = _pollEmulatorDoc(docPath, doc.batchId, function(d) { return d !== null }, 5000,
                                          "batch doc never appeared in the emulator")
        compare(Number(serverDoc.fields.qtyReceived.integerValue), 10)
    }

    function test_addBatchWithId_creates_real_emulator_doc_with_a_pre_reserved_id() {
        // The bulk-import path: skips nextBatchId's mint round-trip
        // entirely, given an already-reserved id (as InventoryStore.
        // upsertMany's pullBatchId() would hand it).
        var doc = StockBatchStore.addBatchWithId("BAT-" + new Date().getFullYear() + "-900",
                                                  "prod-e2e-prereserved", "sup-e2e-1", 7, 3, "Prereserved id test")
        verify(doc !== null, "addBatchWithId returned null")
        compare(doc.batchId, "BAT-" + new Date().getFullYear() + "-900")
        var docPath = "tenants/" + fixture.tenantId + "/stock_batches/" + doc.batchId
        var serverDoc = _pollEmulatorDoc(docPath, doc.batchId, function(d) { return d !== null }, 5000,
                                          "batch doc never appeared in the emulator")
        compare(Number(serverDoc.fields.qtyReceived.integerValue), 7)
    }

    // The actual point of Option A (see the design doc): proves batchId
    // minting is now backed by a real Firestore transaction counter, not
    // just "still happens to produce different ids in this one test run".
    function test_nextBatchId_mints_sequential_ids_via_a_real_counter() {
        var first = null
        var second = null
        StockBatchStore.nextBatchId(function(id) { first = id })
        tryVerify(function() { return first !== null }, 5000, "first nextBatchId callback never fired")
        StockBatchStore.nextBatchId(function(id) { second = id })
        tryVerify(function() { return second !== null }, 5000, "second nextBatchId callback never fired")
        verify(first.length > 0, "first mint returned an empty id")
        verify(second.length > 0, "second mint returned an empty id")
        verify(first !== second, "two sequential mints returned the same batchId")
        var prefix = "BAT-" + new Date().getFullYear() + "-"
        var firstNum = parseInt(first.substring(prefix.length))
        var secondNum = parseInt(second.substring(prefix.length))
        compare(secondNum, firstNum + 1)
    }

    function _firestoreFieldsToPlain(fields) {
        function convertValue(v) {
            if (v.stringValue !== undefined) return v.stringValue
            if (v.integerValue !== undefined) return Number(v.integerValue)
            if (v.doubleValue !== undefined) return v.doubleValue
            if (v.booleanValue !== undefined) return v.booleanValue
            if (v.nullValue !== undefined) return null
            if (v.timestampValue !== undefined) return v.timestampValue
            if (v.arrayValue !== undefined) {
                var arr = (v.arrayValue.values || [])
                var out = []
                for (var i = 0; i < arr.length; ++i) out.push(convertValue(arr[i]))
                return out
            }
            if (v.mapValue !== undefined) return _firestoreFieldsToPlain(v.mapValue.fields || {})
            return null
        }
        var plain = {}
        for (var key in fields) plain[key] = convertValue(fields[key])
        return plain
    }

    function test_duplicate_create_for_the_same_batch_id_produces_a_real_conflict() {
        // First identity creates the batch normally, for real.
        var doc = _createBatch("prod-e2e-conflict", "sup-e2e-1", 20, 5, "Conflict test batch")
        verify(doc !== null, "addBatch did not return a created record")
        var batchId = doc.batchId
        var docPath = "tenants/" + fixture.tenantId + "/stock_batches/" + batchId
        _pollEmulatorDoc(docPath, batchId, function(d) { return d !== null }, 5000,
                          "batch doc never appeared before the conflict test")

        // Change it server-side directly (StockBatchStore itself never
        // calls "update" for stock_batch -- see this file's header comment
        // for why that's fine for this test's purpose: it makes the
        // conflict's `current` payload genuinely differ from what
        // StockBatchStore's local cache still holds, so the reconciliation
        // assertion below is checking a real change, not an echo).
        var currentDoc = _pollEmulatorDoc(docPath, batchId, function(d) { return d !== null }, 5000,
                                           "batch doc vanished unexpectedly")
        var plainBatch = _firestoreFieldsToPlain(currentDoc.fields)
        var updatedAfter = Object.assign({}, plainBatch, { note: "Changed directly server-side" })
        Gateway.recordMutation("stock_batch", batchId, "update", plainBatch, updatedAfter)
        _pollEmulatorDoc(docPath, batchId, function(d) {
            return d !== null && d.fields.note.stringValue === "Changed directly server-side"
        }, 5000, "direct server-side update never landed -- conflict setup failed")

        // Second identity now attempts to CREATE the same batchId, unaware
        // it already exists (before: null) -- the actual reachable
        // conflict path for this entity.
        var savedToken = AuthStore.idToken
        AuthStore.idToken = fixture.secondIdToken
        lastConflict = null
        Gateway.recordMutation("stock_batch", batchId, "create", null,
            { batchId: batchId, productId: "prod-e2e-conflict", qtyReceived: 999, qtyRemaining: 999 })
        AuthStore.idToken = savedToken

        tryVerify(function() { return lastConflict !== null }, 10000,
                  "Gateway.mutationConflicted never fired for a duplicate-create stock_batch conflict")
        compare(lastConflict.entity, "stock_batch")
        compare(lastConflict.entityId, batchId)
        compare(lastConflict.current.note, "Changed directly server-side")

        // The real point of this test: StockBatchStore's own
        // _onMutationConflicted handler (connected app-wide, not just for
        // this test's own callback above) must have reconciled its local
        // cache to match the server's actual current state.
        var cached = StockBatchStore.getById(batchId)
        verify(cached !== null, "StockBatchStore's local cache lost track of the batch entirely")
        compare(cached.note, "Changed directly server-side")
    }
    // ── BC2: product delete is acked before anything else is destroyed or logged ──────────
    // Design: docs/superpowers/specs/2026-10-04-product-delete-batch-cascade-design.md (BC2).
    // Needs BC1 (server sweep) in the functions emulator, which the CI job runs from this checkout.

    function _createProductWithStock(name, sku) {
        var createdId = "", done = false
        InventoryStore.addProduct(name, sku, "General", "", 100, "pc", 10, 2,
                                  120, false, 0, fixture.supplierName, 80, "",
                                  function(ok, id) { done = true; createdId = ok ? id : "" })
        tryVerify(function() { return done }, 5000, "addProduct callback never fired")
        verify(createdId.length > 0, "addProduct did not return a productId")
        E2EHelpers.pollEmulatorDoc(this, emulatorFirestoreHost, "tenants/" + fixture.tenantId + "/inventory/" + createdId,
                                   createdId, function(d) { return d !== null }, 5000, "product doc never appeared", true)
        return createdId
    }

    function _batchesOf(productId) {
        return StockBatchStore.batches.filter(function(b) { return b.productId === productId })
    }

    function _batchDocPath(batchId) { return "tenants/" + fixture.tenantId + "/stock_batches/" + batchId }

    function _productInCache(productId) {
        var ps = InventoryStore.products
        for (var k = 0; k < ps.length; ++k) if (ps[k].productId === productId) return ps[k]
        return null
    }

    function test_BC2_product_delete_hides_batches_at_once_logs_after_ack_and_server_sweeps_them() {
        var productId = _createProductWithStock("E2E BC2 Delete", "SKU-E2E-BC2-1")
        tryVerify(function() { return _batchesOf(productId).length >= 1 }, 10000,
                  "the initial-stock batch never reached the local cache")
        var batchIds = _batchesOf(productId).map(function(b) { return b.batchId })
        for (var i = 0; i < batchIds.length; ++i)
            E2EHelpers.pollEmulatorDoc(this, emulatorFirestoreHost, _batchDocPath(batchIds[i]), batchIds[i],
                                       function(d) { return d !== null }, 10000, "batch doc " + i + " never reached the server", true)
        ActivityLog.clear()
        OutboxStore.clear()

        InventoryStore.deleteProduct(productId)

        // Same call stack, before any network turn: local effects only.
        compare(_batchesOf(productId).length, 0, "batches must be hidden locally at click time")
        compare(ActivityLog.entries.length, 0, "no Activity entry before the server acked")
        compare(OutboxStore.items.filter(function(it) { return it.entity === "stock_batch" }).length, 0,
                "the client must not send any stock_batch delete")

        tryVerify(function() {
            return ActivityLog.entries.length === 1 && ActivityLog.entries[0].kind === "product_deleted"
        }, 15000, "the product_deleted Activity entry never appeared after the ack")
        compare(ActivityLog.entries[0].entityId, productId)
        for (var j = 0; j < batchIds.length; ++j)
            E2EHelpers.pollEmulatorDoc(this, emulatorFirestoreHost, _batchDocPath(batchIds[j]), batchIds[j],
                                       function(d) { return d === null }, 20000,
                                       "server sweep never removed batch " + batchIds[j], true)
        compare(ActivityLog.entries.length, 1, "exactly one Activity entry for one delete")
    }

    function test_BC2_stale_product_delete_409_keeps_product_batches_and_activity_clean() {
        var productId = _createProductWithStock("E2E BC2 Stale", "SKU-E2E-BC2-2")
        tryVerify(function() { return _batchesOf(productId).length >= 1 }, 10000,
                  "the initial-stock batch never reached the local cache")
        var batchIds = _batchesOf(productId).map(function(b) { return b.batchId })
        for (var i = 0; i < batchIds.length; ++i)
            E2EHelpers.pollEmulatorDoc(this, emulatorFirestoreHost, _batchDocPath(batchIds[i]), batchIds[i],
                                       function(d) { return d !== null }, 10000, "batch doc " + i + " never reached the server", true)
        // Make the cached row stale: the server holds stock 10, the cache now claims 999, so the
        // delete's compare-and-set `before` cannot match and the server answers 409.
        var arr = InventoryStore.products.slice()
        for (var k = 0; k < arr.length; ++k)
            if (arr[k].productId === productId) arr[k] = Object.assign({}, arr[k], { stock: 999 })
        InventoryStore.products = arr
        ActivityLog.clear()
        OutboxStore.clear()

        InventoryStore.deleteProduct(productId)

        tryVerify(function() {
            var p = _productInCache(productId)
            return p !== null && p.stock === 10
        }, 15000, "the rejected delete did not restore the server's version of the product")
        tryVerify(function() { return _batchesOf(productId).length === batchIds.length }, 15000,
                  "the rejected delete did not bring the hidden batches back by re-read")
        wait(2000) // room for any (forbidden) late sweep or Activity write to land
        for (var j = 0; j < batchIds.length; ++j)
            E2EHelpers.pollEmulatorDoc(this, emulatorFirestoreHost, _batchDocPath(batchIds[j]), batchIds[j],
                                       function(d) { return d !== null }, 5000,
                                       "batch " + batchIds[j] + " was destroyed by a delete that never committed", true)
        compare(ActivityLog.entries.filter(function(e) { return e.kind === "product_deleted" }).length, 0,
                "a rejected delete must not log 'Product deleted'")
    }

    // ── D2/D3: refuse restock and delete behind a parked write ────────────────────────────
    // A parked item is seeded straight into the outbox (terminal + stuck, so Gateway never
    // sends it) instead of provoking a real server rejection: the guard only reads the outbox.
    function _parkEditFor(productId) {
        var rid = "e2e-park-" + productId
        OutboxStore.enqueue({ requestId: rid, entity: "inventory", entityId: productId, action: "update",
                              before: { stock: 10 }, after: { stock: 10 } })
        OutboxStore.setStuckMeta(rid, { failures: 5, stuck: true, terminal: true })
        return rid
    }

    function test_D3_delete_behind_a_parked_write_is_refused_and_destroys_nothing() {
        var productId = _createProductWithStock("E2E D3 Refuse", "SKU-E2E-D3-1")
        tryVerify(function() { return _batchesOf(productId).length >= 1 }, 10000, "initial-stock batch never reached the cache")
        var batchIds = _batchesOf(productId).map(function(b) { return b.batchId })
        ActivityLog.clear()
        OutboxStore.clear()
        var rid = _parkEditFor(productId)

        compare(InventoryStore.deleteProduct(productId), InventoryStore.parkedWriteMessage)

        verify(_productInCache(productId) !== null, "the product must stay visible")
        compare(_batchesOf(productId).length, batchIds.length, "batches must stay")
        compare(OutboxStore.items.filter(function(it) { return it.action === "delete" }).length, 0, "no delete queued")
        wait(1500)
        for (var j = 0; j < batchIds.length; ++j)
            E2EHelpers.pollEmulatorDoc(this, emulatorFirestoreHost, _batchDocPath(batchIds[j]), batchIds[j],
                                       function(d) { return d !== null }, 5000, "batch " + batchIds[j] + " vanished", true)
        E2EHelpers.pollEmulatorDoc(this, emulatorFirestoreHost, "tenants/" + fixture.tenantId + "/inventory/" + productId,
                                   productId, function(d) { return d !== null }, 5000, "the product doc vanished", true)
        compare(ActivityLog.entries.filter(function(e) { return e.kind === "product_deleted" }).length, 0)

        // After the user discards the parked write, the delete goes through again.
        OutboxStore.markSent(rid)
        compare(InventoryStore.deleteProduct(productId), undefined)
        compare(_productInCache(productId), null)
    }

    function test_D2_restock_behind_a_parked_write_is_refused_and_writes_no_batch() {
        var productId = _createProductWithStock("E2E D2 Refuse", "SKU-E2E-D2-1")
        tryVerify(function() { return _batchesOf(productId).length >= 1 }, 10000, "initial-stock batch never reached the cache")
        var nBatches = _batchesOf(productId).length
        OutboxStore.clear()
        _parkEditFor(productId)
        var result = null
        InventoryStore.restock(productId, 5, "", 10, "", function(ok, sf, refusal) { result = { ok: ok, refusal: refusal } })

        verify(result !== null, "the refusal must answer synchronously, not hang")
        compare(result.ok, false)
        compare(result.refusal, InventoryStore.parkedWriteMessage)
        compare(_batchesOf(productId).length, nBatches, "no batch written")
        compare(OutboxStore.items.length, 1, "only the parked item is queued")
        compare(_productInCache(productId).stock, 10)
    }
}
