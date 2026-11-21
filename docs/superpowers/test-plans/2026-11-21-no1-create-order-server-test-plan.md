# Test plan — NO1: the `createOrder` operation (server only, dormant)

Branch `feat/2026-11-21-no1-create-order-server-op`. Design: `specs/2026-11-21-create-order-atomic-operation-design.md` (D-NO-1..9). Standard format (Skill 49).
Honesty note: this slice changes NO QML, NO rules and NO `functions/index.js`. Every Node test below was RUN in the sandbox (functions suite 2108 -> 2147, all green; scripts 1061/1061; 100% line, branch and function coverage on `counterRegistry.js` and `operationLogic.js`, read from the whole-suite coverage report). The three emulator cases are written but CI-only (no emulator here); their result goes in section 5 after CI. Nothing in the app sends the operation yet (NO3), so nothing user-visible can change: the device plan gives a deploy regression pass and one `curl` smoke of the new type.

## 1. Unit tests
| File | Cases | Run? | Covers |
|---|---|---|---|
| `functions/test/operationLogic.createOrder.test.js` (new) | 35 | RUN 35/35 | R-1/R-2 registry (`order`: `ORD-`, `counters/orders`, entity order, year-independent, other counters unmoved, near-miss keys unregistered); V-1 op type and `createOrder:` namespace; V-2/V-3 accepted shapes (full, no lines); V-4 minted id only for the order entity (4 wrong entities + wrong counter); V-5 unused mint; V-6 update/delete cannot use a token; V-7 undeclared and later-declared tokens; V-8 mint rules; V-9 no feed row; V-10 product delete refused; V-11 monkey (600 corruptions, never throws); V-12 older op types unchanged; B-1..B-16 apply on the strict fake DB: real id everywhere, exact write set and budget, no ledger or feed row, replay (also after an edit), counter behind data (skip, one jump over 48 imported ids), seed from ids (numeric, junk, damaged values), healthy counter never lists, `ORD-1000`, two in a row, client-style mint then server mint, ATOMIC rollback leaves no trace and the retry gets the same id, literal id conflict, year independence, every field kept, typed-brace gap; K-1/K-3/K-4 documented gaps; G-1 dormancy; G-2 source pins |
| `functions/test/counterRegistry.guard.test.js` | 3 (rows +5, mutants 11 -> 16) | RUN 3/3 | both client minters (single add, bulk import) still format and mint `ORD-nnn` from `counters/orders` exactly as the registry does; the order doc id is `orderId`; the guard is mutation-tested |
| `functions/test/index.handlers.recordOperation.test.js` | +2 | RUN | real validator in front of the mocked apply: a `createOrder` request is accepted and its mint result forwarded; a wrong-entity token and a feed row are 400 at the validator and never reach apply |
| `functions/test/index.handlers.ownerOnlyWrites.test.js` | +1 endpoint row, +1 test | RUN | the whole entity x action x role grid now includes `createOrder`; a mint plus an order create passes for owner, admin, manager AND staff |
| `counterRegistry.test.js`, `operationLogic.mint.test.js`, `index.handlers.recordOperation.test.js` | 3 pins flipped | RUN | "order is not a registered counter" now uses `customer` / `staff`: a deliberate decision (D-NO-3) |

Hand mutants (8, each applied to the source, the six related test files run, source restored): prefix, counter name, registry entity, registry collection, op type removed, op type reordered, feed opened to `createOrder`, counter always "usable". **8 of 8 killed.**

## 2. Regression tests
- `completeOrder`, `restock` and `addProduct` validate and apply exactly as before (V-12; the whole older suites pass with only the three one-line pins above).
- `ENTITY_COLLECTIONS` and `OPERATION_ONLY_ENTITIES` are unchanged (V-9, G-2).
- No new server error code, so `FailureCause`'s drift test passes untouched.

