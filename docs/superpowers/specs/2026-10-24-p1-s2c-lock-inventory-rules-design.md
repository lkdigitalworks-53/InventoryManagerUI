# P1 S2c: lock `inventory` writes in `firestore.rules` — Design

**Date:** 2026-10-24. **Status:** ready to implement. The parent decision was approved on 2026-10-19 (S2 design, Q3: lock `inventory` only, do it after S2a). This note records the audit and the small choices left inside that decision.
**Parent:** `2026-10-19-p1-s2-design.md` (slice S2c). **Path:** rules only, no client or server code.

## 1. Problem

`firestore.rules` ends with a generic `match /{collection}/{docId}` that lets any tenant member create, update and delete every collection that is not a ledger or server-only collection. `inventory` is not in either list, so a member with a valid ID token can write a product document directly with the Firestore REST API. That write skips the gateway, so it produces no `audit_log` entry and no `stock_movements` or `transactions` rows. For a CGST Rule 56(2) ledger that is the one hole that matters. Until S2a-2 the app itself had a code path (direct mode) that did exactly this; with #154 merged the app no longer does, so the rule can now be tightened without breaking the app.

## 2. Audit: who writes `inventory` today (2026-10-24, `main` @ `b1faada`)

| Writer | Path | Rules involved | Verdict |
|---|---|---|---|
| App (every product create/edit/delete, restock, deduct, return, import, order completion) | `Gateway` -> Cloud Functions (`recordMutation`, `recordDelta`, `recordOperation`) | Admin SDK, rules skipped | unaffected |
| App photo upload / delete | `uploadProductPhoto` Cloud Function, Storage | Admin SDK | unaffected |
| App edit locks | `LockManager` -> `acquireLock`/`releaseLock` Cloud Functions, `locks` collection | server-only tier | unaffected |
| App id counters | `FirebaseService.mintCounter*` on `counters/*` | wildcard | unaffected (not `inventory`) |
| App other direct writes | `activity_log`, `config/*`, `tenants`, `users`, `tenants/*/members`, `_migrations` | wildcard / own blocks | unaffected |
| App reads (list products, load one) | `FirebaseService.get` / `query` | `allow read` | must stay allowed |
| Node e2e (`recordOperation.e2e`, `cleanupSweep.e2e`, `seed.js`) | Admin SDK | skipped | unaffected |
| QML e2e seeding (`createEmulatorDoc`) | `Authorization: Bearer owner` | skipped | unaffected |
| QML e2e assertions (`pollEmulatorDoc`) | member ID token, GET | read | stays allowed |
| `test/firestore.rules.test.js` | member `setDoc` on `inventory` (loop and R08) | tests assert the OLD behaviour | must change |

Method: grepped `FirebaseService` write callers (`put`, `patch`, `putMany`, `remove`, `mintCounter*`), every `XMLHttpRequest` and Firestore URL in `qml/` and `src/`, `main.cpp`, and every test and e2e writer. No client path writes `inventory`. Limit of the method: it is a grep, not a proof. A path built from a variable that happens to equal `"inventory"` at run time would be missed; none exists in the code read, and the on-device list in the test plan exercises every product action once.

## 3. Choices

**C1. How to express the lock.** Firestore grants a request when ANY matching rule allows it, so a lone `match /inventory/{id} { allow write: if false }` does nothing: the wildcard still allows. (The file already documents this for `pending_cleanup`.) Options:
- A. Add `'inventory'` to `isLedgerCollection`. One word. But the function is documented as "immutable, append-only ledger" (what an MCA auditor reads) and inventory is mutable, so the comment would be false and the name misleading.
- B. New `isGatewayWriteOnlyCollection(name)` with `['inventory']`, and one more `&&` in the wildcard write guard. About 12 lines with comments. Truthful name, and locking `orders`/`staff`/`suppliers` later is a one-word change.
- C. B plus an explicit `match /inventory/{docId}` block. Adds nothing: reads already come from the wildcard and the block cannot deny anything the guard does not.

**Chosen: B.** Cost over A: about 10 lines. Benefit: the rules file tells the truth to the next reader, which matters because the file is audit evidence. C rejected (dead weight).

**C2. Reads stay open to members.** The app lists and loads products straight from Firestore. Locking reads would force a new read endpoint: a different, much larger slice.

**C3. Scope: `inventory` only** (Q3). `orders`, `staff`, `suppliers`, `removed_staff` also go through the gateway but carry no stock ledger rows; each needs its own audit first.

**C4. Subcollections.** `inventory/{id}/...` has no rule at all, so it is already denied by default. The code uses none. A test pins this so nobody adds a sub-collection expecting it to work.

**C5. Exact-name match.** The lock applies to the collection named exactly `inventory`. A look-alike name (`inventory_archive`, `Inventory`) is an ordinary working collection. Nothing in the app uses one. A test pins this so the limit is visible rather than assumed.

## 4. Trade-offs and risks

- **Takes effect only on deploy.** Merging changes nothing in dev until Taher runs `firebase deploy --only firestore:rules`. Deploying before merging, or rolling back, is the same command from a different branch. Rollback is a one-line revert plus redeploy; no data migration either way.
- **Old builds break.** A dev build from before #154 that still has direct mode gets `permission-denied` on product writes after the deploy. Accepted (D10, dev only, no prod yet).
- **Client error handling is unchanged.** If a write ever were denied, `FirebaseService` logs and returns false. There is no new client code path to test.
- **No test can prove the app has no other writer.** The audit is a grep. The device checklist is the second line of defence, and the lock is the third: any missed writer fails loudly with `permission-denied` on dev, not silently in prod.
- **Rules tests are CI-only** (no emulator in the sandbox). Predicted CI: Rules 52.

## 5. Tests

Rules (emulator, CI): member read of a doc and of the whole collection allowed; member create, overwrite, partial update and delete all denied and the stored doc proven unchanged; the same for each of owner, admin, manager, staff (no role bypass); non-member and unauthenticated denied for read and write; sub-collection write denied; look-alike name still writable (C5 pin). The `working/` loop keeps `orders`, `staff`, `suppliers` (writable, unchanged). R08 now says: member still reads `inventory` and still reads and writes `orders`.
Nothing else changes: QML 2104, Functions 722, E2E 93 expected as before. Full plan: `test-plans/2026-10-24-p1-s2c-lock-inventory-rules-test-plan.md`.
