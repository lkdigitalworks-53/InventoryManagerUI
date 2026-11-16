# Product picker v2, slice S5a: the "no selling price" row reason and the emulator E2E

**Date:** 2026-11-15. **Branch:** `feat/2026-11-15-picker-s5a-no-price-and-e2e`, cut from `main` @ `e35c758` (#196 S4 merged).
**Design:** `specs/2026-11-03-product-picker-v2-design.md` (approved). **Test plan:** `test-plans/2026-11-03-product-picker-v2-test-plan.md` (S5a rows). **Carried items closed here:** KNOWN-ISSUES 23 (no-price row) and 34 (emulator E2E, pending-order paths).

## Where S5 stands (read from the repo, 2026-11-15)
S1 to S4 are merged (#185, #187, #194, #196). S5 in the design is "accessibility, themes, font scale, big-catalog performance, regression sweep, on-device plan finalised, docs". Plus everything the S2 to S4 sweeps carried into S5. That is too much for one turn and most of it cannot be seen without a build, so S5 is cut into slices that each merge alone:

| Slice | Content | Needs a device or a decision |
|---|---|---|
| **S5a (this PR)** | `no-price` row reason (KI 23); emulator E2E for New Order and Edit Order on a pending order (KI 34) | none to merge; device checks 97 to 101 afterwards |
| S5b | One stock formula for the cart-row `+` stepper and `_save()` (KI 28a, 37a, 39a), delete the legacy catalog seed (KI 30) if decided | Taher decides Q1, Q2 below; device checks |
| S5c | Touch targets: 28 dp cart steppers to 44 to 48 dp in both dialogs (KI 24a, 28b); Back key with a draft (KI 8, 19b); in-stock row double toggle (KI 19a) | layout unseen without a build; device checks |
| S5d | Measure, then tune: debounce 150 ms, `categories` per rebuild (19c), dry-run cost (25), big catalog | device numbers first (checks 46, 64) |
| S5e | TalkBack, themes, font scale pass; ToastHost wrap (KI 26, its own PR); finalise the on-device plan; decide KI 29 (completed-order edit cap) | device |

Order is my recommendation: S5a first (pure and server-checked, no layout risk), S5b before S5c (money path before cosmetics).

## Scope of S5a
1. `ProductPickability.classify` takes an optional `hasPrice(product)` hook. Both dialogs supply `NP.priceOf(p) !== null`, the same rule `applyPlan` uses to refuse a new line, so the row and the commit can never disagree.
2. `PickerSheetModel`: reason words "No selling price", pill "No price" (status `inactive`), hook passed through.
3. `test/e2e/pickerOrder.e2e.test.js` (CI only, wired into `checks.yml`, junit `results-pickerOrder.xml`): three tests on the real server with the shipped client helpers loaded as text.
4. Docs, tests, test plan, skill.

NOT in S5a: any layout change, any change to a completed-order edit, any server or rules change, the stock-formula unification.

## Decisions (defaults taken, veto in the PR)
**S5a-D1. Where does the price check live: a hook, or inside `ProductPickability`?** Options: (a) read `product.sellingPrice` inside Pickability; (b) optional hook supplied by the dialogs. For (a): no wiring. Against (a): it duplicates `NewOrderPicker.priceOf` (finite number >= 0, `sellingPrice` then legacy `price`, `null` counts as missing) in a lower layer, and the two would drift (they already differ: `PickerSheetModel.priceOf` is the DISPLAY price and turns a missing price into 0). For (b): one rule, owned by `NewOrderPicker`, the same function `applyPlan` calls; the helper stays store-free. The row is never LOOSER than the commit (NOP-32 proves it over 9 price shapes x 6 carts); it can be stricter in one rare case: a cart line that holds no usable quantity (0, NaN, negative) is "not on the order" for the row (`cartQty` skips it) but a bump for `applyPlan` (`_indexOf` is by presence), so a no-price product with such a line is shown disabled while the commit would raise it. Fail closed, pinned in NOP-32. Against (b): one more hook (seven now, pinned by NOW-03 and EOW-03). **Taken: (b).**

**S5a-D2. Absent hook means "not checked", not "no price".** Every other required hook fails closed. This one is optional like `hasQueuedRestock`: an older caller or a test that never heard of prices keeps working, and `applyPlan` stays the final gate either way (it refuses a new line with no price and says "no price"). A hook that is present and does not answer truthy, or throws, fails closed (PICK-37, PICK-40). Cost: a dialog that forgets the hook shows the old behaviour; NOW-03 and EOW-03 fail if either dialog drops it.

**S5a-D3. A product already on the order is NOT disabled for a missing price.** `applyPlan` only refuses a NEW line for no price; a bump touches only the quantity and never the line's price. Disabling the bump would stop a person from finishing an order whose product lost its price after it was started. So the check applies only when `inOrder === 0` (PICK-38, NOW-17, EOW-20). A draft quantity on a product that is not on the order does not make the price acceptable (PICK-39).

**S5a-D4. Precedence.** Hidden guards, then out of stock, then no price, then order full. Out of stock stays first so the in-stock-only filter keeps dropping exactly the out-of-stock rows; a no-price row with stock stays visible, disabled, with its words. "Order full" comes after because a product that can never be added needs the more specific reason (PICK-39).

**S5a-D5. Free items stay allowed.** A price of 0 is a valid price (Taher 2026-11-11: no price must not be allowed, 0 is). Negative, NaN, text and null-without-legacy-price are "no price" (NOW-17).

**S5a-D6. E2E: which paths, and what is honestly not covered.** Covered: New Order commit that spans two FIFO batches, a replay, a stock change by another device between pick and complete (whole operation refused, nothing written, the re-read sheet clamps the draft, the same request id re-planned completes), Edit Order on a PENDING order (bump keeps price and discount, new row, no-price product refused). NOT covered: Edit Order on a COMPLETED order (a QML-only sequential chain, no Node-reachable path; KI 29, 34) and the Felgo layer. A QML E2E (`tst_*E2E.qml` against the emulator) could reach `DataModel._tryAdjustOrder`, but the existing ones cover stores, not dialogs, and a dialog under `qmltestrunner` is blocked by Felgo (Skill 83). I did not invent a harness blind.

**S5a-D7. No emulator here, so the E2E was dry-run offline.** A throwaway require hook (not committed) swapped Firestore for the repo's strict in-memory double and `fetch` for the REAL `validateOperationRequest` + `applyOperation`. All three tests passed there, and the cleanup left no `pkE2E` document. That proves the client-side logic and the operation shapes; it does not prove Firestore semantics (CI does). Found while doing it: the real server also writes one `stock_movements` row per stock change, so the E2E's cleanup covers `audit_log` and `stock_movements` by request-id prefix.

## Honest coverage statement
Pure helpers stay at 100% branch coverage by hand mutants (6 new mutants on the new branch, all killed; first run no survivors). The E2E and the Felgo layer cannot be line-measured. CI is the oracle for the three E2E tests and the regenerated QML twins.

## Questions for Taher (none block the merge of S5a)
**Decided 2026-11-15 (Taher, "as recommended"): Q1 yes, Q2 delete the legacy seed, Q3 measure on a device first (no cap yet). Detail below is the original text.**

- **Q1 (S5b).** Should the cart-row `+` stepper and `_save()` both ask `Edit.availableFor` / `NP.availableFor`? For: one formula, no disagreement on a fractional stock. Against: it changes a money path that no device has confirmed, and a stepper for a product that LEFT the catalog goes from "unlimited +1 then refused at Save" to "cannot go up". Recommendation: yes, in S5b with its own device checks.
- **Q2 (S5b, KI 30).** Delete the legacy seed that turns an order with no `products` array into two lines of the first two catalog products? It stores invented lines as real ones on Save. Recommendation: delete it, and `catalog` and `_rebuildCatalog` go with it. Cost: a very old order (if any exists; dev data only) opens empty.
- **Q3 (S5e, KI 29).** Cap a completed-order edit below 60 new lines, or measure check 82 on a device first? Recommendation: measure first; a cap without a number is a guess.

## PR #200 sweep (2026-11-15), fixed in the same PR
- **Display price used a different rule from the order line's price.** `PickerSheetModel.priceOf` took `sellingPrice` whenever it was not `undefined`, so `sellingPrice: null` with a legacy `price: 3` showed 0 on the row and totalled 0 in the sheet, while `NewOrderPicker.priceOf` (row hook and `applyPlan`) priced the line at 3 (a 6 line shown as 0). The `null` fallback now matches (SHEET-44; the old code fails it). The S5a text said the two "already differ" and left it; with `no-price` now deciding what is addable, a row that is addable and shows 0 is a wrong number in front of the person.
- **Vacuous assertion removed from PICK-39** (it asserted its own lambda). Precedence cases for queued restock and deleting added.
- **NOP-32 (Node only):** the row is never looser than the commit, plus the one safe gap above.
- **Docs:** KNOWN-ISSUES 41 closed (CI emulator ran PK-E1..E3, 3/3), 43 added; the test plan count 1786 was not a measured number, replaced by 1793 (re-run by hand).
- **Not changed, stated in KNOWN-ISSUES 43:** the "0.00 / pcs" price line on a no-price row; the same `null` pattern in `OrderDetailDialog._rebuildCatalog` (the legacy seed, KI 30, Q2).
