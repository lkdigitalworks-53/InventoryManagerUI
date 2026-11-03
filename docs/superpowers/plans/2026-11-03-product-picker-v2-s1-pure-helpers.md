# Product Picker v2, Slice S1: Pure Helpers Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add three pure, fully tested helpers (`ProductSearch.js`, `ProductPickability.js`, `PickerDraft.js`) that decide search results, whether a product can be added, and what a draft commit does. Nothing calls them yet (dormant), so the app behaves exactly as before.

**Architecture:** Each helper is a `.pragma library` file with no Felgo or singleton dependency (Skill 83). Each is tested twice with the same case IDs: in Node against the REAL file text through `functions/test/testSupport/qmlHelpers.js` (run in the sandbox), and in the QML engine through `tests/tst_*.qml` (CI only, because the sandbox has no Qt). The dialogs will inject their own stock formulas and store lookups as plain functions (S3 and S4), which is what keeps the helpers pure.

**Tech Stack:** QML `.pragma library` JavaScript in the style of `qml/helper/StaffPicker.js` (ES5-style `var` and function declarations), Node `node:test` with `node:assert/strict`, QtTest `TestCase`.

## Global Constraints

- Design: `docs/superpowers/specs/2026-11-03-product-picker-v2-design.md` (approved). Test plan: `docs/superpowers/test-plans/2026-11-03-product-picker-v2-test-plan.md`.
- Branch off `main`, name `feat/<date>-picker-s1-pure-helpers`. Never commit to `main`. Do not touch `origin/feature/product-picker-search`.
- No build or run of the app. No Qt tools in the sandbox: QML tests are written and left to CI. Node tests ARE run here.
- Commit message text contains `lkdwtaher@gmail.com` and ends with the trailers `Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>` and `Claude-Session: <session url>`. Author identity `Taher <lkdwtaher@gmail.com>`. Push with `git -c http.extraHeader="AUTHORIZATION: basic <base64 of x-access-token:PAT>"`, never put the PAT in a remote URL or `.git/config`; after a push `grep -c ghp_ .git/config` must print 0.
- Whole units only. `MAX_LINES = 60`, `MAX_DIGITS = 6`, `MAX_QUERY = 200`.
- Hidden reasons: `pending-mint`, `queued-restock`, `unsynced-edit`, `deleting`. Disabled reasons: `out-of-stock`, `order-full`, `unavailable`.
- Test counts are recounted from the files with `grep -c "function test_"` (Skill 49), never carried forward.
- Documents are normal prose; chat may stay terse.

## File Structure

| File | Responsibility |
|---|---|
| `qml/helper/ProductSearch.js` (create) | Tokenize a query, filter and rank products. |
| `qml/helper/ProductPickability.js` (create) | Per-row `visibility` / `reason` / `maxQty`, and list summary with `hiddenCount`. |
| `qml/helper/PickerDraft.js` (create) | The draft, quantity parsing, totals, commit plan, line limit, reconcile. |
| `functions/test/pickerSearch.test.js` (create) | Node cases `SRCH-01..27`. |
| `functions/test/pickerPickability.test.js` (create) | Node cases `PICK-01..25`. |
| `functions/test/pickerDraft.test.js` (create) | Node cases `DRFT-01..30`, including the `MAX_LINES` drift guard. |
| `functions/test/pickerDormancy.test.js` (create) | `DORM-01..03`: nothing calls the helpers; pragma-library shape. |
| `tests/tst_ProductSearch.qml`, `tests/tst_ProductPickability.qml`, `tests/tst_PickerDraft.qml` (create) | The same cases in the QML engine (CI only). |

Case IDs are the contract: each row in the tables below is exactly one test, named `test_<ID>_...` in QML and `<ID> ...` in Node.

---

### Task 1: ProductSearch

**Files:**
- Create: `qml/helper/ProductSearch.js`
- Test: `functions/test/pickerSearch.test.js`, `tests/tst_ProductSearch.qml`

**Interfaces:**
- Produces: `tokenize(query) -> string[]`; `filter(products, query, opts) -> product[]` where `opts = { category: string }` (`""` or `"All"` means no category filter). Returns the same product objects, never copies. Never throws.

- [ ] **Step 1: Write the failing test file (Node), pattern first**

```js
"use strict";
const test = require("node:test");
const assert = require("node:assert/strict");
const { load, plain } = require("./testSupport/qmlHelpers");
const PS = load("ProductSearch.js");

const P = (productId, name, sku, category) => ({ productId, name, sku, category });
const CATALOG = [
    P("PRD-001", "Cherry Tomato", "TOM-CH", "Vegetables"),
    P("PRD-002", "Tomato", "TOM-01", "Vegetables"),
    P("PRD-003", "Matcha", "MAT-01", "Tea"),
];
const ids = (list) => list.map((p) => p.productId);

test("SRCH-01 empty query returns all in catalog order", () => {
    assert.deepEqual(ids(PS.filter(CATALOG, "")), ["PRD-001", "PRD-002", "PRD-003"]);
});
```

