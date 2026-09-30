import QtQuick
import QtTest
import "../qml/helper/DescribeItem.js" as DI

// Headless tests for the stuck-writes dialog's row labels. Pure JS, no singletons.
// Design: docs/superpowers/specs/2026-09-29-stuck-writes-dialog-retry-now-design.md
TestCase {
    name: "DescribeItem"

    function _rng(seed) {
        var s = seed
        return function() {
            s = (s * 1664525 + 1013904223) % 4294967296
            return s / 4294967296
        }
    }

    // ── single mutations: every entity x action ─────────────────────────────

    function test_title_for_every_entity_and_action_data() {
        return [
            { entity: "inventory", action: "create", title: "Added product" },
            { entity: "inventory", action: "update", title: "Edited product" },
            { entity: "inventory", action: "delete", title: "Deleted product" },
            { entity: "stock_batch", action: "create", title: "Added stock batch" },
            { entity: "stock_batch", action: "update", title: "Edited stock batch" },
            { entity: "stock_batch", action: "delete", title: "Deleted stock batch" },
            { entity: "order", action: "create", title: "Added order" },
            { entity: "order", action: "update", title: "Edited order" },
            { entity: "order", action: "delete", title: "Deleted order" },
            { entity: "staff", action: "create", title: "Added team member" },
            { entity: "staff", action: "update", title: "Edited team member" },
            { entity: "staff", action: "delete", title: "Deleted team member" },
            { entity: "removed_staff", action: "create", title: "Added team member record" },
            { entity: "removed_staff", action: "update", title: "Edited team member record" },
            { entity: "removed_staff", action: "delete", title: "Deleted team member record" },
            { entity: "supplier", action: "create", title: "Added supplier" },
            { entity: "supplier", action: "update", title: "Edited supplier" },
            { entity: "supplier", action: "delete", title: "Deleted supplier" },
            { entity: "transaction", action: "create", title: "Added transaction" },
            { entity: "transaction", action: "update", title: "Edited transaction" },
            { entity: "transaction", action: "delete", title: "Deleted transaction" }
        ]
    }
    function test_title_for_every_entity_and_action(d) {
        compare(DI.describe({ entity: d.entity, action: d.action, entityId: "x1" }).title, d.title)
    }

    // ── detail: name, then id ───────────────────────────────────────────────

    function test_detail_prefers_name_from_after() {
        compare(DI.describe({ entity: "inventory", action: "update", entityId: "p1",
                              before: { name: "Old" }, after: { name: "Sugar 1kg" } }).detail, "Sugar 1kg")
    }

    function test_detail_uses_before_when_after_is_null_on_delete() {
        compare(DI.describe({ entity: "inventory", action: "delete", entityId: "p1",
                              before: { name: "Sugar 1kg" }, after: null }).detail, "Sugar 1kg")
    }

    function test_detail_falls_back_to_productName_then_customer() {
        compare(DI.describe({ entity: "transaction", action: "create", entityId: "t1",
                              after: { productName: "Rice" } }).detail, "Rice")
        compare(DI.describe({ entity: "order", action: "update", entityId: "o1",
                              after: { customer: "Asha" } }).detail, "Asha")
    }

    function test_name_wins_over_productName_and_customer() {
        compare(DI.describe({ entity: "order", action: "update", entityId: "o1",
                              after: { name: "N", productName: "P", customer: "C" } }).detail, "N")
    }

    function test_detail_falls_back_to_entityId_without_a_name() {
        compare(DI.describe({ entity: "order", action: "update", entityId: "o7", after: { status: "pending" } }).detail, "o7")
        compare(DI.describe({ entity: "order", action: "update", entityId: "o7" }).detail, "o7")
    }

    function test_blank_or_non_text_names_are_ignored() {
        compare(DI.describe({ entity: "inventory", action: "update", entityId: "p9", after: { name: "   " } }).detail, "p9")
        compare(DI.describe({ entity: "inventory", action: "update", entityId: "p9", after: { name: { x: 1 } } }).detail, "p9")
        compare(DI.describe({ entity: "inventory", action: "update", entityId: "p9", after: { name: 42 } }).detail, "42")
    }

    function test_detail_is_trimmed() {
        compare(DI.describe({ entity: "supplier", action: "update", entityId: "s1", after: { name: "  Acme  " } }).detail, "Acme")
    }

    function test_numeric_entityId_is_stringified() {
        compare(DI.describe({ entity: "order", action: "update", entityId: 12 }).detail, "12")
    }

    // ── unknown entity / action ─────────────────────────────────────────────

    function test_unknown_entity_and_action_use_neutral_words() {
        var d = DI.describe({ entity: "warp_core", action: "explode", entityId: "w1" })
        compare(d.title, "Changed record")
        compare(d.detail, "w1")
    }

    function test_prototype_keys_are_not_mistaken_for_entities_or_actions() {
        var d = DI.describe({ entity: "constructor", action: "toString", entityId: "z" })
        compare(d.title, "Changed record")
        d = DI.describe({ entity: "__proto__", action: "hasOwnProperty", entityId: "z" })
        compare(d.title, "Changed record")
    }

    // ── batch ────────────────────────────────────────────────────────────────

    function test_batch_title_counts_and_pluralises() {
        var mk = function(n) { var a = []; for (var i = 0; i < n; ++i) a.push({ entityId: "e" + i }); return a }
        compare(DI.describe({ entity: "inventory", items: mk(40) }).title, "40 products changed")
        compare(DI.describe({ entity: "stock_batch", items: mk(3) }).title, "3 stock batches changed")
        compare(DI.describe({ entity: "inventory", items: mk(1) }).title, "1 product change")
        compare(DI.describe({ entity: "inventory", items: mk(0) }).title, "0 products changed")
        compare(DI.describe({ entity: "inventory", items: mk(2) }).detail, "")
    }

    function test_batch_of_unknown_entity_says_records() {
        compare(DI.describe({ entity: "??", items: [{}, {}] }).title, "2 records changed")
    }

    // ── delta ────────────────────────────────────────────────────────────────

    function test_delta_is_a_stock_change_with_the_record_id() {
        var d = DI.describe({ entity: "inventory", entityId: "p5", deltas: { stock: -2 } })
        compare(d.title, "Stock change")
        compare(d.detail, "p5")
    }

    // ── operation ────────────────────────────────────────────────────────────

    function test_completeOrder_operation_is_labelled_with_the_first_entity_id() {
        var d = DI.describe({ opType: "completeOrder", ops: [{ entity: "order", entityId: "o9" }, { entity: "inventory", entityId: "p1" }] })
        compare(d.title, "Order completion")
        compare(d.detail, "o9")
    }

    function test_unknown_operation_and_empty_ops_do_not_throw() {
        compare(DI.describe({ opType: "mystery", ops: [{ entityId: "a" }] }).title, "Multi-step change")
        var d = DI.describe({ opType: "completeOrder", ops: [] })
        compare(d.title, "Order completion")
        compare(d.detail, "")
        compare(DI.describe({ ops: [null] }).detail, "")
    }

    function test_operation_wins_over_other_shapes() {
        compare(DI.describe({ ops: [], items: [{}], deltas: {}, entity: "order", action: "update" }).title, "Multi-step change")
    }

    // ── malformed input ──────────────────────────────────────────────────────

    function test_malformed_input_returns_a_placeholder_and_never_throws() {
        var bad = [undefined, null, "str", 5, true, [], function() {}]
        for (var i = 0; i < bad.length; ++i) {
            var d = DI.describe(bad[i])
            verify(typeof d.title === "string" && d.title.length > 0, "case " + i)
            compare(typeof d.detail, "string")
        }
        compare(DI.describe(null).title, "Pending change")
    }

    function test_empty_object_is_a_generic_change() {
        var d = DI.describe({})
        compare(d.title, "Changed record")
        compare(d.detail, "")
    }

    // ── monkey ───────────────────────────────────────────────────────────────

    function test_monkey_random_shapes_always_give_a_non_empty_title_and_string_detail() {
        var r = _rng(20260929)
        var junk = [undefined, null, "", "x", "inventory", "order", "update", "delete", 0, 7, {}, [], { name: "n" }, [{}], [null]]
        var pick = function() { return junk[Math.floor(r() * junk.length)] }
        for (var i = 0; i < 500; ++i) {
            var item = { entity: pick(), entityId: pick(), action: pick(), before: pick(), after: pick(),
                         items: pick(), deltas: pick(), ops: pick(), opType: pick() }
            var d = DI.describe(item)
            verify(typeof d.title === "string" && d.title.length > 0, "iteration " + i)
            verify(typeof d.detail === "string", "iteration " + i)
        }
    }
}