## 3. E2E (real emulator, CI only)
`test/e2e/recordOperation.e2e.test.js` +3 (each records and restores `counters/orders` and deletes the order it minted in its own `finally`; the `test.after` sweep also clears `createOrder:opE2E*` audit rows):
- NO1 happy path: the id comes from the server, the order lands, ONE audit row, no ledger row, no feed row, a replay answers the first id and burns no number;
- a rejected operation (a second create over an existing doc = 409 `conflict`) burns no number and writes no marker; after removing the blocker the retry succeeds and the counter equals the returned id;
- an inventory create named `{{o}}` is 400 `placeholder-entity-mismatch` at op index 1, nothing written.

## 4. Rules
Unchanged (the Admin SDK write skips them; `counters` and `orders` writes by the client stay as they are).

## On-device test plan (Taher, after merge; functions deploy only, NO app build)
The app does not send `createOrder` (NO3). Deploy: the merge deploy step ships functions after your one-tap approval. Prerequisites: P1 signed in as owner on the dev tenant; P2 Firestore console open on `tenants/<t>`; P3 one product with stock 5; P4 an ID token for `curl` (optional steps only).

### Happy path (regression of the shared file)
1. Create a New Order for 1 of the product with a customer name (the OLD path). Expect: an order `ORD-nnn`, `counters/orders` +1, status pending (or completed if auto-approve is ON). Same as before the deploy.
2. Complete it (if pending). Expect stock 4 and a sale row.
3. Restock the product by 2 and add a product through the app. Expect both still work (the other two operations).

### Smoke of the new type (optional, `curl` with the owner's ID token; delete its docs afterwards)
POST `recordOperation` with `opType: "createOrder"`, `requestId: "createOrder:smoke1"` and the two ops of design section 2. Expect 200, `results[0]` = `{ kind: "mint", counter: "order", bind: "o", id: "ORD-<next>" }`, `orders/ORD-<next>` with `orderId` = the id, `audit_log/createOrder:smoke1` and `createOrder:smoke1~1`, NO `stock_movements` row, NO `activity_log` row. Send the same body again: 200 with `idempotentReplay: true`, same id, `counters/orders` unchanged. Delete the order, the two audit rows and restore the counter by hand afterwards.

### Negative
- Same request with `opType: "createorder"`: 400 `unsupported-op-type`.
- A `requestId` that does not start with `createOrder:`: 400 `invalid-request-id`.
- The second op's entity changed to `inventory`: 400 `placeholder-entity-mismatch`, opIndex 1, counter unchanged.
- The mint op alone, or the order create with a literal id and a mint nobody uses: 400 `unused-mint`.
- With a staff token: the smoke still passes (a new order is open to every role).

### Edge cases
- Counter 999 (set by hand): the smoke returns `ORD-1000`.
- An existing `orders/ORD-<next>` doc (set by hand): the smoke returns the NEXT free number and leaves the existing doc untouched.
- Delete `counters/orders`: the smoke seeds from the highest existing `ORD-` id and recreates the counter.

### Affected areas
New Order (old path), order completion, restock, add product, order import (still mints from the same counter), Activity feed (unchanged: no new row).

### Regression
Import a CSV with 3 new orders: ids continue from `counters/orders`.

### Monkey
Create orders from the app (old path) on one device while a second device sends the `curl` smoke repeatedly with new request ids for 2 minutes: no duplicate `ORD-` ids, no conflict or permission toast, counter equals the highest id.

### Not testable on device until NO3
The app's use of the operation (id from the answer, offline refusal, auto-approve after the answer).

## 5. CI result
PR #208, head `d721d66` plus the checkpoint commit (read 2026-11-21): Functions Tests success, Firestore + Storage Rules Tests success, E2E Tests success (the three NO1 emulator cases ran), QML Tests success (no QML changed; the order-counter guard reads `OrdersStore.qml` in the Node job). Deploy steps skipped on the PR, as for every PR.