- [ ] **Step 2: Add the remaining rows as tests, then run and see them fail**

Run: `cd functions && node --test test/pickerSearch.test.js`
Expected: FAIL (`ProductSearch.js` does not exist).

| ID | Input | Expected |
|---|---|---|
| SRCH-01 | query `""` | all three, catalog order |
| SRCH-02 | query `"   "` | same as SRCH-01 |
| SRCH-03 | query `null`, `undefined` | same as SRCH-01 |
| SRCH-04 | `"TOMATO"`, `"tomato"` | `PRD-002`, `PRD-001` (both match, case-insensitive) |
| SRCH-05 | `"prd-003"` | `["PRD-003"]` |
| SRCH-06 | `"mat-01"` | `["PRD-003"]` |
| SRCH-07 | `"tea"` | `["PRD-003"]` (category match) |
| SRCH-08 | `"cherry veg"` | `["PRD-001"]` (every word must match, words may match different fields) |
| SRCH-09 | `"cherry banana"` | `[]` |
| SRCH-10 | products `P("A","prd-1 special")`, `P("prd-1","Other")`, query `"prd-1"` | `["prd-1","A"]` (exact ID above name match) |
| SRCH-11 | skus `ab` and `abc`, query `"ab"` | the `ab` product first |
| SRCH-12 | query `"mat"` on `Matcha` (word prefix) and `Tomato` (substring `mat`) | `Matcha` first |
| SRCH-13 | two products same score, names `"b"` and `"a"`; two with the same name | name ascending, then catalog order |
| SRCH-14 | queries `".*"`, `"("`, `"["`, `"\\"` over a catalog with a product named `"a.b(c"` | never throws; `".*"` matches nothing; `"("` matches only `"a.b(c"` |
| SRCH-15 | Devanagari name `"टमाटर"`, query `"टमा"` | that product |
| SRCH-16 | name `"Café"` stored precomposed (`"Café"`), query typed decomposed (`"café"`), and the reverse | both find it |
| SRCH-17 | products with no `sku`, `category: null`, only `productId` and `name` | no throw; found by the fields they do have |
| SRCH-18 | numeric `productId: 1001`, query `"100"` | found |
| SRCH-19 | products array holding `null`, `undefined`, `5`, `"x"`, `[]` plus valid ones | invalid skipped, valid returned |
| SRCH-20 | `{ category: "Tea" }`; `{ category: "All" }`; `{ category: "" }`; `{}`; `undefined` | Tea only; then the last four return all |
| SRCH-21 | `"tomato"` with `{ category: "Vegetables" }` | the two tomatoes; with `{ category: "Tea" }` returns `[]` |
| SRCH-22 | query of 10,000 characters of `"a"` | `[]`, no throw, under 50 ms |
| SRCH-23 | products `null`, `{}`, `"abc"`, `undefined` | `[]` |
| SRCH-24 | deep-freeze the input array and its products, run any query | no throw, input unchanged |
| SRCH-25 | two products with the same name | both returned, catalog order |
| SRCH-26 | the same call twice | deepEqual results |
| SRCH-27 | seeded monkey, 400 rounds (LCG seed 7): random products (random missing fields, numbers, mixed case, unicode) and random queries | never throws; result is a subset of the input with no duplicates; every returned product matches every token |

- [ ] **Step 3: Write the minimal implementation**

```js
.pragma library

// Pure search over the product catalog for the order picker (design 2026-11-03). No QML or singleton
// deps, so it is unit-testable headless (functions/test/pickerSearch.test.js, tests/tst_ProductSearch.qml).

var MAX_QUERY = 200   // nobody types more; also bounds the work

function _text(v) {
    var s = (v === undefined || v === null) ? "" : String(v)
    if (typeof s.normalize === "function") s = s.normalize("NFC")
    return s.toLowerCase()
}

// "  Red  Tomato " -> ["red", "tomato"]
function tokenize(query) {
    var parts = _text(query).substring(0, MAX_QUERY).split(/\s+/)
    var out = []
    for (var i = 0; i < parts.length; ++i)
        if (parts[i].length > 0) out.push(parts[i])
    return out
}

function _fields(p) {
    return { id: _text(p.productId), sku: _text(p.sku), name: _text(p.name), category: _text(p.category) }
}

// Best score of one token against one product, or -1 when it appears nowhere.
function _tokenScore(f, t) {
    if (f.id === t || f.sku === t) return 100
    if (f.id.indexOf(t) === 0 || f.sku.indexOf(t) === 0) return 60
    if ((" " + f.name).indexOf(" " + t) >= 0) return 40            // a word of the name starts with t
    if (f.name.indexOf(t) >= 0 || f.category.indexOf(t) >= 0) return 10
    if (f.id.indexOf(t) >= 0 || f.sku.indexOf(t) >= 0) return 5
    return -1
}

// products: catalog array. opts: { category } ("" or "All" = every category).
// Empty query keeps catalog order; otherwise best score first, then name, then catalog order.
function filter(products, query, opts) {
    if (!Array.isArray(products)) return []
    var category = (opts && typeof opts.category === "string") ? opts.category : ""
    if (category === "All") category = ""
    var tokens = tokenize(query)
    var hits = []
    for (var i = 0; i < products.length; ++i) {
        var p = products[i]
        if (!p || typeof p !== "object") continue
        if (category !== "" && _text(p.category) !== _text(category)) continue
        var score = 0
        if (tokens.length > 0) {
            var f = _fields(p)
            for (var k = 0; k < tokens.length; ++k) {
                var s = _tokenScore(f, tokens[k])
                if (s < 0) { score = -1; break }
                score += s
            }
            if (score < 0) continue
        }
        hits.push({ p: p, score: score, name: _text(p.name), at: i })
    }
    if (tokens.length > 0) {
        hits.sort(function(a, b) {
            if (a.score !== b.score) return b.score - a.score
            if (a.name !== b.name) return a.name < b.name ? -1 : 1
            return a.at - b.at
        })
    }
    var out = []
    for (var j = 0; j < hits.length; ++j) out.push(hits[j].p)
    return out
}
```

