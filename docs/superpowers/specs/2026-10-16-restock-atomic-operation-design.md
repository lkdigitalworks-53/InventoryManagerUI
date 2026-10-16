# Design — Atomic operations with server-minted ids; restock is the first consumer

**Status:** v2, 2026-10-16. Q-A1..Q-A5 answered by Taher (section 6); one new open question Q-A6. Spec goes to PR review; implementation plan is written only after the PR is approved. No product code written.
**Prior art and gaps:** `docs/superpowers/ATOMIC-OPERATIONS-STATUS.md`.
**Branch:** `docs/2026-10-16-restock-atomic-operation-design`. **Path:** architectural.
**Origin:** `KNOWN-ISSUES.md` first entry (restock decided 2026-09-30) and Taher's standing direction in `E2E-TESTING-ROADMAP.md` (2026-09-16): idempotency and atomicity for network calls generally.

**Correction to v1 (my error):** v1 called server-side minting "the rejected option C". Nobody rejected it. Only "retry deltas on 403" was rejected. v1 also overstated the counter race: the client mint (`FirebaseService.mintCounterValue`) is a REST commit with an `updateTime` precondition on `counters/<name>`, the server would use an Admin transaction on the same doc; Firestore serialises both, so the loser retries. No collision. v1's D1 (client mint, online-only, id gaps) and D4's mint-at-tap are dropped.

## 1. Understanding (please correct)

**Said by Taher:** one tap = one operation with ONE transaction id, covering every call: id creation, product/order create-update-delete, transaction record, audit. All of it atomic and idempotent.
**Success:** after any failure, retry, double delivery or relaunch, either everything for that tap exists exactly once, or nothing does and nothing is burned (no id gaps from rejected operations). Offline taps queue and apply on reconnect.
**Assumed:** this arc builds the engine plus restock, the first consumer. Other consumers (create product with opening stock, import, order create, adjust, reverse) follow one PR each (Q-A5).

## 2. Why today's pieces cannot do it

`recordOperation` is atomic and idempotent but takes **fully formed docs**. Anything whose id comes from a counter (batch `BAT-…`, supplier `SUP-…`, product, order) must be minted by a separate network call first. That call is not part of the transaction, so it can fail (timeout), be repeated (burned number) or be lost (`_pendingMints` queue exists only to patch this). Restock additionally resolves or creates a supplier (another mint plus a write) and writes ActivityLog by a direct client PUT (`activity_log/<id>`, not a gateway entity).

## 3. Engine change: ids are minted inside the transaction

