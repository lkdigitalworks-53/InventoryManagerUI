# Test plan — S2f-4 + S2f-5: default-deny writes (allow-list wildcard, orders/staff/suppliers/removed_staff locked)

**Branch:** `fix/2026-10-24-s2f4-default-deny-writes`, STACKED on `fix/2026-10-24-s2f2-members-rules` (PR #160), which is stacked on PR #159. **Design:** `specs/2026-10-24-s2f-authz-hardening-design.md` (F4, F5, D7).
**Covers:** `firestore.rules` (the wildcard's write guard becomes the allow-list `isClientWritableCollection`: `activity_log`, `config`, `counters`, `_migrations`; helpers `isLedgerCollection`, `isGatewayWriteOnlyCollection`, `isAccessControlCollection` removed) and `test/firestore.rules.test.js`.
**Why:** the blacklist failed open twice (S2c `inventory`, F1 `members`) and left `orders`, `staff`, `suppliers`, `removed_staff` directly writable: a direct write skips the gateway's role gates (staff delete = owner/admin, `removed_staff` tombstone) and the `audit_log` row (F4, F5). Done as ONE slice (design said two) because with no production data and a complete writer audit the allow-list locks all four by construction, and a separate per-name step would only have added two deploys.
**Writer audit (client code, grep of every `FirebaseService.put/patch/putMany/remove/mintCounter*`):** `activity_log`, `config/categories`, `config/orderChannels`, `_migrations/fifo_v1`, `counters/*`; `users`, `tenants`, `members` have their own blocks. `orders`, `staff`, `suppliers`, `removed_staff`, `inventory`, `stock_*` go through `Gateway` (direct mode was deleted in S2a-2). QML e2e suites make no direct writes.
**Takes effect on `firebase deploy --only firestore:rules`.** #159 (functions) is merged: deploy functions first, then #160 and this PR's rules together (they are one file).

## 1. Already covered
Ledger, server-only, inventory lock, pending_cleanup pins (52 rules tests) + PR #160's 31.

## 2. Rules tests (CI only)
Rules **92** = 83 (after #160) - 9 (the old "working tier is open" tests, now wrong) + 18 new, **observed green on `a147caf`: total 3127** (QML 2104, Functions 835, Rules 92, E2E 96). Review sweep adds 3 tests (below): predicted Rules **95**, total **3130**. Rules = `firestore.rules.test.js` (76 -> 85 -> 88) + `storage.rules.test.js` (7).
| Group | Tests | Proves |
|---|---|---|
| client-writable x 4 names | 8 | active member creates/updates/deletes; non-member, anonymous and suspended owner cannot read or write, data untouched |
| gateway-only x 4 names (`orders`, `staff`, `suppliers`, `removed_staff`) | 8 | all four roles read doc and list, no role creates/overwrites/updates/deletes, data untouched; outsider and anon denied |
| default deny | 2 | 14 unknown / look-alike / case-variant names and two sub-collection paths denied; reads of an unknown name still work for an active member only |
| Re-pointed pins | 2 | S2c look-alike pin flipped to deny; R08 now asserts orders write is denied and `activity_log` write succeeds |
| Review sweep (2026-10-25) | 3 | every role writes all four names (staff mints ids); PIN that `counters` accepts any value from any role (rewind, non-number, delete: S2f-6 residual, flips when minting moves server-side); seeded monkey, 100 mutated names x create/update/delete, only the exact allow-list names succeed, denied writes leave data untouched |
Happy path: client-writable. Negative: gateway-only, non-member, suspended. Edge: names (case, suffix, unicode-free look-alikes), sub-collections. Multi-scenario: 4 roles x 4 collections x 4 ops. Monkey: PR #160's last test, the 14-name sweep, and the seeded 100-iteration monkey (fixed seed 20261025, replays exactly; guarded so it must hit at least one allowed name).

## 3. Functions / E2E
No change: Functions 835, E2E 96. The gateway writes with the Admin SDK, which skips rules.

## Deploy and rollback (Taher)
`firebase deploy --only firestore:rules`. Rollback: revert, redeploy. No data migration.

## On-device test plan (the writer audit is grep-based, the device pass is what proves it)
**Prerequisites:** functions and rules deployed (all three PRs); a NEW tenant with owner, admin, manager, staff users; `adb logcat | grep -i "permission\|PERMISSION_DENIED\|403"` running on the owner device. **Any `PERMISSION_DENIED` on a write in logcat during the passes below is a missed writer: send me the path.**

### Happy path (owner, then each role)
| # | Action | Expected |
|---|---|---|
| H1 | Add product with stock, edit, restock, delete | Works; Activity feed shows rows. |
| H2 | Create an order, add items, complete it, return an item | Works; stock changes; no permission error. |
| H3 | Add a supplier, edit, delete | Works. |
| H4 | Add a staff member (HR record), edit, delete (owner/admin) | Works; manager delete is refused with the role message. |
| H5 | Settings: add a category, add an order channel | Works (`config`). |
| H6 | Create several products and orders quickly | Ids keep minting (`counters`); no duplicate ids. |
| H7 | Bulk import 300 products | Works. |
| H8 | Fresh install, first launch | Migration marker written once (`_migrations`), no error. |

### Negative
| # | Action | Expected |
|---|---|---|
| N1 | With a staff ID token, PATCH `tenants/<T>/orders/<id>` through the Firestore REST API | 403. Same for `staff`, `suppliers`, `removed_staff`, `brand_new_collection`. |
| N2 | Same with the owner token | 403 (no role bypass). |
| N3 | Staff tries to delete a staff record from the app | Refused by the gateway role gate (no longer bypassable by a direct write). |

### Edge
| # | Action | Expected |
|---|---|---|
| E1 | Offline: create an order, go online | Drains through the gateway; no direct write attempted. |
| E2 | Two devices edit the same supplier | Lock banner / CAS conflict as before. |
| E3 | Suspend a user, they try `activity_log` write | Fails (suspended). |
| E4 | Staff-role user creates a product and an order, then reads the Activity feed | Ids mint (`counters` as staff), activity row appears; no `PERMISSION_DENIED`. |

### Affected areas / Regression
Everything that persists: orders, suppliers, staff, categories, channels, activity, id minting, import, migration. Reads everywhere (unchanged).

### Monkey
Rapid add/delete of orders and suppliers from two devices for 2 minutes; no `PERMISSION_DENIED`, no crash, ids unique.