- [ ] **Step 4: Run Node tests, expect all PASS**

Run: `cd functions && node --test test/pickerSearch.test.js`
Expected: `# pass 27`, `# fail 0`. If a row fails, fix the helper or the row, whichever is wrong, and write down which in the checkpoint.

- [ ] **Step 5: Write the QML twin**

Create `tests/tst_ProductSearch.qml` in the shape of `tests/tst_StaffPicker.qml` (`import QtQuick`, `import QtTest`, `import "../qml/helper/ProductSearch.js" as PS`, a `TestCase { name: "ProductSearch" }`, a header comment saying "NOT RUN IN THIS SANDBOX, CI is the signal") with one `function test_SRCH_01_...` per row, using `compare()` on arrays. Do not use `long`, `int` or other reserved words as variable names (R3 lost a CI round to `var long`).

- [ ] **Step 6: Commit**

```bash
git add qml/helper/ProductSearch.js functions/test/pickerSearch.test.js tests/tst_ProductSearch.qml
git commit -m "feat(picker-s1): ProductSearch helper (dormant), 27 Node cases + QML twin" -m "Taher: lkdwtaher@gmail.com"
```

---

### Task 2: ProductPickability

**Files:**
- Create: `qml/helper/ProductPickability.js`
- Test: `functions/test/pickerPickability.test.js`, `tests/tst_ProductPickability.qml`

**Interfaces:**
- Consumes: product objects with `productId` (from `InventoryStore.products`).
- Produces: `classify(product, ctx) -> { product, visibility, reason, available, maxQty, inOrder, inDraft }`; `summarize(products, ctx, opts) -> { rows, hiddenCount }` with `opts = { inStockOnly }`. `ctx` fields, all optional functions of one argument unless noted: `availableFor(product)`, `hasPendingMint(id)`, `hasQueuedRestock(id)`, `unsyncedState(id)` (`""`, `"pending"` or `"parked"`), `isDeleting(id)`, `inOrderQty(id)`, `inDraft(id)`, and the boolean `lineLimitReached`.

- [ ] **Step 1: Write the failing test file, pattern first**

```js
"use strict";
const test = require("node:test");
const assert = require("node:assert/strict");
const { load, plain } = require("./testSupport/qmlHelpers");
const PK = load("ProductPickability.js");

const prod = (id) => ({ productId: id, name: "n" + id });
const ctx = (over) => Object.assign({ availableFor: () => 5 }, over || {});

test("PICK-01 normal product with stock is enabled", () => {
    const r = plain(PK.classify(prod("A"), ctx()));
    assert.equal(r.visibility, "enabled");
    assert.equal(r.reason, "");
    assert.equal(r.available, 5);
    assert.equal(r.maxQty, 5);
});
```

- [ ] **Step 2: Add the remaining rows, run, see them fail**

Run: `cd functions && node --test test/pickerPickability.test.js` (expected FAIL: file missing).

