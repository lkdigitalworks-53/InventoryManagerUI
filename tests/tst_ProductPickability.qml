import QtQuick
import QtTest
import "../qml/helper/ProductPickability.js" as PK
import "pickerFixtures.js" as FX

// DERIVED FILE, do not edit. Rebuilt from functions/test/pickerPickability.test.js by
// functions/test/testSupport/pickerTwin.js (node functions/test/testSupport/pickerTwin.js --write);
// functions/test/pickerDormancy.test.js (PAIR-01) fails if this file differs from that output.
// NOT RUN IN THIS SANDBOX (no Qt toolchain): CI's qmltestrunner is the signal. The same bodies run in Node.
// Plan: docs/superpowers/test-plans/2026-11-03-product-picker-v2-test-plan.md
TestCase {
    name: "ProductPickability"

    function eq(actual, expected) { compare(FX.canon(actual), FX.canon(expected)) }
    function ok(cond, msg) { verify(cond, msg) }
    function noThrow(fn) { try { fn() } catch (e) { fail("threw: " + e) } }

    function prod(id) { return { productId: id, name: "n" + id }; }
    function ctx(over) {
        var c = { availableFor: function() { return 5; } };
        for (var k in (over || {})) c[k] = over[k];
        return c;
    }
    function brief(r) { return { visibility: r.visibility, reason: r.reason, available: r.available, maxQty: r.maxQty }; }

    function test_PICK_01_a_product_with_stock_is_enabled() {
        eq(brief(PK.classify(prod("A"), ctx())), { visibility: "enabled", reason: "", available: 5, maxQty: 5 });
    }

    function test_PICK_02_zero_stock_is_disabled_as_out_of_stock() {
        eq(brief(PK.classify(prod("A"), ctx({ availableFor: () => 0 }))),
           { visibility: "disabled", reason: "out-of-stock", available: 0, maxQty: 0 });
    }

    function test_PICK_03_junk_stock_values_count_as_out_of_stock() {
        const junk = [-3, NaN, undefined, "7", Infinity];
        for (let i = 0; i < junk.length; ++i) {
            const v = junk[i];
            eq(brief(PK.classify(prod("A"), ctx({ availableFor: () => v }))),
               { visibility: "disabled", reason: "out-of-stock", available: 0, maxQty: 0 });
        }
    }

    function test_PICK_04_fractional_stock_is_floored() {
        eq(brief(PK.classify(prod("A"), ctx({ availableFor: () => 3.7 }))),
           { visibility: "enabled", reason: "", available: 3, maxQty: 3 });
    }

    function test_PICK_05_pending_mint_hides_the_product() {
        eq(brief(PK.classify(prod("A"), ctx({ hasPendingMint: () => true }))),
           { visibility: "hidden", reason: "pending-mint", available: 0, maxQty: 0 });
    }

    function test_PICK_06_a_queued_restock_hides_the_product() {
        const r = PK.classify(prod("A"), ctx({ hasQueuedRestock: () => true }));
        eq([r.visibility, r.reason], ["hidden", "queued-restock"]);
    }

    function test_PICK_07_a_pending_unsynced_edit_hides_the_product() {
        const r = PK.classify(prod("A"), ctx({ unsyncedState: () => "pending" }));
        eq([r.visibility, r.reason], ["hidden", "unsynced-edit"]);
    }

    function test_PICK_08_a_parked_edit_hides_it_other_states_do_not() {
        eq(PK.classify(prod("A"), ctx({ unsyncedState: () => "parked" })).reason, "unsynced-edit");
        const other = ["", "x", undefined];
        for (let i = 0; i < other.length; ++i) {
            const v = other[i];
            eq(PK.classify(prod("A"), ctx({ unsyncedState: () => v })).visibility, "enabled");
        }
    }

    function test_PICK_09_a_delete_in_flight_hides_the_product() {
        const r = PK.classify(prod("A"), ctx({ isDeleting: () => true }));
        eq([r.visibility, r.reason], ["hidden", "deleting"]);
    }

    function test_PICK_10_hide_reasons_have_a_fixed_precedence_and_beat_out_of_stock() {
        const all = { hasPendingMint: () => true, hasQueuedRestock: () => true, unsyncedState: () => "pending",
                      isDeleting: () => true, availableFor: () => 0 };
        eq(PK.classify(prod("A"), all).reason, "pending-mint");
        all.hasPendingMint = () => false;
        eq(PK.classify(prod("A"), all).reason, "queued-restock");
        all.hasQueuedRestock = () => false;
        eq(PK.classify(prod("A"), all).reason, "unsynced-edit");
        all.unsyncedState = () => "";
        eq(PK.classify(prod("A"), all).reason, "deleting");
        all.isDeleting = () => false;
        eq(PK.classify(prod("A"), all).reason, "out-of-stock");
    }

    function test_PICK_11_order_full_disables_a_new_product() {
        const r = PK.classify(prod("A"), ctx({ lineLimitReached: true }));
        eq([r.visibility, r.reason, r.maxQty], ["disabled", "order-full", 0]);
        eq(PK.classify(prod("A"), ctx({ lineLimitReached: 1 })).visibility, "enabled");
        eq(PK.classify(prod("A"), ctx({ lineLimitReached: "yes" })).visibility, "enabled");
    }

    function test_PICK_12_order_full_still_allows_a_product_already_on_the_order() {
        const r = PK.classify(prod("A"), ctx({ lineLimitReached: true, inOrderQty: () => 2 }));
        eq([r.visibility, r.inOrder], ["enabled", 2]);
    }

    function test_PICK_13_order_full_still_allows_a_product_already_in_the_draft() {
        const r = PK.classify(prod("A"), ctx({ lineLimitReached: true, inDraft: () => 3 }));
        eq([r.visibility, r.inDraft], ["enabled", 3]);
    }

    function test_PICK_14_out_of_stock_wins_over_order_full() {
        const r = PK.classify(prod("A"), ctx({ lineLimitReached: true, availableFor: () => 0 }));
        eq(r.reason, "out-of-stock");
    }

    function test_PICK_15_a_missing_hook_or_context_fails_closed() {
        eq(PK.classify(prod("A"), {}).reason, "out-of-stock");
        eq(PK.classify(prod("A"), undefined).reason, "out-of-stock");
        eq(PK.classify(prod("A"), null).reason, "out-of-stock");
        eq(PK.classify(prod("A"), {}).visibility, "disabled");
    }

    function test_PICK_16_a_throwing_hook_disables_the_row_as_unavailable() {
        const boom = () => { throw new Error("boom"); };
        const a = PK.classify(prod("A"), ctx({ availableFor: boom }));
        eq([a.visibility, a.reason, a.maxQty], ["disabled", "unavailable", 0]);
        const b = PK.classify(prod("A"), ctx({ hasPendingMint: boom }));
        eq([b.visibility, b.reason, b.maxQty], ["disabled", "unavailable", 0]);
    }

    function test_PICK_17_junk_order_and_draft_quantities_become_0() {
        const vals = [4, -1, "2", NaN];
        const want = [4, 0, 0, 0];
        for (let i = 0; i < vals.length; ++i) {
            const v = vals[i];
            const r = PK.classify(prod("A"), ctx({ inOrderQty: () => v, inDraft: () => v }));
            eq([r.inOrder, r.inDraft], [want[i], want[i]]);
        }
    }

    function test_PICK_18_a_product_that_is_not_a_product_is_unavailable_never_a_throw() {
        const junk = [null, undefined, 5, [], {}];
        for (let i = 0; i < junk.length; ++i) {
            const v = junk[i];
            noThrow(() => PK.classify(v, ctx()));
            eq([PK.classify(v, ctx()).visibility, PK.classify(v, ctx()).reason], ["disabled", "unavailable"]);
        }
    }

    function test_PICK_19_summarize_counts_hidden_products_and_keeps_the_rest() {
        const list = [prod("A"), prod("B"), prod("C"), prod("D"), prod("E")];
        const c = ctx({ hasPendingMint: (id) => id === "B", unsyncedState: (id) => (id === "D" ? "parked" : "") });
        const s = PK.summarize(list, c, {});
        eq([s.rows.length, s.hiddenCount], [3, 2]);
    }

    function test_PICK_20_summarize_keeps_the_input_order() {
        const list = [prod("C"), prod("A"), prod("B")];
        const s = PK.summarize(list, ctx({ hasPendingMint: (id) => id === "A" }), {});
        eq(s.rows.map((r) => r.product.productId), ["C", "B"]);
    }

    function test_PICK_21_instockonly_drops_only_out_of_stock_rows() {
        const list = [prod("OUT"), prod("FULL"), prod("BAD"), prod("OK"), prod("HID")];
        const c = {
            availableFor: (p) => {
                if (p.productId === "OUT") return 0;
                if (p.productId === "BAD") throw new Error("boom");
                return 5;
            },
            hasPendingMint: (id) => id === "HID",
            lineLimitReached: true,
            inOrderQty: (id) => (id === "OK" ? 1 : 0)
        };
        const s = PK.summarize(list, c, { inStockOnly: true });
        eq(s.rows.map((r) => r.reason), ["order-full", "unavailable", ""]);
        eq(s.hiddenCount, 1);
    }

    function test_PICK_22_summarize_of_a_non_array_is_empty() {
        const bad = [[], null, "x", undefined];
        for (let i = 0; i < bad.length; ++i) eq(PK.summarize(bad[i], ctx(), {}), { rows: [], hiddenCount: 0 });
    }

    function test_PICK_23_summarize_skips_junk_entries_without_counting_them() {
        const s = PK.summarize([null, 5, [], prod("A")], ctx(), {});
        eq([s.rows.length, s.hiddenCount], [1, 0]);
    }

    function test_PICK_24_inputs_are_never_changed() {
        const list = FX.freeze([prod("A"), prod("B")]);
        const c = FX.freeze({ availableFor: () => 5, lineLimitReached: false });
        noThrow(() => PK.summarize(list, c, { inStockOnly: true }));
        noThrow(() => PK.classify(list[0], c));
        eq(list.length, 2);
    }

    function test_PICK_25_seeded_monkey_400_rounds() {
        const rand = FX.rng(3);
        const outcomes = [true, false, "throw", "junk", 0, 5, -2, "parked", "pending", ""];
        const hook = () => {
            const o = outcomes[Math.floor(rand() * outcomes.length)];
            return () => { if (o === "throw") throw new Error("boom"); return o === "junk" ? { x: 1 } : o; };
        };
        for (let round = 0; round < 400; ++round) {
            const list = [];
            const n = Math.floor(rand() * 9);
            for (let i = 0; i < n; ++i) list.push(rand() < 0.1 ? null : prod("P" + i));
            const c = { availableFor: hook(), hasPendingMint: hook(), hasQueuedRestock: hook(), unsyncedState: hook(),
                        isDeleting: hook(), inOrderQty: hook(), inDraft: hook(), lineLimitReached: rand() < 0.3 };
            let s = { rows: [], hiddenCount: 0 };
            let t = { rows: [], hiddenCount: 0 };
            noThrow(() => { s = PK.summarize(list, c, {}); t = PK.summarize(list, c, { inStockOnly: true }); });
            const valid = list.filter((p) => !!p).length;
            eq(s.rows.length + s.hiddenCount, valid);
            ok(t.rows.length <= s.rows.length, "inStockOnly added rows");
            eq(t.hiddenCount, s.hiddenCount);
            for (let k = 0; k < s.rows.length; ++k) {
                const r = s.rows[k];
                ok(r.visibility !== "hidden", "hidden row in rows");
                if (r.visibility === "enabled") ok(r.maxQty >= 1, "enabled row without capacity");
                else eq(r.maxQty, 0);
            }
        }
    }
}
