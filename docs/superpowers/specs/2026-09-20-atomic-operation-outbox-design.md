# Atomic, replay-safe multi-write operations through the outbox — design (fixes C-3)

**Date:** 2026-09-20
**Status:** Design approved by Taher (decisions D1-D5 below). PR #75 (stuck-write indicator) has merged, so
the client phases are unblocked; Phase 1 (server endpoint) is PR #78.
**Fixes:** the `DataModel._tryCompleteOrder` entry in `docs/superpowers/ASYNC-REENTRANCY-BUGS.md`
(labelled C-3; the `RestockDialog` entry that shared that label was renumbered C-4 in PR #76).
**Plan:** `docs/superpowers/plans/2026-09-20-atomic-operation-outbox.md`
**Test plan:** `docs/superpowers/test-plans/2026-09-20-atomic-operation-outbox-test-plan.md`

## 1. Problem

Completing an order is one business action but five kinds of write: FIFO deltas on `stock_batch` docs
(plus a synthetic drift-repair batch on shortfall), a stock delta per line on `inventory`, the `order`
update, and one sale doc per line on `transaction`. `_tryCompleteOrder` fires them as separate
`Gateway` calls, each with its own fresh `requestId` (`Gateway._nextRequestId()` mints
`"req-" + Date.now() + "-" + random` per call).

Confirmed on-device (C-3): a `deductStock` request hung, the in-memory `_completingOrderIds` guard
(correctly) blocked same-session retries, the user signed out and in, and the re-run planned a new FIFO
consumption with new request ids. The server cannot recognise them as the same operation, so a 1-unit
order took a batch from 10 to 8 while `product.stock` dropped by 1.

Why the existing safety nets do not cover this:

- The server already dedupes per `requestId` (`audit_log/{requestId}`), so a single retried outbox item is
  safe. The gap is one layer up: nothing gives the *operation* a stable identity across attempts.
- `OutboxStore.clear()` runs on sign-out on purpose (a pending write must never replay under the next
  account), so a queued operation that had not landed is dropped while one that had landed stays landed.
  The re-run cannot know which happened.
- No Gateway request has a timeout (below), so a hung request neither fails nor retries; its outbox item
  keeps its in-flight key for the rest of the session.
- On partial failure `_afterAllDeltas` compensates client-side with `restoreFifo` and
  `creditStockNoBatch`. Compensation is itself a set of network calls that can fail or hang.
- Sale docs get `txId = "tx-s-" + Date.now() + "-" + random` (`TransactionStore._nextId`), so a re-run
  would also double-book revenue. This was not in the original C-3 report; it follows from the same cause.

## 2. Requirements (all from Taher)

1. Offline handling through the outbox/Gateway pattern stays (Taher's answer to Q3).
2. Two devices, with the same or different user ids, can complete orders for the same product at the same
   time (Taher's answer to Q4). Client-side planning from a local cache cannot be correct alone under that.
3. The fix must be general, not a patch for one call: any multi-write business operation should get the
   same guarantees (his direction in the tracker entry, and "uniform across all network calls").
4. Tests aim at 100% coverage; the sandbox has no Qt toolchain, so anything that can live in Node or in
   pure `.pragma library` JS should.
5. He deploys Cloud Functions himself; only a dev environment exists.

## 3. Decisions

| # | Decision | Made |
|---|---|---|
| D1 | Approach D: one atomic, idempotent multi-write operation carried by the outbox | Taher, 2026-09-20 |
| D2 | "Server first when online" is piloted on compound operations only, as a Gateway option, not an app-wide rewrite | Taher, 2026-09-20 |
| D3 | An offline-queued completion that the server cannot cover is applied anyway with a drift-repair batch (the sale happened) | Taher, 2026-09-20 |
| D4 | Taher deploys the Cloud Functions; dev only, no prod yet | Taher, 2026-09-20 |
| D5 | Timeouts count toward PR #75's "stuck write" indicator | Taher, 2026-09-20 |

### Approaches considered

- **A. Stable operation keys only.** Smallest diff, no server change. Rejected: the FIFO plan comes from
  mutable local state, so a partial drain or another device changes which batches a retry would pick, and
  a different plan means different keys. Same key with a different payload would also be silently replayed.
- **B. Write-ahead intent on the order plus stable keys.** Closes A's holes for one device, but with
  concurrent devices the resume path has to handle floor rejections mid-resume, needs an order schema
  field with rules and old-client compatibility, and all of it is QML that cannot run in the sandbox.
- **C. Server-side `completeOrder` transaction.** Truly atomic, but it re-homes FIFO, drift repair,
  reject-not-clamp and sale-doc building (tax/discount allocation) onto the server, in one large change.
- **D (chosen).** The client plans (pure function), the server applies the plan atomically. The server
  stays generic: no FIFO logic, only "apply this list of ops in one transaction, floors checked inside,
  replay-safe by request id".

### On "server first when online" (Taher's question)

Valid instinct, kept as a pilot (D2). Catches that shaped the decision:

1. "Online" is not reliable: `AuthService.isOnline` is OS connectivity from `Main.qml`, not "the server
   answers". Server-first therefore needs a timeout and a fallback to the outbox, and that fallback is only
   safe when the retry carries a stable key. So it depends on this design rather than replacing it.
2. Every tap would wait on network latency (Cloud Function cold starts included).
3. It means two code paths per operation, which is more to test and more to drift.
4. It does not by itself make a multi-step operation atomic.

With one atomic operation the pilot is cheap: the response carries the authoritative `after` for every
touched doc, so "wait for the server, then reflect it locally" is one code path with the offline case as
its fallback. Extending it store by store later is a separate decision.

## 4. Design

### 4.1 Flow

```
DataModel._tryCompleteOrder(orderId)
  guard: completed -> done; in-flight -> "already being completed"
  epoch = OperationKeys.nextEpoch(order)            (order.completionEpoch + 1)
  plan  = CompletionPlan.build(inputs, hooks)       pure: ops[], key = completeOrder:{orderId}:{epoch}
       -> not ok: "out of stock" exactly as today
  Gateway.recordOperation("completeOrder", plan.ops, plan.key, { awaitServer: isOnline }, cb)
       durable in the outbox FIRST, then sent
  online:   wait up to awaitTimeoutMs for the server's answer, reflect results.after locally
  timeout / offline: apply plan.predicted locally, show "saved, syncing", keep the in-flight guard
            until the outbox item resolves; the drain resends the SAME key
Server recordOperation
  one Firestore transaction: read marker -> replay? read every doc -> apply all ops in memory
  any floor / CAS / not-found failure -> reject the WHOLE operation, write nothing
  else write docs + one audit entry per op + the marker (id = requestId)
```

### 4.2 Server (`functions/lib/operationLogic.js`, `recordOperation` in `functions/index.js`)

Request: `POST { env, requestId, opType, clientTimestamp, ops: [op, ...] }` with a Firebase ID token, same
auth and tenant derivation as `recordDelta`. `opType` is allowlisted (`completeOrder`); adding a type is a
deliberate server deploy. Each op is either

- `{ kind: "delta", entity, entityId, deltas, floors, clamps }`, or
- `{ kind: "mutation", entity, entityId, action, before, after }` (`create`/`update`/`delete`, CAS on `before`).

Each op is validated by the existing `validateDeltaRequest`/`validateMutationRequest` with a derived per-op
id (`{requestId}:{index}`), so entity and action rules stay defined in one place. Limit: 200 ops
(`MAX_OPS`), so at most 200 doc writes + 200 audit entries + 1 marker = 401 writes, under Firestore's
~500 per transaction. Client mirrors it as `Gateway.maxOperationOps`; both sides pin the value in a test.

Semantics:

- **Replay:** if `audit_log/{requestId}` exists, return `{ ok: true, idempotentReplay: true, results }`
  from the marker and write nothing.
- **Atomic:** every distinct doc is read once (all reads before any write), ops are applied in memory in
  order so later ops see earlier ops' effects (two deltas on one doc compose), and only if every op is
  acceptable does the transaction write.
- **A rejection leaves no trace.** No working-doc write, no audit entry, no marker. So the same
  `requestId` can be sent again later with a re-planned payload. This is what makes a deterministic key
  safe (section 4.4).
- **Rejections:** `409 insufficient-quantity` (`opIndex`, `field`, `current`), `409 conflict` (`opIndex`,
  `current`), `404 not-found` (`opIndex`), `400` validation errors (`opIndex` where per-op).
- **Audit:** per-op entries `audit_log/{requestId}:{i}` in the existing entry shape plus
  `operationId`, `opType`, `opIndex`; the marker `audit_log/{requestId}` has `action: "operation"`,
  `opCount` and the `results` array (`{ entity, entityId, kind, after }` per op). The marker holds full
  `after` docs, so its size is bounded by the 200-op cap.
- **Rules:** unchanged. `audit_log` and the ledger collections are already client write-locked
  (`allow write: if false`), and the function writes with the Admin SDK.
- **Deploy order:** functions first, then the client. Old clients keep the old path; they are no worse
  than today.

### 4.3 Client transport

- **Outbox item kind `op`:** `{ requestId (= opKey), opType, ops, clientTimestamp, enqueuedAt, attempts,
  nextAttemptAt }`. Never coalesced (`enqueueDelta` already skips items without top-level `deltas`).
  `_keysForItem` returns every `entity/entityId` the ops touch, so the outbox's existing per-key
  in-flight blocking orders the operation against other writes to the same docs, like a batch item.
  `enqueueOperation` returns the existing item when that `requestId` is already queued.
- **`Gateway.recordOperation(opType, ops, opKey, options, callback)`**: validates (gateway mode, 1..200
  ops, non-empty key), enqueues durably, drains. Terminal outcomes are delivered two ways: the callback
  (in-memory, lost on relaunch like `_deltaCallbacks`) and signals `operationApplied(requestId, opType,
  results, replay)` / `operationRejected(requestId, opType, rejection)` (so a relaunched app can still
  reconcile). Rejections are terminal (4xx with a well-formed body, as in `_classifyDeltaResponse`);
  network errors, timeouts and 5xx retry with the existing backoff.
- **Per-key ordering fix.** `OutboxStore.dueItems()` checks in-flight keys once, before anything is sent, so
  two due items that share a key (an operation and a later plain edit of the same order) would both be
  dispatched in one drain and race. `dueItems()` now also skips an item whose keys overlap an item already
  chosen in the same pass; the later one goes out on the next drain. This tightens ordering for every item
  kind and is needed because an operation touches many keys.
- **Shared send helper.** The three existing senders and the new one each have their own XHR code today.
  They move onto one helper that owns the request, the timeout `Timer` (racing the XHR, then `abort()`,
  the same pattern as `AuthService._postJson` and `StockBatchStore.nextBatchId`), the response snapshot
  (`_captureBeforeStatusIsLost`) and a single failure path. This is also where the circuit breaker would
  later plug in. The XHR is created through a `xhrFactory` property so tests can inject a fake, which is
  the only way to cover this code headlessly (no HTTP mock layer exists in the repo today).
- **Timeouts:** `SendPolicy.TIMEOUT_BACKGROUND_MS = 30000` for drains, `TIMEOUT_AWAIT_MS = 10000` for the
  foreground wait. Starting values, not measured; tune on a device (Cloud Function cold start is the thing
  to watch). A timeout is a network-class failure: `markFailed` and backoff, not terminal.
- **Retry:** schedule unchanged (2s, 8s, 30s, 2m, 10m capped), plus +-20% jitter (`SendPolicy.jittered`)
  so two devices reconnecting together do not retry in lockstep. Jitter is applied where `markFailed`
  computes `nextAttemptAt`.
- **Stuck writes (D5):** a timeout is reported to `StuckWrites.noteFailure` as `StuckWrites.TIMEOUT` with
  the current `AuthService.isOnline`. It counts only while online; a timeout while offline is expected.
  It shares the counter with server-side failures, so the 5th failure of any counted kind marks the write
  stuck. Numeric statuses ignore the flag, so the existing behaviour is unchanged.
- **Await mode (D2):** with `awaitServer: true` and the device online, the callback waits for the
  terminal result. If `awaitTimeoutMs` passes first, the callback fires once with `{ ok: false, pending:
  true, error: "timeout" }` and the item stays in the outbox; the eventual outcome arrives via the
  signals. Offline, or without the option, the callback fires immediately with `{ ok: true, queued: true }`.

### 4.4 Identity: keys and epochs

`opKey = "completeOrder:{orderId}:{epoch}"`, where `epoch = (order.completionEpoch || 0) + 1`, stored on
the order by the operation itself (its order update sets `completionEpoch: epoch`, with CAS on `before`).

- Same order, same epoch, any number of re-runs (hang, restart, sign-out/in): same key. The server either
  replays the first result or applies once.
- A reopened order (`_reverseCompletedOrder` restocks it and the status goes back to pending or processing) keeps its `completionEpoch`, so its
  next completion is epoch+1 and gets a new key. An old client that completes an order does not bump the
  epoch; the next new-client completion still gets a key no earlier marker used, because the epoch is read
  from the doc, never derived from history.
- Deterministic ids for what the operation creates: sale docs `tx-s-{orderId}-{epoch}-{line}` (keeps the
  `tx-s-` prefix; only `TransactionStore` reads `txId`) and drift-repair batches
  `BAT-RPR-{orderId}-{epoch}-{line}`. Nothing parses batch id shape (verified: FIFO orders by
  `receivedDate`), and no `nextBatchId` network mint is needed, which removes another way completion could hang.
- **A replay with a different payload** (a re-run planned from different local state) returns the *first*
  results. The client must treat `replay: true` as "my plan is irrelevant": apply `results[].after` to the
  local caches instead of its own prediction. This is the C-3 scenario resolving correctly.

### 4.5 The pure planner (`qml/helper/CompletionPlan.js`)

`build(input, hooks)` turns the inputs into the ordered op list. It reads no store and sends nothing.
Order: batch deltas and repair-batch creates, one stock delta per line, the order update, one sale doc per
line. It also returns the lines with `consumption` stamped, the predicted post-state and the key.

- FIFO runs over a working copy of each batch's remaining quantity, shared across lines, so two lines of
  the same product continue where the first stopped.
- Stock validation sums demand per product. Today two lines of one product each pass on their own and the
  order then fails at the second deduct; the planner rejects it up front. Deliberate improvement.
- Shortfall against the batches becomes a repair batch (`qtyReceived = gap`, `qtyRemaining = 0`,
  `unitCost 0`, note `Adjustment (drift repair)`) with a matching consumption entry, the same end state
  as today's `topUpOldest` + re-consume. `clampStock` (D3 re-plan) turns the stock delta's floor into a clamp.
- Lines with quantity 0 pass through with `consumption: []`. Input lines are never mutated, and stale
  `consumption` on a reopened order's lines is replaced, not appended to.
- More than 200 ops returns `too-many-ops` with a user-readable message. Known limit, not worked around.
- The order update and sale docs come in through `hooks` (`OrdersStore.buildOrderUpdate`,
  `TransactionStore.buildSaleDocs`) so the planner stays pure and the stores keep owning their shapes.

### 4.6 Rejection handling and D3

- **Online, awaiting:** a rejection is definitive and nothing was written.
  - Stock floor on an `inventory` op: same message and `out of stock` status as today.
  - Floor or conflict on a batch or order op: another device changed the docs. Reconcile the local cache
    from `current`, re-plan and resend under the **same key** (safe, no marker exists). Bounded at 3 attempts,
    then `out of stock` with a retry message.
- **Queued (offline or after an await timeout), rejected at sync (D3):** the sale already happened and the
  order already shows completed. Re-plan with `clampStock: true` and resend under the same key. The shortfall
  becomes a repair batch and product stock clamps at 0. No user prompt. The result is auditable: repair
  batches are labelled, and clamped deltas appear in the per-op audit entries.
- CAS conflict on the order op (someone else edited or completed it): reload the order; if it is now
  completed, the operation's job is done (treat as applied); otherwise re-plan from the fresh doc.

### 4.7 Local state

Stores get local-only entry points so the operation's effects can be reflected without sending anything:
`InventoryStore.applyRemoteStock`, `StockBatchStore.applyRemoteBatches`, `OrdersStore.applyRemoteOrder` and
`OrdersStore.buildOrderUpdate` (the pure half of `updateOrder`, which is refactored to use it),
`TransactionStore.buildSaleDocs` / `appendLocal`. Offline or after a timeout, `plan.predicted` is applied
immediately; on the server's answer, `results[].after` overwrites it.

## 5. Failure modes

| Situation | Outcome |
|---|---|
| Request hangs (the original C-3) | Await timeout: "saved, syncing", guard stays; background timeout aborts, backoff, resend same key. Exactly once. |
| App killed mid-flight | Outbox is durable; on relaunch the item resends with the same key. Callbacks are gone; signals reconcile. |
| Sign-out while queued or in flight | Outbox is cleared (unchanged). Re-login re-plans, same key (same order, same epoch): replay if it had landed, apply if not. |
| Double tap / two completions in one session | In-flight guard (unchanged); if it were bypassed, same key means the server applies once. |
| Two devices, same product, same moment | Server serialises the transactions. The loser gets a floor rejection with `current`, re-plans, resends. |
| Offline completion, stock gone at sync | D3: re-plan with clamp and repair batch, apply anyway. |
| Reopen then re-complete | Epoch+1, new key. |
| Order needs more than 200 ops | `too-many-ops`, message to the user. |
| Old client completes an order | Old path, unchanged; epoch not bumped; next new-client completion still gets an unused key. |
| Server function not deployed yet | Non-terminal failure (404/5xx): retries; reaches the stuck indicator after 5. Deploy first. |

## 6. Testing strategy

Full matrix in the test plan. Summary:

- **Server (Node, runs in the sandbox):** `operationLogic.test.js` (validation, atomicity, replay, floors,
  CAS, clamp, create/delete, composition, write-count bound), `index.handlers.recordOperation.test.js`
  (auth, 400/403/405/500, forwarding of `opIndex`/`field`/`current`/`conflict`/`results`/`idempotentReplay`).
- **Pure client helpers (`.pragma library`):** `CompletionPlan`, `OperationKeys`, `SendPolicy`,
  `StuckWrites` additions, each with a headless `tst_*.qml` and a seeded monkey test.
- **Wiring:** Outbox op items, Gateway senders through the injected XHR, DataModel flows, store hooks.
- **Regression:** the C-3 sequence (hang, sign-out, sign-in, re-run) as a test that the key is identical
  across the re-run; the double-revenue sale doc case; reopen/re-complete.
- **Coverage honesty:** Node code has measurable line and branch coverage. QML coverage is not measured
  in this repo, so for QML the claim is "CI passes", and unreachable branches are documented instead of
  force-tested, as elsewhere in the repo. Timer and real-network behaviour is covered on-device.

## 7. Scope

**In:** the operation endpoint, outbox op items, Gateway timeouts/jitter/fallback/await mode, D5, the
planner, order completion moved onto it, stores' local hooks, docs and tests.

**Later, separate specs, in this order:**
1. Circuit breaker (closed/open/half-open) on the shared send helper. Needs real timeout data to tune, a
   failure definition (timeouts and 5xx, not 4xx/409/floor rejections) and a UX signal; a false "open"
   would leave the app queue-only while the server is fine.
2. Timeouts for `FirebaseService._request` (reads, id mints). The roadmap's systemic XHR-timeout item.
   Each caller's failure handling must be reviewed first (a retried mint can burn an id).
3. Read fallbacks (serve the local cache on a read timeout), per store.
4. **C-1** (`_tryAdjustOrder` / `ConfirmReturnSheet`): a second consumer of this mechanism (an
   `adjustOrder` op type), plus its lock-span fix and busy state. Its own spec.
5. Server-first as the app-wide default, store by store, if the pilot earns it.

Also in scope of the *pattern* but not of this change: `_completeImportedOrder` mirrors completion, and
`_reverseCompletedOrder` (reopen) is another multi-write action. Both should move onto the same mechanism later.

## 8. Risks and unknowns

- **Not yet measured:** both timeout values, cold-start latency, real marker sizes for large orders.
- **Refactor risk on the server:** composing the per-item transactions into one. Mitigated: the new
  module is separate from `gatewayLogic.js` and reuses its validators, so existing endpoints are untouched.
- **Client wiring is unexecuted code:** written without a Qt toolchain; CI is the first execution.
- **Correction to an earlier statement in this design session:** "no timeouts anywhere in `qml/`" was too
  broad. `AuthService._postJson` (20s) and `StockBatchStore.nextBatchId` (15s) both race a `Timer`
  against the XHR. The Gateway senders and `FirebaseService._request` have none.
- **Old-client mix:** an old client and a new client can both complete orders. Both write the same docs,
  and the server applies each write correctly, but only the new path is exactly-once per operation.
- **Unverified:** whether any Firestore quota or latency issue appears at the 200-op cap in practice.
