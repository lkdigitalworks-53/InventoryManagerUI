# PR #165 final sweep (S2f-7 `provisionMember` add-only) — 2026-10-26

Skills: `superpowers:requesting-code-review`, `ponytail:ponytail-audit`, `qt-development-skills:qt-qml-review`.
Scope read in full: `functions/index.js` `provisionMember` + `deriveContext` + `canAssignRole`, `functions/lib/memberProvisionLogic.js`, both Functions test files, the 5 e2e additions, `qml/model/AuthService.qml` (both callers + error map), `qml/model/Gateway.qml` `provisionMember`, `StaffStore`, `StaffScope`, `AuthStore.currentStaffId`, `cleanupStaffAuthDocs`, `firestore.rules` members block, design, test plan, checkpoint, skills, KNOWN-ISSUES.
Run: `npm test` in `functions/` 866/866 (matches PR). Script tests 109/109. CI on `f7c2bf7`: QML 2118, Functions 866, Rules 106, E2E 101 = 3191, all green. QML lint on the changed files: only project-wide convention noise (`var`, no `id: root`; one false JS-2 on `!==`; 92 of 103 test files do the same); the two changed QML lines have no hit. `qmllint` and the six qml-review deep agents: not run (no Qt, 2 changed QML lines + 1 test file; checked by hand: no bindings, loaders, delegates, states or layout touched).
Not read: Auth emulator internals, `deploy` config, other endpoints.

## Verdict
Server change is correct and well tested. No must-fix. Two client-side side effects (findings 1, 2) and one older design gap (3) need a decision from Taher before multi-role login (L1) flips `Gateway.provisioningAvailable`. Four small doc/text faults fixed in the review PR.

## What is good
- Decision is a pure function; the member doc is read FIRST inside the transaction, so two concurrent calls cannot both create. `users/{uid}` is read only on create.
- Caller gates (token, tenant, caller role, `canAssignRole`) still answer before the target is looked at: no 409-vs-403 probing.
- One public code, reason only in the log; fail-closed on odd shapes; role normalised before the compare.
- Tests: unit table + seeded fuzz with an invariant written separately from the branches; 78-case matrix; structural guard; fix-revert and mutants done by the author; real-emulator race test.

## Findings
**Must fix:** none.

**Should fix**
1. **Staff add loses the login link on 409** (`AuthService.qml` `provisionStaffCredentials`, `functions/index.js` 409 branch). Case: owner adds a staff entry whose email is already a member with another role, or is suspended. The roster record is already saved; the call answers 409; `setAppUid` never runs. Result: the person has a working login but no linked entry (sees no orders, fail-closed), and deleting the entry leaves their member doc, so access outlives it. Dormant today. Fix options in KNOWN-ISSUES. *Decision for Taher (Q4).*
2. **Two roster entries can share one login** (no duplicate-email check in `StaffStore`; repeat call answers 200 with `uid`). Deleting the second entry runs `cleanupStaffAuthDocs` and removes the member doc and `users/{uid}` of the person the first entry still describes. Pre-existing (old merge linked too), now explicit. Dormant. *Decision for Taher (Q4).*
3. **Invite-by-uid adds any existing Auth account with no consent from that person**; the member doc stores that account's Auth email; 404 vs 200 reveals whether a uid exists in the whole project. Pre-existing, untouched by the PR, but test plan row DE3 now pins it. Needs an owner/admin token plus the uid. DPDP-relevant. *Decision for Taher (Q5).*
4. **Wrong message for owner / peer-admin targets** (`AuthService.qml`): "Change their role or status from Team Members" is false for an admin facing the owner or a peer admin (D-1), and the real label is "Team members". FIXED in the review PR (+1 QML test).
5. **Design D14 and Skill 132 rule 3 give a false reason** ("the client retries, the outbox resends"). `Gateway.provisionMember` is a single XHR. The rule stays (double tap, manual retry); the text is corrected and Skill 135 records the lesson. FIXED (docs).
6. **Counts in docs**: "QML +4" but CI reads +6 (every new TestCase file also adds `initTestCase` and `cleanupTestCase`). FIXED (test plan, Skill 135 rule 3).

**Nice to have**
7. The structural guard test counts exact source lines containing `"/members/"`; a harmless refactor breaks it. Keep (it caught a real class of bug); loosen only if it ever misfires.
8. `tst_ProvisionErrorMessage` claimed a new code could not fall through unnoticed; its list is hand-kept. Comment corrected.
9. Branch commit author is `dextran52@gmail.com`; this session's rule is `taher.lkdw@gmail.com`. The checkpoint says that was Taher's instruction earlier today. History NOT rewritten (force-push risk); a squash merge replaces the branch author anyway. Review commits use `taher.lkdw@gmail.com`.

Left alone on purpose: the `unreadable` branch of `decideProvision` is unreachable from `index.js` (`data() || {}`); two lines, tested, and it keeps the function safe if the caller changes. The `owner` check is outcome-equivalent to `role-differs` (only the log reason differs): kept for a clear audit reason.
Lean: -0 lines, -0 dependencies.

## Not changed, still open (already in KNOWN-ISSUES)
No `audit_log` row for membership changes; unknown role becomes `staff`; plain-text 500 on a Firestore blip (#159 finding 9).

## Questions for Taher
Q4 (findings 1, 2): leave documented until L1, or add the one-line client guards now? Recommendation: add them in the L1 slice, with the flag flip.
Q5 (finding 3): accept step for invites in L1? Recommendation yes.
