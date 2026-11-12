# Test plan — Atomic ops R5b: the feed row inside the restock operation, and `recordPurchase` removal

Branch `feat/2026-11-12-r5b-activity-log-in-op`. Design: `docs/superpowers/specs/2026-11-12-r5b-activity-in-operation-design.md` (D-R5b-1..8). Format: Skill 49.

## What was actually executed in the session (honest)
- RUN (Node, this sandbox): `functions/` suite **1711/1711** (was 1671 on `main`: +23 `operationLogic.activity.test.js`, +7 `activityLogAdopt.test.js`, +6 `restockPlan.test.js` AC-1..AC-5 and D-2, +3 `restockWire.test.js` W-20..W-22, +1 `restockSurface.test.js` P-3), `.github/scripts` 1049/1049. 16 of 16 hand mutants killed (section 6; the first run left one alive, test B-11 was written for it).
- NOT RUN here (no Qt, standing rule): the QML twins (`tst_ActivityLog.qml` +5, `tst_RestockPlan.qml` +3 and shape edits, `tst_InventoryStore_applyRestockResults.qml` +3) and the two emulator cases (`test/e2e/recordOperation.e2e.test.js`, R5b). CI is the oracle for both. Device steps below are Taher's.
- Rules: **no change** (the Admin SDK writes the row; `activity_log` stays on the client-writable allow-list because `record`, `dismiss` and `markAllRead` still write it from the client).
- Counts were taken with `node --test | grep "^# "`, not carried from memory.

## 1. Unit (Node)
| IDs | What |
|---|---|
| A-1..A-2 | an activity op after the delta validates and stays a template; an operation without one behaves as before |
| A-3..A-4 | entity only for a `restock` mutation (other op type, delta kind, odd spellings: `unsupported-entity`); create only with `before` null |
| A-5..A-6 | exactly seven client keys (no `actorUid`, no `timestamp`, nothing extra or missing); kind allowlist, id equals entity id and starts `act-`, string types and limits (200 / 1000 / 200, inclusive), `read` and `dismissed` strictly `false` |
| A-7..A-8 | `{{$stock}}` needs an EARLIER delta with a `stock` field for the same product; id placeholder rules with and without a mint; `$` is not a legal bind name |
| A-9 | monkey: 400 single-field corruptions, an independent oracle checks every accepted doc |
| B-1..B-4 | stored doc has server `actorUid` and ISO `timestamp`; token filled from the delta's stock; every occurrence replaced, last delta wins, look-alike brace text untouched; id from the minted batch |
| B-5..B-6 | own audit row carries the stamped doc; marker `results` replay it; a retry replays the SAME stamp and writes nothing |
| B-7..B-8 | a rejected operation leaves no feed row, no audit, no marker; an existing doc at the id is 409 `conflict`, never overwritten |
| B-9..B-11 | `applyOperation` alone refuses a non-create or a token with no delta result, and stamps the caller and clock over any forged `actorUid` / `timestamp` |
| B-10 | write budget: 166 inventory deltas fit, 166 plus one activity op do not |
| G-1..G-3 | `ENTITY_COLLECTIONS` has no activity entry and `recordMutation`, `recordDelta`, `acquireLock`, `releaseLock` validators refuse it; only `operationLogic.js` names `activity_log` in `functions/lib`; `completeOrder` unchanged |
| AC-1..AC-2 | planner cuts product 150 / supplier 100 / reason 500 (never splits an emoji) and never refuses cosmetic text; `{{$stock}}` is reserved text in every typed field |
| AC-3..AC-4 | plan -> REAL server -> `reflect`: row stamped by the server, same wording as `RestockFlow.activityText`; a legacy answer (no row) reflects with `activity: null`; a damaged or doubled row is refused |
| AC-5 | monkey: 2000 random typed inputs, every plan the planner builds passes the server validator |
| AD-1..AD-7 | `ActivityLog.adopt` (real body in a sandbox): order by timestamp, tie, dedupe by id, refuse junk, 50-cap both ways, no in-place change, undefined list |
| D-2 | `TransactionStore.recordPurchase` is gone and nothing in `qml/` or `tests/` calls it; the purchase doc keys are pinned (D-1 replaced the literal-reading drift guard) |

