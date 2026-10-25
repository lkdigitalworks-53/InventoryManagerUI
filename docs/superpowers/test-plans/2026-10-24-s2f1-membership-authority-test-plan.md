# Test plan — S2f-1: the gateway trusts the member doc, never `users/{uid}`

**Branch:** `fix/2026-10-24-s2f1-membership-authority` off `main` @ `b749a80` (PR #156 merged). **Design:** `specs/2026-10-24-s2f-authz-hardening-design.md` (findings F2, F3, decisions D1-D5).
**Covers:** `functions/index.js` `deriveContext` (the single choke point for 10 endpoints), `functions/test/index.handlers.membershipAuthority.test.js` (new, 113 tests after the 2026-10-25 sweep), `test/e2e/recordOperation.e2e.test.js` (+3 emulator tests), docs.
**Why:** `users/{uid}` is writable by its own user, field by field. The old `deriveContext` kept `users.role` when no member doc existed, so a signed-in account could write `{tenantId: <victim>, role: "owner"}` to its own doc and act as that tenant's owner. A removed member whose users doc survives (the client cannot delete another user's users doc) also kept full access. Status `suspended` was ignored on that path.
**Server only. No rules, QML or client change.** Takes effect when Taher runs `firebase deploy --only functions`.

## 1. What is already covered (before this change)
| Layer | Covered by | Notes |
|---|---|---|
| Unit | `functions/test/*` 722 (run in the sandbox, `npm test`) | `deriveContext` itself had no direct test; per-handler "no tenant context" tests used an EMPTY docs map only |
| Functional | handler harness (`testSupport/handlerHarness.js`) | `seedHappyPathAuth` always seeded a member doc, so the fallback path was never exercised |
| Rules | `test/firestore.rules.test.js` 45 + storage 7 | no test for `users`, `tenants`, `members` blocks (PR-B) |
| E2E | `test/e2e` 93 | seeds create users + member docs for both identities; they stay valid |
| Regression | the 722 above | all still green after the change (verified, section 2) |

## 2. Unit / functional (genuinely run in the session)
`cd functions && npm ci && npm test` -> **835 / 835** (722 + 113). New file, per handler (10 handlers: `recordMutation`, `recordDelta`, `recordMutationsBatch`, `recordOperation`, `acquireLock`, `releaseLock`, `provisionMember`, `computeAnalysis`, `uploadProductPhoto`, `deleteProductPhoto`) x 8 scenarios = 80, plus 8 cross-handler tests.

| ID | Scenario (each x 10 handlers) | Proves |
|---|---|---|
| A1 | users doc `{tenantId: victim, role: owner}`, no member doc -> 403 `no-tenant-context`, zero writes | F3 closed |
| A2 | member of tenant HOME, users doc points at VICTIM -> 403 | membership of one tenant never opens another |
| A3 | removed member (users doc survives, member doc gone) -> 403 | removal is effective |
| A4-A6 | member status `suspended`, `inactive`, `banned` -> 403 | F2 on the server, any non-active value |
| A7 | unsafe tenant id (`a/b`, `..`, `tenant/staff/S1`, `a b`, `x\y`) -> 403, zero writes | D4 |
| A8 (control) | real active owner is NOT refused as `no-tenant-context` | bodies are valid, the table is not vacuous |
| X1 | member doc without `status` -> 403 on all 10 handlers | D2 closed: strict, no legacy tolerance (dev data confirmed all `active`) |
| X9 | actorName from member doc (displayName, name), never the users doc | F8 closed (S2f-6) |
| X2 | users.role owner + member.role staff -> product delete 403 `role-not-allowed` | role from the member doc only |
| X3 | same, staff delete | same |
| X4 | users.role owner + member.role staff -> `provisionMember` 403 `not-authorized` | cannot mint accounts |
| X5 | member.role `""` + users.role owner -> no privilege | D3 fail closed |
| X6 | users doc missing / `{}` / empty tenantId / no tenantId -> 403 | unchanged behaviour pinned |
| X7 | monkey: 3 passes x 10 handlers x 4 refusal states, never 200, never a write | randomised-order stability |
| X8 | guard: count of `await deriveContext(` in `index.js` equals the table size | a new endpoint cannot skip this file |

