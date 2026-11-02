# R3: the client planner for the atomic restock operation

Date: 2026-11-01. Branch `feat/2026-11-01-r3-restock-plan`. Review sweep of PR #181 (same day, same branch) added T11, T12 and the error-code guard; see section 8. Parent design: `2026-10-16-restock-atomic-operation-design.md` (architecture approved when #147 merged; this slice implements its section 7 step R3). Server side: R1+R2 (PR #172, merged, deployed, device-tested). Next slices: R4 (wire `InventoryStore.restock`), R5 (dialog wording, `activity_log` id).

## 1. What this slice is

The pure client layer that R4 will call. Nothing in the app calls it yet, so merging it changes no behaviour (pinned by test P-1; R4 changes that expectation on purpose).

- `OperationKeys`: `restockNonce`, `restockKey`, `isRestockKey`, `purchaseTxId`.
- `qml/helper/RestockPlan.js`: `build(input)` turns "restock this product" into the ordered op list; `reflect(results)` reads the server's answer back into plain docs.
- `FailureCause.forRestock` and more bug codes in `forRejection`; the restock label in `DescribeItem`.
- Two local-only hooks: `SupplierStore.addLocalSupplier` and `InventoryStore.applyRestockResults`.

## 2. The plan the client builds

Op order (each op's shape is checked by the real server code in `functions/test/restockPlan.test.js`):

1. `mint supplier` bound as `sup` (only when the person typed a new supplier name)
2. `mint stock_batch` bound as `batch`
3. `create supplier {{sup}}` (new supplier only)
4. `create stock_batch {{batch}}`
5. `delta inventory <productId>` with `stock +qty`, no floors, no clamps, and one explicit `receipt` movement
6. `create transaction tx-p-{{batch}}` (the purchase ledger row)

A known supplier adds no mint and no supplier doc (four ops). No supplier gives empty `supplierId` and `party`. Both mints come first so every token is declared before any op uses it. The `at` map in the result gives each op's index (-1 when absent) so R4 and the tests never count by hand.

## 3. Decisions (vetoable in the PR)

| # | Decision | Why | Trade-off and the alternative not taken |
|---|---|---|---|
| T1 | The request key is made once, at the tap: `restock:<nonce>`. It is not derived from a record. | A restock has no record to derive from before the server mints the batch id. A key made at tap and kept in the outbox entry makes every retry a replay (the server's marker at `audit_log/<requestId>`). | Gap G4: sign-out clears the outbox, so a restock queued and then abandoned by sign-out is simply gone, never repeated. Deriving the key from product + time was rejected: two deliberate restocks of the same product in one minute would collide. |
| T2 | Nonce = millisecond time + two 6-character base36 draws. A key must match `[A-Za-z0-9._-]{1,100}` after the prefix. | Time keeps keys sortable and debuggable; the draws separate two taps in one millisecond. The charset is the server's request-id rule, so a key cannot be refused as `invalid-request-id`, and it contains no `/` or `~` (document-path characters). | 12 random chars is not a crypto guarantee, but a collision needs the same millisecond AND the same 62 random bits, and the server would then answer `request-id-in-use` (wording below), not corrupt anything. |
| T3 | The supplier id is minted by the server only for a NEW supplier name. | Matches `addSupplier` today (a new supplier is created with the restock). A known supplier id is used as typed. | A client-minted supplier id would burn numbers on a rejected or repeated restock; that is the whole reason R2 exists. |
| T4 | The purchase doc id is `tx-p-` plus the minted batch id. | Same id `TransactionStore.recordPurchase` writes today (drift test D-1), and it is stable on replay because the batch id is. | None found; the id is derived, not chosen. |
| T5 | The stock delta carries an explicit `receipt` movement (reason trimmed, cut to the movement limit for the ledger row only). | The server requires the movement to match the delta; without it the server would derive an `adjustment` and the ledger would read wrong. The batch doc keeps the full reason as typed. | Two copies of the reason (batch note and movement). That mirrors today's data, so reports do not change. |
| T6 | `reflect` uses only the results, never the plan. | After an app relaunch the plan is gone but the stored answer is still there; the replay path must work from the answer alone. | Slightly more checking in `reflect` (cross-checks batch id, product id, purchase id, supplier id). Worth it: a half-understood answer must never reach the local stores. |
| T7 | Text the person typed that CONTAINS a bound token (`{{sup}}`, `{{batch}}`) anywhere is refused (`reserved-text`). | The server replaces tokens anywhere inside `after` strings, not only when the whole text equals one (review F5: the first wording said "equals", the code and tests always refused "contains", which is the right rule). A note `see {{batch}}` would be rewritten into an id inside a stored record. | A person can no longer type that exact text in a restock note. Practically unreachable; six lines of code. Silently stripping it was rejected: it changes what they typed. |
| T8 | The client runs the same movement check as `Gateway.recordDelta` (`SM.validate`) and refuses before queueing. | A queued write the server refuses terminally is dropped together with its stock change. A refusal at the tap costs nothing. | A second place to keep in step with the server. The Node test R-3 and the real-server tests S-1..S-7 catch drift. |
| T9 | `applyRestockResults` applies a whole answer or nothing, adds each doc only if its id is absent, and skips the stock when `opts.replay === true`. | A replay can arrive after a later stock change; its `after.stock` is then older than what the device knows (the caller re-reads inventory). Docs are idempotent by id, so applying twice duplicates nothing. | A replayed restock does not move the displayed stock by itself; R4 must refresh the product after a replay. That is recorded in the R4 notes. |
| T10 | Dormant: no caller until R4. | Smallest reviewable slice; the risky wiring (latch, picker hide, outbox) is R4's own review. | Dead code for one release cycle. Mitigated by tests that run it against the real server logic, so it cannot rot unnoticed. |
| T11 | `build` refuses a plan whose docs would pass Firestore's size limit (`too-large`), using the shared `DocLimits.exceedsDoc` on every doc it creates. | Review F2. The reason is a free single-line field with no length cap and lands in three docs (batch note, purchase reason, and the ledger row cut to 500). A pasted wall of text would make the server refuse the whole operation; a queued refused write retries or parks for nothing. Refusing at the tap costs nothing and keeps the person's stock unchanged. | The estimate is the same one product edits use (1 MiB minus a 4 KiB reserve), so it can refuse a doc that Firestore would barely accept; the server stays the authority. Not taken: a `maxLength` on the dialog field alone (the planner must be safe for any caller; R5 may add a field cap on top). Not taken: a whole-request size check (the operation is far below the transaction cap unless one doc is huge, and each doc is checked). |
| T12 | `build` refuses `qty * unitCost` that is not finite (`bad-cost`). | Review F1. Both factors can be finite while the product overflows (`5 * 1e308`). JSON turns Infinity into `null`, so the stored purchase would carry `total: null` and every ledger sum would break. The cost field takes `1e308` today (`parseFloat`). | A cost problem whichever factor is huge. A zero cost with a huge quantity has total 0 and is allowed. |

## 4. Failure wording (`FailureCause.forRestock`)

- `not-found`: "<product>: ... Nothing was added" (the product vanished).
- `conflict`: "Another device changed this at the same time. Nothing was added. Try again".
- `mint-exhausted`: a limit message that names the code and says nothing was added.
- `request-id-in-use`: kind `duplicate`.
- `insufficient-quantity` and `operation-too-large`: app problems, with no order wording (a restock never consumes stock).
- Everything else falls back to `forRejection`. The mint and placeholder codes of R2, and (review F3) every delta, movement, entity and action validator code, are app problems there: a request the client built wrongly. `functions/test/failureCauseCodes.test.js` reads the server's own code list and fails when a code is neither a person-facing cause nor classified, so a future server code cannot fall through to "The server rejected this change" unnoticed.

## 5. What is deliberately NOT here

- No change to `InventoryStore.restock`, `Gateway`, `DataModel`, the outbox, the picker or any dialog (R4/R5).
- No `activity_log` entity inside the operation (R5).
- No server change. R2 is deployed.
- No new Felgo or QML type: the helpers are `.pragma library` files so they load in Node (`functions/test/testSupport/qmlHelpers.js`) and run against the real server code.

## 6. Verification

- Node, real server code: `functions/test/restockPlan.test.js` (26) and `restockSurface.test.js` (15). The plan goes through `validateOperationRequest` + `applyOperation` on the strict fake DB; `reflect` is compared with the stored docs; replay, next id, 404 and write budget are covered; seeded monkey of 400 inputs.
- Hand mutation runs: planner and keys, 21 of 23 mutants killed alone (the 2 survivors are the redundant pair `qty <= 0` / `SM.validate`, each alone sufficient, killed together); client surface, 16 of 18 on the first run, the two survivors (exact conflict text, zero quantity label) got stronger tests, then 18 of 18.
- QML (CI is the oracle, no Qt here): `tst_RestockPlan.qml`, additions to `tst_FailureCause.qml` and `tst_DescribeItem.qml`, `tst_SupplierStore_addLocal.qml`, `tst_InventoryStore_applyRestockResults.qml`.
- Test plan: `docs/superpowers/test-plans/2026-11-01-r3-restock-plan-test-plan.md`.
- Review sweep additions: Node `restockPlan.test.js` R-4..R-6 (overflow, size, exact size edge), `failureCauseCodes.test.js` (server code list vs `FailureCause`), QML twins in `tst_RestockPlan.qml` and `tst_FailureCause.qml`; hand mutants 6 of 6 killed.

## 7. Notes for R4

1. Make the key at the tap (`Keys.restockKey(Keys.restockNonce(Date.now(), Math.random))`) and store it in the outbox entry; never remake it on retry.
2. Resolve the default unit cost before calling `build`; `build` refuses a negative or missing cost.
3. On a replay (`replay: true`) re-read the product's stock; do not trust `after.stock`.
4. Change test P-1 on purpose when the first real caller lands.
5. Deploy the functions (R2) before the client reaches a device. Already done for #172.

## 8. Review sweep of PR #181 (2026-11-01): what changed and what was left for R4/R5

Fixed in this PR: F1 overflowing total (T12), F2 no size guard (T11), F3 thirteen server validator codes shown as "unknown" (section 4), F4 the `OperationKeys` entropy comment (about 62 bits, not 50), F5 T7 wording.

Left on purpose, for the slice that owns it (also in `ATOMIC-OPERATIONS-STATUS.md` section 9):
1. R4 must choose `{ id }` or `{ newName }` the way `_resolveSupplierId` does today: a text starting `SUP-` is an id, a known name (case-insensitive `findByName`) is that supplier's id, only an unknown name is `{ newName }`. `build` cannot know the store. Two devices offline that both type the same new name still make two suppliers (the server does not dedupe by name; the old path had the same race).
2. R4 maps every refusal reason of `build` to words: `bad-quantity` keeps `restockQtyRefusal`; `too-large`, `reserved-text`, `bad-cost` (including an overflow) need a short person-facing text (R5); `bad-key`, `bad-product`, `bad-time`, `bad-supplier` are app problems.
3. The old `restock` turned a falsy amount into 10 (`amount || 10`); the planner refuses 0. R4 decides whether the default stays (the dialog's spin box is the only caller that matters).
4. A replayed answer carries the batch (`qtyRemaining`) and supplier as of the FIRST application. `applyRestockResults` adds them only when the id is absent, so a stale copy can enter only when the device lacks the doc; the next sync overwrites it. R4 must re-read the product, and should not rely on the replayed batch for FIFO figures until that sync.
5. `build` checks that `now` is a non-empty string and `date` looks like `yyyy-MM-dd`; it does not prove they are a real timestamp or calendar date (the caller formats both from `new Date()`). R4's caller test pins the format.
