# R1+R2: the `mint` op (ids minted inside the operation transaction) — slice design

**Date:** 2026-10-28. **Status:** built on `feat/2026-10-28-r2-mint-engine`. Server only. **Parent:** `2026-10-16-restock-atomic-operation-design.md` (v2, approved by merge of #147), section 3 and 7. Taher asked for one turn with no interactive gate, so M1-M11 are DEFAULTED and each is vetoable in the PR. **Path:** architectural (touches `operationLogic.js`, the file every operation goes through), so the review pass below was done BEFORE code.

## 1. R1 findings (read from code on `main` @ `fbd7dec`, 2026-10-28)
| Fact | Evidence | Consequence |
|---|---|---|
| Counter doc is `tenants/<t>/counters/<name>` with one numeric field `value` | `FirebaseService.mintCounterValue` (REST commit with `updateTime` / `exists:false` precondition) | Server transaction reads and writes the SAME doc; Firestore serialises both writers, the loser retries. No collision |
| Supplier: `counters/suppliers`, id `SUP-` + `padStart(3,"0")`, doc id = `supplierId` | `SupplierStore.nextSupplierId`, `Gateway.recordMutation("supplier", doc.supplierId, ...)` | registry entry `supplier` |
| Batch: `counters/stockBatches-<year>`, id `BAT-<year>-` + `padStart(3,"0")`, doc id = `batchId` | `StockBatchStore.nextBatchId`, `_batchIdPrefixForYear` | registry entry `stock_batch`; year is part of the counter NAME |
| `padStart` never truncates, so value 1000 gives `SUP-1000` | JS semantics | server must not truncate either; seed parse is numeric, not lexical (`SUP-1000` < `SUP-999` as strings) |
| Client seed when the counter doc is missing = highest existing id number (`parseInt` of the part after `-`) | the five `next*Id` functions | server seeds the same way, from the collection's doc ids, never from the client (Q-A4) |
| `activity_log` and `counters` stay client-writable | `firestore.rules` allow-list (S2f-4/5), design 7b items 2-3 | untouched here; the pin flips in the arc's last PR |
| Results of a replay come from the marker's `results` array, index-aligned with `ops` | `applyOperation` | mint results go into that array at the mint op's index; an operation with no mint op is byte-identical to today |

## 2. Contract
Request op: `{ kind: "mint", counter: "stock_batch" | "supplier", bind: "<name>" }`. Later ops reference the id as `{{name}}`.
- Substituted: `entityId` of a mutation `create`, and every STRING VALUE (deep, objects and arrays) inside `after` of any mutation. Never: keys, `before`, `deltas`, delta `entityId`.
- Result entry at the mint op's index: `{ kind: "mint", counter, bind, id }`. The marker stores it, a replay returns it and mints nothing.
- Mint ops write no audit row of their own (the minted id is in the audit rows of the docs that use it, and in the marker results). Their op index is simply skipped in `requestId~i`.

## 3. Decisions
| # | Decision | Chosen | Rejected, why |
|---|---|---|---|
| M1 | Registry size | only `stock_batch` + `supplier` (what restock needs). Each later consumer PR adds one entry + one parity row | all five now: three entries with no consumer and no test of real use |
| M2 | Where the counter lives | the existing client doc, same shape `{ value }` | a second server-only counter: two sequences for one id space = collisions |
| M3 | Year for `BAT-<year>-` | calendar year in `Asia/Kolkata` from the server clock (constant `COUNTER_TIME_ZONE`) | UTC (wrong for 5.5 h around new year for this INR / en-IN app); client-sent year (a trust-boundary field). A device in another zone can mint a different-year prefix around midnight Jan 1; ids stay unique because the prefix differs |
| M4 | Missing counter doc | seed = max numeric suffix over `listDocuments()` of the target collection, filtered by the registry's id pattern, then +1 | seed 0 (reissues ids of existing data); client seed (Q-A4 forbids) |
| M5 | Counter behind the data (hand edit, drift) | a minted id whose doc already exists is skipped (burned), at most 20 skips, then 409 `mint-exhausted`, zero writes. **Amended 2026-10-29 (M12): on the first collision the counter jumps once to the highest id in use, so a gap wider than 20 heals instead of failing for ever** | let the later `create` hit 409 `conflict`: retry mints the same id again = a permanently stuck restock until someone edits the counter by hand |
| M6 | Placeholder syntax scope | strict for `entityId` (create only; unknown or later-declared name = 400 `unbound-placeholder`; any `{{` or `}}` left over = 400); lenient for `after` strings (only names bound EARLIER are replaced; a name declared LATER = 400; any other text is left alone). No scanning at all when the operation has no mint op | strict everywhere: a supplier typed as `{{x}}` would 400 forever. Cost of lenient: user text that equals a bound name (`{{batch}}`) is replaced, cosmetic |
| M7 | Guards | bind `^[a-z][A-Za-z0-9]{0,15}$`, unique, at most 5 mint ops, unknown counter 400, resolved ids re-checked with `isSafeDocId` | |
| M8 | Write budget | `2 * nonMintOps + mintOps + 1 + movementRows` against `MAX_TXN_WRITES` (a mint op is one counter write, no audit) | counting a mint op as two writes: over-counts, rejects valid operations |
| M9 | `restock` opType | added to `OP_TYPES`; NO default movement kind (D5: no per-opType shape check; a restock delta must carry an explicit `receipt` movement, otherwise it derives `adjustment`) | default `receipt`: a negative derived delta would be refused, and it hides a missing movement |
| M10 | Rejection | any rejection returns before the first write, so the counter is not incremented: no gaps from rejected operations | |
| M11 | Rules | no change. `counters` remains client-writable until the last caller migrates (7b). Server uses the Admin SDK | |

## 4. Transaction shape (reads before writes, as Firestore requires)
1. read marker (replay check, unchanged). 2. For each distinct counter: read the counter doc; if missing, seed by listing ids (outside the transaction, harmless: M5 absorbs a stale listing). 3. In op order assign ids: candidate = next number, read the target doc (memoised, shared with step 4), if it exists skip. 4. Substitute, re-validate ids, read every working doc once (as today). 5. Apply ops (unchanged logic). 6. Only now write: working docs, audit rows, movement rows, counter docs `{ value: last }`, marker.

## 5. Review pass before code (ponytail + hostile read)
- **Cut:** a registry for five counters (M1); a `minted` map in the response (the results already carry it); a per-op audit row for mint (no ledger value).
- **Risk, replay:** results must be stored BEFORE any later change can alter them: they are built inside the transaction and written in the marker. Test: replay after the counter moved on returns the old ids.
- **Risk, byte compatibility:** an operation without a mint op must produce the same writes, results and error shapes. Pinned by running the whole existing `operationLogic.test.js` unchanged (it is not edited).
- **Risk, two writers on the counter:** server transaction vs client REST mint. Safe by Firestore serialisation; an emulator test interleaves them (CI only, no emulator here).
- **Risk, placeholder injection:** user text can only ever be replaced by a minted id the same caller was just given; it cannot reach another tenant or another counter. Guarded by M7.
- **Hole found while reviewing:** `isSafeDocId` on a TEMPLATE passes `{{`; the resolved id must be re-checked (done, step 4).
- **Honest cost:** the transaction reads one extra doc per mint (collision probe) plus the counter; `listDocuments()` once per counter lifetime per tenant.

## 6. Not in scope
Client `RestockPlan`/`InventoryStore.restock` rewrite (R3-R5); product/order/staff counters; `activity_log` entity in operations (Q-A3, R5); flipping the `counters` rules pin; any QML.

## 7. Review sweep 2026-10-29 (PR #172) — findings fixed in the same PR
Method: three invoked reviews (`requesting-code-review`, `ponytail-audit`, `qt-qml-review` = N/A, no QML in the diff). Every finding below was REPRODUCED against the real code with `strictDb` before it was fixed, and each fix is pinned by a test that was mutation-checked (7 mutants, all killed).
| # | Finding (concrete case) | Severity | Fix | Decision |
|---|---|---|---|---|
| F1 | A collision probe loaded the occupied doc into the working state, and the write loop rewrote EVERY loaded doc: skipping `SUP-001` re-wrote `suppliers/SUP-001` (bumped its update time) and the rewrites were not in the M8 write budget (up to 20 per mint, 100 for 5 mints; 401 + 100 > 500 on a big operation) | Must fix | each state entry has `dirty`; only ops set it; the write loop skips clean entries. Old operations: every loaded doc was already touched, so byte-identical | none needed |
| F2 | Counter 5, ids `SUP-006..SUP-045` exist (gap 40): every attempt ends `409 mint-exhausted`, and because a rejected operation never moves the counter (M10) every retry fails identically: a permanently stuck restock, the exact failure M5 was written to avoid | Must fix | **M12:** on the first collision per counter, jump to `max(counter, highest numeric id in the collection)` once (one `listDocuments`, outside the transaction, harmless because the probe still checks every id). `mint-exhausted` stays as the bound for a stale listing | M12 |
| F3 | A mint nobody uses (or a mint-only operation) was accepted: any member could burn numbers and write a marker for nothing, and a client that forgets to use a bind silently leaves gaps | Should fix | **M13:** `400 unused-mint` (opIndex = the mint). A use = the name inside an `entityId` token or an earlier-declared name inside an `after` string. `before`, keys, deltas never count | M13 |
| F4 | `substituteDeep` copied with `out[k] = ...`: a JSON key `__proto__` became the copy's prototype and vanished from the stored doc, while the same body without a mint op keeps it as an own key | Should fix | `Object.defineProperty` copy | none |
| F5 | `{ kind: mint, counter: supplier }` + `create stock_batch {{s}}` put a `SUP-` id into `stock_batches` (two id spaces in one collection) | Should fix | **M14:** an `entityId` that is exactly one `{{name}}` must belong to the entity its counter serves, else `400 placeholder-entity-mismatch`. Embedded ids (`tx-p-{{batch}}`) stay free | M14 |
| F6 | The e2e test `a rejected restock burns no number` failed in CI: the first mint test left `BAT-<year>-038` in place, the counter was restored, so the next test's `idFor(v0 + 1)` was an occupied id and the server (correctly) skipped it | Test bug | every test deletes the docs it minted in its own `finally` | none |
| F7 | docs predicted `E2E 106`; 106 is the Rules count. E2E observed 99 (96 + 3) | Doc bug | corrected in the test plan | none |

Reviewed and left alone (with the reason): no role gate on `restock` (parity with `completeOrder` and `recordMutation`, which only gate deletes; the gate question belongs to the arc's rules PR, F7 in KNOWN-ISSUES); `mint` allowed in any opType (a stray mint in `completeOrder` now fails `unused-mint` unless it is really used; restricting by opType is a later per-consumer decision); M3 IST year, M6 lenient `after`, M11 rules untouched; `yearFor` throwing on an odd ICU build is a 500 that cannot happen on the Cloud Functions Node runtime.

M15 (test hygiene rule, no code): an e2e test that mints must remove what it minted in its own `finally`, never at the end of the file.
