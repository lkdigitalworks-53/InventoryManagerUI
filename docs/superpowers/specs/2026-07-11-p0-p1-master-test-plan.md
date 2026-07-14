# Master Test Plan — P0 Compliance Gateway + P1 Stock-Movement Taxonomy

**Covers:** PR #32 (merged — P0 gateway gap-closure + Orders/Staff/Suppliers fast-follow) and
`feature/p1-stock-movement-taxonomy` (open — stock-movement data model + wiring).
**Supersedes:** `docs/superpowers/specs/2026-07-11-p0-gateway-test-plan.md` for anything P0 — that
doc's detail is folded in here; this is the one to work from for a full-feature pass.

Both features share one fact that shapes this whole plan: **`Gateway.mode` is still `"direct"`.**
Every write below still goes to Firestore exactly as it did before either feature — you are
testing that the new *indirection* (store → `Gateway.recordMutation`/`recordMutations` →
`FirebaseService`) reproduces the old behavior exactly, not that a real audit trail is being
written (it isn't yet, on purpose).

---

## 1. Automated unit tests

### P0 — verified, `cd functions && npm test` (48/48 passing)

| File | Tests | Covers |
|---|---|---|
| `gatewayLogic.test.js` | 16 | `recordMutation`'s validation + write logic; all 5 entity mappings (`inventory`, `stock_batch`, `order`, `staff`, `supplier`) |
| `cutoverLogic.test.js` | 10 | `runCutover`'s owner/confirm gates, marker shape, batch-chunking |
| `batchMutationLogic.test.js` | 13 | `recordMutationsBatch`'s validation, atomicity, idempotency |
| `breakdownMath.test.js` / `realisedMath.test.js` | 9 | Pre-existing, unrelated, untouched — confirms no regression |

### P1 — **none**

No Cloud Function code changed for P1 (the `stock_movement` entity was already registered by the
original P0 session), so there was nothing to add `node --test` coverage for. **100% of P1 is
QML**, and this repo's sandbox has no Qt toolchain — so P1 has **zero automated verification of
any kind** right now. Treat every P1 scenario below as something that has genuinely never been
executed, not just "unit-tested but not integration-tested."

### Written but unverified (both features) — run before trusting

```bash
qmltestrunner -input tests -platform offscreen        # tst_Gateway.qml, tst_OutboxStore.qml (P0)
firebase emulators:exec --only firestore "node --test test/"   # firestore.rules.test.js (P0)
```

P1 added no new automated test files at all (see above) — this is itself a gap worth deciding on:
you may want a `tst_StockMovementStore.qml` before merge, even though nothing in this session's
scope required it.

---

## 2. Regression tests

Run these before anything else — they catch the "did I break something old" class of bug, which
is the highest-blast-radius risk given how many shared singletons both sessions touched
(`Gateway`, `OutboxStore`, `InventoryStore`, `DataModel`).

- [ ] **App launches without QML errors.** Single most important check — `Gateway.qml`,
  `OutboxStore.qml`, `InventoryStore.qml`, `DataModel.qml`, `EditProductDialog.qml`, `Main.qml`,
  and `Logic.qml` were all edited across both sessions. A bad edit shows up as a console error or
  broken binding at startup, and nothing automated here can catch a QML load failure.
- [ ] `cd functions && npm test` → 48/48.
- [ ] **Existing Edit Product flows unaffected when stock doesn't change** — edit name/price/SKU/
  category/etc. with the stock field left exactly as-is: no kind picker appears, saves normally,
  no stock movement recorded (confirms the `delta !== 0` guard).
- [ ] **Existing Edit Product flows unaffected on a stock *increase*** — no kind picker required,
  saves normally (confirms increases silently default to `"adjustment"`).
- [ ] Inventory add/delete product, category management — untouched by either session, quick
  smoke pass since they share `InventoryStore`.
- [ ] Orders/Staff/Suppliers CRUD (P0) — full pass, see §3.
- [ ] Bulk CSV import (products and orders) — `ImportPreviewDialog`'s update path calls
  `updateProduct` with only 2 args (no `kind`); confirm this still works and doesn't throw with
  the new 4-arg signal signature (QML tolerates missing trailing args, but this is the one place
  that isn't obvious from reading the diff alone — verify it on device).

---

## 3. Functional tests (on-device, happy path)

### P0 — Orders
- [ ] Create, edit, delete an order; apply a line-item adjustment.
- [ ] **Approve All Pending** with: zero pending (no-op, no crash); one pending; a realistic bulk
  batch (a few dozen) — **highest-risk scenario in P0's whole change set**, replaced a working
  `FirebaseService.putMany()` call with new batch-gateway logic.
- [ ] Bulk-import new orders via CSV.

### P0 — Staff
- [ ] Add, update (all fields), delete a staff member.
- [ ] Set/change a staff member's app login link (`setAppUid` — a separate update site from the
  general field-update path, test independently).

### P0 — Suppliers
- [ ] Add, update, delete a supplier; confirm the list stays sorted by name after an update.

### P1 — Receipts
- [ ] Restock a product with a reason → confirm the restock itself behaves exactly as before
  (this is the regression-sensitive part); no direct way to observe the `stock_movements` row
  from the UI yet (no register report), but confirm nothing errors or hangs.

### P1 — Sales
- [ ] Complete an order with a single-batch line item (all stock drawn from one FIFO batch).
- [ ] Complete an order with a line item that spans **multiple** FIFO batches — confirms multiple
  `sale` movements get recorded for that one line (one per batch portion), not just one.
- [ ] Complete an **imported** order (status arrives as `"completed"`) — the second, separate
  code path (`completeImportedOrder`), including the understocked/top-up case.

### P1 — Returns
- [ ] Reopen a mistakenly-completed order (`_reverseCompletedOrder`) — confirm stock restores
  correctly, no visible behavior change from before this session.
- [ ] Adjust a completed order with a genuine **undamaged** return (`condition !== "damaged"`) —
  stock credited back to sellable inventory, same as before.
- [ ] Adjust a completed order with a **damaged** return (`condition === "damaged"`) — stock
  should **stay reduced** (not credited back), exactly matching pre-P1 behavior. This is the path
  that gained new movement-recording this session (`sales_return` + `destroyed`) with **zero
  visible change** to what the user sees — the whole point is it's invisible today.
- [ ] A return spanning multiple original-sale batches (multi-batch restore plan) — same
  multi-portion concern as the multi-batch sale case above.

### P1 — Manual stock adjustments
- [ ] Decrease stock via Edit Product, picking each of the 7 kind options in turn at least once
  over the course of testing: Lost, Stolen, Damaged/Destroyed, Written off, Free sample, Gift,
  Other adjustment — confirm the picker only appears when the new value is below the current one,
  and confirm the save succeeds once a kind is picked.
- [ ] Increase stock via Edit Product's stock field directly (not via Restock) — confirm **no**
  kind picker appears, save succeeds normally.

---

## 4. Negative tests

- [ ] **Submit a stock decrease in Edit Product without picking a kind** (leave the picker on
  "Select a reason…") → must be blocked with a validation error, same UX pattern as the other
  field validations in that dialog (name too short, invalid price, etc.) — should **not** save
  partially or crash.
- [ ] Attempt operations as a role without permission (non-owner/admin trying to update a
  product, add staff, etc.) — confirms the existing role gates in `DataModel.qml`'s Connections
  handlers still fire correctly; none of this session's changes touched the role checks
  themselves, but they sit right next to the code that did change.
- [ ] Network cut mid-write for any of the above (airplane mode during Approve All Pending, during
  a restock, during an order completion) — confirm existing error-handling/toast behavior is
  unchanged from before either session. Nothing in `"direct"` mode adds new retry/offline
  behavior (that only activates once `Gateway.mode` flips to `"gateway"`), so this should look
  identical to pre-P0 behavior.
- [ ] Force `Gateway.recordMutation`/`recordMutations` to receive an unregistered entity string
  (not directly reachable from the UI, but worth a code-level sanity check if you're auditing):
  confirms `""` is returned and nothing is silently written — already covered by
  `tst_Gateway.qml`'s `test_recordMutation_returns_empty_string_for_an_unknown_entity`, but that
  test itself hasn't been run (see §1) — worth a deliberate manual check if you want confidence
  here before merge.

---

## 5. Edge cases

- [ ] **Batch-import stock decrease with no kind supplied** (`ImportPreviewDialog`'s bulk-edit
  path) — should NOT crash; falls back to `"adjustment"` and logs a console warning
  (`updateProduct: stock decreased with no kind supplied for <productId>`). Worth deliberately
  triggering once to confirm the fallback path is real and not just theoretical.
- [ ] **`Approve All Pending` right at/near the 200-item batch cap** — `MAX_BATCH_SIZE` is 200
  server-side; this session didn't add client-side chunking for batches over that size, so a
  201st pending order in a single approve-all action would currently fail the whole batch
  server-side (once the gateway is actually live — today in `"direct"` mode it'll still just do
  a plain `FirebaseService.putMany`-equivalent path item-by-item, so this specific edge case
  isn't reachable in `"direct"` mode at all; it's a **pre-deploy** thing to remember, not a
  today-thing to test).
- [ ] **Order with a mix of new-consumption and pre-FIFO legacy lines** in the same completion —
  confirms `_recordSaleMovements`/`_recordReturnMovements`'s two branches (batch-portion detail
  vs. the no-lineage fallback with `valueAtCost: 0, batchRef: null`) both fire correctly within
  a single transaction without interfering with each other.
- [ ] **Edit Product: type a stock value, then change your mind and type the original value back
  before saving** — the kind picker should disappear again (it's a live binding on the current
  field text vs. `_originalStock`, not a one-time check), and no kind should be required to save.
- [ ] **Restock immediately followed by a manual stock decrease on the same product** — confirms
  the newly-created batch (from the receipt) is a valid target for the very next FIFO
  consumption/return plan, no stale-reference issues.
- [ ] **Zero-quantity or negative-quantity inputs** anywhere a quantity is user-entered (restock
  amount, adjustment delta) — existing input validation should reject these before any of this
  session's code even runs; confirm that's still true (regression, not new behavior).

---

## 6. Explicitly out of scope

- Anything requiring `Gateway.mode: "gateway"` to actually be live (real `audit_log` entries
  appearing, offline-queue drain-on-reconnect, rules actually rejecting a client write) — needs
  the full deploy → rules → cutover → mode-flip sequence against a real (ideally `dev`)
  environment. Not part of merging either branch.
- The P1 opening/closing-balance register report — doesn't exist yet, nothing to test.
- Load/volume testing beyond "a few dozen" for Approve All Pending — the 200-item cap is a
  server-side design constant, not something to stress-test against production data today.
