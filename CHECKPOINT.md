# CHECKPOINT — 2026-10-24 S2f authz hardening (resume here)

**Branch (current):** `review/2026-10-26-pr160-final-sweep`, STACKED on PR #160 (`fix/2026-10-24-s2f2-members-rules`, tip `853ac8f`, on `main` @ `3e14826`). History: PR-A = #159 (merged), PR-B = #160 (this sweep reviews it).
**Commit identity:** `taher.lkdw@gmail.com`. PAT only inline in the push command; after push `grep -c ghp_ .git/config` must print 0.
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
- PR #159 CI: QML/Functions/Rules green; E2E 1 failure = my test used a recordOperation requestId without the `completeOrder:` prefix (400 before auth). Fixed. Real E2E baseline was 86, not 93.
- PR-A now strict: member.status must equal `active`; actorName from member doc (F8). Functions 811/811.
- NEXT: push PR-A fix, stack PR-B (rules F1/F2 + canAssignRole + strict status + tests), then S2f-4+5 (allow-list wildcard, locks 4 collections), S2f-3 (client wording), S2f-6 counters.
- [x] PR-B built (branch `fix/2026-10-24-s2f2-members-rules`, stacked on #159): rules + 31 tests (CI-only; predicted Rules 83, total 3087), test plan, Skill 129. Pushed; CI result pending.
- NEXT: read CI on PR-B and fix; then S2f-4+5 (PR-C: allow-list wildcard, locks staff/removed_staff/orders/suppliers), S2f-3 client wording (PR-D), S2f-6 counters.

## Update 2026-10-25 (session 3, restored: the #160 rebase kept the branch version of this file and dropped it)
Decisions from Taher on the PR #159 sweep: Q1 role allow-list yes (gateway in #159; rules mirror = this sweep, D9), Q2 `provisionMember` owner-demotion / un-suspend = its own slice (NOT started, see `specs/2026-10-25-pr159-final-sweep.md` finding 6), Q3 log now / distinct client codes later (S2f-3), Q4 remove redundant lines, Q5 delete dead `photoAccessDenied` check. #159 merged as `fe1409f`. Not done on purpose: finding 9 (plain-text 500 on a Firestore blip), 11 (tenant-id charset), 12 (client role default, S2f-3).

## Update 2026-10-26 (session 4: rebase + final-sweep review of PR #160)
- [x] 1. Cloned, PAT scrubbed from `.git/config`, identity `taher.lkdw@gmail.com`. PR #160 was ALREADY on `main` @ `3e14826` (merge-base = main tip, 0 behind, 0 file overlap): rebase = no-op, nothing force-pushed.
- [x] 2. CI on `853ac8f`: 3118/3118 (QML 2104, Functions 835, Rules 83, E2E 96). The plan/PR body said 3087 (stale baselines): fixed in docs.
- [x] 3. Read: `firestore.rules` (full), `storage.rules` (no membership use, no drift), `deriveContext`, server/client `canAssignRole`, every client writer of `members/` and `tenants/`, the 31 tests, docs.
- [x] 4. Fixes (stacked branch): R1 `isMember` also requires `roleIsValid(role)` (Q1 mirror, revives dead `roleIsValid`); R2 member `uid` immutable on update; R3 tenant `ownerId` immutable on update (closed a second-owner path via the bootstrap rule); +9 rules tests (CI only; predicted Rules 92, total 3127); `dbAs` now delegates to `dbWith`; test plan N3/N4 wording fixed (UI DOES offer all roles), N6/N7/E4 + section 2b added; Skill 129 rules 7-10; AGENTS line; design D8 edges, D9, D10, open D-1.
- [ ] 5. CI on the review PR (rules emulator is the oracle; if red, the new helper line in `isMember` or an R-test is the suspect).
- [ ] 6. Taher decides D-1 (peer-admin hierarchy), then merge review PR into #160's branch, then #160.
- NEXT after merge: S2f-4+5 (PR #161, restack on #160), S2f-3 client wording (client ignores `status` today: `_loadMembership` applies the role of a suspended member), provisionMember owner-demotion slice.
