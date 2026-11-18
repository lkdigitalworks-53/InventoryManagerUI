# Step 2, slice AP3a: wire `InventoryStore.addProduct` to the atomic `addProduct` operation

Date 2026-11-16. Branch `feat/2026-11-16-ap3a-add-product-wire`, cut from `main` @ `503adda` (#201 merged and device tested by Taher). Contract (decided by Taher 2026-11-15, "go with recommended"): `specs/2026-11-13-add-product-atomic-operation-design.md` sections 7 to 9 and `specs/2026-11-15-ap2-add-product-client-plan-design.md` section 6 (the AP3 checklist). This file records only what AP3a decides on top of them.

## 1. Scope
**Built (AP3a):**
- `qml/helper/AddProductFlow.js` (new, pure): `newKey`, `makeInput` (the defaults the old `addProduct` had, one `Date` for instant and day, supplier resolution through `RestockFlow.supplierFor`), `refusalText`, `classify`, `supplierPendingText`, and the four fixed texts.
- `InventoryStore.addProduct` rewritten: ONE `Gateway.recordOperation("addProduct", ops, key, { awaitServer: true })`. New `_addFailureText`, `_applyAddProduct`, `applyAddProductResults`, `_addLocalProduct`, `onAddProductApplied`, `onAddProductRejected`. `_resolveSupplierId` removed.
- `DataModel`: the `onAddProduct` route passes the new `status`; `Connections` on Gateway routes `operationApplied/Rejected` for `addProduct`.
- `AddProductDialog`: the submit callback takes `(ok, newId, refusal, status)` and the photo/toast logic follows it. Nothing else in the dialog changes.
- `RestockFlow.queuedNewSupplierClash` also reads queued `addProduct` items.
- e2e helpers (6 files) adapted; both dormancy guards (AP1 G-1 and AP2 G-1) replaced by wiring pins.

**Not built (AP3b, next):** the dialog's inline supplier "Use" row (R5a pattern), strict number parsing and limits in the dialog (so a value the planner refuses is stopped before the tap), the dialog submit body tested in Node. Until then the dialog's old "Save" supplier row still mints the supplier BEFORE the add (KNOWN-ISSUES 47).

## 2. Evidence read
`InventoryStore.addProduct` (seven independent writes: product id mint, supplier resolve/create, product create, batch, `created` row, Activity row, photo later), `RestockDialog.qml` and `InventoryStore.restock` (the pattern for await, queued, rejected, replay), `Gateway.recordOperation` (waiter first, then the signal; `awaitTimeoutMs`), `AuthService.isOnline`, `TransactionStore.addLocalEntries`, `ActivityLog.adopt`, `AddProductPlan.build/reflect`, the six e2e files that call `addProduct`.

## 3. Decisions (all vetoable in the PR)
**D-AP3-1: split AP3 into AP3a and AP3b.** One chat turn cannot carry the store wire, the dialog rewrite, the tests and the docs at the quality bar. AP3a changes what is stored and sent; AP3b changes only what the dialog lets through. Trade-off: for one merge window the dialog can send values the planner refuses; AP3a shows the planner's own text in that case (D-AP3-2), so nothing is lost silently.
**D-AP3-2: pure refusals come before the connection check.** A bad name, price, tax, stock or supplier shows ITS OWN text even offline; only a valid add that cannot be sent shows the offline text. Alternative: offline first (simpler, but a person offline with a typo would fix nothing and fail again online).
**D-AP3-3: nothing is shown locally before the server answers.** No optimistic product (the id does not exist yet, D-AP-7). The busy overlay the dialog already has covers the wait. A slow answer is `queued`: the dialog closes with "Product saved. It appears in your list when it syncs", and the product appears when the signal arrives.
**D-AP3-4: `malformed-results` after commit is `unconfirmed`.** The server committed, our reader refused its answer. A plain retry would be a new key, so a SECOND product. The store applies nothing, re-reads inventory, batches, suppliers and history, and the callback gets `(true, "", undefined, "unconfirmed")`; the text says "Check the product list before adding it again". `productAdded` is not emitted.
**D-AP3-5: a replayed answer never adds the product from the answer.** It is as of the FIRST application and may be stale (edited, restocked or deleted since). The inventory and batches are re-read; the supplier, batch and history rows are still reflected (their stores are idempotent by id).
**D-AP3-6: the waiter and the signal cannot both apply.** `_addSettled[key]` is set when the waiter applies; the signal consumes it and returns. A queued answer sets nothing, so the later signal applies once. A relaunch loses `_addNames` (typed name for rejection texts); a late rejection then reads "A queued product was not added. <cause>" without the name.
**D-AP3-7: a queued add gets no photo.** The photo needs the product id, which exists only in a live answer (D-AP-8). The toast says so ("Add its photo from the product page"). Known limit: KNOWN-ISSUES 47.
**D-AP3-8: a second add that would create the SAME new supplier while the first is queued is refused** (R5a rule extended to `addProduct` items), because the local supplier list learns the first only when the server answers. Two phones offline can still make two (KNOWN-ISSUES, restock O1).
**D-AP3-9: `nextProductId` stays as dead code** with a comment: `operationLogic.addProduct.test.js` R-1 pins the server counter's id format to this body (the bulk import still uses the same counter). Delete it only together with that pin.
**D-AP3-10: e2e helpers go online for the add.** The emulator suites call `addProduct` with `AuthService.isOnline` false; the helpers flip it true inside try/finally and three suites point `Gateway.operationFunctionUrl` at the emulator. CI-only (unproven locally): KNOWN-ISSUES 49.

## 4. What the tests prove (details: test plan)
`addProductFlow.test.js` (17) runs the helper's real text and sends every input it builds through the real planner and the real server. `addProductWire.test.js` (19) runs the REAL bodies of the seven store functions in a Node vm, with fake stores around them and the real `operationLogic` answering the queued operation: live apply once, queued then signal, replay, unconfirmed, rejection texts, offline, supplier clash, source order, a seeded monkey. Existing guards were updated, not weakened (11 mutants in the counter guard).

## 5. Deploy and compatibility
The server half is already live (AP1 deployed). AP3a is a client change: no functions deploy, no rules change. A build of this branch needs a connection to add a product (D-AP-7); an add already queued by the PREVIOUS build is not an operation (it used separate writes) and drains as before. Revert: safe; operations already in the outbox would then stay queued with an unknown label until the stuck-writes sheet discards them.

## 6. For AP3b and AP4
- AP3b checklist: KNOWN-ISSUES 44 (dialog values the planner refuses), the inline supplier row, a submit body testable in Node.
- AP4: device test of the whole arc (test plan section "On-device").