| ID | Input | Expected |
|---|---|---|
| PICK-01 | stock 5 | enabled, reason `""`, available 5, maxQty 5 |
| PICK-02 | `availableFor` returns 0 | disabled, `out-of-stock`, maxQty 0 |
| PICK-03 | available `-3`, `NaN`, `undefined`, `"7"` (a string), `Infinity` | each: disabled `out-of-stock`, maxQty 0 |
| PICK-04 | available `3.7` | enabled, maxQty 3, available 3 |
| PICK-05 | `hasPendingMint` true | hidden, `pending-mint`, maxQty 0 |
| PICK-06 | `hasQueuedRestock` true | hidden, `queued-restock` |
| PICK-07 | `unsyncedState` returns `"pending"` | hidden, `unsynced-edit` |
| PICK-08 | `unsyncedState` returns `"parked"` -> hidden `unsynced-edit`; returns `""`, `"x"`, `undefined` -> not hidden | as stated |
| PICK-09 | `isDeleting` true | hidden, `deleting` |
| PICK-10 | all four hide hooks true -> `pending-mint`; remove one at a time in order -> `queued-restock`, `unsynced-edit`, `deleting`; with a hide hook true and stock 0 -> still hidden | as stated |
| PICK-11 | `lineLimitReached: true`, `inOrderQty` 0, `inDraft` 0 | disabled, `order-full`, maxQty 0 |
| PICK-12 | `lineLimitReached: true`, `inOrderQty` returns 2 | enabled, `inOrder` 2 |
| PICK-13 | `lineLimitReached: true`, `inDraft` returns 3 | enabled, `inDraft` 3 |
| PICK-14 | `lineLimitReached: true` and available 0 | `out-of-stock` (not `order-full`) |
| PICK-15 | no `availableFor`; and `ctx` `undefined`; and `ctx` `null` | disabled `out-of-stock` (fail closed); with no hide hooks nothing is hidden |
| PICK-16 | `availableFor` throws; separately `hasPendingMint` throws | disabled, `unavailable`, maxQty 0, no throw |
| PICK-17 | `inOrderQty` returns `4`, `-1`, `"2"`, `NaN`; `inDraft` same | `inOrder`/`inDraft` are `4,0,0,0` |
| PICK-18 | `classify(null)`, `classify(undefined)`, `classify(5)` | disabled `unavailable`, no throw |
| PICK-19 | summarize 5 products, 2 hidden for different reasons | `rows.length` 3, `hiddenCount` 2 |
| PICK-20 | summarize preserves input order | same order as input minus hidden |
| PICK-21 | `inStockOnly: true` with one `out-of-stock`, one `order-full`, one `unavailable`, one enabled, one hidden | rows: `order-full`, `unavailable`, enabled; hiddenCount 1 |
| PICK-22 | summarize `[]`, `null`, `"x"`, `undefined` | `{ rows: [], hiddenCount: 0 }` |
| PICK-23 | summarize with `null`, `5`, `[]` entries among valid ones | skipped, not counted anywhere |
| PICK-24 | deep-freeze products and ctx | no throw, nothing mutated |
| PICK-25 | seeded monkey, 400 rounds: random products, random hook outcomes (true, false, throws, junk values) | no throw; no `hidden` row in `rows`; every `enabled` row has `maxQty >= 1`; `rows.length + hiddenCount (+ inStockOnly removals) ` equals the number of valid products |

- [ ] **Step 3: Write the minimal implementation**

```js
.pragma library

// Pure, single place that decides whether a product can be added to an order (design 2026-11-03,
// section 4). The dialog injects its own lookups as plain functions, so the three stock formulas
// (new order, edit pending, edit completed) stay in their dialogs and this file stays headless-testable.
//
// Fail closed: a missing or throwing `availableFor` never makes a row addable. A missing HIDE hook
// means "not hidden" (that guard does not exist yet, e.g. hasQueuedRestock before R4).

var REASON = {
    pendingMint: "pending-mint", queuedRestock: "queued-restock", unsyncedEdit: "unsynced-edit",
    deleting: "deleting", outOfStock: "out-of-stock", orderFull: "order-full", unavailable: "unavailable"
}

function _call(fn, arg, dflt) { return (typeof fn === "function") ? fn(arg) : dflt }
function _whole(n) { return (typeof n === "number" && isFinite(n) && n > 0) ? Math.floor(n) : 0 }

function _hide(row, reason) { row.visibility = "hidden"; row.reason = reason; row.maxQty = 0; return row }
function _disable(row, reason) { row.visibility = "disabled"; row.reason = reason; row.maxQty = 0; return row }

function classify(product, ctx) {
    var c = ctx || {}
    var row = { product: product, visibility: "enabled", reason: "", available: 0, maxQty: 0, inOrder: 0, inDraft: 0 }
    if (!product || typeof product !== "object") return _disable(row, REASON.unavailable)
    var id = product.productId
    try {
        if (_call(c.hasPendingMint, id, false)) return _hide(row, REASON.pendingMint)
        if (_call(c.hasQueuedRestock, id, false)) return _hide(row, REASON.queuedRestock)
        var u = _call(c.unsyncedState, id, "")
        if (u === "pending" || u === "parked") return _hide(row, REASON.unsyncedEdit)
        if (_call(c.isDeleting, id, false)) return _hide(row, REASON.deleting)
        row.inOrder = _whole(_call(c.inOrderQty, id, 0))
        row.inDraft = _whole(_call(c.inDraft, id, 0))
        row.available = _whole(_call(c.availableFor, product, 0))
        if (row.available <= 0) return _disable(row, REASON.outOfStock)
        if (c.lineLimitReached === true && row.inOrder === 0 && row.inDraft === 0)
            return _disable(row, REASON.orderFull)
        row.maxQty = row.available
    } catch (e) {
        return _disable(row, REASON.unavailable)
    }
    return row
}

// -> { rows: [classified, not hidden], hiddenCount }. opts.inStockOnly drops the out-of-stock rows only.
function summarize(products, ctx, opts) {
    var inStockOnly = !!(opts && opts.inStockOnly)
    var rows = []
    var hiddenCount = 0
    if (!Array.isArray(products)) return { rows: rows, hiddenCount: 0 }
    for (var i = 0; i < products.length; ++i) {
        var p = products[i]
        if (!p || typeof p !== "object") continue
        var r = classify(p, ctx)
        if (r.visibility === "hidden") { hiddenCount++; continue }
        if (inStockOnly && r.reason === REASON.outOfStock) continue
        rows.push(r)
    }
    return { rows: rows, hiddenCount: hiddenCount }
}
```

