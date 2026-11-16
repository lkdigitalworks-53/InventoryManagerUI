# Test plan: AP3a, Add Product sent as ONE atomic operation

Branch `feat/2026-11-16-ap3a-add-product-wire`. Design: `specs/2026-11-16-ap3a-add-product-wire-design.md` (D-AP3-1..10) on top of `specs/2026-11-13-add-product-atomic-operation-design.md`. Standard format (Skill 49).
Honesty note: Node tests were RUN in the sandbox against the real server code. QML twins and the e2e emulator suites are CI-only (no Qt in the sandbox, by rule). I did not build or run the app.

## 1. Unit tests
| File | Cases | Run? | Covers |
|---|---|---|---|
| `functions/test/addProductFlow.test.js` (new) | 17 | RUN 17/17 | F-1 key; F-2..F-4 defaults and pass-through; F-5 one Date, local day; F-6 bad time; F-7, F-8 supplier none/id/known name/new name/blank/too long; F-9 every supplier x stock builds, plans and is accepted by the real server; F-10 old call shapes; F-11 every refusal reason has a text; F-12 classify; F-13 fixed texts; F-14, F-15 supplier clash covers an add; M-1 3000-input monkey; G-1 purity guard |
| `functions/test/addProductWire.test.js` (new) | 19 | RUN 19/19 | the REAL store bodies in a vm + the real server: W-1 live apply once; W-2 stock 0 / known supplier; W-3 queued then signal; W-4 replay (live and late) adds no product and re-reads; W-5 sync landed first; W-6 offline refusal; W-7 pure refusals even offline; W-8 no callback; W-9 supplier clash; W-10..W-12 rejections (live, late, after relaunch); W-13..W-15 unconfirmed and 10 damaged answer shapes; W-16 own key per tap; W-17 source order and the old path gone; W-18 removed helper; M-1 seeded 300-tap monkey |
| `tests/tst_AddProductFlow.qml` (new, CI) | 16 functions | CI only | the flow cases for the QML engine |
| `tests/tst_InventoryStore_addProduct.qml` (new, CI) | 12 functions | CI only | the wire with the real Gateway (await timeout shortened), DataModel Connections and the real stores |
| edited guards | | RUN | `operationLogic.addProduct.test.js` and `addProductPlan.test.js` G-1 (dormancy -> wiring pin), `sheetBusyOverlay.test.js` SB-4, `restockHold.test.js` P-2, `counterRegistry.guard.test.js` (11 mutants), `restockR5a.test.js` K-7 scoped to restock |

## 2. Regression tests
Full functions suite: RUN 1918/1918 green (1899 after the code, +19 wire test). Restock, order completion, import and delete suites unchanged.

## 3. E2E (emulator, CI only)
Six e2e files call `addProduct`; each helper goes online inside try/finally and three suites set `Gateway.operationFunctionUrl` to the emulator. InventoryE2E `initTestCase` warms the `recordOperation` endpoint. Unproven locally: if the E2E job is red, read the first failing add helper first.

## 4. Rules
Unchanged.

## On-device test plan (Taher; requires a build of this branch and the already-deployed AP1 functions)
### Happy path
1. Online, owner. Add product "Tomato", stock 12, no supplier, with a photo. Expect: busy overlay, then "Product added"; the product in the list with stock 12 and its photo; History shows a "created" row; Stock batch shows 12; Activity shows "Product added: Tomato".
2. Same with a NEW supplier "Newco" typed in the dialog's supplier field. Expect the supplier in Suppliers, the batch carrying it.
3. Same with a known supplier (any letter case). Expect no second supplier.
4. Stock 0. Expect product and History row only, no batch.
### Negative
5. Airplane mode, tap Save. Expect: "Adding a product needs an internet connection. Connect and try again", nothing queued (Settings > stuck writes empty), no product.
6. Empty name, negative price, tax 120: each shows its own message even offline.
7. Two adds with the SAME new supplier name while the first is slow (throttle): the second says the supplier change is still waiting to sync.
### Edge cases
8. Throttle the network so the answer is late: the dialog closes with "Product saved. It appears in your list when it syncs" (and, with a photo, "Add its photo from the product page"); the product appears later, once; Activity has ONE row.
9. Name `{{prd}}` or a name with `}}`: stored with one space inside the pair, never an id.
10. Fractional stock 2.5: History row shows 2.5 (the old row showed 2).
11. Kill the app right after tapping Save on a slow link, reopen online: the product appears once.
### Affected areas
Stuck-writes sheet label for an add ("Add product <name>"); order creation with the new product; restock of the new product; delete of the new product (cascade).
### Regression
Restock a product; complete an order; edit a product; import a CSV with 3 products; add a staff member.
### Monkey
Two minutes of rapid add / cancel / restock / order, toggling airplane mode: no crash, no duplicate product, no stray toast.

## 5. CI result
Filled in after the push (see CHECKPOINT.md).
