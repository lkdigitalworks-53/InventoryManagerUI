# S2f: authorization hardening (design)

**Date:** 2026-10-24. **Status:** S2f-1 implemented (PR-A), S2f-2 implemented (PR-B, stacked), S2f-3 to S2f-6 designed, not started.
**Parent:** `2026-10-19-p1-s2-design.md` (S2c locked `inventory`), `2026-10-24-pr156-final-sweep.md` (found F1, F2).
**Decisions marked "default" were taken by the author so the work could proceed in one session. Taher can veto any of them in the PR; each is cheap to reverse.**

## 1. Findings (all proven, none speculative)

| ID | Finding | Where | Proof | Severity |
|---|---|---|---|---|
| F3 | **The gateway trusts the client-writable `users/{uid}` doc.** `deriveContext` read `tenantId` and `role` from it and, when the member doc did not exist, kept that role. Any signed-in account could write `{tenantId: <victim>, role: "owner"}` to its own doc and then call every gateway endpoint as that tenant's owner. A removed member whose users doc survives keeps full access too: `AuthService.cleanupStaffAuthDocs` tries to delete the other user's `users/{uid}`, which the rules forbid (`allow delete: if false`), so the delete fails with only a console warning. | `functions/index.js` `deriveContext` | Handler test red before the fix (non-member got 200 on `recordMutation`); 40 of 88 new tests fail on the old code. | **Critical** (cross-tenant takeover) |
| F2 | **A suspended member keeps access.** Rules `isMember` only checks `exists()`; `isOwner` / `isAdmin` ignore `status`, so a suspended admin can still manage members. The gateway also ignored status for the role-less path above. | `firestore.rules`, `deriveContext` | Probe PR #157 (CI run 40103744373): suspended member read `inventory`, wrote `orders`. | High |
| F1 | **Any member can rewrite memberships**, including promoting itself to owner: the wildcard `match /{collection}/{docId}` also matches `members/{uid}` and Firestore ORs matching rules. | `firestore.rules:174-180` | Probe PR #157: 5 of 6 red, control green. | **Critical** |
| F4 | Server role gates for `staff` delete and the `removed_staff` tombstone are bypassable by a direct write (collections still open). | `functions/index.js:203-218` vs rules | Audit in the sweep report, section 5. | High |
| F5 | `orders`, `suppliers` writable directly: a direct write skips `audit_log`; `orders` carry money fields. | rules | same | Medium |
| F6 | No test existed for the `users`, `tenants`, `members` rule blocks. | `test/firestore.rules.test.js` | zero tests | Medium |
| F7 | `activity_log` (client-writable UX feed) sits next to `audit_log` (compliance). `counters/*` client-writable (can burn ids, cannot overwrite). | rules | audit | Low, document |
| F8 | `actorName` in audit rows can fall back to the self-writable `users.name`. The uid is always recorded beside it. | `deriveContext` | read | Low, kept, documented |

F3 is the reason this is more than the two items the sweep named. It was found by reading `deriveContext` while designing the F2 fix, which is the rule of Skill 127 applied one layer down: **a rule is only as strong as the weakest place that decides the same question.** Three places decide "is this person allowed in this tenant, and as what?": the Firestore rules, the gateway, and the client. Only the first two are boundaries.

## 2. Principles this design follows

1. **Membership is the only authority.** The member doc (`tenants/{t}/members/{uid}`: `role`, `status`) decides tenant, role and status, in the rules and in the gateway. `users/{uid}` is a convenience pointer for the client (which tenant to open at login); it may name a tenant, it never grants anything.
2. **One definition, two enforcers.** "Active" is defined once in prose and implemented twice (rules `isActiveMember`, gateway `deriveContext`); a parity test pins each side. A missing `status` counts as active in both (legacy docs); any other value than `active` is refused in both.
3. **Fail closed.** Missing member doc, empty role, unsafe tenant id, unknown status: refused.
4. **Default-deny is the end state, not a blacklist.** Every new explicit `match` block under a wildcard is a latent F1. See S2f-5.
5. **Each slice leaves the app working** and is small enough for one session and one CI cycle.

## 3. Slices (each one session)

| Slice | Scope | Needs | Status |
|---|---|---|---|
| **S2f-1** (PR-A) | Gateway `deriveContext`: member doc required, role from member only, status gate, safe tenant id. 88 handler tests over all 10 handlers, 3 emulator e2e. Server only. | functions deploy | **done** |
| **S2f-2** (PR-B, stacked on A) | Rules: `isActiveMember` (one `get()`), used by `isMember` / `isOwner` / `isAdmin`; `members` excluded from the wildcard's write guard; tests for the `users`, `tenants`, `members` blocks (probe tests + the matrix in the test plan). | rules deploy | **done** (CI is the oracle) |
| S2f-3 | Client wording only: `FailureCause.js` says "your access was removed or suspended" for `no-tenant-context` (today: "could not resolve this account's shop"). Login for a suspended member: clear screen instead of empty lists. Skills `qt-ui-design` + `qt-qml`. | app build | designed, not started |
| S2f-4 | Lock `staff` + `removed_staff` (closes F4), then `orders`, `suppliers` (F5): one name each in `isGatewayWriteOnlyCollection`; the `working/` test loop and R08 move to `activity_log` / `config`. | rules deploy + device pass of staff / order / supplier actions | designed, not started |
| S2f-5 | Replace the wildcard's blacklist with an allow-list of client-writable collections (`activity_log`, `config`, `counters`, `_migrations`); reads unchanged. Default-deny forever, closes look-alike names. | after S2f-4 proves the list | designed, not started |
| S2f-6 | Backfill / tighten: members without `status` become `active` explicitly, then rules and gateway drop the legacy tolerance. Also: server-side counter minting so `counters` can be locked (F7). | dev data check | designed, not started |

