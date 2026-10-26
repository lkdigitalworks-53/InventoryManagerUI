# CHECKPOINT — 2026-10-24 S2f authz hardening (resume here)

**Branch (current):** `fix/2026-10-24-s2f4-default-deny-writes` (PR #161, S2f-4+5), rebased onto `main` @ `34e20ae` (#160 merged). Backup of the pre-rebase tip: local `backup/pr161-pre-rebase` (not pushed).
**Commit identity:** `tsadmin@gmail.com` as committer (older commits keep `taher.lkdw@gmail.com` as author). PAT only inline in the push command or `GH_TOKEN` env; after push `grep -c ghp_ .git/config` must print 0.
**Rules in force:** no build/run; no Qt in sandbox (CI is the QML + rules-emulator oracle); push without asking; short scope per session; honest trade-offs; tests + test plan for every change; caveman FULL for chat only.
**Skills used:** (2026-10-26 sweep) `superpowers:requesting-code-review`, `ponytail:ponytail-audit`, `qt-development-skills:qt-qml-review` (no QML changed by #160: deep agents N/A, client paths traced by hand); earlier: `superpowers:brainstorming` (design doc, decisions marked vetoable), `ponytail`, `qt-qml` and `qt-ui-design` (no QML/UI in PR-A or PR-B; only a client wording follow-up is queued, S2f-3).
**Previous checkpoint archived:** `docs/superpowers/specs/2026-10-24-s2c-prev-CHECKPOINT.md`.

## Why
PR #156 sweep proved F1 (any member can rewrite `members`) and F2 (suspended member keeps direct access). Re-reading the gateway while designing the fix found F3, worse than both: `deriveContext` trusts the client-writable `users/{uid}` doc when no member doc exists. Proven red in the handler harness (non-member got 200 on `recordMutation` in another tenant, role `owner`).

## Steps
- [x] 1. Read memory + sweep report, cloned, cut branch, archived previous checkpoint.
- [x] 2. Probe F3 in the handler harness (`/tmp` only): users doc `{tenantId: victim, role: owner}`, no member doc -> 200. Red.
- [x] 3. Design doc `specs/2026-10-24-s2f-authz-hardening-design.md` (8 findings, principles, slices S2f-1..6, decisions D1-D7, open questions).
- [x] 4. PR-A built: `deriveContext` fixed (member doc required, role from member only, status gate, safe tenant id). `functions/test/index.handlers.membershipAuthority.test.js` 88 tests; `npm test` 810/810 (722 + 88). Fix-revert: 40 red. 4 mutants all caught. +3 emulator e2e in `recordOperation.e2e.test.js` (not run, no emulator). Test plan, Skill 128, SKILLS-INDEX (129 skills), AGENTS.md, README, test-plans index done. Script tests 109/109. Predicted CI total 3062 (QML 2104, Functions 810, Rules 52, E2E 89 = 3055).
- [ ] 5. Push PR-A.
- [ ] 6. PR-B (stacked): rules F1 + F2 + tests for users/tenants/members blocks, test plan, docs.
- [ ] 7. Push PR-B.

## NEXT
See the design doc section "Slices". Not started: S2f-3 (client wording), S2f-4 (lock orders/staff/suppliers/removed_staff), S2f-5 (allow-list wildcard).

## Update 2026-10-25 (session 2)
- Taher: dev members all `active`, no legacy/prod data, do ALL S2f slices before moving on.
- PR #159 CI: QML/Functions/Rules green; E2E 1 failure = my test used a recordOperation requestId without the `completeOrder:` prefix (400 before auth). Fixed. (I briefly mis-read the baseline as 86 from the failed run; it is 93, now 96.) After the fix #159 was green at 3063 on its own branch; main later settled at Functions 835 / total 3087.
- PR-A now strict: member.status must equal `active`; actorName from member doc (F8). Functions 811/811 on that branch (835 once merged to main).
- NEXT: push PR-A fix, stack PR-B (rules F1/F2 + canAssignRole + strict status + tests), then S2f-4+5 (allow-list wildcard, locks 4 collections), S2f-3 (client wording), S2f-6 counters.
- [x] PR-B built (branch `fix/2026-10-24-s2f2-members-rules`, stacked on #159): rules + 31 tests (Rules 83; CI observed total 3118 on the #160 head after #159 merged), test plan, Skill 129. **CI green on #160.**
- NEXT: read CI on PR-B and fix; then S2f-4+5 (PR-C: allow-list wildcard, locks staff/removed_staff/orders/suppliers), S2f-3 client wording (PR-D), S2f-6 counters.
- [x] PR-C built (branch `fix/2026-10-24-s2f4-default-deny-writes`, stacked on #160): allow-list wildcard, locks orders/staff/suppliers/removed_staff; rules tests re-pointed (-9 +18), test plan, Skill 130. CI observed green on the rebased head: Rules 92, total 3127.
- NEXT: read CI on #159/#160/PR-C and fix; S2f-3 client wording (PR-D); S2f-6 server-side counters (PR-E, big: needs design).

## Update 2026-10-25 (session 3, restored: the #160 rebase kept the branch version of this file and dropped it)
Decisions from Taher on the PR #159 sweep: Q1 role allow-list yes (gateway in #159; rules mirror = this sweep, D9), Q2 `provisionMember` owner-demotion / un-suspend = its own slice (NOT started, see `specs/2026-10-25-pr159-final-sweep.md` finding 6), Q3 log now / distinct client codes later (S2f-3), Q4 remove redundant lines, Q5 delete dead `photoAccessDenied` check. #159 merged as `fe1409f`. Not done on purpose: finding 9 (plain-text 500 on a Firestore blip), 11 (tenant-id charset), 12 (client role default, S2f-3).

## Update 2026-10-25 (session 3b: rebase + review of PR #161, branch `fix/2026-10-24-s2f4-default-deny-writes`)
**STANDING FACT (Taher, 2026-10-25): there is NO production code released and none is planned for the near future. No real data exists. Do not ask about production, version skew, min-app-version gates or migrations of live data.** Also in `AGENTS.md` (rule 4).
- [x] 1. Cloned, `git rebase --onto origin/fix/2026-10-24-s2f2-members-rules fd93b57` (the #160 branch had already been rebased onto main; plain `rebase main` would replay the squash-merged #159 commits). 2 own commits replayed, 2 doc conflicts (stale counts), took upstream numbers. Pushed `a147caf` with `--force-with-lease`. CI green, 3127 = QML 2104 + Functions 835 + Rules 92 + E2E 96.
- [x] 2. Review (code-review, ponytail audit scoped to the PR surface, qt-qml-review: 0 QML files in the diff). Full report: `specs/2026-10-25-pr161-final-sweep.md`. No must-fix in the diff; client writer audit reproduced independently.
- [x] 3. Fixes in THIS PR (no new branch): 3 rules tests (every role writes the 4 names; PIN S2f-6 counters; seeded 100-iteration monkey), `ROSTER_ROLES` hoisted, counts corrected in both test plans + index, `FIRESTORE_RULES.md` rewritten (stale unsafe code copy removed, summary table, pointer to `firestore.rules`), Skill 131.
- [x] 4. Documented for later in `KNOWN-ISSUES.md`: owner can mint a second owner via `ownerId` (finding 7, NOT PROVEN), client cleanup writes the rules refuse (finding 8).
- [ ] 5. DECIDED NOT in this PR: `counters` lock (S2f-6, server-side minting). Stays pinned by the test.
- Predicted CI after this push: Rules 95 (`firestore.rules.test.js` 88 + `storage.rules.test.js` 7), total 3130. If CI differs, recount with the stub method in Skill 131 before editing docs.
- NEXT: read CI on the new head and fix; probe finding 7 in the emulator (KNOWN-ISSUES has the exact probe); S2f-3 client wording; S2f-6.

## Update 2026-10-26 (session 4: rebase + final-sweep review of PR #160)
- [x] 1. Cloned, PAT scrubbed from `.git/config`, identity `taher.lkdw@gmail.com`. PR #160 was ALREADY on `main` @ `3e14826` (merge-base = main tip, 0 behind, 0 file overlap): rebase = no-op, nothing force-pushed.
- [x] 2. CI on `853ac8f`: 3118/3118 (QML 2104, Functions 835, Rules 83, E2E 96). The plan/PR body said 3087 (stale baselines): fixed in docs.
- [x] 3. Read: `firestore.rules` (full), `storage.rules` (no membership use, no drift), `deriveContext`, server/client `canAssignRole`, every client writer of `members/` and `tenants/`, the 31 tests, docs.
- [x] 4. Fixes (stacked branch): R1 `isMember` also requires `roleIsValid(role)` (Q1 mirror, revives dead `roleIsValid`); R2 member `uid` immutable on update; R3 tenant `ownerId` immutable on update (closed a second-owner path via the bootstrap rule); +9 rules tests (CI only; predicted Rules 92, total 3127); `dbAs` now delegates to `dbWith`; test plan N3/N4 wording fixed (UI DOES offer all roles), N6/N7/E4 + section 2b added; Skill 129 rules 7-10; AGENTS line; design D8 edges, D9, D10, open D-1.
- [x] 5. CI on #164 head `a892be8`: all green (R1-R3 + docs).
- [x] 6. Taher decided D-1 = option (b), hierarchy. Done in the same PR: rules `canManageTarget` (update + delete), `qml/helper/MemberPolicy.js`, `AuthService` refusals, `MemberManagementDialog` gating (`actorRole`, `Main.qml`), `tst_MemberPolicy` (6), D-1 matrix rules tests (3 replace the pin; total +11), test plan N6/E4 + 2b, Skill 129 rules 9/11, design D-1 decided, AGENTS.
- [x] 7. CI on D-1 commit `bf003ae`: 3137/3137 (QML 2112, Functions 835, Rules 94, E2E 96); #164 mergeable, clean.
- [ ] 8. Taher: merge #164 into #160's branch, then #160, then `firebase deploy --only firestore:rules` (after the functions deploy of #159). Then restack #161. Device steps: N6, E4 in the test plan.
- NEXT after merge: S2f-4+5 (PR #161, restack on #160), S2f-3 client wording (client ignores `status` today: `_loadMembership` applies the role of a suspended member), provisionMember owner-demotion slice.
