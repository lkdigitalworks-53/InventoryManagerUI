# Multi-role login + cross-actor behaviour — DRAFT design (decisions OPEN)

**Status:** DRAFT 2026-10-25, written by brainstorming. **No decision here is approved.** Every `Dn` below has a recommendation and an empty `Taher:` line. Resume AFTER the compliance features are done (Taher's call, 2026-10-25). Nothing is built. Per-slice test plans are written when a slice is built (rule: no feature without a test plan); section 6 is the strategy they follow.
**Trigger:** device-testing PR #159: owner flows pass, every non-owner case is untestable (see `KNOWN-ISSUES.md` "No way to log in as staff").
**Resume:** read this file, then `2026-10-25-multi-role-login-CHECKPOINT.md`, answer section 8 one question at a time, then write the plan (`superpowers:writing-plans`).

## 1. Verified facts (code read 2026-10-25, branch `main` @ `b749a80`)
- `Gateway.provisioningAvailable = false` (`Gateway.qml` L41) blocks BOTH Add Staff login (`AuthService.provisionStaffCredentials`) and Invite by UID (`inviteMember`). Server `provisionMember` exists (`functions/index.js` ~L710), accepts roles admin/manager/staff, owner-only/admin via `canAssignRole`.
- Sign-in with email/Google exists. After sign-in `AuthService` reads `users/{uid}` then `tenants/{t}/members/{uid}` for tenant + role (L195, L256-280).
- Role flags live in `AuthStore` (`canManageInventory`, `canViewFinancials`, `canViewAllSales`, `canOpenProductDetail`, `isStaffRole`...). They are CLIENT-ONLY. Server RBAC exists for `staff/delete` only (`KNOWN-ISSUES` "Security: recordMutation has no server-side role check"). After PR #159 the server trusts the member doc for tenant/role/status, but still does not check what that role may DO.
- Stores load from Firestore once, at `tenantContextReady` (`Main.qml` L297-305: `syncFromFirebase()` per store). I found no realtime listener and no resume/periodic refresh of data stores (grep only; NOT proven absent). **Corrected 2026-10-31 (`2026-10-31-l3-session-lifecycle-design.md` F1-F3): there is no listener and no resume hook, but `refreshIdToken` and `onIsOnlineChanged` re-run the profile load, which fires `tenantContextReady` and re-syncs every store about hourly and on every reconnect (as a side effect, with a sign-in cover and a blanked Orders list).** So a second device does see changes, about hourly, by accident. Q0 is answered.
- Order `staffId` comes from a dropdown. `StaffStore.findByAppUid` / `AuthStore.currentStaffId` map login to staff record (role-restrictions plan 2026-06-16).
- E2E harness can already mint per-user ID tokens (`test/e2e/seed.js` custom token -> idToken) and call handlers with `Authorization: Bearer`. QML E2E runs ONE app session per process (singletons), so two-actor tests live at the server/rules/emulator layer.

## 2. Goals / non-goals
Goals: (a) any role can be created and can sign in; (b) a non-owner can do exactly what its role allows, enforced on the SERVER; (c) cross-user actions behave correctly and visibly (sale, restock, status change, removal, demotion); (d) all of it testable.
Non-goals (YAGNI, v1): realtime push, custom claims, SSO/SCIM, per-field read ACLs, email-invite links, multi-tenant switching UI.

## 3. Decisions (each: options, trade-offs, recommendation)
**D1 Provisioning flag.** (a) flip to `true`; (b) delete the flag and its dead branch; (c) leave, enable via config.
a = one line, but a dead flag stays and tests that rely on the `false` default (`tst_AddStaffSyncClose`, `tst_ProvisionStaffCredentialsFailureRouting` and docs) keep an odd seam. b = leanest, but rewires those tests. c = more states, no benefit. **Rec: (a) in slice L1, (b) as a follow-up inside L1 only if rewiring is under ~5 test files.** Taher:
**D2 How a non-owner gets credentials.** (a) owner sets a temporary password (existing code); (b) invite link by email; (c) Google-only, owner enters email. a = works today, but the password is shared by chat/phone and the email is never verified (a typo'd email = no reset). b = best security, needs email sending + deep links (new infra, Blaze cost). c = nice for gmail users, excludes others. **Rec: (a) now, plus forced password change on first login (L5); revisit (b) if shops get big.** Taher:
**D3 Server-side RBAC matrix.** Turning on staff login makes the open KNOWN-ISSUE exploitable: any member can call the gateway directly and skip every client guard. Options: (a) table-driven matrix `role x entity x action` in `functions/lib` checked in every endpoint + `staffId` binding; (b) only the high-risk set (delete, price/cost edit, adjust, staff/member writes); (c) defer. a = right, bigger, needs a client/server parity test so `AuthStore` flags and the table cannot drift. b = faster, leaves holes you must list and remember. c = not acceptable once real staff log in on prod. **Rec: (a), slice L2, MUST land before any real staff account on prod.** Taher:
**D4 Read scope of staff.** Rules let every active member read the whole tenant (cost, suppliers, others' sales). Hiding them is UI only. Options: (a) accept, document; (b) split sensitive fields into owner-only docs; (c) serve reads through functions that filter by role. a = zero work, a motivated staff member with a debugger can read cost. b/c = large migration/rewrite. **Rec: (a) for v1, written in `SECURITY.md`, because the stated goal is B2C shop counters and this is dev-only data today. Taher must confirm he accepts that a staff member can technically read cost prices.** Taher:
**D5 Cross-device freshness.** (a) nothing; (b) sync on app resume + pull-to-refresh; (c) polling; (d) Firestore streaming. a = staff sells against stale stock (server atomic deltas keep real stock correct, UI lies, conflicts show as CAS toasts). b = cheap, bounded staleness. c = battery/quota cost. d = REST streaming in Qt is hard. **Rec: (b).** Taher:
**D6 Membership change while the other user is signed in** (suspend, remove, demote, set to leave). Server already refuses (PR #159), but the client keeps the old role until restart. Options: (a) re-resolve member doc on every token refresh + on resume; (b) only react to server error codes; (c) both. **Rec: (c)**: distinct codes (`not-a-member`, `member-not-active`, `role-not-allowed`; S2f-3 already queued) sign the user out with a clear screen; re-resolve role on refresh so demotion drops UI rights within one token life (about 1 h) or at next resume. Taher:
**D7 Meaning of "leave".** `StaffStore` record status and member-doc `status` are two different things (UNVERIFIED how/if they are linked). Options: (a) staff-record status is HR info only, no access effect; (b) "leave" also sets member `status` to non-active (blocks login and writes); (c) separate switch. **Rec: (c)**: leave must not silently lock or unlock access, and suspending must be an explicit act. Taher:
**D8 Sale attribution.** For role `staff`, server forces `order.staffId` = caller's own staff record (no selling as someone else); manager/admin/owner may pick. A login with no linked staff record cannot sell. **Rec: yes, part of L2.** Taher:

## 4. Architecture and slices (each = own branch, own PR, own test plan)
- **L1 Provisioning on.** D1; emulator E2E "owner provisions staff -> staff signs in -> member + users docs correct"; device run. Small. Unblocks PR #159 device tests.
- **L2 Server RBAC + staffId binding.** `functions/lib/rolePolicy.js` pure table + `authorize(role, entity, action, ctx)` called from every endpoint after `deriveContext`; error `role-not-allowed` (distinct 403). Parity test: `AuthStore` flags vs table for every role. Biggest slice; split by endpoint if needed.
- **L3 Session lifecycle.** D6/D7: refresh re-resolve, sign-out screens (removed, suspended), distinct codes (merge with S2f-3), outbox behaviour when the member is gone (parked writes -> existing stuck-writes dialog).
- **L4 Freshness.** D5 sync on resume + pull-to-refresh using existing `syncFromFirebase()`; guard against running during pending outbox/locks.
- **L5 First-login password change** (+ reset path) per D2.
- **L6 Consolidated cross-actor matrix** (section 5) as emulator E2E + one manual two-device plan.
UI (qt-ui-design): no new tabs. New surfaces only: blocked/removed screen, first-login password screen, pull-to-refresh. Role-limited pages already exist (Skill 16/17 props pattern).

## 5. Cross-actor matrix (E2E, two or more actor tokens, emulator)
| # | Scenario | Expected |
|---|---|---|
| X1 | staff completes an order | owner reads order; stock down; `sale` movement carries staff actor; staffId = staff's own |
| X2 | staff sells while owner restocks same product | final = start + restock - sold, no lost update |
| X3 | two staff sell the last unit | one succeeds, one gets insufficient-stock; stock never < 0 |
| X4 | owner edits price/cost while staff holds stale list | order keeps price sent by client policy; no cost leak in staff payload (D4 caveat) |
| X5 | owner sets staff record to leave | per D7: no access change (c) or blocked (b); both asserted |
| X6 | owner suspends member, staff writes | refused `member-not-active`; direct rules read refused |
| X7 | owner removes member mid-order | completeOrder refused, parked, stuck dialog, Discard reverts order to pending |
| X8 | owner demotes manager to staff | next write of manager-only action refused; UI drops rights after refresh |
| X9 | staff direct gateway call: delete product, adjust others' order, edit staff, invite, change roles, sell as other staff | all `role-not-allowed` |
| X10 | owner deletes product while staff sells it | rejected `product-not-found`, no resurrect |
| X11 | staff A vs staff B same-order edit | CAS/lock conflict toast, no silent overwrite |
| X12 | member of tenant A calls tenant B | refused (PR #159 control) |
| X13 | provision: duplicate email, weak password, role escalation (staff provisions admin), owner demotion | refused with distinct codes |
Roles x endpoints: the full grid is generated from `rolePolicy.js` (every role x entity x action), not hand-listed.

## 6. Test strategy (every slice)
Unit (`node --test`: policy table, parity, helpers) -> functional handlers (10+ endpoints x 4 roles) -> rules tests (members, suspended, wildcard) -> emulator E2E (matrix above) -> QML tests per role (flags, hidden controls, blocked screens; single actor) -> regression (owner flows unchanged) -> negative/edge (missing member, bad role, empty/oversize ids, token expiry) -> seeded fuzz/monkey (random role x action sequences must never exceed the table). QML + rules + E2E verified by CI only. Device plan: two phones or phone + emulator, Happy / Negative / Edge / Affected / Regression, with the console workaround NOT used once L1 ships.

## 7. Risks
R1 shipping L1 without L2 = real staff can bypass client guards (do not enable on prod before L2). R2 matrix/flags drift (parity test). R3 stale UI causes wrong sales (L4). R4 shared temp passwords (L5). R5 `SKILLS.md` numbering collisions with PR #159-#161 (renumber on rebase). R6 L2 touches every endpoint: large diff, slice it.

## 8. Open questions (ask ONE at a time on resume, in this order)
Q0 Is there really no refresh/listener beyond login? (verify in code first; changes D5).
Q1 First slice: L1 alone, or L1+L2 together before any prod staff? (rec: L1 alone for testing, L2 before prod)
Q2 D3 full matrix vs high-risk subset.
Q3 D4 accept staff can technically read cost?
Q4 D7 what must "leave" do?
Q5 D2 temp password acceptable, force change on first login?
Q6 D5 resume + pull-to-refresh enough?
Q7 Staff with no linked staff record: block selling (D8)?