## 2. Functional (Node, real function bodies + real server code)
| IDs | What |
|---|---|
| W-23 | answer with the server's row: adopted once, NO client-written row, the same answer again adds nothing |
| W-24 | legacy answer (queued by the previous build): the old client row is written once |
| W-25 | damaged feed row: nothing applied, nothing recorded, everything re-read |
| P-3 | source pins: the tap writes no row; `applyRestockResults` adopts; the legacy `record` exists only behind `!out.activity` |
| H-3/H-4 | `applyRestockResults` order now supplier, batch, purchase, feed row, stock; replay keeps stock alone |

## 3. Rules / E2E (emulator, CI only)
- `recordOperation.e2e.test.js` "R5b: a restock with an activity op stores the feed row with the SERVER's actor and time...": real Firestore doc, stamp and token, replay leaves the first row untouched, own audit row.
- "R5b: a client that sends its own actorUid or timestamp ... is refused (400 invalid-activity)": nothing written, counter untouched.
- Rules suite: unchanged and must stay green (proves the allow-list did not move).

## 4. Regression (automated)
All 1671 earlier functions tests pass unedited except the shape assertions that now see one more op (B-1..B-3 in `restockPlan.test.js`, F-8, W-14) and the sandboxes that now provide `ActivityLog.adopt`. `operationLogic.test.js` and `operationLogic.mint.test.js` are NOT edited: they passing is the evidence an operation without an activity op is byte-identical.

## 5. Monkey and multi-scenario
A-9 (400 corruptions), AC-5 (2000 typed inputs), existing `restockWire` M-1 (400 random taps and outcomes, never two rows for one tap), B-6 retry, B-7 rejection, B-8 collision.

## 6. Hand mutants (16 / 16 killed)
opType restriction dropped; exact-keys dropped; `read`/`dismissed` check dropped; `act-` prefix dropped; document `actorUid` beats the caller (SURVIVED the first run, killed by B-11); only the first token replaced; placeholder check skipped when there is no mint; apply-time create guard dropped; subtitle cap dropped; token delta-product check dropped; surrogate split allowed; stock token not reserved; two feed rows allowed; feed `entityId` unchecked; `adopt` dropped; legacy row always written.

## 7. On-device (Taher). Deploy functions BEFORE installing the client.
1. **Online restock, known supplier.** Restock 5 of a product with a supplier. Expected: stock +5, one "Restocked: <name>" row at the top of the Activity page and the dashboard card, subtitle `+5 · now N in stock · from <supplier> · <reason>`, N equals the new stock. Exactly ONE row.
2. **Row persists.** Force-close and reopen, then sign out and in. Expected: the row is still there (it is in Firestore `activity_log/act-BAT-...`, not only in memory). Check the console doc: `actorUid` is your uid, `timestamp` is an ISO string close to now.
3. **New supplier typed in the dialog.** Subtitle says `from <typed name>`; the supplier exists once.
4. **Offline restock.** Airplane mode, restock, observe "saved, syncing" and NO row yet; go online. Expected: one row appears after the answer, with the time of the SYNC (design D-R5b-2: server clock). The purchase row keeps the tap time.
5. **Kill the app between the answer and the feed.** Restock online, force-close at once. Expected: reopen shows the row (the old client PUT could lose it).
6. **Replay.** Not reproducible by hand; covered by B-6 and W-23.
7. **Long text.** Product name of 300 characters and a 500-character reason: the restock succeeds, the feed title is cut, nothing is refused.
8. **Old build in the queue.** Skip unless an offline restock queued by the previous APK exists; then update, go online: ONE row (the legacy path), no duplicate.
9. **Bell.** Another account restocks: your bell badge counts it; your own restock does not (actor stamped by the server).
10. **Feed order.** Make a normal activity (edit a product), then restock: restock row on top, both in order.
11. **Negative.** Restock for a product deleted on another device: refused, no feed row.
12. **Purchase ledger.** Analysis > Purchased still shows the restock (the removed `recordPurchase` was not on that path since R4).

## 8. CI correction round (honest)
First CI read on `bde06ca`: Functions green; QML RED, 4 of the QML cases: `tst_InventoryStore_restock` (2) and `tst_RestockPlan` M1 still expected the old 4/6 op counts, and `tst_ActivityLog` 50-cap case used an equal timestamp (equal goes AFTER the held row). Test-side only, product code was right; fixed in the next commit. Learning: Skill 166 rule 9.

## 9. Counts
Functions 1711/1711, scripts 1049/1049, QML twins and e2e in CI.
