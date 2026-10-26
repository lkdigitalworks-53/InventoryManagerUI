# Test plan — P1 S2c: lock `inventory` writes in `firestore.rules`

**Branch:** `feat/2026-10-24-p1-s2c-lock-inventory-rules` off `main` @ `b1faada` (PR #154 merged). **Design:** `specs/2026-10-24-p1-s2c-lock-inventory-rules-design.md` (parent: `specs/2026-10-19-p1-s2-design.md`, slice S2c).
**Covers:** `firestore.rules` (new `isGatewayWriteOnlyCollection(['inventory'])`, one more `&&` in the wildcard write guard, comments), `test/firestore.rules.test.js` (10 new tests, `working/` loop drops `inventory`, R08 re-pointed), `FIRESTORE_RULES.md`, docs.
**Why:** before this change any tenant member with an ID token could `PATCH` a product document directly in Firestore and change stock with no `audit_log` entry and no `stock_movements` / `transactions` rows. The app no longer has such a path (direct mode was deleted in S2a-2), so the rule can be closed.
**No client, server or QML code changes.** Merging changes nothing in dev until the rules are deployed.

## 1. What is already covered (before this change)
| Layer | Covered by | Notes |
|---|---|---|
| Unit (QML) | 2104 tests in `tests/` | CI only (no Qt in the sandbox); untouched |
| Functional | store / DataModel QML files that write through the Gateway | untouched |
| Rules | `test/firestore.rules.test.js` 38 + `storage.rules.test.js` 7 = 45 | member write to `inventory` was asserted to SUCCEED (loop + R08) |
| E2E | `test/e2e/*` 93 (emulator) | writes only through Cloud Functions; seeds use Admin SDK or `Bearer owner`, which skip the rules |
| Regression | server suite 722 | untouched |

## 2. Unit / functional (this change)
None added or changed. Expected CI: QML **2104**, Functions **722**, E2E **93**, all unchanged. Local runs in the session: `node --check test/firestore.rules.test.js`, `node --test .github/scripts/__tests__/*.test.js`, `node .github/scripts/skills-index.js --check` (results in CHECKPOINT).

## 3. Rules (emulator, CI job `firestore-rules-tests`)
**Predicted: 52** (45 − 3 `working/inventory` loop tests + 10 new). Counted by script: 20 static tests + 4 role-loop + 12 ledger-loop + 9 working-loop = 45, plus 7 storage. Not run in the sandbox (no emulator download).

| ID | Test | Proves |
|---|---|---|
| I1 | member can read one product and list the collection | reads still work (the app lists products straight from Firestore) |
| I2 | member create, overwrite, partial update, delete all denied; stored doc unchanged, new doc absent | the lock itself, and that a denied write left no trace |
| I3-I6 | the same read-yes / write-no check as `owner`, `admin`, `manager`, `staff` | no role bypasses the lock |
| I7 | signed-in non-member: get, list, set, delete all denied | tenant isolation unchanged |
| I8 | unauthenticated: get, set, delete denied | same |
| I9 | write to `inventory/PRD-1/notes/n1` denied | sub-collections stay denied by default |
| I10 | `inventory_archive` and `Inventory` still writable | pins that the lock is exact-name (documents a limit) |
| R08 (changed) | member reads `inventory`, reads and writes `orders` | the exclusion is not too broad; wildcard unchanged for other collections |
| `working/` loop (changed) | `orders`, `staff`, `suppliers`: member create/update/delete, non-member denied, anon denied | 9 tests, was 12; `inventory` moved to I1-I10 |
| unchanged | ledger loop (12), locks, pending_cleanup R01-R07, R09, R11, in-isolation tests | regression |

- **Happy path:** I1, R08, `working/` loop.
- **Negative:** I2, I7, I8, I9.
- **Edge cases:** partial `updateDoc` (not only `setDoc`), sub-collection, look-alike names, a doc proven unchanged after denial.
- **Multi-scenario:** I3-I6 (four roles), I1 (get and list).
- **Monkey / matrix:** the role loop crosses four roles with create, update, delete and read; the look-alike pin catches a future prefix match.
- **Mutation check for CI review:** (a) delete `&& !isGatewayWriteOnlyCollection(collection)` from the wildcard: I2 and I3-I6 must fail. (b) empty the list: same tests fail. (c) add `'orders'` to the list: R08 and `working/orders` must fail. (d) add the name to `isServerOnlyCollection`: I1 must fail.

## 4. E2E
No change. The emulator job is the regression signal that the real gateway path still writes `inventory` (it uses the Admin SDK, so it cannot be blocked by this rule) and that reads with a member token still work (`pollEmulatorDoc`).

## 5. Deploy and rollback (Taher)
1. Merge when CI is green (expect Rules 52, total 2971).
2. Deploy to dev only: `firebase deploy --only firestore:rules`. Nothing in dev changes before this step.
3. Roll back: revert the PR (or check out the previous `firestore.rules`) and run the same command. No data migration either way.
4. An old dev build from before #154 (still has direct mode) gets `permission-denied` on product writes after the deploy. Accepted (dev only, no prod yet).

## On-device test plan (Taher, after the rules deploy; app build from `main`, no functions deploy)
All unticked; nothing here has been run.

**Prerequisites**
- P1. Rules deployed to the dev project (section 5, step 2).
- P2. App built from `main` (after #154 + #155). Signed in as owner on a dev tenant with at least 2 products and 1 supplier.
- P3. A second device or login for E3.
- P4. `adb logcat` filtered on `qml`, running during every step; look for `permission-denied`, `PERMISSION_DENIED`, `403` or `[Firestore] PATCH failed` / `PUT failed`.
- P5. An Excel file with 5 products and one with 300 rows.

### Happy path (every product action still works through the gateway)
| # | Action | Expected |
|---|---|---|
| H1 | Inventory: add a product (name, SKU, stock 10) | Row appears at once; Activity shows "Product added" within a few seconds; no stuck-writes caption. |
| H2 | Restock +5 on that product | Stock 15; a stock-batch row exists; Activity shows the restock. |
| H3 | Edit name and stock (reason entered), save | New values at once; after sync Activity "Product updated" and Transactions show the field change and the stock adjustment. |
| H4 | Orders: create an order for 2 units and approve | Order completes; stock drops by 2; a sale appears in Transactions. |
| H5 | Add a product photo, then delete the photo | Upload and delete both work. |
| H6 | Delete a product that has batches | Product and batches go; no error. |
| H7 | Import the 5-product Excel file | 5 products appear; no stuck-writes caption. |
| H8 | Cold start: kill the app and reopen online | Product list loads (the read path is still allowed). |

### Negative (the lock itself)
| # | Action | Expected |
|---|---|---|
| N1 | Firebase Console > Firestore > Rules > Rules Playground: simulate **update** on `/databases/(default)/documents/tenants/<TENANT>/inventory/<PRODUCT>` as the owner's uid | Denied. Repeat for create and delete: denied. |
| N2 | Same playground, **get** and **list** on that path as the owner | Allowed. |
| N3 | Same playground, **update** on `.../orders/<ORDER>` as the owner | Allowed (orders are not locked in this slice). |
| N4 | Optional, with a real token: sign in with the Auth REST API, then `PATCH https://firestore.googleapis.com/v1/projects/inventorymanager-48392/databases/(default)/documents/tenants/<TENANT>/inventory/<PRODUCT>?updateMask.fieldPaths=name` with body `{"fields":{"name":{"stringValue":"x"}}}` and `Authorization: Bearer <idToken>` | HTTP 403. The same URL with `GET` returns 200. The product name in the app is unchanged. |
| N5 | Logcat during H1-H8 | No `permission-denied` or 403 from `firestore.googleapis.com`. If one appears, a client path still writes `inventory` directly: record the path and do NOT merge more locks until it is fixed. |

### Edge cases
| # | Action | Expected |
|---|---|---|
| E1 | Offline: add a product and restock another; go online | Both drain through the gateway in order; no `permission-denied`. |
| E2 | Import the 300-row file | Chunked; all 300 arrive; no stuck-writes caption. |
| E3 | Second device: edit a product on device A, watch device B | B shows the change (reads still allowed); a conflicting edit still gives the conflict toast. |
| E4 | Queue a write offline, force-stop the app, reopen online | The write drains on its own. |
| E5 | Sign out, sign in as a staff-role member, open Inventory | Products are listed; add/edit follows the role rules of the app, and any write goes through the gateway. |

### Affected areas
Inventory (list, add, edit, restock, delete, import, photos), Orders (completion), Stock batches, Transactions, Activity log. Staff, Suppliers, Orders pages are unaffected (not locked).

### Regression
| # | Action | Expected |
|---|---|---|
| R1 | A completion that gets parked, then Discard | Order goes back to pending. |
| R2 | Edit a completed order | New total shown, Activity entry appears. |
| R3 | Add a supplier and a staff member | Both appear (their collections are not locked). |

### Monkey
| # | Action | Expected |
|---|---|---|
| M1 | 2 minutes of random taps across Inventory, Orders, Suppliers, Staff, Analysis; toggle airplane mode twice | No crash, no `permission-denied` in logcat, caption clears once online. |
