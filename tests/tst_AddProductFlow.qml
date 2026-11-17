import QtQuick
import QtTest
import "../qml/helper/AddProductFlow.js" as AF
import "../qml/helper/AddProductPlan.js" as AP
import "../qml/helper/RestockFlow.js" as RF
import "../qml/helper/OperationKeys.js" as OK

// Headless tests for the pure add-product flow decisions (atomic-ops AP3a). Pure JS, no singletons.
// Design: docs/superpowers/specs/2026-11-16-ap3a-add-product-wire-design.md
// Test plan: docs/superpowers/test-plans/2026-11-16-ap3a-add-product-wire-test-plan.md
// The same cases run in Node against the REAL server code in functions/test/addProductFlow.test.js; this file is the
// qmltestrunner copy, so a QML-engine difference (number formatting, Date handling, string methods) cannot hide.
// NOT RUN IN THIS SANDBOX: no Qt/qmltestrunner toolchain here. CI is the oracle.
TestCase {
    name: "AddProductFlow"

    readonly property string key: "addProduct:1781000000000-abcdefabcdef"
    readonly property var suppliers: [{ supplierId: "SUP-009", name: "Acme Farms" }]

    function _args(over) {
        var base = { key: key, name: "Tomato", sku: "TO-1", category: "Veg", unit: "kg", size: "", description: "Red", price: 20, sellingPrice: 30,
                     taxable: true, taxPercent: 5, stock: 12, minStock: 2, unitCost: 18, party: "", suppliers: suppliers,
                     now: new Date("2026-06-15T12:00:00Z") }
        for (var k in over) base[k] = over[k]
        return base
    }
    function _make(over) { return AF.makeInput(_args(over)) }

    // ── newKey ────────────────────────────────────────────────────────────
    function test_newKey_is_an_add_key_and_deterministic_for_fixed_inputs() {
        var n = 0
        var zero = function() { return 0 }
        var k = AF.newKey(1700000000123, zero)
        compare(k, "addProduct:1700000000123-000000000000")
        verify(OK.isAddProductKey(k))
        verify(!OK.isRestockKey(k))
        compare(AF.newKey(1700000000123, zero), k)
        verify(AF.newKey(1700000000124, zero) !== k)
    }

    // ── defaults ──────────────────────────────────────────────────────────
    function test_defaults_match_the_old_addProduct() {
        var r = _make({ sellingPrice: undefined, unitCost: undefined, taxPercent: undefined, minStock: undefined, taxable: undefined })
        verify(r.ok)
        compare(r.input.sellingPrice, 20)
        compare(r.input.unitCost, 20)
        compare(r.input.taxPercent, 0)
        compare(r.input.minStock, 0)
        compare(r.input.taxable, false)
        compare(_make({ sellingPrice: null }).input.sellingPrice, 20)
        compare(_make({ sellingPrice: 0 }).input.sellingPrice, 0)
        compare(_make({ unitCost: 0 }).input.unitCost, 0)
        compare(_make({ unitCost: NaN }).input.unitCost, 20)
        compare(_make({ taxPercent: NaN }).input.taxPercent, 0)
        compare(_make({ taxable: 1 }).input.taxable, true)
    }
    function test_a_price_that_is_not_a_number_gives_cost_zero_and_the_planner_refuses_the_price() {
        var r = _make({ price: undefined, unitCost: undefined, sellingPrice: undefined })
        verify(r.ok)
        compare(r.input.unitCost, 0)
        compare(AP.build(r.input).reason, "bad-price")
    }
    function test_values_the_planner_must_judge_pass_through_unchanged() {
        var r = _make({ stock: -1, price: -5, taxPercent: 101 })
        verify(r.ok)
        compare(r.input.stock, -1)
        compare(r.input.price, -5)
        compare(r.input.taxPercent, 101)
    }

    // ── time ──────────────────────────────────────────────────────────────
    function test_one_Date_gives_the_instant_and_the_local_day() {
        var d = new Date(2026, 5, 15, 23, 59, 59, 900)
        var r = _make({ now: d })
        compare(r.input.now, d.toISOString())
        compare(r.input.date, "2026-06-15")
        compare(r.input.date, RF.localDate(d))
    }
    function test_a_missing_or_wrong_time_is_bad_time() {
        var bad = [undefined, null, "2026-06-15T12:00:00Z", 1781000000000, new Date("nope"), {}]
        for (var i = 0; i < bad.length; ++i) {
            var r = _make({ now: bad[i] })
            compare(r.ok, false, String(bad[i]))
            compare(r.reason, "bad-time")
        }
        compare(AF.makeInput(undefined).reason, "bad-time")
        compare(AF.makeInput(null).reason, "bad-time")
    }

    // ── supplier ──────────────────────────────────────────────────────────
    function test_supplier_none_id_known_name_and_new_name() {
        var none = ["", null, undefined]
        for (var i = 0; i < none.length; ++i) compare(_make({ party: none[i] }).input.supplier, null)
        compare(JSON.stringify(_make({ party: "SUP-009" }).input.supplier), JSON.stringify({ id: "SUP-009" }))
        compare(JSON.stringify(_make({ party: "SUP-404" }).input.supplier), JSON.stringify({ id: "SUP-404" }))
        compare(JSON.stringify(_make({ party: " acme farms " }).input.supplier), JSON.stringify({ id: "SUP-009" }))
        compare(JSON.stringify(_make({ party: "Newco" }).input.supplier), JSON.stringify({ newName: "Newco" }))
        compare(JSON.stringify(_make({ party: { id: "SUP-009" } }).input.supplier), JSON.stringify({ id: "SUP-009" }))
        compare(JSON.stringify(_make({ party: { newName: "SUP-looking name" } }).input.supplier), JSON.stringify({ newName: "SUP-looking name" }))
    }
    function test_bad_suppliers_are_refused_with_RestockFlows_reasons() {
        compare(_make({ party: "   " }).reason, "bad-supplier")
        compare(_make({ party: { newName: "   " } }).reason, "bad-supplier")
        compare(_make({ party: {} }).reason, "bad-supplier")
        compare(_make({ party: new Array(RF.MAX_SUPPLIER_NAME + 2).join("x") }).reason, "supplier-too-long")
        verify(_make({ party: new Array(RF.MAX_SUPPLIER_NAME + 1).join("x") }).ok)
        verify(_make({ party: "x", suppliers: undefined }).ok)
    }

    // ── the flow builds what the planner accepts ──────────────────────────
    function test_every_supplier_and_stock_combination_builds_and_plans() {
        var parties = ["", "SUP-009", "Newco"]
        var stocks = [0, 1, 12]
        for (var i = 0; i < parties.length; ++i) {
            for (var j = 0; j < stocks.length; ++j) {
                var made = AF.makeInput(_args({ party: parties[i], stock: stocks[j] }))
                verify(made.ok)
                var plan = AP.build(made.input)
                verify(plan.ok, parties[i] + "/" + stocks[j])
                compare(plan.opType, "addProduct")
            }
        }
    }
    function test_the_old_call_shapes_still_build() {
        var dialogLike = AF.makeInput(_args({ party: "SUP-009", sellingPrice: 120, unitCost: 100, price: 100, size: "M", description: "" }))
        verify(AP.build(dialogLike.input).ok)
        var routeLike = AF.makeInput(_args({ party: undefined, unitCost: undefined, size: undefined, sellingPrice: undefined, minStock: 0 }))
        verify(AP.build(routeLike.input).ok)
    }

    // ── refusal texts ─────────────────────────────────────────────────────
    function test_refusalText_per_reason() {
        var fixable = ["bad-name", "bad-price", "bad-tax", "bad-stock", "bad-cost", "bad-supplier", "supplier-too-long"]
        var seen = {}
        for (var i = 0; i < fixable.length; ++i) {
            var t = AF.refusalText(fixable[i])
            verify(t.length > 10, fixable[i])
            verify(t.indexOf("report this") < 0, fixable[i] + " is something the person can fix")
            verify(t.indexOf("{{") < 0 && t.indexOf("undefined") < 0 && t.indexOf("null") < 0, fixable[i])
            verify(!seen[t], "no two reasons share a text: " + fixable[i])
            seen[t] = true
        }
        var bugs = ["bad-key", "bad-time", "too-large", "something-new", undefined]
        for (var k = 0; k < bugs.length; ++k) verify(AF.refusalText(bugs[k]).indexOf("Please report this") >= 0, String(bugs[k]))
        verify(AF.refusalText("something-new").indexOf("something-new") >= 0)
    }

    // ── classify and fixed texts ──────────────────────────────────────────
    function test_classify_is_RestockFlows() {
        var shapes = [{ ok: true, results: [] }, { ok: true, queued: true }, { ok: false, pending: true }, { ok: false, error: "conflict" },
                      null, undefined, "x", 7, {}]
        for (var i = 0; i < shapes.length; ++i) compare(AF.classify(shapes[i]), RF.classify(shapes[i]))
        compare(AF.classify({ ok: true, results: [] }), "applied")
        compare(AF.classify({ ok: false, pending: true }), "queued")
        compare(AF.classify({ ok: false, error: "x" }), "rejected")
    }
    function test_fixed_texts_are_distinct_and_the_unconfirmed_text_offers_no_plain_retry() {
        var texts = [AF.OFFLINE_TEXT, AF.QUEUED_TEXT, AF.UNCONFIRMED_TEXT, AF.DISCARDED_TEXT]
        for (var i = 0; i < texts.length; ++i) {
            verify(texts[i].length > 20)
            for (var j = i + 1; j < texts.length; ++j) verify(texts[i] !== texts[j])
        }
        verify(!/nothing was added|try again/i.test(AF.UNCONFIRMED_TEXT))
        verify(AF.UNCONFIRMED_TEXT.indexOf("Check the product list") >= 0)
        verify(AF.OFFLINE_TEXT.indexOf("needs an internet connection") >= 0)
        verify(AF.supplierPendingText('A "b"').indexOf('A "b"') >= 0)
    }

    // ── the supplier clash covers an add ──────────────────────────────────
    function _addItem(name) {
        return { opType: "addProduct", ops: [{ kind: "mint", counter: "product", bind: "prd" },
                 { kind: "mutation", entity: "supplier", action: "create", after: { name: name } }] }
    }
    function test_clash_sees_a_queued_add_and_a_queued_restock_and_ignores_the_rest() {
        verify(RF.queuedNewSupplierClash("acme", [_addItem("Acme")]))
        verify(RF.queuedNewSupplierClash(" ACME ", [{ opType: "restock", ops: _addItem("Acme").ops }]))
        verify(!RF.queuedNewSupplierClash("acme", [_addItem("Other")]))
        verify(!RF.queuedNewSupplierClash("acme", [{ opType: "completeOrder", ops: _addItem("Acme").ops }]))
        verify(!RF.queuedNewSupplierClash("acme", [{ opType: "addProduct", ops: [{ kind: "mutation", entity: "inventory", action: "create", after: { name: "Acme" } }] }]))
        verify(!RF.queuedNewSupplierClash("acme", [{ opType: "addProduct", ops: "junk" }, null, 5]))
        verify(!RF.queuedNewSupplierClash("", [_addItem("")]))
    }
    function test_clash_on_a_real_planned_add() {
        var plan = AP.build(AF.makeInput(_args({ party: "Newco" })).input)
        verify(RF.queuedNewSupplierClash("newco", [{ opType: plan.opType, ops: plan.ops }]))
        var none = AP.build(AF.makeInput(_args({ party: "SUP-009" })).input)
        verify(!RF.queuedNewSupplierClash("acme farms", [{ opType: none.opType, ops: none.ops }]))
    }

    // ── monkey (seeded) ───────────────────────────────────────────────────
    function test_seeded_monkey_never_throws() {
        var seed = 17
        var rnd = function(n) { seed = (seed * 1103515245 + 12345) & 0x7fffffff; return (seed >>> 8) % n }
        var pick = function(a) { return a[rnd(a.length)] }
        var mostly = function(good, hostile) { return rnd(10) < 8 ? pick(good) : pick(hostile) }
        var num = function() { return mostly([0, 1, 2.5, 12, 100], [1e9, 1e308, -1, NaN, Infinity, undefined, null, "5", "x"]) }
        var text = function() { return mostly(["Tomato", "TO-1", "", "é"], [" ", "{{prd}}", "}}{{", "a".repeat(200), undefined, null, 7]) }
        var accepted = 0, refused = 0
        for (var i = 0; i < 600; ++i) {
            var a = _args({ name: text(), sku: text(), category: text(), price: num(), sellingPrice: num(), stock: num(), minStock: num(),
                            unitCost: num(), taxPercent: mostly([0, 5, 100], [101, -1, NaN, "x"]),
                            party: mostly(["", "SUP-009", "Newco"], [{ newName: "" }, 7, {}, undefined]) })
            var made = AF.makeInput(a)
            var plan = made.ok ? AP.build(made.input) : made
            compare(typeof plan.ok, "boolean")
            if (plan.ok) accepted++
            else { refused++; verify(typeof AF.refusalText(plan.reason) === "string") }
        }
        verify(accepted > 50 && refused > 50, "both sides reached: " + accepted + "/" + refused)
    }

    // ── doneText ──────────────────────────────────────────────────────────
    function test_doneText_every_status_with_and_without_a_skipped_photo() {
        compare(AF.doneText("applied", false), "Product added")
        compare(AF.doneText("applied", true), "Product added. Its photo could not be added. Add it from the product page")
        compare(AF.doneText("queued", false), AF.QUEUED_TEXT)
        compare(AF.doneText("queued", true), AF.QUEUED_TEXT + ". Add its photo from the product page")
        compare(AF.doneText("unconfirmed", false), AF.UNCONFIRMED_TEXT)
        compare(AF.doneText("unconfirmed", true), AF.UNCONFIRMED_TEXT + ". Its photo was not attached")
    }
    function test_doneText_unknown_status_reads_as_applied_and_only_strict_true_skips() {
        var statuses = [undefined, null, "", "x", 7]
        for (var i = 0; i < statuses.length; ++i) compare(AF.doneText(statuses[i], false), "Product added")
        var flags = [undefined, null, 1, "true", 0]
        for (var j = 0; j < flags.length; ++j) {
            compare(AF.doneText("applied", flags[j]), "Product added")
            compare(AF.doneText("queued", flags[j]), AF.QUEUED_TEXT)
        }
    }
}
