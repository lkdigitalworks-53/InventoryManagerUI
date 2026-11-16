# Product picker v2, slice S5b: one stock rule, legacy seed deleted

**Date:** 2026-11-16. **Branch:** `feat/2026-11-16-picker-s5b-one-stock-formula-delete-legacy-seed`. **Follows:** S5a (PR #200, merged).
**Scope (KNOWN-ISSUES 28a, 37a, 39a, 30, 43c; decisions Q1 and Q2 of item 44, "as recommended"):** the product sheet, the cart-row `+` stepper and the save-time stock check ask ONE definition of "how many units may this order hold"; the legacy catalog seed in Edit Order is deleted.

## The rule
`NP.ceilingOf(product)` = whole units on hand (0 for a missing product). `Edit.ceilingFor(productId, product, ctx)` = that, plus on a COMPLETED order the units the order already took out of stock (`originalOf`). A blank id has 0. An unknown status takes the pending formula (fail closed).
Readers: `NP.availableFor`, `Edit.availableFor` (sheet), `Edit.stepUp` (the `+` tap, per ROW: ceiling minus the other lines of the same product), `Edit.stockShortfalls` (Save, per PRODUCT: all lines together). New Order's `changeQty` reads `NP.ceilingOf`.

## Decisions (defaults, Taher can veto in the PR)
| id | decision | trade-off |
|---|---|---|
| S5b-D1 | One ceiling function, every reader calls it (Skill 170) | A change to the rule is one edit; cost: Edit Order's helper now depends on NP's `ceilingOf` (it already depended on NP for `cartQty`). |
| S5b-D2 | `stepUp` never lowers a row on `+` and never raises it past the ceiling | A row already over (stock fell) keeps its quantity; Save then reports it. Alternative (clamp down on `+`) hides a real over-sell from the user. |
| S5b-D3 | A product that LEFT the catalog is skipped by the save check; its row cannot go up (completed order: can return to what it held) | Keeps an unrelated edit (customer name) saveable; completion refuses the line later (KI 6, 28c). Alternative (refuse at Save) warns earlier but blocks every edit of that order until the line is removed. **Open Q1.** |
| S5b-D4 | The save check groups by PRODUCT (old: per line) | Catches two lines of one product (legacy orders). Cost: the message names the first line's name. |
| S5b-D5 | New Order `changeQty` included; `trySubmit` left on raw `inv.stock` | Q1 names `NP.availableFor`, the stepper had the same fractional-stock bug (24c). `trySubmit` gives the same answer for whole quantities, so changing it adds risk, no benefit. |
| S5b-D6 | Legacy seed deleted (`catalog`, `_rebuildCatalog`, the else branch): an order without a `products` array opens with no lines | Per Q2. Side effect: Save on such an order stores `products: []` and `items: 0` (verified at `OrderDetailDialog` `items: itemCount`). Dev data only, so accepted; **open Q2**. |
| S5b-D7 | Message wording unchanged ("Widget: only 2 in stock, need 1 more"); the shortfall field is `need` | `short` is a reserved word QML refuses; the reserved-word guard (Q-3) caught it. |

## Behaviour changes a user can see
- Stock 2.5: `+` stops at 2 (was 2.5 / 3), same as the sheet.
- A pending row for a product that left the catalog, or a row with no product id: `+` does nothing (was +1 each tap, then refused at Save).
- Two lines of one product: Save checks them together.
- A completed order with on-hand 0 or negative and an unchanged line: Save works (old check blocked it when on-hand was negative).
- An order with no `products` array: opens empty (was: two invented lines).

## Open questions for Taher
- **Q1** product gone from the catalog at Save: skip (default) or refuse?
- **Q2** order with no `products` array: Save writes `products: []`, `items: 0`. Accept (dev data only) or guard?
- **Q3** New Order `trySubmit` keep raw `inv.stock` (default) or move to `ceilingOf` for symmetry?

## Tests
Node: NOP-33..35, EOP-32..39 (EOP-39 and NOP-35 are seeded monkeys, Node only), EOW-20..25, NOW-18; EOW-01/09/11/17 updated. EOW-22 replays 400 seeded orders against the OLD per-line check (regression parity). QML twins regenerated (`tst_EditOrderPicker`, `tst_NewOrderPicker`). 18 hand mutants of the new helper code, all killed. Test plan: `test-plans/2026-11-03-product-picker-v2-test-plan.md`, steps 104 to 114.

## Not in S5b (still open, in the plan table of S5a)
S5c touch targets, Back key, in-stock double toggle (24a, 28b, 8, 19b, 19a); S5d measure then tune (19c, 25, 14); S5e TalkBack, themes, font scale, ToastHost wrap (26), KI 29 cap.