Note for PICK-16 when `hasPendingMint` throws: `_disable` is reached from `catch` only if the throw happens before a `return`; the row is then `unavailable`, which is the safe answer.

- [ ] **Step 4: Run, expect `# pass 25`, `# fail 0`**

Run: `cd functions && node --test test/pickerPickability.test.js`

- [ ] **Step 5: QML twin** `tests/tst_ProductPickability.qml`, same rules as Task 1 step 5, 25 functions `test_PICK_01_...`.

- [ ] **Step 6: Commit**

```bash
git add qml/helper/ProductPickability.js functions/test/pickerPickability.test.js tests/tst_ProductPickability.qml
git commit -m "feat(picker-s1): ProductPickability helper (dormant), 25 Node cases + QML twin" -m "Taher: lkdwtaher@gmail.com"
```

---

### Task 3: PickerDraft

**Files:**
- Create: `qml/helper/PickerDraft.js`
- Test: `functions/test/pickerDraft.test.js`, `tests/tst_PickerDraft.qml`

**Interfaces:**
- Produces: `MAX_LINES`, `empty()`, `parseQty(raw) -> { ok, qty }`, `setQty(draft, id, raw, maxQty) -> draft`, `step(draft, id, delta, maxQty) -> draft`, `totals(draft, priceOf) -> { items, lines, amount }`, `commitPlan(draft, orderLines) -> { adds: [{productId, qty}], bumps: [{productId, qty}] }`, `lineCountAfter(orderLines, plan) -> number`, `lineLimitReached(orderLines, draft) -> boolean`, `reconcile(draft, maxQtyOf) -> draft`. Every function returns a NEW object and never mutates its input. `orderLines` is `[{ productId, ... }]`; only `productId` is read, because New Order uses `qty` and Edit Order uses `quantity`.

- [ ] **Step 1: Write the failing test file, pattern first**

```js
"use strict";
const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { load, plain } = require("./testSupport/qmlHelpers");
const PD = load("PickerDraft.js");

test("DRFT-02 parseQty accepts digits only", () => {
    assert.deepEqual(plain(PD.parseQty("3")), { ok: true, qty: 3 });
    assert.deepEqual(plain(PD.parseQty(3)), { ok: true, qty: 3 });
    assert.deepEqual(plain(PD.parseQty(" 12 ")), { ok: true, qty: 12 });
    assert.deepEqual(plain(PD.parseQty("007")), { ok: true, qty: 7 });
    assert.deepEqual(plain(PD.parseQty("0")), { ok: true, qty: 0 });
});
```

- [ ] **Step 2: Add the remaining rows, run, see them fail**

Run: `cd functions && node --test test/pickerDraft.test.js` (expected FAIL: file missing).

