# Test plan — owner/admin-only writes on every endpoint (KNOWN-ISSUES 42)

Fixed inside PR #199 (add product, AP1) on branch `feat/2026-11-13-ap1-add-product-server-op`; the bug itself is older than AP1 and exists on `main`. Found in the review sweep of that PR. Standard format (Skill 49).
Honesty note: this changes `functions/index.js` (one helper, three call sites) and NO QML and NO rules. Every Node test below was RUN in the sandbox: functions suite 1720 -> 1730 measured on the fix alone, 1766 with AP1 and the two gap pins, all green; the new test file was run RED against the unfixed code first (6 of 10 failed, exactly the six that assert the gate; the four that guard existing behaviour passed), then GREEN after the fix. The lines added to `index.js` are all covered (none is in the uncovered list of `--experimental-test-coverage`). The one emulator case is CI-only (no emulator here): written, not run.

## What changed
`recordMutation` refused a `staff` delete, any `removed_staff` write and an `inventory` delete for every role except owner/admin. `recordOperation` and `recordMutationsBatch` did not, and their validators accept the first two, so a lowest-role token could delete a staff record or plant a tombstone with one POST. Now one helper, `isOwnerAdminOnlyWrite(entity, action)`, is called by all three endpoints right after the membership context: 403 `role-not-allowed`, zero writes, the WHOLE operation (or batch) refused.
No client sends such a write through an operation or a batch (the app deletes staff through `recordMutation`), so nothing a user does changes; a revert only reopens the hole.

## 1. Unit tests (handler level: real handler, real validators, real role derivation; apply step mocked and COUNTED)
| File | Cases | Run? | Covers |
|---|---|---|---|
| `functions/test/index.handlers.ownerOnlyWrites.test.js` (new) | 10 | RUN 10/10 (on the unfixed code 6 failed and 4 passed) | the sensitive writes (`staff` delete, `removed_staff` create / update / delete) on all four endpoint shapes (`recordMutation`, `recordMutationsBatch`, `recordOperation` as `completeOrder`, `recordOperation` as `restock`) x four roles: 403 `role-not-allowed` for manager and staff, 200 for owner and admin, and the apply step is reached exactly when allowed (zero writes on a refusal); the product delete inside an operation or a batch is still 400 `cascade-delete-not-allowed` for every role; REGRESSION: every OTHER entity x create/update/delete stays open to the lowest role on every endpoint (the gate blocks three writes and nothing else); REGRESSION: the real staff-phone operations (order-completion delta, restock delta) pass; a MIXED operation (harmless ops + one staff delete) is refused as a whole with nothing applied; a batch refuses on ANY item; the role is the MEMBER doc's (a staff member whose `users` doc claims owner is still refused on all four shapes, S2f-1) |

The test file keeps its OWN copy of the rule (`OWNER_ONLY`) on purpose: if the rule in the code drifts, the table does not move with it.

## 2. Regression tests
- All handler tests (`index.handlers.*.test.js`) pass unchanged; the full functions suite is 1730/1730.
- `recordMutation`'s behaviour is byte-identical (its inline flags became the helper; the F3b membership tests for product delete and staff delete pass unedited).

## 3. E2E (real emulator, CI only)
`test/e2e/recordOperation.e2e.test.js` +1, mirrored on the existing "BC role gate" case: a staff token (`fixture.secondIdToken`) gets 403 `role-not-allowed` for a staff delete through `recordOperation` AND through `recordMutationsBatch`, the staff record is intact and no marker is written; the owner token deletes it (200). The case cleans up its own docs in a `finally`.

## 4. Rules
Unchanged (the Admin SDK write skips them).

## On-device test plan (Taher, after merge; functions deploy only, NO app build)
Prerequisites: P1 an owner account and a staff-role account on the dev tenant; P2 Firestore console open; P3 one throwaway staff member created for the test.

### Happy path (regression: the app still works for every role)
1. As STAFF: complete an order of 1 unit. Expect success and stock minus 1 (operation path, no staff write in it).
2. As STAFF: restock a product by 2. Expect success (operation path).
3. As OWNER: delete the throwaway staff member in the app. Expect it gone (the app uses `recordMutation`, unchanged).
4. As MANAGER or STAFF: create / edit a product, an order and a supplier. Expect all allowed (the gate blocks three writes only).

### Negative (the point of the fix; `curl` with the caller's own ID token, the same body for each)
- STAFF token, `recordOperation` with `opType: "completeOrder"` and one mutation op `{ entity: "staff", entityId: <throwaway>, action: "delete", before: <its doc>, after: null }`: expect 403 `role-not-allowed`; the staff doc still exists; no `audit_log` marker.
- STAFF token, `recordMutationsBatch` with `entity: "staff"` and one delete item: expect 403, doc intact.
- STAFF token, `removed_staff` create through either endpoint: expect 403, no tombstone.
- MANAGER token, the same three: expect 403 (manager is not owner/admin).

### Edge cases
- OWNER token, the same operation body: expect 200 and the doc deleted (so the gate is not just closed for everyone).
- ADMIN token: same as owner.
- A mixed operation (an order update + a staff delete) as STAFF: the WHOLE operation is refused and the order update is NOT applied.
- A product delete inside an operation or a batch, any role: 400 `cascade-delete-not-allowed` (unchanged).

### Multiple scenarios
- Two phones at once (OWNER deleting the throwaway staff, STAFF attempting the same through `recordOperation`): the staff attempt is 403 whichever order they land; the owner's delete succeeds once.

### Monkey
- STAFF phone: complete orders, restock, import a CSV and edit products for 2 minutes while a second device replays the three refused bodies in a loop: no refused body ever writes, no legitimate action gets a 403, no `role-not-allowed` toast appears in the app.

### Affected areas
`recordOperation` (order completion, restock), `recordMutationsBatch` (bulk edits), `recordMutation` (all single writes), staff management page.

## 5. CI result (fill after push)
Head `c1b5a11` (PR #199 after merging main): Functions Tests, Firestore + Storage Rules Tests, QML Tests and E2E Tests all success, including the new emulator case; Deploy Check, Deploy to Firebase and Record Deployed Commit skipped (PR, not main). Local functions suite 1819/1819.
