import QtQuick
import QtTest
import "../qml/helper/PendingMints.js" as PM

// Headless tests for the tenant rules of StockBatchStore's pending batch-id mint queue.
// Pure JS, no singletons: StockBatchStore calls these same functions, so this file tests
// what ships (not a mirror). The store wiring (tenant captured at addBatch, the check in
// the retry callback, the tenantContextReady hook) is covered by the on-device plan.
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

    // ── normalize ───────────────────────────────────────────────────────────

    function test_normalize_keeps_valid_items() {
        var r = PM.normalize([_it("a", "T1", "P1"), _it("b", "T2", "P2")])
        compare(r.items.length, 2)
        compare(r.dropped, 0)
    }

    function test_normalize_drops_items_saved_before_the_fix_data() {
        return [
            { name: "no tenantId", item: { id: "a", productId: "P1", qty: 1 } },
            { name: "empty tenantId", item: _it("a", "", "P1") },
            { name: "numeric tenantId", item: _it("a", 7, "P1") },
            { name: "no id", item: _it(undefined, "T1", "P1") },
            { name: "empty id", item: _it("", "T1", "P1") },
            { name: "no productId", item: _it("a", "T1", undefined) },
            { name: "empty productId", item: _it("a", "T1", "") },
            { name: "zero qty", item: _it("a", "T1", "P1", { qty: 0 }) },
            { name: "negative qty", item: _it("a", "T1", "P1", { qty: -2 }) },
            { name: "NaN qty", item: _it("a", "T1", "P1", { qty: NaN }) },
            { name: "string qty", item: _it("a", "T1", "P1", { qty: "3" }) },
            { name: "null", item: null },
            { name: "number", item: 5 },
            { name: "string", item: "x" },
            { name: "array", item: [] }
        ]
    }
    function test_normalize_drops_items_saved_before_the_fix(data) {
        var r = PM.normalize([data.item, _it("ok", "T1", "P1")])
        compare(r.items.length, 1, data.name)
        compare(r.items[0].id, "ok")
        compare(r.dropped, 1)
    }

    function test_normalize_of_non_arrays_is_empty_data() {
        return [{ v: null }, { v: undefined }, { v: "x" }, { v: 3 }, { v: {} }, { v: true }]
    }
    function test_normalize_of_non_arrays_is_empty(data) {
        var r = PM.normalize(data.v)
        compare(r.items.length, 0)
        compare(r.dropped, 0)
    }

    function test_normalize_does_not_mutate_or_alias() {
        var src = [_it("a", "T1", "P1"), null]
        var before = JSON.stringify(src)
        var r = PM.normalize(src)
        compare(JSON.stringify(src), before)
        r.items.push("x")
        compare(src.length, 2)
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

    function test_forTenant_tenant_ids_are_case_and_whitespace_exact() {
        var list = [_it("a", "Tenant1", "P1")]
        compare(PM.forTenant(list, "tenant1").length, 0)
        compare(PM.forTenant(list, "Tenant1 ").length, 0)
        compare(PM.forTenant(list, "Tenant1").length, 1)
    }

    function test_forTenant_tolerates_non_array_and_null_entries() {
        compare(PM.forTenant(null, "T1").length, 0)
        compare(PM.forTenant("x", "T1").length, 0)
        compare(PM.forTenant([null, undefined, _it("a", "T1", "P1")], "T1").length, 1)
    }

    function test_has_is_per_tenant_the_cross_tenant_hide_bug() {
        // Product ids repeat across tenants ("P-001"): tenant B must not see A's pending mint.
        var list = [_it("a", "A", "P-001")]
        compare(PM.has(list, "A", "P-001"), true)
        compare(PM.has(list, "B", "P-001"), false)
        compare(PM.has(list, "", "P-001"), false)
        compare(PM.has(list, "A", "P-002"), false)
    }

    // ── due ─────────────────────────────────────────────────────────────────

    function test_due_is_the_tenants_items_minus_those_in_flight() {
        var list = [_it("a", "T1", "P1"), _it("b", "T1", "P2"), _it("c", "T2", "P3")]
        var d = PM.due(list, "T1", { a: true })
        compare(d.length, 1)
        compare(d[0].id, "b")
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
        compare(PM.due(list, "T1", { a: true }).length, 0)
    }

    // ── sameTenant ──────────────────────────────────────────────────────────

    function test_sameTenant_data() {
        return [
            { a: "T1", b: "T1", want: true },
            { a: "T1", b: "T2", want: false },
            { a: "T1", b: "", want: false },
            { a: "", b: "", want: false },
            { a: "", b: "T1", want: false },
            { a: undefined, b: undefined, want: false },
            { a: null, b: null, want: false },
            { a: 1, b: 1, want: false },
            { a: "t1", b: "T1", want: false }
        ]
    }
    function test_sameTenant(data) {
        compare(PM.sameTenant(data.a, data.b), data.want)
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
        compare(PM.without(null, "a").length, 0)
        compare(PM.without("x", "a").length, 0)
        compare(PM.without([null, _it("a", "T1", "P1")], "a").length, 1)
    }

    // ── the bug, end to end: queue under A, sign in as B, sign back in as A ──

    // A tiny driver that composes the helper the way StockBatchStore does.
    function _driver() {
        return {
            list: [], inFlight: ({}), tenant: "", written: [], writtenUnder: [], _n: 0,
            queue: function(product, tenant) {
                if (!tenant) return
                this.list = this.list.concat([_it("m" + (this._n++), tenant, product)])
            },
            retryPass: function(mintAnswersFor) {
                // mintAnswersFor(item) -> tenant that is signed in when the mint ANSWERS
                var self = this
                PM.due(this.list, this.tenant, this.inFlight).forEach(function(it) {
                    self.inFlight[it.id] = true
                    var answeredUnder = mintAnswersFor ? mintAnswersFor(it) : self.tenant
                    delete self.inFlight[it.id]
                    if (!PM.sameTenant(it.tenantId, answeredUnder)) return
                    self.written.push(it.tenantId + ":" + it.productId)
                    self.writtenUnder.push(answeredUnder)
                    self.list = PM.without(self.list, it.id)
                })
            }
        }
    }

    function test_scenario_item_queued_under_A_is_never_written_under_B() {
        var d = _driver()
        d.tenant = "A"; d.queue("P-001", "A")
        d.tenant = ""            // signed out: queue is kept
        compare(d.list.length, 1)
        d.tenant = "B"           // another account signs in, device comes online
        d.retryPass()
        compare(d.written.length, 0)
        compare(PM.has(d.list, "B", "P-001"), false)
        compare(PM.has(d.list, "A", "P-001"), true)
        d.tenant = "A"           // A signs back in: now it is replayed, once
        d.retryPass()
        compare(JSON.stringify(d.written), JSON.stringify(["A:P-001"]))
        compare(d.list.length, 0)
    }

    function test_scenario_no_tenant_yet_retries_nothing_then_the_tenant_ready_pass_does() {
        var d = _driver()
        d.queue("P1", "A")
        d.tenant = ""
        d.retryPass()
        compare(d.written.length, 0)
        d.tenant = "A"
        d.retryPass()
        compare(d.written.length, 1)
    }

    function test_scenario_account_switch_while_the_mint_is_out_keeps_the_item() {
        var d = _driver()
        d.tenant = "A"; d.queue("P1", "A")
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
        d.tenant = "B"; d.retryPass()
        compare(JSON.stringify(d.written), JSON.stringify(["B:P-001"]))
        compare(PM.has(d.list, "A", "P-001"), true)
        compare(PM.has(d.list, "B", "P-001"), false)
    }

    function test_scenario_failure_with_no_tenant_is_not_queued() {
        var d = _driver()
        d.queue("P1", "")
        compare(d.list.length, 0)
    }

    // ── seeded monkey ───────────────────────────────────────────────────────

    function test_monkey_a_tenant_only_ever_writes_its_own_items() {
        var r = _rng(26102026)
        var tenants = ["A", "B", "C", ""]
        for (var round = 0; round < 200; ++round) {
            var d = _driver()
            var queuedBy = { A: 0, B: 0, C: 0 }
            for (var step = 0; step < 30; ++step) {
                var roll = r()
                var t = tenants[Math.floor(r() * tenants.length)]
                if (roll < 0.35) {
                    d.queue("P" + Math.floor(r() * 4), t)
                    if (t) queuedBy[t]++
                } else if (roll < 0.8) {
                    d.tenant = t
                    d.retryPass(r() < 0.3 ? function() { return tenants[Math.floor(r() * tenants.length)] } : undefined)
                } else {
                    d.tenant = t                       // sign in / out only
                }
            }
            var written = { A: 0, B: 0, C: 0 }
            d.written.forEach(function(w, idx) {
                written[w.split(":")[0]]++
                // THE invariant: a batch is only ever written while its own tenant is signed in
                compare(d.writtenUnder[idx], w.split(":")[0])
            })
            // never more writes than queued, per tenant, and what is left still belongs to someone
            for (var k in written) verify(written[k] <= queuedBy[k], "tenant " + k)
            compare(d.list.length + d.written.length, queuedBy.A + queuedBy.B + queuedBy.C)
            for (var i = 0; i < d.list.length; ++i) verify(d.list[i].tenantId.length > 0)
        }
    }
}