| ID | Input | Expected |
|---|---|---|
| DRFT-01 | `empty()` twice | `{}` and two different objects |
| DRFT-02 | shown above | as shown |
| DRFT-03 | `""`, `"  "`, `"abc"`, `"2.5"`, `2.5`, `"-1"`, `-1`, `"+3"`, `"1e3"`, `NaN`, `Infinity`, `null`, `undefined`, `{}`, `[]` | each `{ ok: false, qty: 0 }` |
| DRFT-04 | `"999999"` and `"1000000"` | ok 999999; rejected |
| DRFT-05 | `setQty({}, "A", "3", 10)` | `{ A: 3 }` |
| DRFT-06 | `setQty({}, "A", "50", 8)` | `{ A: 8 }` |
| DRFT-07 | `setQty({ A: 3 }, "A", "0", 10)` | `{}` |
| DRFT-08 | `setQty({ A: 3 }, "A", "abc", 10)`, `"2.5"`, `""` | `{ A: 3 }` each, and a new object |
| DRFT-09 | `setQty({ A: 3 }, "A", "2", 0)`, `maxQty` `undefined`, `-4`, `NaN` | `{}` (key removed), `setQty({}, "A", "2", 0)` -> `{}` |
| DRFT-10 | id `"__proto__"`, `""`, `5`, `null`, `undefined` | draft unchanged, no throw, `Object.prototype` untouched |
| DRFT-11 | `step({}, "A", 1, 5)` | `{ A: 1 }` |
| DRFT-12 | `step({ A: 1 }, "A", -1, 5)` | `{}` |
| DRFT-13 | `step({ A: 5 }, "A", 1, 5)` | `{ A: 5 }` |
| DRFT-14 | `step({}, "A", -1, 5)`, `step({ B: 2 }, "A", -1, 5)` | `{}`, `{ B: 2 }` |
| DRFT-15 | delta `NaN`, `1.5`, `"1"`, `Infinity`, `null` | draft unchanged |
| DRFT-16 | deep-freeze the input draft, run every function | no throw, input unchanged |
| DRFT-17 | `totals({ A: 2, B: 3 }, id => ({ A: 10, B: 5 })[id])` | `{ items: 5, lines: 2, amount: 35 }` |
| DRFT-18 | prices `0.1` and `0.2`, qty 1 each; price `19.999` qty 3 | amount `0.3`; `60` (rounded to 2 decimals: `59.997` -> `60`) |
| DRFT-19 | prices `undefined`, `NaN`, `-5`, `"9"`; `priceOf` missing | items and lines still counted, amount 0 |
| DRFT-20 | `commitPlan({ B: 2, A: 1, C: 4 }, [{ productId: "B", qty: 9 }])` | `adds: [A:1, C:4]`, `bumps: [B:2]`, each sorted by `productId` |
| DRFT-21 | corrupt draft `{ A: 0, B: -1, C: 2.5, D: "3", E: NaN, F: 2 }` | only `F` appears |
| DRFT-22 | empty draft, `null` draft, `null` orderLines | `{ adds: [], bumps: [] }` (and with `null` orderLines every positive entry is an add) |
| DRFT-23 | orderLines using `qty`, using `quantity`, and with no qty field at all | the same line is detected as existing in all three |
| DRFT-24 | `lineCountAfter([{A},{A},{B}], { adds: [C,D] })` | 4 (distinct existing plus adds) |
| DRFT-25 | with `MAX_LINES - 1` distinct existing lines and an empty draft -> false; plus a draft of one new product -> true; draft that only bumps existing lines -> false | as stated |
| DRFT-26 | Node only: read `MAX_OPS` from `qml/helper/CompletionPlan.js` (`/var MAX_OPS = (\d+)/`) and from `functions/lib/operationLogic.js` (`/const MAX_OPS = (\d+)/`) | the two are equal, and `3 * MAX_LINES + 1 <= MAX_OPS`; both regexes matched |
| DRFT-27 | `reconcile({ A: 5, B: 2 }, id => ({ A: 3, B: 9 })[id])` | `{ A: 3, B: 2 }` |
| DRFT-28 | `maxQtyOf` returns 0 / `undefined` / unknown id for a key; and `maxQtyOf` missing | those keys removed; with the function missing the result is `{}` (fail closed) |
| DRFT-29 | `reconcile` of a draft that is already within limits | deepEqual to the input, a new object |
| DRFT-30 | seeded monkey, 400 rounds (LCG seed 11): random sequences of `setQty`, `step`, `reconcile` with junk ids, junk text and random maxima, then `commitPlan` | never throws; every quantity is an integer between 1 and the last maximum applied; no key holds 0; the sum of `adds` and `bumps` quantities equals the sum of the draft; `adds` and `bumps` are disjoint and sorted |

- [ ] **Step 3: Write the minimal implementation**

