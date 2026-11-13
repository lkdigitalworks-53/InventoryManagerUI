# R5b design: the activity row inside the restock operation, and `recordPurchase` removal

Date 2026-11-12. Branch `feat/2026-11-12-r5b-activity-log-in-op`. Follows R5a (#191, merged). Source notes: `ATOMIC-OPERATIONS-STATUS.md` sections 4, 6, 11 and `specs/2026-11-10-r5a-restock-dialog-design.md` section 5. Question Q-A3 of the restock design ("the activity entry is part of the transaction") was answered yes; this slice builds it.

## 1. Problem

A restock is one atomic server operation (supplier, batch, stock, purchase). Its feed row (`activity_log/act-<ms>-<rand>`) is still a separate client PUT made after the answer arrives:

- It is lost if the app dies between the answer and the PUT, and nothing retries it.
- A replayed answer (`idempotentReplay`) records a second row, because `_applyRestock` calls `ActivityLog.record` every time.
- `actorUid` and `timestamp` are whatever the client says. A phone with a wrong clock can pin a row at the top of the feed for ever (the feed orders by `timestamp`, and the prune pass keeps the newest 50).
- `activity_log` cannot leave the client-writable allow-list (`firestore.rules`) while this writer exists. It still has other writers (`record` for other kinds, `dismiss`, `markAllRead`), so it stays on the list in this slice.

## 2. Decisions (all vetoable in the PR)

**D-R5b-1: an operation-only entity, not an entry in `ENTITY_COLLECTIONS`.** `operationLogic.js` gets `OPERATION_ONLY_ENTITIES = { activity: { collection: "activity_log", opTypes: ["restock"] } }`. `ENTITY_COLLECTIONS` is read by `lockLogic`, `batchMutationLogic` and every single-record endpoint, so adding it there would let any member write the feed through them. A guard test pins that `ENTITY_COLLECTIONS` has no `activity`/`activity_log` and that every other endpoint answers `unsupported-entity`. Against: a second map to keep in step. For: the blast radius is exactly one operation type.

**D-R5b-2: the server stamps `actorUid` and `timestamp`; the client sends neither.** The client doc has exactly seven keys (`id, kind, title, subtitle, entityId, read, dismissed`); any other key, including `actorUid` or `timestamp`, is `invalid-activity`. The server adds `actorUid` (the caller) and `timestamp` (an ISO string from the server clock, the same format `ActivityLog.record` uses, so the feed's `orderBy timestamp` never mixes types). Trade-off the person should know: a restock queued offline at 09:00 and applied at 17:00 shows 17:00 in the feed. The purchase ledger row keeps the client time (`now`), so no business record loses its time; only the feed row does. Alternative rejected: trust the client time inside a window around the server time. It adds a rule that fails a legitimately old offline restock. If this is the wrong call, flip one line in `stampActivity`.

**D-R5b-3: the "now N in stock" part of the subtitle stays, through one server token `{{$stock}}`.** The text used to be built after the answer from the server's stock value. The server cannot know it before the delta runs, so the client sends the literal `{{$stock}}` and the server replaces it with the `stock` the same operation's delta op for the same product produced. `$` is not legal in a mint bind name (`BIND_NAME`), so the token can never collide with a minted id. Validation proves a delta op for that product comes earlier (`activity-stock-missing`); typed text that equals the token is refused by the planner (`reserved-text`), like the other two tokens. Alternative: drop the clause (smaller, loses information the feed shows today). Taken: keep, since the cost is one small function.

**D-R5b-4: the id is `act-{{batch}}`.** Derived from the minted batch id, so it is unique, readable in audit rows, and the create is conflict-checked (an existing doc is a 409 `conflict`, never an overwrite). A retry never reaches it (the marker replays first).

**D-R5b-5: the activity op is last, create-only, for `restock` only, kind `product_restocked` only.** Anything else is refused. Widening is a server deploy by design, the same rule as `OP_TYPES`. It adds one audit row and one write to the budget, which `2 * workOps` already counts.

**D-R5b-6: strict shape, client clips.** Caps: title 200, subtitle 1000, id and `entityId` 200 (the server's id limit). The planner clips the product name (150), reason (500) and supplier name (100) without cutting a surrogate pair, so a valid restock can never be refused for cosmetic text. The server refuses anything over the caps as `invalid-activity` (an app problem, listed in `FailureCause`).

**D-R5b-7: the client adopts the server's row, it does not write one.** `ActivityLog.adopt(entry)` inserts a row the server wrote, newest first by `timestamp`, deduplicated by id, 50-capped, no Firestore write. A live answer and a replay both go through `applyRestockResults`, so a replay adds nothing twice. `reflect()` accepts 0 or 1 activity result. **Legacy fallback:** a restock queued by the previous build (no activity op) can be answered after the app updates; its results have no activity row, so `_applyRestock` records the old client-built row for that case only. Remove after one release (KNOWN-ISSUES).

**D-R5b-8 (P2): `TransactionStore.recordPurchase` is deleted.** Nothing in production calls it (R4 removed the last caller). Its tests are removed, and the drift guard D-1 compares the planner's purchase doc to a pinned key list in the test instead of to that function's literal.

## 3. Deploy and compatibility

Server first. Old clients keep working (no activity op, accepted as before). A NEW client against an OLD server gets `unsupported-entity` for the activity op, a terminal 400, so the new client must not ship before the functions deploy (same rule as R3/R4). Deploy Check ships functions on merge; Taher still confirms before the client build goes out.

## 4. What changes

Server: `functions/lib/operationLogic.js` (entity map, `validateActivityOp`, `stampActivity`, token), no handler change. Client: `RestockPlan.js` (`activityOp`, `reflect`), `ActivityLog.qml` (`adopt`), `InventoryStore.qml` (`applyRestockResults`, `_applyRestock`), `FailureCause.js` (two codes), `TransactionStore.qml` (delete one function). Rules: unchanged (the Admin SDK write skips them; the allow-list entry stays until the last client writer moves).

## 5. Not in this slice (scope kept short)

- `activity_log` leaving the rules allow-list (other writers remain).
- Moving other kinds (`product_added`, `product_updated`, ...) into operations (add-product slice, step 2).
- `AddProductDialog`'s inline supplier row (step 2).
- Removing the legacy fallback (one release later).

## 6. Test strategy

Node (real server code): validation matrix and monkey run, stamping, token substitution, replay equals first answer, rejection leaves no trace (no doc, no audit, no marker), conflict on an existing id, wrong opType, source guards (entity map, no other endpoint accepts it). Planner: shape, clipping, token refusal, plan -> real server -> `reflect`. QML twins for `ActivityLog.adopt`, `applyRestockResults`, `RestockPlan` (CI only). Device steps in the test plan.
