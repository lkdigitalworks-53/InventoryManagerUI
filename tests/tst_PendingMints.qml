import QtQuick
import QtTest
import "../qml/helper/PendingMints.js" as PM

// Headless tests for the tenant rules of StockBatchStore's pending batch-id mint queue.
// Pure JS, no singletons: StockBatchStore calls these same functions, so this file tests
// what ships (not a mirror of it). The store wiring itself (the tenant captured at addBatch and
// compared again when the mint answers, the ledger-loaded gate in retryPendingMints, the
// quarantine settings key) cannot run here: the driver below models that control flow with the
// real helper, and the on-device plan covers the real thing.
// Design: docs/superpowers/specs/2026-10-26-pending-mints-tenant-scope-design.md
// Test plan: docs/superpowers/test-plans/2026-10-26-pending-mints-tenant-scope-test-plan.md
TestCase {
    name: "PendingMints"

    function _rng(seed) {
        var s = seed
        return function() {
            s = (s * 1664525 + 1013904223) % 4294967296
            return s / 4294967296
        }
    }

    function _it(id, tenant, product, over) {
        var o = { id: id, tenantId: tenant, productId: product, supplierId: "", qty: 3, unitCost: 10, note: "" }
        for (var k in over) o[k] = over[k]
        return o
    }

    function _json(v) { return JSON.stringify(v) }

    // ── normalize ───────────────────────────────────────────────────────────

    function test_normalize_keeps_valid_items_whole_and_in_order() {
        var a = _it("a", "T1", "P1", { supplierId: "S1", qty: 2.5, unitCost: 7.25, note: "n1" })
        var b = _it("b", "T2", "P2")
        var r = PM.normalize([a, b])
        compare(r.items.length, 2)
        compare(r.dropped, 0)
        compare(r.rejected.length, 0)
        compare(_json(r.items[0]), _json(a))
        compare(r.items[1].id, "b")
    }

    function test_normalize_keeps_a_minimal_item_and_odd_but_valid_qty_data() {
        return [
            { tag: "only the required fields", item: { id: "a", tenantId: "T1", productId: "P1", qty: 1 } },
            { tag: "fractional qty", item: _it("a", "T1", "P1", { qty: 0.5 }) },
            { tag: "huge finite qty", item: _it("a", "T1", "P1", { qty: 1e9 }) },
            { tag: "no unitCost", item: _it("a", "T1", "P1", { unitCost: undefined }) }
        ]
    }
    function test_normalize_keeps_a_minimal_item_and_odd_but_valid_qty(data) {
        var r = PM.normalize([data.item])
        compare(r.items.length, 1, data.tag)
        compare(r.dropped, 0, data.tag)
        compare(PM.has(r.items, "T1", "P1"), true, data.tag)
    }

    function test_normalize_drops_items_saved_before_the_fix_data() {
        return [
            { tag: "no tenantId", item: { id: "a", productId: "P1", qty: 1 } },
            { tag: "empty tenantId", item: _it("a", "", "P1") },
            { tag: "numeric tenantId", item: _it("a", 7, "P1") },
            { tag: "no id", item: _it(undefined, "T1", "P1") },
            { tag: "empty id", item: _it("", "T1", "P1") },
            { tag: "no productId", item: _it("a", "T1", undefined) },
            { tag: "empty productId", item: _it("a", "T1", "") },
            { tag: "zero qty", item: _it("a", "T1", "P1", { qty: 0 }) },
            { tag: "negative qty", item: _it("a", "T1", "P1", { qty: -2 }) },
            { tag: "NaN qty", item: _it("a", "T1", "P1", { qty: NaN }) },
            { tag: "Infinity qty", item: _it("a", "T1", "P1", { qty: Infinity }) },
            { tag: "-Infinity qty", item: _it("a", "T1", "P1", { qty: -Infinity }) },
            { tag: "string qty", item: _it("a", "T1", "P1", { qty: "3" }) },
            { tag: "null", item: null },
            { tag: "number", item: 5 },
            { tag: "string", item: "x" },
            { tag: "array", item: [] }
        ]
    }
    function test_normalize_drops_items_saved_before_the_fix(data) {
        var r = PM.normalize([data.item, _it("ok", "T1", "P1")])
        compare(r.items.length, 1, data.tag)
        compare(r.items[0].id, "ok", data.tag)
        compare(r.dropped, 1, data.tag)
        compare(r.rejected.length, 1, data.tag)
    }

    function test_normalize_counts_every_dropped_entry_and_hands_them_back_in_order() {
        var bad1 = { id: "x", productId: "P1", qty: 1 }          // no tenant
        var bad2 = null
        var bad3 = _it("c", "T1", "P1", { qty: 0 })
        var r = PM.normalize([bad1, _it("a", "T1", "P1"), bad2, _it("b", "T1", "P2"), bad3])
        compare(r.dropped, 3)
        compare(r.items.length, 2)
        compare(r.items[0].id, "a")
        compare(r.items[1].id, "b")
        compare(_json(r.rejected), _json([bad1, bad2, bad3]))
        compare(r.dropped + r.items.length, 5)
    }

    function test_normalize_does_not_dedupe_ids() {
        // Pinned: ids are Date.now()_random so a clash is not expected; if one happens, both items
        // are kept here and both go when `without` removes that id (see test_without_*).
        compare(PM.normalize([_it("a", "T1", "P1"), _it("a", "T2", "P1")]).items.length, 2)
    }

    function test_normalize_of_non_arrays_is_empty_data() {
        return [{ v: null }, { v: undefined }, { v: "x" }, { v: 3 }, { v: {} }, { v: true }]
    }
    function test_normalize_of_non_arrays_is_empty(data) {
        var r = PM.normalize(data.v)
        compare(r.items.length, 0)
        compare(r.dropped, 0)
        compare(r.rejected.length, 0)
    }

    function test_normalize_does_not_mutate_or_alias() {
        var src = [_it("a", "T1", "P1"), null]
        var before = _json(src)
        var r = PM.normalize(src)
        compare(_json(src), before)
        r.items.push("x")
        r.rejected.push("y")
        compare(src.length, 2)
    }

    // ── make ────────────────────────────────────────────────────────────────

    function test_make_builds_a_replayable_item_with_defaults() {
        var it = PM.make("i1", "T1", "P1", undefined, "3", 12.5, undefined)
        compare(it.id, "i1")
        compare(it.tenantId, "T1")
        compare(it.productId, "P1")
        compare(it.supplierId, "")
        compare(it.qty, 3)
        compare(typeof it.qty, "number")
        compare(it.unitCost, 12.5)
        compare(it.note, "")
        // the point of make(): what it queues survives the next launch's normalize()
        var r = PM.normalize(JSON.parse(JSON.stringify([it])))
        compare(r.dropped, 0)
        compare(r.items[0].tenantId, "T1")
    }

    function test_make_keeps_supplier_note_and_cost() {
        var it = PM.make("i1", "T1", "P1", "S9", 2, 0, "Adjustment")
        compare(it.supplierId, "S9")
        compare(it.note, "Adjustment")
        compare(it.unitCost, 0)
        compare(it.qty, 2)
    }

    function test_make_refuses_what_could_never_be_replayed_data() {
        return [
            { tag: "no tenant", args: ["i", "", "P1", "", 1] },
            { tag: "undefined tenant", args: ["i", undefined, "P1", "", 1] },
            { tag: "null tenant", args: ["i", null, "P1", "", 1] },
            { tag: "numeric tenant", args: ["i", 7, "P1", "", 1] },
            { tag: "no id", args: ["", "T1", "P1", "", 1] },
            { tag: "undefined id", args: [undefined, "T1", "P1", "", 1] },
            { tag: "no product", args: ["i", "T1", "", "", 1] },
            { tag: "undefined product", args: ["i", "T1", undefined, "", 1] },
            { tag: "numeric product", args: ["i", "T1", 5, "", 1] },
            { tag: "zero qty", args: ["i", "T1", "P1", "", 0] },
            { tag: "negative qty", args: ["i", "T1", "P1", "", -1] },
            { tag: "NaN qty", args: ["i", "T1", "P1", "", NaN] },
            { tag: "Infinity qty", args: ["i", "T1", "P1", "", Infinity] },
            { tag: "text qty", args: ["i", "T1", "P1", "", "abc"] },
            { tag: "empty-string qty", args: ["i", "T1", "P1", "", ""] },
            { tag: "null qty", args: ["i", "T1", "P1", "", null] },
            { tag: "undefined qty", args: ["i", "T1", "P1", "", undefined] }
        ]
    }
    function test_make_refuses_what_could_never_be_replayed(data) {
        compare(PM.make.apply(null, data.args), null, data.tag)
    }

    // ── appendRejected (quarantine) ─────────────────────────────────────────

    function test_appendRejected_appends_in_order_and_round_trips() {
        var first = PM.appendRejected("", [{ id: "a" }, { raw: "{broken" }], 50)
        compare(_json(JSON.parse(first)), _json([{ id: "a" }, { raw: "{broken" }]))
        var second = PM.appendRejected(first, [{ id: "c" }], 50)
        var all = JSON.parse(second)
        compare(all.length, 3)
        compare(all[0].id, "a")
        compare(all[1].raw, "{broken")
        compare(all[2].id, "c")
    }

    function test_appendRejected_keeps_the_newest_cap_entries() {
        var prev = _json([{ n: 1 }, { n: 2 }, { n: 3 }])
        var out = JSON.parse(PM.appendRejected(prev, [{ n: 4 }, { n: 5 }], 3))
        compare(out.length, 3)
        compare(out[0].n, 3)
        compare(out[2].n, 5)
    }

    function test_appendRejected_default_cap_is_50_newest_kept() {
        var entries = []
        for (var i = 0; i < 60; ++i) entries.push({ n: i })
        var out = JSON.parse(PM.appendRejected("", entries, undefined))
        compare(out.length, 50)
        compare(out[0].n, 10)
        compare(out[49].n, 59)
    }

    function test_appendRejected_cap_edges_data() {
        return [
            { tag: "zero -> default 50", cap: 0, want: 50 },
            { tag: "NaN -> default 50", cap: NaN, want: 50 },
            { tag: "text -> default 50", cap: "x", want: 50 },
            { tag: "negative -> at least 1", cap: -3, want: 1 },
            { tag: "fraction floors", cap: 2.7, want: 2 },
            { tag: "one", cap: 1, want: 1 }
        ]
    }
    function test_appendRejected_cap_edges(data) {
        var entries = []
        for (var i = 0; i < 60; ++i) entries.push({ n: i })
        var out = JSON.parse(PM.appendRejected("", entries, data.cap))
        compare(out.length, data.want, data.tag)
        compare(out[out.length - 1].n, 59, data.tag)      // newest always survives
    }

    function test_appendRejected_a_damaged_previous_value_starts_fresh_data() {
        return [
            { tag: "empty", prev: "" }, { tag: "undefined", prev: undefined }, { tag: "null", prev: null },
            { tag: "broken json", prev: "{" }, { tag: "json null", prev: "null" },
            { tag: "json object", prev: "{}" }, { tag: "json number", prev: "5" }
        ]
    }
    function test_appendRejected_a_damaged_previous_value_starts_fresh(data) {
        var out = JSON.parse(PM.appendRejected(data.prev, [{ id: "a" }], 50))
        compare(out.length, 1, data.tag)
        compare(out[0].id, "a", data.tag)
    }

    function test_appendRejected_ignores_non_array_entries_and_keeps_prev_data() {
        return [{ e: null }, { e: undefined }, { e: "x" }, { e: 3 }, { e: {} }]
    }
    function test_appendRejected_ignores_non_array_entries_and_keeps_prev(data) {
        var out = JSON.parse(PM.appendRejected(_json([{ id: "keep" }]), data.e, 50))
        compare(out.length, 1)
        compare(out[0].id, "keep")
    }

    function test_appendRejected_does_not_mutate_its_inputs() {
        var entries = [{ id: "a" }]
        var before = _json(entries)
        PM.appendRejected(_json([{ id: "p" }]), entries, 50)
        compare(_json(entries), before)
    }

    // ── forTenant / has ─────────────────────────────────────────────────────

    function test_forTenant_returns_only_that_tenants_items_in_order() {
        var list = [_it("a", "T1", "P1"), _it("b", "T2", "P1"), _it("c", "T1", "P2")]
        var mine = PM.forTenant(list, "T1")
        compare(mine.length, 2)
        compare(mine[0].id, "a")
        compare(mine[1].id, "c")
    }

    function test_forTenant_with_no_signed_in_tenant_is_empty_data() {
        return [{ t: "" }, { t: null }, { t: undefined }, { t: 0 }, { t: {} }]
    }
    function test_forTenant_with_no_signed_in_tenant_is_empty(data) {
        compare(PM.forTenant([_it("a", "T1", "P1")], data.t).length, 0)
        // an untagged item (tenantId "") must not match a signed-out state either
        compare(PM.forTenant([_it("a", "", "P1"), _it("b", undefined, "P2")], data.t).length, 0)
    }

    function test_forTenant_tenant_ids_are_case_whitespace_and_type_exact() {
        var list = [_it("a", "Tenant1", "P1")]
        compare(PM.forTenant(list, "tenant1").length, 0)
        compare(PM.forTenant(list, "Tenant1 ").length, 0)
        compare(PM.forTenant(list, "Tenant1").length, 1)
        // a raw entry with a numeric tenant never matches the same digits as a string
        compare(PM.forTenant([_it("a", 7, "P1")], "7").length, 0)
    }

    function test_forTenant_tolerates_non_array_and_null_entries() {
        compare(PM.forTenant(null, "T1").length, 0)
        compare(PM.forTenant("x", "T1").length, 0)
        compare(PM.forTenant([null, undefined, _it("a", "T1", "P1")], "T1").length, 1)
    }

    function test_forTenant_returns_a_new_array_and_leaves_the_list_alone() {
        var list = [_it("a", "T1", "P1")]
        var before = _json(list)
        var mine = PM.forTenant(list, "T1")
        mine.push("x")
        compare(_json(list), before)
    }

    function test_has_is_per_tenant_the_cross_tenant_hide_bug() {
        // Product ids repeat across tenants ("P-001"): tenant B must not see A's pending mint.
        var list = [_it("a", "A", "P-001")]
        compare(PM.has(list, "A", "P-001"), true)
        compare(PM.has(list, "B", "P-001"), false)
        compare(PM.has(list, "", "P-001"), false)
        compare(PM.has(list, "A", "P-002"), false)
    }

    function test_has_finds_any_of_several_items_and_stays_exact() {
        var list = [_it("a", "A", "P1"), _it("b", "A", "P2"), _it("c", "B", "P3")]
        compare(PM.has(list, "A", "P2"), true)
        compare(PM.has(list, "A", "P3"), false)
        compare(PM.has(list, "A", "p2"), false)
        compare(PM.has(list, "A", "P2 "), false)
    }

    function test_has_refuses_a_missing_or_non_string_product_data() {
        return [{ p: undefined }, { p: null }, { p: "" }, { p: 5 }, { p: {} }]
    }
    function test_has_refuses_a_missing_or_non_string_product(data) {
        // a raw entry with no productId must not match `undefined`
        compare(PM.has([{ id: "a", tenantId: "A" }, _it("b", "A", "P1")], "A", data.p), false)
    }

    function test_has_is_type_exact_on_product_ids() {
        compare(PM.has([_it("a", "A", 5)], "A", "5"), false)
    }

    function test_has_tolerates_junk_lists() {
        compare(PM.has(null, "A", "P1"), false)
        compare(PM.has("x", "A", "P1"), false)
        compare(PM.has([null, undefined, _it("a", "A", "P1")], "A", "P1"), true)
        compare(PM.has([], "A", "P1"), false)
    }

    // ── due ─────────────────────────────────────────────────────────────────

    function test_due_is_the_tenants_items_minus_those_in_flight() {
        var list = [_it("a", "T1", "P1"), _it("b", "T1", "P2"), _it("c", "T2", "P3")]
        var d = PM.due(list, "T1", { a: true })
        compare(d.length, 1)
        compare(d[0].id, "b")
    }

    function test_due_keeps_queue_order() {
        var list = [_it("a", "T1", "P1"), _it("x", "T2", "P1"), _it("b", "T1", "P2"), _it("c", "T1", "P3")]
        var d = PM.due(list, "T1", { b: true })
        compare(d.length, 2)
        compare(d[0].id, "a")
        compare(d[1].id, "c")
    }

    function test_due_with_no_tenant_starts_nothing() {
        compare(PM.due([_it("a", "T1", "P1")], "", {}).length, 0)
        compare(PM.due([_it("a", "T1", "P1")], undefined, {}).length, 0)
    }

    function test_due_inflight_must_be_strictly_true_and_tolerates_junk() {
        var list = [_it("a", "T1", "P1")]
        compare(PM.due(list, "T1", { a: 1 }).length, 1)
        compare(PM.due(list, "T1", null).length, 1)
        compare(PM.due(list, "T1", "x").length, 1)
        compare(PM.due(list, "T1", undefined).length, 1)
        compare(PM.due(list, "T1", ["a"]).length, 1)      // an array is not an id map
        compare(PM.due(list, "T1", { a: true }).length, 0)
    }

    function test_due_tolerates_a_junk_list_and_leaves_inputs_alone() {
        compare(PM.due(null, "T1", {}).length, 0)
        compare(PM.due("x", "T1", {}).length, 0)
        var list = [_it("a", "T1", "P1")]
        var busy = { z: true }
        var beforeList = _json(list)
        PM.due(list, "T1", busy).push("x")
        compare(_json(list), beforeList)
        compare(_json(busy), _json({ z: true }))
    }

    // ── sameTenant ──────────────────────────────────────────────────────────

    function test_sameTenant_data() {
        return [
            { tag: "same", a: "T1", b: "T1", want: true },
            { tag: "different", a: "T1", b: "T2", want: false },
            { tag: "current signed out", a: "T1", b: "", want: false },
            { tag: "both empty", a: "", b: "", want: false },
            { tag: "item untagged", a: "", b: "T1", want: false },
            { tag: "both undefined", a: undefined, b: undefined, want: false },
            { tag: "both null", a: null, b: null, want: false },
            { tag: "both numbers", a: 1, b: 1, want: false },
            { tag: "case differs", a: "t1", b: "T1", want: false },
            { tag: "digits string vs number", a: "7", b: 7, want: false },
            { tag: "number vs digits string", a: 7, b: "7", want: false },
            { tag: "current undefined", a: "T1", b: undefined, want: false },
            { tag: "trailing space", a: "T1", b: "T1 ", want: false }
        ]
    }
    function test_sameTenant(data) {
        compare(PM.sameTenant(data.a, data.b), data.want, data.tag)
    }

    function test_sameTenant_is_also_the_ledger_loaded_gate() {
        // StockBatchStore._loadedTenant vs the signed-in tenant
        compare(PM.sameTenant("", "A"), false)           // nothing loaded yet / just cleared
        compare(PM.sameTenant("A", "A"), true)           // A's ledger is in
        compare(PM.sameTenant("A", "B"), false)          // B signed in, A's ledger is stale
        compare(PM.sameTenant("A", ""), false)           // signed out
    }

    // ── without ─────────────────────────────────────────────────────────────

    function test_without_removes_by_id_not_by_position() {
        var list = [_it("a", "T1", "P1"), _it("b", "T1", "P2"), _it("c", "T1", "P3")]
        var r = PM.without(list, "b")
        compare(r.length, 2)
        compare(r[0].id, "a")
        compare(r[1].id, "c")
        compare(list.length, 3)
    }

    function test_without_unknown_id_and_junk() {
        var list = [_it("a", "T1", "P1")]
        compare(PM.without(list, "zzz").length, 1)
        compare(PM.without(list, undefined).length, 1)
        compare(PM.without(null, "a").length, 0)
        compare(PM.without("x", "a").length, 0)
        compare(PM.without([null, _it("a", "T1", "P1")], "a").length, 1)
    }

    function test_without_removes_every_item_that_shares_the_id() {
        // Pinned, not endorsed: ids are Date.now()_random (a clash is not expected on one device).
        compare(PM.without([_it("x", "A", "P1"), _it("x", "B", "P1"), _it("y", "B", "P2")], "x").length, 1)
    }

    function test_without_returns_a_new_array() {
        var list = [_it("a", "T1", "P1")]
        var r = PM.without(list, "nope")
        r.push("x")
        compare(list.length, 1)
    }

    // ── the bugs, end to end ────────────────────────────────────────────────
    //
    // A small driver that composes the helper the way StockBatchStore does:
    //  - queue()      = _queuePendingMint (make(); no tenant / bad qty -> nothing queued)
    //  - addBatch()   = addBatch (tenant captured at the call, compared again when the mint answers)
    //  - signIn()     = a tenant signs in: the ledger of the previous one is no longer loaded
    //  - loadDone()   = _fetchFromFirebase's last page arrived: _loadedTenant = tenant, then retry
    //  - retryStart() / retryFinish() = retryPendingMints / _retryOnePendingMint (async mint)
    //  - retryPass()  = both in one go, for tests that do not care about the gap between them

    function _driver() {
        return {
            list: [], inFlight: ({}), tenant: "", loadedTenant: "",
            written: [], writtenUnder: [], direct: [], mints: [], reloads: 0, queued: 0, _n: 0,

            queue: function(product, tenant, qty) {
                var it = PM.make("m" + (this._n++), tenant, product, "", qty === undefined ? 3 : qty, 10, "")
                if (!it) return null
                this.list = this.list.concat([it])
                this.queued++
                return it
            },

            // answeredUnder: the tenant signed in when the mint ANSWERS (default: unchanged)
            addBatch: function(product, answeredUnder, qty) {
                var callTenant = this.tenant
                var now = answeredUnder === undefined ? this.tenant : answeredUnder
                if (callTenant !== now) { this.queue(product, callTenant, qty); return null }
                this.direct.push({ owner: callTenant, product: product, under: now })
                return callTenant
            },

            signIn: function(tenant) { this.tenant = tenant; this.loadedTenant = "" },

            loadDone: function() {
                this.loadedTenant = this.tenant
                this.retryPass()
            },

            retryStart: function() {
                var self = this
                var due = PM.due(this.list, this.tenant, this.inFlight)
                if (due.length === 0) return []
                if (!PM.sameTenant(this.loadedTenant, this.tenant)) { this.reloads++; return [] }
                due.forEach(function(it) {
                    self.inFlight[it.id] = true
                    self.mints.push({ owner: it.tenantId, under: self.tenant,
                                      ledgerReady: self.tenant !== "" && self.loadedTenant === self.tenant })
                })
                return due
            },

            retryFinish: function(it, answeredUnder) {
                delete this.inFlight[it.id]
                if (!PM.sameTenant(it.tenantId, answeredUnder)) return
                this.written.push(it.tenantId + ":" + it.productId)
                this.writtenUnder.push(answeredUnder)
                this.list = PM.without(this.list, it.id)
            },

            retryPass: function(mintAnswersFor) {
                var self = this
                this.retryStart().forEach(function(it) {
                    self.retryFinish(it, mintAnswersFor ? mintAnswersFor(it) : self.tenant)
                })
            }
        }
    }

    function _loaded(d, tenant) { d.signIn(tenant); d.loadDone() }

    function test_scenario_item_queued_under_A_is_never_written_under_B() {
        var d = _driver()
        _loaded(d, "A"); d.queue("P-001", "A")
        d.signIn("")             // signed out: the queue is kept
        compare(d.list.length, 1)
        _loaded(d, "B")          // another account signs in, device is online
        compare(d.written.length, 0)
        compare(PM.has(d.list, "B", "P-001"), false)
        compare(PM.has(d.list, "A", "P-001"), true)
        _loaded(d, "A")          // A signs back in: now it is replayed, once
        compare(_json(d.written), _json(["A:P-001"]))
        compare(d.list.length, 0)
    }

    function test_scenario_retry_before_the_ledger_is_loaded_mints_nothing_then_the_load_does() {
        // The tenantContextReady race: the retry fires before syncFromFirebase has filled
        // `batches`, and the counter seed would come from an empty ledger.
        var d = _driver()
        d.queue("P1", "A")
        d.signIn("A")
        d.retryPass()
        compare(d.mints.length, 0)
        compare(d.written.length, 0)
        compare(d.reloads, 1)                // it asked for the ledger instead
        d.loadDone()
        compare(d.mints.length, 1)
        compare(d.written.length, 1)
        compare(d.list.length, 0)
    }

    function test_scenario_no_tenant_yet_retries_nothing_and_does_not_ask_for_a_load() {
        var d = _driver()
        d.queue("P1", "A")
        d.retryPass()
        compare(d.mints.length, 0)
        compare(d.reloads, 0)
        _loaded(d, "A")
        compare(d.written.length, 1)
    }

    function test_scenario_an_empty_queue_never_asks_for_a_load() {
        var d = _driver()
        d.signIn("A")
        d.retryPass()
        compare(d.reloads, 0)
    }

    function test_scenario_after_an_account_switch_the_old_ledger_does_not_count() {
        var d = _driver()
        _loaded(d, "A")
        d.queue("P1", "B")
        d.tenant = "B"                       // B signed in; A's ledger is still what `batches` holds
        compare(d.loadedTenant, "A")
        d.retryPass()
        compare(d.mints.length, 0)
        d.loadDone()                         // B's own ledger is in
        compare(_json(d.written), _json(["B:P1"]))
    }

    function test_scenario_account_switch_while_the_mint_is_out_keeps_the_item() {
        var d = _driver()
        _loaded(d, "A"); d.queue("P1", "A")
        d.retryPass(function() { return "B" })   // B was signed in when the mint answered
        compare(d.written.length, 0)
        compare(d.list.length, 1)
        compare(d.list[0].tenantId, "A")
        d.retryPass()                            // still A: replays
        compare(d.written.length, 1)
    }

    function test_scenario_two_tenants_same_product_id_do_not_interfere() {
        var d = _driver()
        d.queue("P-001", "A"); d.queue("P-001", "B")
        _loaded(d, "B")
        compare(_json(d.written), _json(["B:P-001"]))
        compare(PM.has(d.list, "A", "P-001"), true)
        compare(PM.has(d.list, "B", "P-001"), false)
    }

    function test_scenario_every_retry_mint_starts_under_the_items_own_tenant_with_a_loaded_ledger() {
        var d = _driver()
        d.queue("P1", "A"); d.queue("P2", "B"); d.queue("P3", "A")
        _loaded(d, "A")
        _loaded(d, "B")
        compare(d.mints.length, 3)
        d.mints.forEach(function(m) {
            compare(m.under, m.owner)
            compare(m.ledgerReady, true)
        })
    }

    function test_scenario_a_second_pass_while_a_mint_is_out_starts_nothing_new() {
        var d = _driver()
        _loaded(d, "A")
        d.queue("P1", "A")
        var started = d.retryStart()
        compare(started.length, 1)
        compare(d.retryStart().length, 0)    // same item, still in flight
        compare(d.mints.length, 1)
        d.retryFinish(started[0], "A")
        compare(d.written.length, 1)
        compare(d.list.length, 0)
        compare(d.retryStart().length, 0)
        compare(Object.keys(d.inFlight).length, 0)
    }

    function test_scenario_a_failed_or_timed_out_mint_frees_the_item_for_the_next_pass() {
        var d = _driver()
        _loaded(d, "A"); d.queue("P1", "A")
        var started = d.retryStart()
        d.retryFinish(started[0], "")        // answered while nobody (or someone else) was signed in
        compare(d.list.length, 1)
        compare(Object.keys(d.inFlight).length, 0)
        compare(d.retryStart().length, 1)    // eligible again
    }

    function test_scenario_addBatch_success_after_an_account_switch_is_owed_to_the_old_tenant() {
        // A restocks, the mint takes seconds, B signs in meanwhile: the batch must not land in B.
        var d = _driver()
        _loaded(d, "A")
        compare(d.addBatch("P-001", "B"), null)
        compare(d.direct.length, 0)
        compare(d.list.length, 1)
        compare(d.list[0].tenantId, "A")
        compare(PM.has(d.list, "B", "P-001"), false)
        _loaded(d, "B")
        compare(d.written.length, 0)         // B's retry pass does not touch A's item
        _loaded(d, "A")
        compare(_json(d.written), _json(["A:P-001"]))
    }

    function test_scenario_addBatch_signed_out_while_the_mint_was_out_is_owed_not_lost() {
        var d = _driver()
        _loaded(d, "A")
        compare(d.addBatch("P1", ""), null)
        compare(d.list.length, 1)
        compare(d.list[0].tenantId, "A")
    }

    function test_scenario_addBatch_with_an_unchanged_tenant_writes_directly() {
        var d = _driver()
        _loaded(d, "A")
        compare(d.addBatch("P1"), "A")
        compare(d.direct.length, 1)
        compare(d.direct[0].under, "A")
        compare(d.list.length, 0)
    }

    function test_scenario_addBatch_with_no_tenant_at_all_is_not_queued_and_not_written_for_anyone() {
        // tenant "" at the call and "" at the answer: unchanged, so it takes the normal path
        // (what the headless store tests rely on); a FAILED mint with no tenant queues nothing.
        var d = _driver()
        compare(d.queue("P1", ""), null)
        compare(d.list.length, 0)
        compare(d.queued, 0)
    }

    function test_scenario_a_bad_qty_is_never_queued() {
        var d = _driver()
        compare(d.queue("P1", "A", 0), null)
        compare(d.queue("P1", "A", -1), null)
        compare(d.queue("P1", "A", NaN), null)
        compare(d.queue("P1", "A", "x"), null)
        compare(d.list.length, 0)
        compare(d.queue("P1", "A", "4").qty, 4)   // a numeric string is coerced, not lost
        compare(d.list.length, 1)
    }

    // ── seeded monkey ───────────────────────────────────────────────────────

    function test_monkey_a_tenant_only_ever_writes_its_own_items_on_a_loaded_ledger() {
        var r = _rng(26102026)
        var tenants = ["A", "B", "C", ""]
        for (var round = 0; round < 300; ++round) {
            var d = _driver()
            var open = []                                  // mints started but not answered
            for (var step = 0; step < 40; ++step) {
                var roll = r()
                var t = tenants[Math.floor(r() * tenants.length)]
                var prod = "P" + Math.floor(r() * 4)
                if (roll < 0.20) {
                    d.queue(prod, t)
                } else if (roll < 0.30) {
                    d.addBatch(prod, r() < 0.4 ? tenants[Math.floor(r() * tenants.length)] : undefined)
                } else if (roll < 0.45) {
                    d.signIn(t)                            // sign in / out only
                } else if (roll < 0.60) {
                    d.loadDone()
                } else if (roll < 0.80) {
                    d.retryPass(r() < 0.3 ? function() { return tenants[Math.floor(r() * tenants.length)] } : undefined)
                } else if (roll < 0.90) {
                    open = open.concat(d.retryStart())     // a mint goes out and stays out
                } else if (open.length > 0) {
                    var which = Math.floor(r() * open.length)
                    d.retryFinish(open[which], r() < 0.5 ? d.tenant : tenants[Math.floor(r() * tenants.length)])
                    open.splice(which, 1)
                }
            }
            // THE invariants
            d.written.forEach(function(w, idx) {
                compare(d.writtenUnder[idx], w.split(":")[0])        // written only while its tenant is signed in
            })
            d.mints.forEach(function(m) {
                compare(m.under, m.owner)                            // minted only under the owning tenant
                compare(m.ledgerReady, true)                         // ... and only on a loaded ledger
            })
            d.direct.forEach(function(w) { compare(w.under, w.owner) })
            // nothing created from thin air or lost: every queued item is waiting or was written
            compare(d.list.length + d.written.length, d.queued)
            for (var i = 0; i < d.list.length; ++i) verify(d.list[i].tenantId.length > 0)
            // an item still in flight is still queued
            for (var id in d.inFlight) verify(PM.without(d.list, id).length < d.list.length, "in-flight item " + id)
        }
    }
}