```js
.pragma library

// Pure draft for the order picker (design 2026-11-03). The draft maps productId -> whole quantity and
// is keyed by product, never by visible rows, so filtering never loses a quantity. Every function
// returns a NEW object. "Add N more" only: commitPlan never removes or reduces a line.
//
// MAX_LINES is conservative: a completed line costs at least 3 server changes (batch, stock, sale
// record) plus 1 for the order, and the server refuses more than MAX_OPS (functions/lib/operationLogic.js,
// qml/helper/CompletionPlan.js). A product that spans many batches costs more, so this is an early stop,
// not a guarantee; CompletionPlan stays the final check. functions/test/pickerDraft.test.js (DRFT-26)
// fails if 3 * MAX_LINES + 1 ever exceeds MAX_OPS.

var MAX_LINES = 60
var MAX_DIGITS = 6

function empty() { return {} }

function _has(o, k) { return Object.prototype.hasOwnProperty.call(o, k) }
function _whole(n) { return (typeof n === "number" && isFinite(n) && n > 0) ? Math.floor(n) : 0 }
function _validId(id) { return typeof id === "string" && id.length > 0 && id !== "__proto__" }
function _isQty(q) { return typeof q === "number" && isFinite(q) && q > 0 && Math.floor(q) === q }

function _clone(d) {
    var out = {}
    if (d && typeof d === "object")
        for (var k in d) if (_has(d, k) && k !== "__proto__") out[k] = d[k]
    return out
}

// Typed or stepped value -> { ok, qty }. Digits only, at most MAX_DIGITS; anything else is refused.
function parseQty(raw) {
    var s = ""
    if (typeof raw === "number") s = String(raw)
    else if (typeof raw === "string") s = raw.trim()
    if (!/^[0-9]+$/.test(s) || s.length > MAX_DIGITS) return { ok: false, qty: 0 }
    return { ok: true, qty: parseInt(s, 10) }
}

function _put(draft, id, qty, maxQty) {
    var out = _clone(draft)
    if (!_validId(id)) return out
    var q = Math.min(qty, _whole(maxQty))
    if (q > 0) out[id] = q
    else delete out[id]
    return out
}

function setQty(draft, productId, raw, maxQty) {
    var p = parseQty(raw)
    if (!p.ok) return _clone(draft)
    return _put(draft, productId, p.qty, maxQty)
}

function step(draft, productId, delta, maxQty) {
    if (typeof delta !== "number" || !isFinite(delta) || Math.floor(delta) !== delta) return _clone(draft)
    var cur = (_validId(productId) && draft && _has(draft, productId) && _isQty(draft[productId])) ? draft[productId] : 0
    return _put(draft, productId, Math.max(0, cur + delta), maxQty)
}

function totals(draft, priceOf) {
    var d = _clone(draft)
    var items = 0, lines = 0, amount = 0
    for (var id in d) {
        if (!_isQty(d[id])) continue
        items += d[id]
        lines++
        var price = (typeof priceOf === "function") ? priceOf(id) : 0
        if (typeof price === "number" && isFinite(price) && price > 0) amount += price * d[id]
    }
    return { items: items, lines: lines, amount: Math.round(amount * 100) / 100 }
}

function _existing(orderLines) {
    var set = {}
    if (Array.isArray(orderLines))
        for (var i = 0; i < orderLines.length; ++i) {
            var l = orderLines[i]
            if (l && l.productId !== undefined && l.productId !== null) set["k:" + String(l.productId)] = true
        }
    return set
}

// -> { adds, bumps }: adds = product not yet on the order, bumps = add to an existing line. Sorted by id.
function commitPlan(draft, orderLines) {
    var d = _clone(draft)
    var ex = _existing(orderLines)
    var ids = Object.keys(d).sort()
    var adds = [], bumps = []
    for (var i = 0; i < ids.length; ++i) {
        var q = d[ids[i]]
        if (!_isQty(q)) continue
        var entry = { productId: ids[i], qty: q }
        if (_has(ex, "k:" + ids[i])) bumps.push(entry)
        else adds.push(entry)
    }
    return { adds: adds, bumps: bumps }
}

function lineCountAfter(orderLines, plan) {
    var n = Object.keys(_existing(orderLines)).length
    return n + ((plan && Array.isArray(plan.adds)) ? plan.adds.length : 0)
}

// True when the order plus the draft's new lines already holds MAX_LINES distinct lines.
function lineLimitReached(orderLines, draft) {
    return lineCountAfter(orderLines, commitPlan(draft, orderLines)) >= MAX_LINES
}

// After a live refresh: clamp each quantity to the product's current maxQty, drop what reached 0.
// A missing maxQtyOf drops everything (fail closed).
function reconcile(draft, maxQtyOf) {
    var d = _clone(draft)
    var out = {}
    for (var id in d) {
        if (!_isQty(d[id])) continue
        var m = (typeof maxQtyOf === "function") ? _whole(maxQtyOf(id)) : 0
        var q = Math.min(d[id], m)
        if (q > 0) out[id] = q
    }
    return out
}
```

- [ ] **Step 4: Run, expect `# pass 30`, `# fail 0`**

Run: `cd functions && node --test test/pickerDraft.test.js`

- [ ] **Step 5: QML twin** `tests/tst_PickerDraft.qml`, 29 functions (every row except DRFT-26, which needs the file system and stays Node only), same rules as Task 1 step 5.

- [ ] **Step 6: Commit**

```bash
git add qml/helper/PickerDraft.js functions/test/pickerDraft.test.js tests/tst_PickerDraft.qml
git commit -m "feat(picker-s1): PickerDraft helper (dormant), 30 Node cases + QML twin" -m "Taher: lkdwtaher@gmail.com"
```

---

### Task 4: Dormancy pin, mutants, docs, push

**Files:**
- Create: `functions/test/pickerDormancy.test.js`
- Modify: `SKILLS.md`, `SKILLS-INDEX.md` (generated), `README.md` (one status line), `docs/superpowers/test-plans/README.md` (index row), `docs/superpowers/test-plans/2026-11-03-product-picker-v2-test-plan.md` (verification status block), `CHECKPOINT.md`

- [ ] **Step 1: Write the dormancy tests, run them**

