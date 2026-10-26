# S2f-7: `provisionMember` only adds members (design, built in the same PR)

**Date:** 2026-10-26. **Status:** built. Decisions marked "default" were taken by the author so the slice fits one session; Taher can veto any of them in the PR, each is cheap to reverse.
**Parent:** `2026-10-24-s2f-authz-hardening-design.md` (S2f-1..6), finding 6 of `2026-10-25-pr159-final-sweep.md` (probes P2, P3). Taher decided on 2026-10-25 (Q2) that this is its own slice.

## 1. Finding (proven in the PR #159 probes, reproduced again in the handler harness)
`provisionMember` writes `tenants/{t}/members/{uid}` with the Admin SDK, so `firestore.rules` never sees it. It merged into whatever member doc the target already had:

| # | What an owner or admin could do through it | Policy it broke |
|---|---|---|
| P2 | admin sends `{uid: <owner>, role: "staff"}` -> the owner's doc becomes `staff`; the shop can end with no owner | rules and client: an owner's membership cannot be changed |
| P3 | invite a `suspended` member -> `status: "active"` is merged in, silently un-suspending them | suspension is an explicit act (rules `canManageTarget`, D-1) |
| P4 | admin demotes a peer admin to manager or staff | D-1: an admin acts only on manager/staff targets |
| P5 | `joinedAt` and `invitedBy` are overwritten on every call | the roster would lie about who added whom, and when |
| P6 | owner or admin re-roles themselves | self-demotion with no owner left is unrecoverable from the app |

**Severity, honestly.** Needs an owner or admin token (not a cross-tenant hole like F3). The client cannot reach it today: `Gateway.provisioningAvailable` is `false`, so only a direct HTTP call exploits it. It becomes reachable for every admin the day login provisioning is switched on (multi-role design, slice L1), so it must be closed first. Medium now, High after L1.

## 2. Options and trade-offs
| Option | What | For | Against |
|---|---|---|---|
| **A (default)** | `provisionMember` only ADDS. Existing member doc: exact repeat (same role, already active) = 200 with no write; anything else = 409 `member-exists`. Role and status changes of an existing member stay on the rules path. | Hierarchy defined once (rules `canManageTarget`), no third copy of it. About 10 lines in the handler, one pure function, fully testable in Node. Retry after a lost response still works. | A flow that "re-invites" to change a role or re-activate now gets 409 and must use Team Members. None exists in the app today (the endpoint is dormant); the Team Members dialog already offers role and Suspend/Remove under D-1. |
| B | Keep merging, but add the hierarchy check (`canManageTarget`) and "keep status" inside the endpoint | Re-invite keeps working as a role editor | Three enforcers of one policy (rules, client helper, server): drift is the exact failure Skill 129 rule 10 warns about. Bigger diff. `status` handling still needs a rule of its own. |
| C | Delete role/status writes from the endpoint, add a separate `changeMemberRole` function | Cleanest end state | A new endpoint is new surface and a new deploy; nothing needs it yet (YAGNI). Revisit if the rules path is ever removed (custom claims, D1(c) of the S2f design). |

**Default: A.** Veto path: B is a swap of `decideProvision` for a policy call; the tests in `index.handlers.provisionMemberTarget.test.js` flip for the cases listed in the test plan, section 2.

## 3. Decisions
- **D11 The decision is a pure function** (`functions/lib/memberProvisionLogic.js`, `decideProvision(existing, requestedRole)` -> `create | unchanged | refuse`). The handler reads the member doc inside the transaction and obeys the verdict, so two concurrent invites cannot both "create". A structural test pins that `index.js` has exactly one writer of member docs and that it comes after the decision.
- **D12 One public error code, `member-exists` (409).** The reason (`owner`, `not-active`, `role-differs`, `unreadable`) is log-only with actor, target and a capped tenant id. The caller already knows the uid or email it sent, so nothing about other people leaks; and an owner target looks the same as any other member.
- **D13 Order of refusals is unchanged and still comes first:** token, tenant context, caller role (`not-authorized`), `canAssignRole` (`role-not-allowed`), then the target. A manager therefore cannot probe which uids are members through 409 versus 403.
- **D14 Exact repeat is not an error.** The client retries on a lost response (the outbox resends on a 5xx or a lost response); a 409 on the retry of a call that succeeded would show a failure for a success. It writes nothing, so `joinedAt` and `invitedBy` survive.
- **D15 A missing or non-`active` `status` on the existing doc is refused,** never repaired (D2 of S2f: strict, no legacy data).
- **D16 Client:** one new message for `member-exists` in `AuthService._provisionErrorMessage`, pointing to Team Members. No new UI, no flow change (qt-ui-design: nothing to design; the flag is still dormant).

## 4. Not done on purpose (open, see `KNOWN-ISSUES.md`)
1. **No `audit_log` row for membership changes.** `provisionMember`, and the rules-path role/status edits, leave no ledger entry; the gateway's `ENTITY_COLLECTIONS` map has no `member` entity. For a Rule 11(g) auditor "who gave Ravi admin, and when" is an access-control question. Needs a design (entity name, where rules-path edits would be recorded, since the client writes those directly). Not in this slice.
2. **An unknown `role` string silently becomes `staff`** (`provisionMember` normalisation, pre-existing, pinned by an old test). Safer to refuse with 400. Behaviour change for a dormant endpoint; ask Taher.
3. **`body.uid` is not checked with `isSafePathSegment`** before it becomes part of a document path. `getUser(uid)` must succeed first, and an app-created Auth uid cannot contain `/`, so it is not exploitable today; a one-line hardening if wanted.
4. Finding 9 of the #159 sweep (plain-text 500 on a Firestore blip in the identity step) stays open.

## 5. Questions for Taher (defaults applied above)
1. Option A (add-only) or B (role editor with the hierarchy inside the endpoint)? Recommendation A.
2. Should an unknown role become a 400 instead of `staff` (item 4.2)?
3. Do you want membership changes in `audit_log` before staff login goes live (item 4.1)? Recommendation yes, as its own slice before multi-role L1.
