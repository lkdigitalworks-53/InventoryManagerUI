# Test plan — AP1: the `addProduct` operation (server only, dormant)

Branch `feat/2026-11-13-ap1-add-product-server-op`. Design: `specs/2026-11-13-add-product-atomic-operation-design.md` (D-AP-1..10). Standard format (Skill 49).
Honesty note: this slice changes NO QML, NO rules and NO `functions/index.js`. Every Node test below was RUN in the sandbox (functions suite 1720 -> 1754, all green; 100% line, branch and function coverage on `counterRegistry.js` and `operationLogic.js`). The three emulator cases are written but CI-only (no emulator here); their result is recorded in section 5 after CI. Nothing in the app sends the operation yet (AP3), so nothing user-visible can change: the device plan below proves the deploy broke nothing and gives one `curl` smoke of the new type.

## 1. Unit tests
| File | Cases | Run? | Covers |
|---|---|---|---|
| `functions/test/operationLogic.addProduct.test.js` (new) | 32 | RUN 32/32 | R-1/R-2 registry (`product`: `PRD-`, `counters/products`, entity inventory, year-independent, `PRD-1000` unpadded, junk ids); V-1 op type allowlist and `addProduct:` id namespace; V-2..V-4 accepted shapes (full, smallest, literal id); V-5 kind tied to opType (both directions, 8 junk kinds); V-6 completeOrder still refused; V-7 the row must name a product CREATED earlier (no create, create after, other product, update, delta, same id of another entity); V-8 stock token refused; V-9 placeholder entity rules for the product id (+ unused product mint); V-10 seven keys, create-only, one row; V-11 monkey (400 corruptions); V-12 restock regression; B-1..B-15 apply on the strict fake DB: real ids everywhere, ONE derived `receipt` row with caller and opType, exact write set and budget, replay, zero stock (no batch, no row), fractional stock, known supplier, counter behind data (skips, never overwrites), seed from ids (numeric, junk ignored), `PRD-1000`, two operations in a row, rollback leaves no trace and the retry gets the SAME id, existing feed row is a 409, server stamp wins, IST year; K-1 documented gap (non-numeric stock gets no ledger row); G-1 dormancy (no QML sends `addProduct`); G-2 source pins |
| `functions/test/counterRegistry.guard.test.js` | 3 (rows +5, mutants 7 -> 12) | RUN 3/3 | both client minters (single add, bulk import) still format and mint `PRD-nnn` from `counters/products` exactly as the server registry does; every inventory create uses the minted id; the guard is mutation-tested |
| `functions/test/index.handlers.recordOperation.test.js` | +2 | RUN | real validator in front of the mocked apply: an `addProduct` request is accepted and its mint result forwarded; a restock-kind row, a row about another product and the stock token are each 400 `invalid-activity` at the row and never reach apply |
| `counterRegistry.test.js`, `operationLogic.mint.test.js`, `operationLogic.activity.test.js`, `index.handlers.recordOperation.test.js` | 4 pins flipped | RUN | "product is not a registered counter" now uses `order`/`inventory`; the source pin "restock only" now lists `restock` and `addProduct`. Each flip is a deliberate decision (design D-AP-3, D-AP-5) |

Hand mutants (16 server mutants, each applied to the source, the four related test files run, source restored): prefix, counter name, registry entity, registry collection, kind table, kind check removed, "named" check removed, create-action check removed, entity check removed, entity-id check removed, token check removed, op type removed, opTypes list narrowed, branch forced for restock, one-row rule removed, title-token rule removed. **16 of 16 killed.**

## 2. Regression tests
- `completeOrder`- and `restock`-shaped operations are unchanged: V-12 pins that a restock still needs a DELTA to name its product and that a mere inventory create does not satisfy it; the whole older operation suites pass without edits beyond the four one-line pins above.
- `ENTITY_COLLECTIONS` has no `activity` entry (G-2 and the older G-1).
- Failure codes: no new server error code, so `FailureCause`'s drift test (`failureCauseCodes.test.js`) passes untouched.