**New op kind `mint`** in `functions/lib/operationLogic.js`:
`{ kind:"mint", counter:"stock_batch", bind:"batch" }`.
- Server reads the counter doc, increments it, formats the id exactly like the client does (`BAT-<year>-NNN`, `SUP-NNN`), binds it to the name `batch`. The counter write is part of the same transaction, so a rejected operation rolls the counter back: **no gaps from rejections**.
- Later ops reference it with `{{batch}}` in `entityId` and in string values of `after` (also embedded: `"tx-p-{{batch}}"`). Substitution is done server-side before validation of each op.
- The marker's `results` record every minted id. A replay of the same `requestId` returns them and mints nothing. One `requestId` is the single transaction id; derived ids are `requestId~i` (audit rows), the minted ids (in results) and `tx-p-<batch>`.
- Counter registry is a server allowlist mirroring client formats, pinned by a parity fixture test (the repo's existing parity pattern).

**Guards (validation, all 400 and zero writes):** placeholder name matches `^[a-z][A-Za-z0-9]{0,15}$`; bound by an EARLIER `mint` op; at most 5 `mint` ops; substitution only in `entityId` and `after` string values (never `before`, `deltas`, keys); a resulting id passes `isSafeDocId`; unknown counter rejected.
**Write budget:** each `mint` adds one counter write; update the budget formula (#146 has one: `2*ops+1+rowBudget` vs 500).
**Counter missing (new tenant or new year):** server falls back to the max existing id for the prefix (one query, once) as the seed. The client sends no seed (a client-supplied seed is a trust-boundary hole). Detail verified in R1 (exact tenant-scoped counter path).
**Compatibility:** additive. `completeOrder` and old clients send no `mint` ops and behave exactly as today. Deploy functions before the client.

## 4. Restock as the first consumer

One tap creates `requestId = "restock:" + <device id>` **at tap** (same shape as `Gateway._nextRequestId`; durable once the outbox item is saved). Ops, one transaction:
1. `mint` supplier `sup` (only when the user typed a new supplier name);
2. `mutation create` `supplier/{{sup}}` (same condition);
3. `mint` stock_batch `batch`;
4. `mutation create` `stock_batch/{{batch}}` (supplierId = known id or `{{sup}}`);
5. `delta` `inventory/<productId>` `{stock:+qty}`, with explicit `receipt` movement once #146 is in;
6. `mutation create` `transaction/tx-p-{{batch}}` (purchase doc);
7. `mutation create` `activity_log/act-{{batch}}` if Q-A3 = yes.

Client `InventoryStore.restock`: keep the parked-write refusal (D2) and a synchronous per-product in-flight latch (enqueue is now synchronous, so the double-tap window is a single tick, not a network round trip); build ops with a pure `RestockPlan.build`; `Gateway.recordOperation("restock", ops, key, {awaitServer: online})`. Applied (callback or `operationApplied`, both carry minted ids in results): set stock from the server value, add the batch, purchase (and supplier, activity) docs locally from results. Rejected or Discard: nothing exists server-side, nothing to undo but the latch, show the cause text. **Removed:** `_resolveSupplierId`'s separate mint for restock, the parallel `addBatch` + `recordDelta`, the callback-gated writes. `addBatch`, `SupplierStore.addSupplier` and the pending-mint queue stay for their other callers until those get their own PR.

## 5. Generality check (paper walk-through, not built)

Create product with opening stock: `mint` product `p`, `mint` stock_batch `b`, `mutation create inventory/{{p}}`, `mutation create stock_batch/{{b}}`, `mutation create transaction/tx-c-{{p}}`. Order create: `mint` order, `mutation create order/{{order}}`. Both fit with no further engine change. Bulk import (hundreds of rows) does not: one operation caps at `MAX_OPS` (200) and the write ceiling, so import needs chunking with one `requestId` per chunk. That is a real limit of "everything in one shot" and is named, not hidden.

## 6. Decisions

Standing from Taher (2026-10-16): D2 purchase record inside the operation; D5 no per-opType server shape check; D6 no "Saved. Syncing…" caption; D7 hard dependency on the server deploy, `recordOperation` already live and device-tested, no fallback to the two-write path. D1/D4 of v1 replaced by section 3 and "key at tap".

### Answered (Taher, 2026-10-16)
- **Q-A1:** generic `mint` + `{{placeholder}}`, client builds the docs. (Server-authoritative builders not chosen.)
- **Q-A2:** a queued restock has no optimistic batch; the product is hidden from the order picker until the restock applies or is discarded. Accepted cost: after an offline restock the product cannot be sold until sync.
- **Q-A3:** `activity_log` entry is part of the transaction (needs `activity_log` on the server entity allowlist, a rules check, an id parameter on `ActivityLog.record`).
- **Q-A4:** the server derives the counter seed from existing ids when the counter doc is missing; the client never sends a seed.
- **Q-A5:** engine + restock first; then create-product, then order paths, then import (chunked); one PR each.

### Open
**Q-A6. A queued restock is lost on sign-out (gap G4).** `OutboxStore.clear()` drops queued items on sign-out so a pending write never replays under another account. `completeOrder` is safe because its key is derived from order + epoch (a re-run resends it). A restock key is random per tap, so a restock queued offline and then cleared by sign-out is gone while the UI said done. Options: (a) block sign-out while the outbox holds unapplied operations and say how many (**my pick**: the stuck-writes indicator already counts them, so it is a guard plus a message, and it keeps the "tap is durable" promise); (b) keep the current behaviour and say so in the restock toast; (c) derive the key from content (product + qty + cost + minute) so a re-run collides, which is fragile and can merge two deliberate restocks. This does not change the engine, so it does not block the PR; it must be answered before the restock consumer (R4) is built.

## 7. Build order for step (1) (each its own branch off `main`, after #146 merges)

| Step | What |
|---|---|
| R1 | Verify counter path, seed fallback, formats (`_batchIdPrefixForYear`, `SUP-`), `activity_log` rules. Parity fixtures. |
| R2 | Server: `mint` kind, substitution, guards, budget, replay results, `restock` opType, tests (Node, run before push). |
| R3 | `OperationKeys.restockKey`, `RestockPlan.build` (pure), local apply-from-results hooks (reuse Task 9 hooks). |
| R4 | `InventoryStore.restock` rewrite, latch, pending-restock picker hide (Q-A2). |
| R5 | `RestockDialog`, `FailureCause` texts, ActivityLog id param (Q-A3). |
| R6 | Docs, device test. |

## 8. Risks
- Server engine change touches `operationLogic.js`, the file every operation goes through: replay, marker and budget must stay byte-compatible for `completeOrder`. Regression tests pin the existing marker and result shapes first (R2 step 1).
- Two writers on the counter docs (server transaction, client REST mint for unmigrated paths). Safe by Firestore serialisation, but pin with an emulator test that interleaves both.
- Counter format drift between client and server: parity fixtures.
- Hidden product after offline restock (Q-A2) is a user-visible cost, accepted.
- Sign-out drops a queued restock (Q-A6, G4) until answered.
- #146 overlap: build after it merges.

## 9. Not in scope
Steps (2)-(4) of Q-A5; per-opType server shape validation (D5); app-wide request timeouts; removing the pending-mint queue (needed until all minting callers migrate).
