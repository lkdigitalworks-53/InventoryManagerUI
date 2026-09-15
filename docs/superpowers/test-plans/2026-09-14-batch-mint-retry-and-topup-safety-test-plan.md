# Test plan — fix/2026-09-14-batch-mint-retry-and-topup-safety

**Covers:** `qml/model/StockBatchStore.qml` (pending-mint retry queue, `topUpOldest` simplification),
`qml/pages/NewOrderDialog.qml` + `qml/pages/OrderDetailDialog.qml` (order-picker filtering).
Design: `docs/superpowers/E2E-TESTING-ROADMAP.md` item 1's "Resolved this arc" entry (2026-09-14) —
full root-cause trace and both decisions' rationale there, not repeated here.

**Read this first:** this fix has two parts, and they're separable in what they protect against.
Decision 1 (retry-on-reconnect + hide-from-picker) stops the *original* gap — a batch silently never
getting created. Decision 2 (`topUpOldest` always synthesizes) stops the *consequence* if a gap ever
happens anyway (from this cause or any other — manual edits, imports, legacy data are the other
documented causes). Testing both together is fine and mostly what this plan does, but E3 below tests
Decision 2 in isolation, since it should hold even for drift that has nothing to do with a failed
mint.

**Status (2026-09-14):** implemented, modeled in an automated test (`tests/tst_
PendingMintAndTopUpSafety.qml`, originally 11/11 passing), **N1 run on-device by Taher against this
plan's original scope — failed.** Restocking with a brand-new supplier and dropping connectivity
right after submit still lost the batch, and the dialog hung (didn't close) for over a minute with
the app left open, batch still never appeared in Firestore even after reopening. Root cause and fix:
see the roadmap's item-1 entry's follow-up note (same day) — no XHR timeout anywhere in the codebase
meant the mint could hang indefinitely rather than failing, so the retry queue this plan tests never
got a chance to engage. Fixed: `nextBatchId()` now races the real mint against a 15s safety-net timer
(4 new tests, `tst_PendingMintAndTopUpSafety.qml` now 15/15), and `restock()` no longer nests the
batch creation inside the stock delta's callback. **Re-run of N1/N2 against this updated code is what
this test plan is now waiting on** — still not run against the real singletons or the real dialogs on
a device, same category of gap as items 2 and 3's own test plans this session (`StockBatchStore.
addBatch`/`topUpOldest`/`nextBatchId` are read-only methods on a `pragma Singleton`, so the test
models the control flow rather than driving the real code).

---

## 1. Unit tests

### 1.1 Already covered (automated, in `tests/`)

`tests/tst_PendingMintAndTopUpSafety.qml` (11 tests) — failed mint queued not dropped; stays queued
across a retry that still fails; succeeds and clears on a retry that works, preserving the *original*
request's supplier/cost (not re-guessing them); independent products' pending state doesn't cross-talk;
overlapping retry calls don't double-process the same in-flight item; `topUpOldest` with existing
batches creates a new one and leaves the original's `qtyReceived`/supplier/cost completely untouched
(the direct regression guard for what Taher's test found); `topUpOldest` with zero batches still
synthesizes one (unchanged from before); zero-deficit is still a no-op; a top-up whose own mint fails
is queued the same way a restock's would be.

`tests/tst_StockBatchStore.qml`'s existing `topUpOldest` guard-clause tests (zero deficit, missing
productId) are unaffected — this fix didn't touch that early-return line at all.

### 1.2 Gap — not covered by any committed test

- Neither the real `StockBatchStore` singleton nor the two dialogs (`NewOrderDialog`,
  `OrderDetailDialog`) are exercised by any test. The picker-filtering logic specifically — does a
  product with a pending mint actually disappear from the combo box, and does selecting *around* it
  still resolve to the right product afterward — has zero automated coverage of any kind, model or
  otherwise; these are UI dialogs with no existing test precedent in this repo to build on. Section 3
  below is the only way to know this works as designed.
- The `Settings`-backed persistence itself (does `_pendingMints` actually survive a real app restart)
  needs `QtCore`, which isn't available in the sandbox this was built in — reasoned through against
  `OutboxStore`'s identical, already-relied-upon pattern, but not directly exercised.

---

## 2. Regression tests

- [ ] A normal restock or initial-stock-add, fully online, no interruption — batch appears
      immediately, same as before this fix. `_pendingMints` should stay empty; nothing about this
      path should feel different.
- [ ] A normal order completion where the FIFO ledger already covers the sale (no drift at all) —
      `topUpOldest` is never called, unaffected by anything in this fix.
- [ ] The order picker (both dialogs) shows every product exactly as before, for any product that
      has never had a pending mint.
- [ ] `tst_StockBatchStore.qml`'s existing guard-clause tests for `topUpOldest` — still pass unchanged.
- [ ] Bulk import (`addBatchWithId`/`addBatchMany`) — untouched by this fix, pre-mints ids in bulk via
      a different path entirely; confirm it still behaves identically.

---

## 3. On-device tests

### 3.1 Happy path

| # | Flow | Steps | Expect |
|---|---|---|---|
| H1 | Normal restock | Restock any product with a stable connection, no interruption | Batch appears immediately, product stays visible and orderable in both pickers throughout |
| H2 | Normal order, no drift | Place and complete an order against a product whose stock and batches already agree | Completes normally, no adjustment batch created |

### 3.2 Negative / race tests — Decision 1, the core scenario

| # | Scenario | Expect |
|---|---|---|
| N1 | **Taher's original reproduction.** Restock a product, submit, immediately go to airplane mode. Wait a few seconds, check the product in **both** the new-order picker and the edit-order picker while still offline. | Product does **not** appear in either picker's "add a line" combo — `hasPendingMint` should be true the moment the mint fails, not just eventually. No error or warning shown anywhere in the UI. |
| N2 | Continuing from N1: turn airplane mode back off, wait a few seconds for reconnect to be detected. | The batch appears (check both the product's batch history and Firestore directly, matching how N1 was originally confirmed). Still no error/warning shown at any point — the whole recovery should be invisible. |
| N3 | Continuing from N2: once the batch has appeared, check both pickers again. | Product is selectable again in both. |
| N4 | Same as N1, but this time try to actually **place an order** against the product while it's still offline and pending (before doing N2's reconnect). | Product isn't in the picker to select in the first place — confirm there's no other way to add it to an order while pending (e.g., search box, barcode scan if this app has one, any path that bypasses the combo). |
| N5 | **The new timeout behavior specifically.** Restock with a brand-new supplier name (not one already used), submit, go to airplane mode immediately. Stay offline for a full **20+ seconds** (past the 15s safety-net timer) before touching anything. | The restock dialog should close on its own well before the 20s mark — it's no longer waiting on the batch at all, only on the stock delta (which may itself still take a while if it's also stuck — see the roadmap's new "no XHR timeout" item; that half isn't fixed by this branch). Check `hasPendingMint` for the product once the dialog closes or once 15s has passed, whichever is checkable first — it should be `true`, confirming the mint's own timeout fired and queued it rather than still silently hanging. |
| N6 | Continuing from N5: reconnect, wait a few seconds. | Batch appears (same check as N2) — confirms the queued-via-timeout path resolves the same way a queued-via-fast-failure one does. |

### 3.3 Edge cases

| # | Scenario | Expect |
|---|---|---|
| E1 | Force-close and relaunch the app while a mint is still pending (right after N1, before reconnecting) | On relaunch, still offline: product still hidden from both pickers. Reconnect after relaunch: batch still appears correctly — confirms the pending queue actually survived the restart, not just an in-memory session |
| E2 | Two different products both restocked and dropped mid-flight before either reconnects | Both hidden from pickers; reconnecting resolves both independently — one succeeding shouldn't affect the other's pending state either way |
| E3 | **Decision 2 in isolation, unrelated to a failed mint.** Manually create a drift between `product.stock` and its batch ledger some other way if you have one available (or ask me to help engineer one deliberately for this test) — e.g. any existing "manual stock edit" feature bypassing the batch system, if one exists — then complete an order that exceeds recorded batch quantity. | A **new**, separate batch appears labeled "Adjustment (drift repair)" — the original batch(es) are completely untouched, not rewritten. If no way to trigger this independently of N1 exists, this is covered adequately by N1→order-completion already; skip if so. |
| E4 | Rapid reconnect/disconnect cycling right around when a pending mint would retry (airplane mode on/off several times quickly after N1) | No duplicate batches created from multiple overlapping retry attempts — exactly one batch per originally-failed request, regardless of how many reconnect blips happened in between |

### 3.4 Monkey testing

- Restock several different products in quick succession, toggling airplane mode on/off unpredictably
  throughout — at the end, once fully reconnected and settled, confirm every restock eventually
  produced exactly one batch each, no duplicates, no permanently-missing ones.
- Repeatedly open and close the new-order and edit-order dialogs while a mint is pending — confirm the
  picker's filtered list stays consistent (doesn't flicker the hidden product in and out, doesn't
  crash) across repeated opens.
- Force-close and relaunch multiple times in a row while various products are mid-retry — confirm the
  pending queue doesn't grow unboundedly or duplicate entries for the same failed request across
  relaunches.

---

## 4. Suggested order of attack

1. **N5/N6** — the timeout fix specifically, since this is what N1's failure actually traced to. If
   this doesn't hold, nothing else below matters yet.
2. **N1** — confirms the picker-hiding half of Decision 1 works at all.
3. **N2/N3** — confirms the retry-on-reconnect half actually completes the loop.
4. **E1** — the durability question; if this fails, a relaunch during a real outage would silently
   lose the pending request entirely, which would be worse than not having this fix at all.
5. **H1/H2** — quick sanity baseline.
6. **E2, E4** — the multi-item and rapid-flapping variants.
7. **N4** — checking there's no bypass path around the picker.
8. **E3** — only if there's an easy way to trigger drift independently; otherwise skip, N1's own
   order-completion step already exercises Decision 2.
9. Regression checklist — spot check.
10. Monkey testing last.

## 5. Explicitly out of scope for this test plan

- Whether `topUpOldest`'s new adjustment batches should carry forward a "best guess" supplier/cost
  from the newest existing batch instead of leaving them blank/zero — deliberately not done (the
  approved fix was "always synthesize," not "synthesize with inference"); a possible future
  refinement, not tested here since it wasn't built.
- Any UI copy/wording around the hidden-product state (e.g., a tooltip explaining *why* a product is
  briefly unavailable) — not requested, not built, nothing to test.

## 6. Sign-off checklist

- [x] N1 attempted on-device (2026-09-14) — **failed**, root-caused, fixed (see roadmap). Needs
      re-confirmation against the updated code — reopened below as N5/N6.
- [ ] N5/N6 confirmed on-device — the timeout-race fix specifically, and that a timed-out mint still
      resolves correctly once queued.
- [ ] N1 re-confirmed on-device against the updated code — the picker-hiding mechanism.
- [ ] N2/N3 confirmed on-device — the retry-and-recover loop closes.
- [ ] E1 confirmed on-device — durability across a relaunch.
- [ ] Regression checklist — spot-check at minimum.
- [ ] Remaining scenarios (N4, E2-E4, monkey testing) — opportunistic, not blocking.
