# CHECKPOINT — 2026-11-01 L3 slice A (silent session re-check + resume): BUILT, pushed, CI UNVERIFIED (resume here)

**Branch:** `feat/2026-10-31-l3a-silent-recheck`, rebased on `main` after PR #175 was squash-merged (`main` @ 8de6fa2); PR targets `main`. Skill renumbered 146 -> 149 at rebase (main took 145-148).
**Commit identity:** `Taher (via Claude session) <lkdigitalworks@gmail.com>`. PAT only through `git -c http.extraHeader`, never in the remote URL or repo.
**Rules in force:** no build or run; no Qt in the sandbox (CI is the QML oracle); branch always; push without asking; scope short enough for one chat turn; honest trade-offs; tests plus test plan for every change.
**Design:** `docs/superpowers/specs/2026-10-31-l3-session-lifecycle-design.md` (section 8 = as built). **Test plan:** `docs/superpowers/test-plans/2026-10-31-l3-session-lifecycle-test-plan.md`. **Skill 149.**

## Done
- [x] `qml/helper/SessionRecheck.js`: `canStart` (60 s spacing, one in flight, a check out for 120 s is lost and replaceable) and `changeKind` (block / unblock / tenant / role / none).
- [x] `AuthService.qml`: `checking` flag (bound by no UI), `requestRecheck` = the only door to `_loadUserProfile(true)`, `_sessionOpen`, `_recheckOrLoad` (open session silent, else full load), `onAppResumed` (refreshes an expiring token first), `roleChanged` signal, silent branches in `_loadUserProfile` / `_verifyMembership` / `_applyAccess` (answer that changes nothing touches nothing), sign-out clears `checking`, refresh answer dropped when the refresh token changed since it was sent.
- [x] `Main.qml`: `Connections { target: Qt.application }` resume hook (thin), role toast, Staff overlay closes on a role change when `!canViewStaff`.
- [x] Tests (sandbox: whole script suite 623 of 623, was 462): `sessionRecheck.test.js` 37 (33 mutants), `sessionRecheckBehavior.test.js` 84 (41 scenarios, 38 mutants, 4 seeded monkeys x 6000 steps with pinned coverage), `sessionRecheckWiring.test.js` 40 (36 mutants), `tests/tst_SessionRecheck.qml` 25 functions (CI only; its model-style test was replayed in Node). Existing `accessBlockBehavior` / `accessBlockWiring` pins moved to the new call shapes.
- [x] Docs: test plan (as built + N8-N11), design section 8, KNOWN-ISSUES (updated 2 entries, added 2), AGENTS, README, Skill 149, SKILLS-INDEX regenerated.
- [x] Lint: no new findings except `var` style that the file already uses and a linter false positive on strict `!==`. Brackets balanced in all touched files.

## Bug caught before commit (independent review)
The first version never synced the stores at cold start: `init()` resolves offline, then `isOnline` flips true, and the silent check saw "no change". Fixed with `_contextSynced` (first answer of a sign-in always counts as a change, no toast) and every emitter marks it; scenarios now replay the real order and a mutant reverts the bug. Device step N12 checks it.

## NOT proven (needs CI or a device)
`qmltestrunner` results for `tst_SessionRecheck.qml`; the real foreground transition on Android / iOS / Felgo; what the screen draws; test-plan B0 (does the flash exist at all on `main`?), H1-H6, N8-N11. Nothing was built or run.

## Decisions made by Claude while building (flag if you disagree)
1. L3-D5b: no tab is role-gated, so no tab jump; only the Staff overlay closes. `canViewStaff` has no other consumer (KNOWN-ISSUES).
2. A lost silent check is replaced after 120 s (no XHR timeout exists).
3. Refresh-answer-after-sign-out guard added in this slice (it is a pre-existing race that resume makes likelier).
4. Only an already-open session is re-checked silently; cold start, sign-in, onboarding and Try again stay full loads.

## NEXT
1. Read CI on the slice A PR; fix whatever `tst_SessionRecheck.qml` or the QML suites report. Taher: device steps B0 first (does the flash exist?), then H1-H6, N8-N11.
2. L4 (resume sync, pull to refresh): replaces the accidental hourly refresh that slice A removed (accepted at L3-D1c). Own design first.
3. Answer L3-D3 (additive server `reason`), D4 (silent `recheckAccess` on a refused request), D6, D7, then slice B (server, deploy first) and C (client).
4. Separate follow-ups recorded in KNOWN-ISSUES: Staff overlay not role-gated; no timeout on `FirebaseService` reads (a hung read in a FULL load keeps the sign-in cover up).
5. S2f-6 only together with the restock `mint` design approval (unchanged).