- **TDD proof:** with the old `deriveContext` restored, 56 of 113 fail (57 pass: controls and unchanged paths).
- **Mutation check (run):** drop the member-exists check -> 31 fail; drop the status check -> 31 fail; restore `|| user.role` -> 1 fails (X5, the only case where the member role is empty); drop the safe-segment check -> 8 fail. All four caught.
- **Happy path:** A8, X1. **Negative:** A1-A7, X2-X6. **Edge:** X1, X5, X6, A7 values. **Multi-scenario:** the whole table (10 handlers). **Monkey:** X7.

## 3. Rules
Not changed in this slice (PR-B). Expected CI: Rules **52** unchanged.

## 4. E2E (emulator, CI job `e2e-tests`, `recordOperation.e2e.test.js`)
**Observed on CI: 96** (baseline 93 + 3 new). Written, NOT run in the sandbox (no emulator).
| ID | Test | Proves |
|---|---|---|
| E1 | seeded staff user, member doc deleted, users doc left -> `recordMutation` 403 `no-tenant-context`, no audit row | removed member, real Firestore reads |
| E2 | member status `suspended` -> `recordMutation`, `acquireLock`, `recordOperation` all 403, no audit rows | F2 end to end, three endpoints |
| E3 | restored member doc -> same user is not refused as a non-member | the seed user is restored (`finally`), later suites unaffected |
The member doc is always restored in a `finally`; cleanup also removes `authE2E-*` audit and order docs.
**CI total observed: 3087** (QML 2104, Functions 835, Rules 52, E2E 96). A different number means a test was not picked up.

## 5. Deploy and rollback (Taher)
1. Merge when CI is green. 2. `firebase deploy --only functions` (dev). 3. Rollback: revert the PR, same command. No data migration.
4. **Before deploying, check once:** Firestore console > `tenants/<your tenant>/members` > every doc has a `role`. A member doc with an empty or missing `role` can now do nothing through the gateway (before, the users doc role was used).

## On-device test plan (Taher, after the functions deploy; app build from `main`)
All unticked; nothing here has been run.

**Prerequisites**
- P1. Functions deployed to dev (section 5).
- P2. Two logins on the same dev tenant: the owner (device A) and a staff member (device B). Staff member created from the app (Team Members) so it has a users doc and a member doc.
- P3. Firestore console open on `tenants/<T>/members/<staffUid>` and `users/<staffUid>`.
- P4. `adb logcat` on both devices, filter `qml`; look for `403`, `no-tenant-context`, `stuck`.

### Happy path (the change must be invisible to a legitimate member)
| # | Action | Expected |
|---|---|---|
| H1 | Device A (owner): add product, restock, edit price, complete an order, delete a product | All succeed; no stuck-writes caption; Activity shows each action. |
| H2 | Device B (staff): complete an order, add a supplier | Succeeds. Product delete is refused with the role message (unchanged). |
| H3 | Device A: add a staff member with a login (`provisionMember`), upload and delete a product photo, open Analysis | All succeed. |
| H4 | Open the same order on both devices | Lock banner behaves as before. |

