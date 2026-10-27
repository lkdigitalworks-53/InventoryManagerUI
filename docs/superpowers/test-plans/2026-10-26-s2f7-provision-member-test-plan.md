# Test plan — S2f-7: `provisionMember` only adds members

**Branch:** `fix/2026-10-26-s2f7-provision-member-target-guard` off `main` @ `b494d52` (PR #161 merged). **Design:** `specs/2026-10-26-s2f7-provision-member-design.md` (decisions D11-D16, options A/B/C).
**Covers:** `functions/lib/memberProvisionLogic.js` (new), `functions/index.js` `provisionMember`, `functions/test/memberProvisionLogic.test.js` (new, 11), `functions/test/index.handlers.provisionMemberTarget.test.js` (new, 20 registrations, 78-case matrix inside one), `test/e2e/recordOperation.e2e.test.js` (+5 emulator tests), `tests/tst_ProvisionErrorMessage.qml` (new, 4), `AuthService.qml` (one message).
**Why:** the endpoint writes with the Admin SDK, so the rules cannot see it; it merged into any existing member doc (owner demotion, un-suspend, peer-admin demotion, overwritten `joinedAt`/`invitedBy`).
**Server change plus one client string.** Takes effect with `firebase deploy --only functions`. No rules change.

## 1. What was already covered
| Layer | Covered by | Gap |
|---|---|---|
| Unit | `functions/test/*` 835 | none for the target's existing doc |
| Functional | `index.handlers.remaining.test.js` (14 provisionMember tests), `membershipAuthority` (caller identity) | every test seeded a target with NO member doc |
| Rules | not applicable (Admin SDK) | |
| E2E | `recordOperation.e2e.test.js` 96 in total | no provisionMember test |
| QML | none for `_provisionErrorMessage` | no mapping test |

## 2. Unit / functional (genuinely run in the session)
`cd functions && npm ci && npm test` -> **866 / 866** (835 + 11 + 20). New lib file: 100% line, branch, function.
| ID | Scenario | Proves |
|---|---|---|
| U1-U9 | `decideProvision` table: null, owner (any status), non-active (12 status values), role differs (6 pairs), exact repeat, bad role shapes, non-object input (10 values), `{}`, frozen input | the whole policy, fail closed |
| U10 | seeded monkey, 2000 docs, independent oracle; asserts every branch is reached | no unforeseen shape creates or repeats |
| H1 | probe P2 admin names the owner | 409, owner doc identical, zero writes |
| H2 | probe P3 suspended target | 409, status stays suspended |
| H3 | owner and admin re-role themselves | 409 |
| H4 | admin vs peer admin (2 roles), owner vs admin (2 roles) | 409 `role-differs` (D-1 parity) |
| H5 | promote staff to manager | 409 |
| H6 | existing doc without status | 409, not repaired |
| H7 | control: new member by uid; new member by email | 200, doc has role, `active`, `invitedBy`, `joinedAt`; users doc gets the tenant |
| H8 | exact repeat after the doc was aged | 200, no write at all, `joinedAt`/`invitedBy` survive |
| H9 | unknown role string normalised to staff before the comparison | staff vs staff = repeat, admin vs staff = refused |
| H10 | target is owner of ANOTHER tenant | added here, other tenant and active tenant untouched |
| H11 | manager caller / admin assigning admin, target is the owner | 403 first (D13): no probing |
| H12 | by email, existing account already a member | 409, `createUser` never reached |
| H13-H14 | refusal log: actor, target, reason, capped tenant; success logs nothing | observability, `member-exists` carries no reason |
| H15 | read order: member doc first, `users/{target}` only on create | lean reads |
| H16 | transaction failure -> 5xx, never 409 | error class kept |
| H17 | MATRIX 2 callers x 13 target states x 3 requested roles = 78, independent oracle | every outcome and every stored doc |
| H18 | seeded monkey, 300 calls incl. self-target, owner, `viewer`, bad roles | an existing doc never changes; no owner is ever minted |
| H19 | guard: exactly one writer of member docs in `index.js`, after the decision | a new write path cannot skip the guard |
- **TDD proof (run):** with the old handler restored (`git stash` of `index.js` only) **14 of 31** new tests fail.
- **Mutation check (run, 8 mutants):** drop owner check -> 2 fail (reason code only; behaviour is equal because the endpoint can never request `owner`, so it is an equivalent mutant for outcomes); drop status check -> 6; drop role-differs -> 9; repeat becomes create -> 7; falsy means create -> 1; ignore the verdict -> 12; refusal answers 200 -> 10; never read the member doc -> 13. All caught.
- **Happy path:** H7, H8, matrix create/repeat rows. **Negative:** H1-H6, H11, H12. **Edge:** U-table shapes, H6, H9, H10. **Multi-scenario:** H17. **Monkey:** U10, H18.

## 3. Rules
Not applicable (Admin SDK). Expected CI: Rules unchanged.

## 4. E2E (emulator, CI job `e2e-tests`, `recordOperation.e2e.test.js`)
Written, NOT run in the sandbox (no emulator). Expected: E2E +5.
| ID | Test | Proves |
|---|---|---|
| E1 | owner re-provisions the seeded staff as manager | 409, doc identical |
| E2 | owner names their own uid with role admin | 409, owner doc identical |
| E3 | seeded staff `suspended`, invited as staff | 409, still suspended (restored in `finally`) |
| E4 | new email by owner, then the exact repeat | 200 created, 200 not created, doc identical, `invitedBy` = owner |
| E5 | two identical invites at once for a real Auth user | both 200, one member doc (real transaction contention) |
Cleanup deletes the created member, users and Auth docs.

## 5. QML (CI only, no Qt in the sandbox)
`tst_ProvisionErrorMessage.qml`: 5 functions (sweep added one): `member-exists` text points at "Team members" (the real label); it does not promise "Change their role" (an admin facing the owner or a peer admin cannot); every code in the hand-kept list has its own text; the two permission codes share one; empty/undefined/unknown fall back.

## 6. Counts
Functions **866** (was 835). QML +5 test functions after the sweep (+4 before), **CI count = functions + 2** (the JUnit report also lists `initTestCase` and `cleanupTestCase` for every new TestCase file; same +2 seen for `tst_MemberPolicy` in #164). E2E +5. Rules unchanged. Observed on the #165 head BEFORE the sweep (4 functions): QML 2118, Functions 866, Rules 106, E2E 101 = 3191; the sweep head should read QML 2119. Read the new CI comment before trusting this line. **Do not trust a predicted grand total: read it from the CI comment on the PR** (Skill 131 rule 11).

## 7. Deploy and rollback (Taher)
1. Merge when CI is green. 2. `firebase deploy --only functions`. 3. Rollback: revert, same command. No data migration.

## On-device and server test plan (Taher, after the deploy)
All unticked. **Honest scope:** `Gateway.provisioningAvailable` is `false`, so the app cannot call this endpoint; the phone only proves nothing regressed. The endpoint itself is proved with `curl` and a real ID token.

**Prerequisites**
- P1. Functions deployed to dev. P2. Dev tenant with the owner (device A), one staff member and one admin (created from the Team Members screen or the console), all `status: active`.
- P3. An ID token for each: `curl -s "https://identitytoolkit.googleapis.com/v1/accounts:signInWithPassword?key=<WEB_API_KEY>" -H 'Content-Type: application/json' -d '{"email":"<e>","password":"<p>","returnSecureToken":true}'` -> `idToken`. (Google-only accounts: use the Auth emulator or skip those rows.)
- P4. Firestore console open on `tenants/<T>/members`.
- P5. Base call (replace the bracketed parts): `curl -s -X POST https://asia-south1-inventorymanager-48392.cloudfunctions.net/provisionMember -H "Authorization: Bearer <idToken>" -H 'Content-Type: application/json' -d '{"env":"<your env>","uid":"<targetUid>","role":"<role>"}'`

### Happy path
| # | Action | Expected |
|---|---|---|
| DH1 | As owner, invite a NEW Auth account's uid with role `manager` | `{"ok":true,...}` 200; member doc exists: role `manager`, status `active`, `invitedBy` = owner uid, `joinedAt` set |
| DH2 | Send the identical call again | 200 `{"ok":true,"uid":...,"created":false}`; the member doc is byte-identical (same `joinedAt`) |
| DH3 | Phone (owner): open Team Members | list loads, new member listed with role manager |

### Negative (each: member doc in the console unchanged afterwards)
| # | Action | Expected |
|---|---|---|
| DN1 | As ADMIN, target = owner uid, role `staff` | 409 `member-exists`; owner doc still `owner` |
| DN2 | As owner, target = the staff member, role `manager` | 409; role still `staff` |
| DN3 | Suspend the staff member in the console, then invite them as `staff` as owner | 409; status still `suspended`; restore to `active` afterwards |
| DN4 | As admin, target = another admin, role `staff` | 409; peer admin still `admin` |
| DN5 | As owner, target = own uid, role `admin` | 409; still `owner` |
| DN6 | As MANAGER or STAFF token, any target | 403 `not-authorized` |
| DN7 | As admin, role `admin` | 403 `role-not-allowed` (before the target is looked at) |
| DN8 | Token of an account with no member doc | 403 `no-tenant-context` |
| DN9 | Cloud Functions log (`firebase functions:log --only provisionMember`) | one `provisionMember refused` warning per DN1-DN5 with actor, target, reason (`owner`, `role-differs`, `not-active`, `role-differs`, `owner`) |

### Edge
| # | Action | Expected |
|---|---|---|
| DE1 | Role `"superadmin"` for an existing active staff member | 200 (normalised to staff = exact repeat) |
| DE2 | Role `"superadmin"` for an existing active admin | 409 |
| DE3 | A uid that is owner of ANOTHER tenant, not a member here | 200; the other tenant's docs unchanged. NOTE: this pins today's "no consent" invite-by-uid, see KNOWN-ISSUES; flip this row if an accept step is added |
| DE4 | Member doc with its `status` field deleted in the console | 409 (strict); restore it afterwards |

### Multi-scenario / monkey
| # | Action | Expected |
|---|---|---|
| DM1 | Run DH1's call twice in parallel (two terminals) | both 200; one member doc |
| DM2 | 10 rapid mixed calls from DN1-DN5 | never a 5xx; no member doc changes |

### Affected-area regression (phone)
| # | Action | Expected |
|---|---|---|
| DR1 | Owner: Team Members, change a role (rules path) | still works (this slice does not touch it) |
| DR2 | Owner: Suspend then re-activate the staff member | still works |
| DR3 | Add Staff with "Create app login" ticked | the staff record saves; the notice says login access will be enabled once the server is set up (flag still dormant) |
| DR4 | Invite by UID dialog | same dormant notice |
