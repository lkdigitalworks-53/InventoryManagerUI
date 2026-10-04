# Test plan — restock and product delete refuse behind a parked write (D2, D3) + BC2 E2E fix

**Branch / PR:** `feat/2026-10-04-bc2-client-ack-gating` (PR #119), commits `ee6fe4d` (CI fix) and `2362d9d` (D2/D3).
**Design:** `../specs/2026-10-04-product-delete-batch-cascade-design.md` (section "Decisions recorded 2026-10-04").
**Status:** **written, NOT run** (no Qt toolchain in the sandbox, standing rule; CI is the first run). Commit identity `allibaas1998@gmail.com`.

## 0. What changed
`OutboxStore.hasParkedForEntity`; `InventoryStore.hasParkedWrite` / `parkedWriteMessage`; `restock` answers `callback(false, false, message)` and `deleteProduct` returns the message when the product has a parked write (server-rejected, waiting for Retry/Discard). Nothing is written on a refusal. `DataModel` and `RestockDialog` show the message. Separate fix: `tst_StockBatchStoreE2E.qml` now declares `DataModel { id: dm }` (BC2 409 E2E failed on CI because no DataModel instance existed to re-read batches).

## 1. Unit / functional (QML, CI-only)
`tests/tst_OutboxStore.qml` +9: parked single item true; pending-but-unparked false; stuck-but-not-terminal false; other id / other entity / empty id false; delta, batch (both members) and operation items; false after `markSent`; survives relaunch (`_load`); one of two items parked still true; empty queue false.
`tests/tst_ParkedWriteGuard.qml` (new, 18): `hasParkedWrite` (none / only the parked product / same id under another entity); delete refused changes nothing (product, batches, outbox, `_pendingDeletes`, Activity); other product still deletes; delete allowed after the park is cleared; unparked pending write does not block; unknown id quiet no-op; restock refused writes nothing (no batch, no delta, stock unchanged), no callback does not throw, unknown product keeps the plain failure, other product not refused; DataModel routing (message via `errorOccurred`, `productDeleted` / `productRestocked` not emitted, no park still emits, role guard wins); 60-step seeded monkey (park / clear / delete / restock on two products).
## 2. Rules / functions
Not applicable: no `firestore.rules`, `storage.rules` or `functions/` change. Run the existing suites as regression only (CI does).
## 3. E2E (emulator, CI-only)
`tst_StockBatchStoreE2E.qml` +2 (parked item seeded directly in the outbox): D3 delete refused, product + batch docs still on the emulator, no Activity entry, delete works after the park is cleared; D2 restock refused synchronously, no batch written, only the parked item queued. Existing BC2 409 case now has the `DataModel` instance it needs.
## 4. On-device (Taher)
Prereq: BC1 deployed to `inventorymanager-48392` (confirmed by Taher 2026-10-04), BC2 build.
- **4.1 Happy path:** edit a product so the write is rejected (description over 1 MiB), wait for it to appear in the rejected list. Tap Restock => confirm: toast "Fix or discard the stuck change for this product first", dialog stays usable (not stuck busy), stock unchanged, no new batch in Firestore. Tap Delete => confirm: same toast, product stays in the list, nothing sent. Discard the parked edit in the stuck-writes dialog, then Restock and Delete both work.
- **4.2 Negative:** a product with NO parked write restocks and deletes as before. A different product restocks/deletes while the first is parked. Staff / manager still get the role message, not this one.
- **4.3 Edge:** Retry on the parked write (server rejects again, still parked) => still refused. Park, relaunch the app => still refused (parked state persists). Product with parked write for a different field (price) => refused. A merely retrying (not parked) write does NOT block.
- **4.4 Multiple scenarios:** two devices: A parks an edit, B restocks the same product (B is not blocked, B has no park; known limit, server decides). Order completion that touches a parked product: NOT guarded (known gap, see KNOWN-ISSUES), expect the old hang behaviour.
- **4.5 Monkey:** 5 minutes of random edit / Discard / Retry / Restock / Delete on two products on one device; at the end every product that shows in the list exists in Firestore, batch count per live product equals Firestore, Inventory Value unchanged by refused actions.
- **4.6 BC2 409 regression (CI fix):** device A edits price while device B (stale) deletes: B shows the restored toast, product AND batches reappear.

## 5. Regression watch
`tst_InventoryStore_deleteProductCascade`, `tst_DataModel_deleteGuards`, `tst_DataModel_discardResync`, `tst_OutboxStore`, `tst_Gateway`, photo cascade e2e, order-completion e2e (shares `OutboxStore` keying).