### Negative
| # | Action | Expected |
|---|---|---|
| N1 | Device A: Team Members > Suspend the staff member. Device B: edit a product | The write is refused (the existing `no-tenant-context` cause text from `FailureCause`); it parks as stuck; Activity has no row. Reads on B still work until PR-B (rules). |
| N2 | Device A: Activate the staff member again. Device B: Retry now on the stuck write | Succeeds on the next request, no restart needed. |
| N3 | Console: delete `members/<staffUid>` only (leave `users/<staffUid>`). Device B: edit a product | Refused as in N1. Before this fix the write succeeded. |
| N4 | Console: set staff `role` to `""` (and again to `"viewer"`) in the member doc. Device B: add a supplier | Refused as in N1 (invalid role); never executed, not even as staff. Restore the role after. Function logs show `deriveContext refused` with `reason: invalid-role`. |
| N5 | (optional, cross-tenant proof) With a second Firebase account that is NOT a member: sign in with the Auth REST API, `PATCH` its own `users/<uid>` with `tenantId` = your tenant and `role` = `owner` (the rules allow this), then `POST` the app's `recordMutation` URL (`functionUrl` in `qml/model/Gateway.qml`) with that ID token and a valid order body | HTTP 403 `no-tenant-context`. Before this fix: 200. |

### Edge cases
| # | Action | Expected |
|---|---|---|
| E1 | Console: remove the `status` field from the staff member doc. Device B: edit a product | Refused (strict, D2). Put `status: "active"` back. |
| E2 | Device A: change the staff role admin -> staff, then Device B tries a product delete | Refused with the role message on the very next request. |
| E3 | A user who belongs to two tenants switches tenant | Works; each tenant uses its own member doc. |
| E4 | Offline write on B, then A suspends B, then B goes online | The queued write is refused on drain and parks; it does not run. |

### Affected areas
Every gateway call: `recordMutation`, `recordDelta`, `recordMutationsBatch`, `recordOperation`, `acquireLock`, `releaseLock`, `provisionMember`, `computeAnalysis`, photo upload and delete, the scheduled cleanup (unchanged: it does not use `deriveContext`).

### Regression
Order completion with returns; bulk import of 300 rows; photo upload on a slow link; stuck-writes dialog Retry and Discard; staff delete by owner and by a manager (manager refused).

### Monkey
On device A toggle Suspend / Activate on the staff member 10 times quickly while device B adds products. Expected: no crash on either device; B's writes are refused while suspended and drain after the final Activate; no duplicate products.

## Sweep additions (2026-10-25, PR #159 final sweep)

Unit (`functions/test/index.handlers.membershipAuthority.test.js`, now 113 tests, Functions suite 835):
- Role allow-list, every handler: `""`, `"viewer"`, `"Owner"`, `"OWNER"`, `" owner"`, `"staff,admin"`, number, object, array, null, missing role are refused with 403 `no-tenant-context` and nothing is written, even when the users doc says `owner`; each of the four valid roles gets past the identity step.
- `tenantId` in the users doc of a wrong type or shape (number, boolean, object, array, 65 characters, non-ASCII, dot, newline, encoded slash) is refused on every handler.
- Logging: each refusal reason (`no-user-doc`, `no-tenant`, `unsafe-tenant`, `no-member`, `not-active` for suspended and for a missing status, `invalid-role`) logs exactly one warning with the uid and reason; a legitimate member logs nothing; the logged tenant id is capped at 64 characters.
- Lean identity step: a document-read recorder shows every handler reads `users/{uid}` and the member doc, and only `provisionMember` reads the tenant doc.
- `provisionMember` stamps the tenant name from the tenant doc (`name`, then `tenantName`, else empty), never from the self-writable users doc.
- Seeded fuzz (400 random users-doc / member-doc shapes x random handler, fixed seed) against an independent oracle: allowed only for an active member with a valid role in the tenant the users doc names; everything else 403 and no write.
- Updated: BC-H01 (inventory delete with an empty or unknown role is now refused at the identity step with `no-tenant-context`; `staff` and `manager` still get `role-not-allowed`).

Rules / E2E / device: unchanged by this slice (the mirrored role allow-list in `firestore.rules` is part of PR #160). Device step N4 above now also covers `"viewer"` and the log line.

Mutants run against the new tests: drop role allow-list 12 red, drop status gate 33 red, drop safe-segment 12 red, drop logging 2 red, uncapped logged tenant id 1 red; `member.role || user.role` survives (equivalent after the allow-list, not added).