| ID | Check |
|---|---|
| DORM-01 | Walk `qml/`, `src/`, `main.cpp`, `tests/`, `functions/` (skip `node_modules`); no file other than the three helpers and their own tests mentions `ProductSearch`, `ProductPickability` or `PickerDraft`. S3 changes this expectation on purpose, in the same PR. |
| DORM-02 | Each of the three files starts with `.pragma library` and has no `.import` line and no `Constants`, `InventoryStore`, `StockBatchStore`, `OutboxStore`, `dp(` or `sp(` token. |
| DORM-03 | `qml/helper/qmldir` does not need an entry: the three files are imported by path in S2. Assert the three names are absent from `qmldir`, so the S2 author adds them deliberately. |

Run: `cd functions && node --test test/pickerDormancy.test.js`. Expected: `# pass 3`.

- [ ] **Step 2: Hand mutants**

In a throwaway copy (never committed), apply each mutant to the helper text, run its Node test file, and require at least one failure. Record killed and survived in the test plan's verification block.

| Helper | Mutants |
|---|---|
| ProductSearch | every-word `AND` to `OR`; drop `toLowerCase`; drop `normalize`; swap scores 100 and 60; word-prefix score 40 to 10; drop the stable `at` tie-break; drop the `MAX_QUERY` cut; category compare made case-sensitive; skip the `typeof p !== "object"` guard; sort ascending |
| ProductPickability | swap pending-mint and queued-restock order; drop the `unsynced` `parked` case; hidden check after out-of-stock; `Math.floor` removed; `_whole` accepts strings; `lineLimitReached` ignores `inDraft`; `lineLimitReached` ignores `inOrder`; drop the `catch`; missing `availableFor` defaults to 99; `inStockOnly` also drops `order-full` |
| PickerDraft | `MAX_LINES` 60 to 100; `MAX_DIGITS` 6 to 9; regex allows `.`; drop the `__proto__` guard; drop the clamp to `maxQty`; `delete` replaced by writing 0; `commitPlan` sort removed; `commitPlan` emits bumps as adds; rounding removed; `reconcile` missing function keeps the draft; `step` accepts fractional delta; `_clone` mutates the input |

Any survivor means a missing test: add it, rerun, and note it.

- [ ] **Step 3: Skill, index, README, test plan**

Add `## Skill 152: ...` to `SKILLS.md` only if a real lesson came out of S1 (a survivor, a QML-vs-Node difference). If none, skip it and say so in the checkpoint. If added: `node .github/scripts/skills-index.js --write`. Add one dated line to the README status area and one row to `docs/superpowers/test-plans/README.md` for the new plan. Fill the verification block of the test plan with numbers recounted by `grep -c "function test_" tests/tst_ProductSearch.qml tests/tst_ProductPickability.qml tests/tst_PickerDraft.qml` and the Node `# pass` lines.

- [ ] **Step 4: Run the full local suites**

Run: `cd functions && npm ci && npm test 2>&1 | tail -8` and `cd .. && node --test .github/scripts/__tests__/*.test.js 2>&1 | grep -E "^# (pass|fail)"`.
Expected: no failures. A first run before `npm ci` shows files failing on `node-mocks-http`; that is a missing install, not a code failure.

- [ ] **Step 5: Commit, push, read CI**

Update `CHECKPOINT.md` (what is done, what CI said), commit, push with the header method, then read the CI result. The first CI run may fail on a QML-only difference (R3 lost a round to a reserved word): fix and push again, and record it. Do not claim the QML tests pass until CI shows it.

## Self-Review (done when this plan was written)

- **Spec coverage:** design section 3 helpers `ProductSearch`, `ProductPickability`, `PickerDraft` have Tasks 1 to 3; rules 1 to 8 of design section 4 map to: fail closed (PICK-15, PICK-16), precedence (PICK-10, PICK-14), order full and drift (PICK-11 to 13, DRFT-25, DRFT-26), survives filtering (the draft has no row keys, DRFT-05 to 09), live refresh (DRFT-27 to 29), additive commit (DRFT-20 to 23), whole units (DRFT-03, 04), literal search (SRCH-14 to 16, 22). `PickerRowGeometry.js` is S2, not here.
- **Placeholder scan:** the three helpers are complete code. Tests are given as exact rows (input and expected value) with one full example per file instead of 82 repeated code blocks; that is a deliberate size choice, and each row is one test.
- **Type consistency:** `classify` row fields (`visibility`, `reason`, `available`, `maxQty`, `inOrder`, `inDraft`) are the same in the design, Task 2 interfaces and the code; `commitPlan` returns `{ adds, bumps }` of `{ productId, qty }` everywhere; `reconcile(draft, maxQtyOf)` takes a function of the product ID; `lineLimitReached(orderLines, draft)` feeds `ctx.lineLimitReached` as a boolean.
- **Known gap, on purpose:** the sheet, the row, `scrollBody` and the dialog wiring are S2 to S4 and get their own plans after S1 merges, because their code depends on how S1 lands.
