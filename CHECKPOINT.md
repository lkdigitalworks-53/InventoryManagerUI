# CHECKPOINT — 2026-10-24 S2f authz hardening (resume here)

**Branch:** `fix/2026-10-24-s2f1-membership-authority` off `main` @ `b749a80` (PR #156 merged). PR-B (`fix/2026-10-24-s2f2-members-rules`) will be STACKED on this branch.
**Commit identity:** `taher.lkdw@gmail.com`. PAT only inline in the push command; after push `grep -c ghp_ .git/config` must print 0.
**Rules in force:** no build/run; no Qt in sandbox (CI is the QML + rules-emulator oracle); push without asking; short scope per session; honest trade-offs; tests + test plan for every change; caveman FULL for chat only.
**Skills used:** `superpowers:brainstorming` (design doc, decisions marked vetoable), `ponytail`, `qt-qml` and `qt-ui-design` (no QML/UI in PR-A or PR-B; only a client wording follow-up is queued, S2f-3).
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
- PR #159 CI: QML/Functions/Rules green; E2E 1 failure = my test used a recordOperation requestId without the `completeOrder:` prefix (400 before auth). Fixed. Real E2E baseline was 86, not 93.
- PR-A now strict: member.status must equal `active`; actorName from member doc (F8). Functions 811/811.
- NEXT: push PR-A fix, stack PR-B (rules F1/F2 + canAssignRole + strict status + tests), then S2f-4+5 (allow-list wildcard, locks 4 collections), S2f-3 (client wording), S2f-6 counters.

## Update 2026-10-25 (session 3, sweep fixes applied on this PR; working branch `work/pr159-sweep-fixes`, pushed to this branch)
Decisions from Taher: Q1 role allow-list yes (gateway here; rules mirror goes to PR #160), Q2 `provisionMember` owner-demotion/un-suspend = its own slice, Q3 log now / distinct client codes later (S2f-3), Q4 remove redundant lines, Q5 delete dead `photoAccessDenied` check.
- [x] `deriveContext`: role allow-list (`VALID_ROLES`), one `logger.warn` per refusal (uid + reason, tenant id capped at 64), redundant `exists` return removed, tenant doc read moved into `provisionMember` (name from tenant doc only; no users-doc fallback), `photoAccessDenied` dead tenant check removed.
- [x] Tests: `membershipAuthority` 89 -> 113 (role table x10 handlers, valid-role controls, tenantId types, logging, lean reads, tenantName source, seeded fuzz replacing the fixed "monkey"); BC-H01 updated. `npm test` 835/835; against `main`'s old `deriveContext` 56 of 113 red; mutants caught (see test plan "Sweep additions").
- [x] Docs: Skill 127 rule 5, Skill 128 rules 4/7 + new 10-12 (no new Skill number, so #160/#161 do not renumber), test plan sections (CI count lines 46/53 left for #161, which rewrites them), AGENTS line.
- [ ] CI result on the new head, then fix the CI-count lines in the test plan + `test-plans/README.md` row + PR body (observed numbers).
- [ ] Mirror the role allow-list in `firestore.rules` `isMember`/`memberStatusIsActive` on PR #160 (rules tests, CI only).
- [ ] Rebase #160 and #161 onto the new #159 head (docs conflicts expected: SKILLS.md, CHECKPOINT.md, AGENTS.md, test plan).
- [ ] Own slice: `provisionMember` must refuse changing an `owner` member doc and decide what re-provisioning a `suspended` member does (sweep finding 6).
- Not done on purpose: finding 9 (plain-text 500 on a Firestore blip), 11 (tenant-id charset check of dev data), 12 (client role default, S2f-3).