**Why this order.** F3 and F1 are privilege escalations: do them first, smallest diffs, nothing else rides along. S2f-1 is verifiable end to end in the sandbox (Node), so it goes first; S2f-2 can only be proved by CI, so it goes second and stacked. S2f-4 is a behaviour change that needs a device pass, so it is its own slice. S2f-5 is the better end state but touches every collection, so it waits for the evidence S2f-4 produces.

## 4. Decisions, trade-offs, default taken

**D1. How to fix F3.**
- (a) Require the member doc in `deriveContext`; role from it only. *Default.* About 10 changed lines, one choke point for 10 handlers, closes F3 and the removed-member case.
- (b) Also lock `users/{uid}` fields in the rules (`tenantId`, `role` not client-writable). Rejected for now: the client legitimately writes these at onboarding and leave-workspace (`AuthService.qml` 566, 904, 985), so it needs a server function for onboarding first. Worth doing only if the client ever starts trusting `users.role` for something that matters; today it does not (the server is the boundary).
- (c) Custom auth claims for tenant and role. Strongest and cheapest per request, but needs claim refresh on every role change and a token refresh on the client. Over-scoped for a solo dev project; revisit with multi-tenant switching.
- *Cost of (a):* one extra Firestore read per request was already there (the member doc was read when it existed). No new read. A user with a users doc but no member doc is now refused instead of served; that is the point.

**D2. Missing `status` on a member doc.** Default: treated as active in both enforcers, exactly as the gateway did before. Strict (require `active`) is more secure but locks out any legacy doc without `status` the moment the rules deploy, including possibly Taher's own dev owner. Mitigation until S2f-6: bootstrap and member-admin rules already require a valid status on every new write, so only pre-status docs can lack it. **Question for Taher:** does your dev owner member doc have `status: "active"`? If yes for every dev member, say so and S2f-6 can be done right after S2f-2.

**D3. Empty or missing member `role`.** Refused as "no privilege", not a fallback to `users.role`. Fails closed; a member with no role could do nothing anyway under the rules (`role` is required by `myRole`).

**D4. Tenant id safety.** `deriveContext` rejects tenant ids that are not a safe path segment (the existing `PhotoValidation.isSafePathSegment`). The id becomes a document path (`tenants/<id>/members/<uid>`); a `/` would walk to a different document. Defence in depth: the member lookup would fail anyway because clients cannot create deeper documents.

**D5. `actorName` fallback to `users.name` (F8).** Kept. Changing it changes the audit format; the uid is always beside it. Revisit in S2f-6.

**D6. One PR or two.** Two, stacked. A is server only and fully tested in the sandbox; B is rules only and only CI can prove it. If B needs CI iterations, A is not held up, and the two deploy commands stay separate (`firebase deploy --only functions`, `firebase deploy --only firestore:rules`).

**D7. Allow-list now (S2f-5 first) vs blacklist now.** Allow-list is future proof and I recommend it as the end state. Doing it before the F1 fix would put a whole-file restructure in front of a 6-line privilege-escalation fix, and every missed writer would be a regression with no test to catch it. So: fix F1 minimally, then restructure with S2f-4's audit as evidence. Cost of waiting: the file carries a blacklist for two more slices; the new tests for `members` pin it meanwhile.

## 5. Deploy order and rollback (Taher)

1. Merge PR-A, deploy functions (`firebase deploy --only functions`). Check: sign in on a device, add a product, open the stuck-writes caption (no 403).
2. Merge PR-B, deploy rules (`firebase deploy --only firestore:rules`). Check with the on-device lists in the two test plans.
3. Rollback: revert the PR, redeploy the same target. No data migration in either slice.
4. Order matters little for safety (each closes its own hole), but deploy functions first: it is the one that stops a cross-tenant takeover and carries the smaller device risk.

## 6. Open questions for Taher (defaults applied above)

1. D2: do all dev member docs have `status: "active"`? (A Firestore console look at `tenants/<id>/members` settles it.)
2. Is there more than one dev tenant, or any real user on dev data? (Decides how urgent F3 is for the data that exists today; the code fix is the same.)
3. S2f-4 now (after B) or S2d (kinds on deltas) first?
4. S2f-3: do you want a dedicated "access suspended" screen, or only the clearer error text?
