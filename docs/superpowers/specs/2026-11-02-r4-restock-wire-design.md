# R4: restock goes through one atomic operation

Date: 2026-11-02. Branch `feat/2026-11-02-r4-restock-wire`. Parent designs: `2026-10-16-restock-atomic-operation-design.md` (architecture, approved with #147), `2026-11-01-r3-restock-plan-design.md` (the planner R4 calls). Status: `docs/superpowers/ATOMIC-OPERATIONS-STATUS.md` sections 8 to 10.

## 1. What this slice is

The first slice that changes what a person sees. `InventoryStore.restock` used to make four separate writes (a supplier mint and create, a batch mint and create, a stock delta, a purchase row), each with its own failure window, and could leave a batch without stock or stock without a batch. It now plans ONE operation with `RestockPlan.build` and sends it with `Gateway.recordOperation("restock", ...)`. The server applies supplier, batch, stock, purchase and the ledger row in one transaction, mints the ids inside it, and answers with them.

In scope: the `restock` rewrite, a per-product latch, a hide of the product from the order picker and from sales while a restock is queued, the route that settles an answer that arrives after the caller left, the review observations O1 to O4 from `ATOMIC-OPERATIONS-STATUS.md` section 9, and the minimal dialog wording change. Out of scope (R5): dialog redesign, the `activity_log` entity inside the operation, an id parameter on `ActivityLog.record`, wording for `too-large` and `reserved-text` beyond the short texts here, a `maxLength` on the reason field.

## 2. How it works

1. Tap. `RestockFlow.makeInput` assembles the planner input (supplier resolved from the typed text, cost default, ONE `Date` for the timestamp and the local date). `RestockPlan.build` plans. Any refusal returns a person-facing text and queues nothing.
2. Guards. A parked write for the product refuses with the old message. A queued restock for the product refuses with a new one (R4-D1).
3. Send. `Gateway.recordOperation` enqueues synchronously. Online, the caller waits for the server (the existing await window); offline it is told at once that the restock is saved.
4. Settle. When the server answers (in the wait, later, or after a relaunch) `_applyRestock` runs exactly once: `applyRestockResults` fills supplier, batch, purchase and stock, then one Activity entry is written from the answer alone. A rejection tells the waiting caller the cause; if nobody waits it is announced once through the dispatcher. A discard is silent.

The Gateway always fires its signal after it answers a waiter. To keep the effects single, a live callback marks the key in `_restockSettled` and the signal handler consumes that mark and does nothing; an answer with no mark (queued, slow, relaunch) is applied by the handler.

## 3. Decisions (vetoable in the PR)

| # | Decision | Why | Trade-off and the alternative not taken |
|---|---|---|---|
| R4-D1 | The latch is the durable outbox item (`OutboxStore.hasQueuedOperationFor`), not a second in-memory flag. A second restock of the same product is refused while one is queued, in flight or parked. | Enqueue is synchronous, so the double-tap window is one tick and the outbox already closes it. It survives a relaunch and cannot drift from what is really queued. | A person who really receives two deliveries while offline cannot queue the second until the first syncs. They get a clear message and nothing is lost. Not taken: allow it (two operations, two batches, valid on the server), because the picker and sale hide must also reason about "what stock will be", and one open restock keeps that simple. Veto if two offline restocks of one product matter to you. |
| R4-D2 | The old `amount \|\| 10` default is gone: a zero, negative, text or non-finite quantity is refused with "Quantity must be greater than zero". | A silent 0 to 10 turned a mistake into real stock. Nothing in the UI sends 0 (the spin box is at least 1). | The `restockProduct` logic signal can no longer be used as "restock a default amount". Nothing uses it that way. |
| R4-D3 | The callback is `(ok, queued, refusal)`; the old `supplierFailed` is removed. | A supplier can no longer fail on its own, it is inside the transaction. `queued` is the new fact a caller needs to word its toast truthfully. | Same arity, different meaning of the second argument; both callers and all tests were changed in this PR. |
| R4-D4 | A product with a queued restock is hidden from the New Order picker and its sale is refused at completion (same family as the unsynced-edit refusal). | A queued restock has no local batch, so the stock on the device is not what the server will hold. Selling against it is the drift the order flow has been closing. | The product cannot be sold for as long as the restock is queued (usually seconds, hours if offline). The picker is rebuilt when the sheet opens or the cart changes, so a restock that settles while the sheet is open stays hidden until then; the completion guard is the backstop. |
| R4-D5 | Supplier resolution (O1): empty is none; a `SUP-` prefix is an id; a known name (trimmed, case-insensitive) is that supplier; anything else is a new supplier; whitespace-only is refused. | Same rules as `_resolveSupplierId`, but trimmed: the old path compared untrimmed text and made a duplicate for " Acme". | Two offline devices typing the same new name still make two suppliers (the server does not dedupe by name; the old path had the same race). Left for a later slice. |
| R4-D6 | A replayed answer leaves the stock alone (O3) and re-reads the inventory and the batches; an unreadable answer applies nothing and re-reads inventory, batches, suppliers and transactions. | A replay carries the figures as of the FIRST application. Trusting them could roll stock back. | Extra reads in a rare case; a short flicker is possible. |
| R4-D7 | One `Date` gives both the ISO timestamp and the local date (O4). | A tap near midnight could otherwise get a date and a time from different instants. | None. |
| R4-D8 | A rejection with nobody waiting is announced once through `dispatcher.errorOccurred("inventory", ...)` with the cause. After a relaunch the text has no product name. | Nothing exists server-side and nothing was applied locally, so there is nothing to undo; the person only needs to know. | A toast can be missed. The stuck-writes sheet still lists a parked item. Not taken: a persistent inbox entry (not built yet). |
| R4-D9 | The Activity entry is still written on the client, from the answer, at settle time. | Moving it into the operation is R5 (needs an id parameter). | A crash between the answer and the Activity write loses one entry; the stock and batch are safe. |
| R4-D10 | The pure decisions live in `qml/helper/RestockFlow.js`; `restock` stays glue. | They run in Node against the real server code. The QML glue is covered by the Node sandbox (real function bodies) and CI. | One more helper file. |

## 4. What was found and not done (recorded in the status doc, section 10)

`TransactionStore.recordPurchase` has no production caller now; it stays because its own tests and the R3 doc-shape drift guard use it. The restock dialog's "add new party" still creates the supplier through the old separate mint (an orphan supplier is possible if the restock then fails). G4 (sign-out clears the outbox, so a queued restock abandoned by sign-out is gone) is unchanged. `_restockSettled` keeps a key forever if its signal never comes (sign-out clears the outbox mid-flight); it holds a few bytes.

## 5. Verification

Node: `restockFlow.test.js` (helper, end to end through the real server), `restockWire.test.js` (the real bodies of `restock`, `_applyRestock`, `onRestockApplied`, `onRestockRejected` and `OutboxStore.hasQueuedOperationFor`, answered by the real server code), `restockSurface.test.js` P-1 rewritten from "dormant" to "one caller, no legacy writes". 23 hand mutants over the new code were all killed (see the test plan). QML tests and the emulator e2e case are written and run in CI only. Test plan: `docs/superpowers/test-plans/2026-11-02-r4-restock-wire-test-plan.md`.
