# Step 3 design: a new order is ONE atomic operation (slice NO2 = client planner, pure and dormant)

Date 2026-11-22. Branch `feat/2026-11-22-no2-create-order-client-plan`, cut from `main` @ `a3227e7` (#208 merged). Server contract: `specs/2026-11-21-create-order-atomic-operation-design.md` (D-NO-1..9; D-NO-5b is the rule this file must satisfy). Roadmap: `ATOMIC-OPERATIONS-STATUS.md` section 18 ("Next: NO2").

## 0. Where the roadmap stood (read from `main`, 2026-11-22)
Done: step 1 restock (R1..R5b), step 2 add product (AP1..AP3b), NO1 (server `createOrder`, merged as #208 with the review fix `checkCreateOrder`). Open: NO2 (this), NO3 wire, NO4 device test; `_tryAdjustOrder`, `completeImportedOrder`, `_reverseCompletedOrder` (each needs a design and rulings); step 4 import chunking; AP4 (your device pass of the add arc). The four NO1 questions were not vetoed in the merged PR, so the recommended answers stand: Q-NO-1 order of step 3 (new order first), Q-NO-2 auto-approve stays a second operation, Q-NO-3 offline new order refused (answered by you), Q-NO-4 no feed row.

## 1. What NO2 builds
Nothing visible. Pure helpers, called by no store, page or dialog (a guard test walks `qml/`):

| File | New |
|---|---|
| `qml/helper/OperationKeys.js` | `createOrderNonce`, `createOrderKey`, `isCreateOrderKey` (prefix `createOrder:`, the restock nonce) |
| `qml/helper/OrderPlan.js` (new) | `build({ key, order })` -> `{ ok, key, opType, ops, at }` or `{ ok:false, reason }`; `reflect(results)` -> `{ ok, orderId, order }` or `malformed-results` |
| `qml/helper/FailureCause.js` | `forCreateOrder(rejection, customer)` |
| `qml/helper/DescribeItem.js` | `OPERATION.createOrder = "New order"` (the customer is the detail: `_opDetail` already reads the order op) |
| `qml/helper/AddProductPlan.js` | two exports, `isIsoInstant` and `isIsoDate`, taken out of `build` so the two planners share ONE time check |

## 2. Decisions (all vetoable in the PR)
**D-NO2-1: the planner takes the doc `OrdersStore._normalizeOrder` already builds; it does not build totals.** Options: A (taken) the store keeps authoring the doc and its totals, the planner wraps it, swaps the id for the token and checks it; B re-implement `computeOrderTotals` in the planner (a second source of truth for tax and discount rules: rejected); C move `computeOrderTotals` into a pure `.js` shared by store and planner (single source, but it rewrites live code that every order path uses inside a dormant slice: deferred, KNOWN-ISSUES 94). Cost of A: the planner must not trust the doc blindly (D-NO2-3).

**D-NO2-2: a new order is `pending`, epoch 0, no adjustments, no consumption.** The server checks the structure only (D-NO-5b). A create with `status: "completed"` would be a sale that never touched stock or the ledger, because stock is taken by the SECOND operation (D-NO-6). The planner refuses it (`bad-status`). Consequence recorded in KNOWN-ISSUES 96: a caller that must create a non-pending order (the import, step 4) cannot use `createOrder`.

**D-NO2-3: invariants, not rules.** The planner checks what holds for ANY correct doc: items = sum of quantities, subtotal = sum of quantity x price (rounded to cents), 0 <= discount <= subtotal, tax >= 0, total = subtotal - discount + tax (rounded), tax rows finite and in 0..100. It does not know the discount and tax rules. Why this much: the money of a sale is the one field nobody can fix afterwards, and a refused order costs nothing (nothing is queued). Why not more: every extra rule is a place the planner and the store can disagree. The chain probe P-1 (2500 random carts through the REAL `_normalizeOrder` and the REAL server) pins that they agree (KNOWN-ISSUES 94 says what to run when the store's rounding changes).

**D-NO2-4: per-line and per-field bounds** (`bad-line`, with the line index): whole quantity >= 1, price >= 0 finite, tax percent 0..100, discount type `flat`/`percent` and a finite non-negative value, a non-empty name, `consumption` empty, and a unit price of at most 1e9 (`RestockFlow.MAX_UNIT_COST`, the app's one price limit; added in the review sweep because New Order's unit-price field has no cap of its own, KNOWN-ISSUES 101). Cart empty = `bad-line`, index -1. The UI already guarantees all of it (customer >= 2 characters, at least one product, stock): the planner is the guard for every other caller and for a future UI change. It refuses only an EMPTY customer after trimming; the 2-character rule stays a UI rule.

**D-NO2-5: every typed string is trimmed and neutralised** (customer, email, phone, notes, channel, staff id, line name and product id) with the one `neutralisePlaceholders` of AP2 (closes KNOWN-ISSUES 75 for the new path). Output is a WHITELIST of the keys `_normalizeOrder` returns, so an extra key on the input never reaches the server. A drift test (B-3) compares the key lists with the REAL normaliser. Trimming is a small change against the old path, which stored the raw text (KNOWN-ISSUES 95).

**D-NO2-6: times are checked, not trusted.** `date` and `updatedAt` must be a real day and a real instant (the AP2 round trip). The check lives in `AddProductPlan.js` as two exports; `build` there uses them too, so there is one copy.

**D-NO2-7: `reflect` reads only the answer.** Exactly one `mint` bound `ord` and one `order` mutation, id `ORD-` + 3 or more digits, the doc's `orderId` and the result's `entityId` equal to the minted id, status `pending`, at least one line. Anything else is `malformed-results`, never applied. It works after a relaunch (no plan needed) and on a replay (a replay returns the FIRST answer, which is `pending` even if the order was completed since).

**D-NO2-8: cause texts.** `conflict` (another device took the same number), `mint-exhausted`, `request-id-in-use` have person wording that says "Nothing was saved"; `not-found`, `insufficient-quantity`, `operation-too-large` and `invalid-order` are app bugs (a create reads no record and takes no stock). The drift test C-2 now runs the three planners over every server code.

**D-NO2-9: dormancy.** NO1's G-1 guard (no QML names `createOrder`) is widened to the three helpers that must (`OperationKeys`, `OrderPlan`, `DescribeItem`); a new guard (G-1 in `createOrderPlan.test.js`) pins that no store, page or dialog names the planner or its keys. NO3 replaces both with a wiring guard.

## 3. What NO3 will have to do (not in this slice)
`OrdersStore.addOrder` stops minting over REST and sends `recordOperation("createOrder", plan.ops, key, { awaitServer: true })` (offline refused with a clear text, as AP3a); the callback becomes `(ok, id)` from `reflect`; `DataModel` routes `operationApplied/Rejected` for the op and adds the order to the store from the answer; auto-approve starts `_tryCompleteOrder(id)` AFTER the answer (D-NO-6); `NewOrderDialog` keeps its busy state until the callback. The no-lines branch of `addOrder` (`items`/`total` arguments) is unreachable from the dialog and refused by the planner: NO3 deletes it (KNOWN-ISSUES 97). The three questions NO3 needs are in section 4.

## 4. Questions for Taher (recommendation taken above; veto in the PR)
1. **Q-NO2-1 order again (Q-NO-1 was not answered, only merged past).** Honest value check from NO1 still holds: after the mint, a new order is already one document write, so NO3 buys less than restock or add product did (no burned or repeated number, the order counter gets one minter). `_tryAdjustOrder`, `completeImportedOrder` and `_reverseCompletedOrder` are where a half-applied write corrupts stock or the ledger. Recommendation: do NO3 (small, mechanical, proven twice) and then those three, but if you only have appetite for ONE more risky change, it is `_tryAdjustOrder`, not NO3. Say so and the next session designs it first.
2. **Q-NO2-2 D-NO2-2** a new order must be `pending`. Do you ever need to create an order that is already completed (a back-dated sale entered after the fact)? If yes, it needs its own operation with stock in it, not this one.
3. **Q-NO2-3 D-NO2-4** the planner refuses an empty customer only. Should a one-character customer be refused here too (the dialog does)? Recommendation: no, the UI owns the wording of that rule.
