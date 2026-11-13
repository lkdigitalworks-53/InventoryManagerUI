# Step 2 design: add product with opening stock is ONE atomic operation (slice AP1 = server, dormant)

Date 2026-11-13. Branch `feat/2026-11-13-ap1-add-product-server-op`, cut from `main` @ `024a6f6` (#197 merged). Follows R5b. Source notes: `ATOMIC-OPERATIONS-STATUS.md` sections 3, 4, 13 ("step 2: add product with opening stock, which also takes `AddProductDialog`'s inline supplier row") and `specs/2026-10-16-restock-atomic-operation-design.md` line 77 (the op list was sketched there; this document fixes it).

## 1. Problem (evidence, read from `main`)

`InventoryStore.addProduct` makes up to seven independent writes, none of them atomic with the others:

| # | Write | How | Failure today |
|---|---|---|---|
| 1 | new supplier (typed name) | `SupplierStore.addSupplier` = REST mint + create, BEFORE the product | a refused or abandoned add leaves an orphan supplier and a burned `SUP-` number |
| 2 | product id | `FirebaseService.mintCounterValue("counters/products")`, REST, outside any transaction | a timeout burns a number; two phones can race the seed (`max(local)+1`) |
| 3 | `inventory/<id>` create | `Gateway.recordMutation` | the only write that is ledgered (server derives a `receipt` row) |
| 4 | feed row `product_added` | `ActivityLog.record`, client PUT | lost if the app dies after the callback; client clock and uid |
| 5 | `created` transaction | `TransactionStore.recordCreated`, random id `tx-c-<ms>-<rand>` | a retried tap writes a second row |
| 6 | batch id | `StockBatchStore.addBatch` mints its own id | a failed mint leaves a product with stock and NO batch (the pending-mint patch exists for exactly this) |
| 7 | opening batch create | `StockBatchStore.addBatch` | product exists with stock, FIFO has nothing to consume: a later sale fails or drifts |

Gap G2 (ids minted outside a transaction) and G1 (one opType) both cover this path. Row 6/7 is the dangerous one: stock with no batch breaks FIFO cost and the P1 stock register's reconciliation.

## 2. The operation (what the server will accept)

`opType: "addProduct"`, key `addProduct:<nonce>` (a client key helper comes in AP2). Ops, in this order, every token declared before use:

```
mint   product  -> {{prd}}                       (always)
mint   supplier -> {{sup}}                       (only when the typed supplier name is new)
mint   stock_batch -> {{batch}}                  (only when opening stock > 0)
create supplier/{{sup}}                          (new supplier only)
create inventory/{{prd}}   after: the product doc (productId {{prd}}, stock N, supplierId {{sup}} or a known id or "")
create stock_batch/{{batch}}  (stock > 0)        productId {{prd}}, qtyReceived = qtyRemaining = N, "Initial stock"
create transaction/tx-c-{{prd}}                  kind "created", deterministic id
create activity/act-{{prd}}                      kind "product_added", one row, server stamps who and when
```

The server already derives the ledger row for the inventory create: `MovementLogic.deriveForMutation("create", null, after)` = one `receipt` row of `+stock`, stamped with the caller, the operation id and `opType`. Stock 0 derives no row (nothing moved). Nothing in `applyOperation` changes.

## 3. Decisions (all vetoable in the PR)

**D-AP-1: slice the step, server first and dormant.** AP1 (this PR): server only. AP2: client pure layer (`OperationKeys.addProductKey`, `AddProductPlan.build/reflect`, `FailureCause`, `DescribeItem` label), dormant. AP3: wire `InventoryStore.addProduct`, `AddProductDialog` (incl. the inline supplier row, the R5a "Use" pattern), the `DataModel` route for `operationApplied/Rejected`. AP4: docs and the device test of the whole arc. Why: KNOWN-ISSUES 33. #197 put the server half and the client half in one PR, the server deploys only after merge, so the device test of the open PR ran a new client against the old server and failed with `unsupported-entity`. With the server merged and deployed first, every later slice is device-testable while its PR is open. Cost: one more PR cycle (about one review round).

**D-AP-2: a new opType `addProduct`, not a flag on `restock` or a generic `create`.** The audit trail, the replay key namespace (`addProduct:` prefix is enforced) and the activity pairing (D-AP-5) all key on the opType. Cost: one allow-list entry, deployed before the client by construction.

**D-AP-3: the product id comes from a server counter (`product` registry entry), `PRD-` + number padded to 3 digits, counter doc `counters/products`.** Byte-identical to `InventoryStore.nextProductId`, pinned by the existing drift guard (extended here). The client keeps minting from the SAME doc over REST for bulk import (`upsertMany`) until step 4; the engine's collision probe and heal already handle two writers (R2 test "a client-style counter mint and a server mint racing"). Alternative considered: client-chosen UUID ids. Rejected: the repo's ids are human-facing (`PRD-007` appears on labels, orders and exports) and a second id scheme means two code paths in every parser.

**D-AP-4: the opening stock is ledgered as `receipt`, by the existing derivation.** There is no `opening` movement kind (the P1 spec has nine kinds plus `sales_return`). Adding one is a P1 decision with a CA question (design 8) and a change in `KIND_DIRECTION`, the register and the app's labels. Today's path already writes `receipt` for the same create, so behaviour does not change. Recorded in KNOWN-ISSUES: the register's "receipts" column includes the opening stock of products created in the app.

**D-AP-5: the feed row is in the operation; its kind is tied to the opType.** `restock` may write only `product_restocked`, `addProduct` only `product_added`. For `addProduct` the row must name a product THIS operation creates (an EARLIER inventory create for the same id), the same "names what this operation changed" rule as PR #197 review F2, adapted (a create, not a delta). The stock token `{{$stock}}` has no meaning here (the client knows the opening stock) and is refused, so it can never be stored as literal text. Restock keeps its exact current rules (a pinned regression test).

**D-AP-6: no per-opType shape check on the server (same as D5 for completeOrder and restock).** The planner (AP2) is the shape authority and its tests run against this real server code, so drift fails a test. A server-side "exactly one inventory create, one batch if stock > 0" check would be a second source of truth deployed in lock-step, and it would not stop a member from doing any single write through `recordMutation`, which has no such check either. Trade-off accepted: a buggy client could send an odd `addProduct` operation; each op in it is still individually validated (entity allow-list, create-only conflict check, ids, sizes, write budget).

**D-AP-7 (decided for AP3, recorded now so the grill happens before code): adding a product needs a connection.** The id is minted inside the server transaction, so offline there is no id to show, to attach a photo to, or to refer to. Options and trade-offs:
 - A (recommended): refuse offline with a clear text ("Adding a product needs a connection"). Today's behaviour (the REST mint fails and the add aborts), so nothing is lost. Simple, honest.
 - B: queue the operation and show the product only after the server answers. The user sees "Saved" and no product; a second tap would add a duplicate name; photos cannot attach. Worse UX than A for a rare case.
 - C: a provisional local id remapped on the answer. Touches every store, order line and photo queue key. Rejected (largest blast radius for the smallest gain).
 The "online but the answer is slow" case (Gateway `awaitServer` window passes) falls into B's behaviour by design: the operation stays queued, the product appears when the answer lands.

**D-AP-8 (for AP3): the photo is attached from the answer.** `AddProductDialog` keeps the picked photo source until the live answer carries the id, then calls `StorageService.addProductPhoto`. If the answer comes late (queued), the photo is not attached; the toast says the product was saved and photos can be added from the product page. Persisting a pending-photo association across a relaunch is not built (YAGNI; the photo can always be added later).

**D-AP-9: no duplicate-product guard in this arc.** Two products with the same name or SKU are possible today (client-only SKU generator). Not changed; recorded.

**D-AP-10: no legacy client fallback.** AGENTS rule 4. An `addProduct` operation exists only in builds after AP3, and an old build never sends one, so there is no queued legacy item to answer (unlike R5b's restock row).

## 4. Deploy and compatibility

AP1 is additive: `OP_TYPES` gains one entry, the `activity` entity gains one opType, the registry gains one key. No client sends any of it, so nothing observable changes on deploy. Old clients keep working. A revert is safe (nothing depends on it yet). Deploy Check ships functions on merge after Taher's one-tap approval; because AP1 is dormant, the approval can be given at once, and AP2/AP3 then device-test against a server that already knows `addProduct`.

## 5. What changes in AP1

- `functions/lib/counterRegistry.js`: `product` entry.
- `functions/lib/operationLogic.js`: `addProduct` in `OP_TYPES`; `activity` entity for `restock` and `addProduct`; `ACTIVITY_KIND_BY_OPTYPE`; `checkActivityOp` takes the opType and has the `addProduct` branch.
- Tests: new `operationLogic.addProduct.test.js`; the counter guard test gains the product rows and mutants; one source-pin test in the activity file widened; an emulator case in `recordOperation.e2e.test.js` (CI only); a dormancy guard (no QML sends `addProduct` yet).
- Docs: this design, a test plan, README, AGENTS, SKILLS 168 + index, ATOMIC-OPERATIONS-STATUS section 14, KNOWN-ISSUES, CHECKPOINT.
- No QML, no rules, no `functions/index.js` change.

## 6. Not in this slice (scope kept short)

AP2 to AP4 above. Also: `AddProductDialog`'s inline supplier row (AP3), imported products (`upsertMany`, step 4), product delete (G5), the other 12 `ActivityLog.record` call sites, the inventory-doc shape check (KNOWN-ISSUES, found while writing the tests below: a create with a non-numeric `stock` leaves no ledger row, and `recordMutation` has the same hole).

## 7. Questions Taher would be grilled on (recommendation taken above; veto in the PR)

1. D-AP-7: offline add. A (refuse, recommended), B (queue, product appears later), C (provisional id, rejected).
2. D-AP-4: opening stock as `receipt` (taken) or a new `opening` kind (a P1 slice of its own, CA input needed).
3. D-AP-1: server-first split (taken) or one big PR (rejected after #197).
4. D-AP-6: no server shape check (taken), accepting that the planner tests are the only guard for the shape.