## 3. E2E (real emulator, CI only)
`test/e2e/recordOperation.e2e.test.js` +3 (each records and restores both counter docs and deletes every doc it minted, in its own `finally`; the `test.after` sweep also clears `addProduct:opE2E*` audit and ledger rows):
- AP1 happy path: ids from the server, every doc lands, ONE `receipt` ledger row (`addProduct:opE2E-ap1~2~m0`), feed row stamped with a server actor and an ISO time, replay answers the first id and burns no number;
- a rejected add (literal create over an existing doc = 409 `conflict`) burns no product number and no batch number, writes no marker, does not overwrite the blocker; after removing it the retry succeeds and the counter equals the returned id;
- the feed row is tied to the op type and to a created product: wrong kind, another product and the stock token are each 400 `invalid-activity` at op index 5, nothing written.

## 4. Rules
Unchanged (the Admin SDK write skips them; `counters` and `inventory` writes by the client stay as they are).

## On-device test plan (Taher, after merge; functions deploy only, NO app build)
The app does not send `addProduct` (AP3). Deploy: the merge deploy step ships functions after your one-tap approval. Prerequisites: P1 signed in as owner on the dev tenant; P2 Firestore console open on `tenants/<t>`; P3 one existing product and one supplier.

### Happy path (regression of the shared file)
1. Add a product with stock 5 and a new supplier through the app (the OLD path). Expect: product `PRD-nnn` (counter `counters/products` +1), a supplier, a batch, a `created` history row, an Activity row, and one `receipt` row in `stock_movements`. Nothing different from before the deploy.
2. Restock that product by 2 (the `restock` operation, R6 of the restock arc). Expect stock 7 and a "Restocked: ..." row.
3. Complete an order of 1 unit. Expect stock 6.

### Smoke of the new type (optional, `curl` with the owner's ID token; deletes its docs afterwards)
POST `recordOperation` with `opType: "addProduct"` and the op list of design section 2 (one product mint, one batch mint, the four creates, the feed row). Expect 200, `results[0]` = `{ kind: "mint", counter: "product", bind: "p", id: "PRD-<next>" }`, the product doc with stock 4, ONE `stock_movements` row of kind `receipt` and qty 4, an `activity_log/act-PRD-<next>` row with `actorUid` and an ISO `timestamp`. Send the same body again: 200 with `idempotentReplay: true` and the same id; `counters/products` does not move. Delete the product, batch, transaction, feed row, ledger row, audit rows and restore the counter by hand afterwards (the app cannot see them as part of a flow).

### Negative
- Same request with the feed row kind changed to `product_restocked`: expect 400 `invalid-activity`, `opIndex` = the feed row, nothing written, counter unchanged.
- Same request with `opType: "addproduct"`: 400 `unsupported-op-type`.
- A body whose `requestId` does not start with `addProduct:`: 400 `invalid-request-id`.

### Edge cases
- Opening stock 0 (leave out the batch mint and the batch doc): expect the product and NO ledger row, NO batch.
- A fractional stock (2.5): ledger qty 2.5.
- Two requests with different ids sent at once: two different `PRD-` numbers, no gap, no duplicate.

### Affected areas
Add product (old path), restock, order completion, import (all still on their existing paths), Activity feed ordering.

### Regression
Import a CSV with 3 new products: ids continue from `counters/products` (the bulk minter writes the same counter doc; the server mint is only used by the new type).

### Monkey
Add products from the app (old path) on one device while a second device runs the `curl` smoke repeatedly with new request ids for 2 minutes: no duplicate `PRD-` ids, no permission or conflict toast, counter equals the highest id.

### Not testable on device until AP3
The app's use of the operation (id from the answer, photo, offline refusal): AP3 and AP4 carry their own plan.

## 5. CI result (fill after push)
Pending.
