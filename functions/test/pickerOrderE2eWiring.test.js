"use strict";
// Picker v2, slice S5a: pins for the emulator E2E file and its place in CI. The E2E itself runs only on CI (needs the
// Firebase emulator); these cases run everywhere and fail when the file stops being safe to run or stops being run.
// E2EW-01..05. Plan: docs/superpowers/plans/2026-11-15-product-picker-v2-s5a-no-price-and-e2e.md.
const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

const ROOT = path.join(__dirname, "..", "..");
const read = (rel) => fs.readFileSync(path.join(ROOT, rel), "utf8");
const E2E = read("test/e2e/pickerOrder.e2e.test.js");
const WF = read(".github/workflows/checks.yml");

test("E2EW-01 CI runs the picker E2E after the other two Node E2E files, with a junit report that is uploaded", () => {
    const run = WF.split("\n").filter((l) => l.indexOf("test/e2e/seed.js") >= 0)[0] || "";
    assert.ok(run.indexOf("test/e2e/recordOperation.e2e.test.js") < run.indexOf("test/e2e/cleanupSweep.e2e.test.js"));
    assert.ok(run.indexOf("test/e2e/cleanupSweep.e2e.test.js") < run.indexOf("test/e2e/pickerOrder.e2e.test.js"), "picker E2E is not in the chain");
    assert.ok(run.includes("--test-reporter-destination=results-pickerOrder.xml test/e2e/pickerOrder.e2e.test.js"));
    const upload = WF.slice(WF.indexOf("name: e2e-test-results"), WF.indexOf("name: e2e-test-results") + 300);
    assert.ok(upload.includes("results-pickerOrder.xml"), "the junit file is not uploaded with the E2E artifact");
    assert.ok(!/\|\|\s*true/.test(run), "the chain must not swallow a failure");
});

test("E2EW-02 the file refuses to run against anything but the emulator, and uses its own app and its own ids only", () => {
    assert.ok(/if \(!process\.env\.FIRESTORE_EMULATOR_HOST\)[\s\S]{0,200}process\.exit\(1\)/.test(E2E));
    assert.ok(/initializeApp\(\{ projectId: PROJECT_ID \}, "pickerOrderE2E"\)/.test(E2E), "a named app, so it cannot collide with the other E2E files");
    const seeded = E2E.match(/await seed\("([^"]+)"/g) || [];
    assert.ok(seeded.length >= 20, "expected the fixtures, found " + seeded.length);
    for (const s of seeded) assert.ok(/pkE2E-/.test(s), "a fixture outside the pkE2E prefix: " + s);
});

test("E2EW-03 it uses the shipped client helpers loaded as text, and defines no copy of a picker or planner rule", () => {
    for (const h of ["PickerSheetModel.js", "PickerDraft.js", "NewOrderPicker.js", "EditOrderPicker.js", "CompletionPlan.js"])
        assert.ok(E2E.includes('load("' + h + '")'), h + " is not loaded");
    assert.ok(!/function (availableFor|priceOf|applyPlan|classify|commitPlan|build)\b/.test(E2E), "the E2E re-implements a rule it should be testing");
    assert.ok(E2E.includes("NP.priceOf(p) !== null"), "the hasPrice hook must be the dialogs' one");
});

test("E2EW-04 it cleans up what the real server writes: fixtures, sale docs, audit rows and stock movements by request id", () => {
    assert.ok(E2E.includes("for (const p of createdPaths) await db.doc(p).delete()"));
    assert.ok(/\["audit_log", "stock_movements"\]/.test(E2E));
    assert.ok(E2E.includes('startsWith("completeOrder:pkE2E")'));
    assert.ok(E2E.includes("trackSaleDocs(plan)") && E2E.includes("trackSaleDocs(first.plan)"));
});

test("E2EW-05 the three scenarios are all there: two batches and a replay, a stock change between pick and complete, an Edit Order on a pending order", () => {
    for (const id of ["PK-E1", "PK-E2", "PK-E3"]) assert.ok(E2E.includes('test("' + id + ":"), id + " is missing");
    assert.ok(E2E.includes("idempotentReplay, true"));
    assert.ok(E2E.includes('"insufficient-quantity"') && E2E.includes("refused.status, 409"));
    assert.ok(E2E.includes("the picker never touches an existing row's price or discount"));
});
