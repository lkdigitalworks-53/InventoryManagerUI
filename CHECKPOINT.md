# CHECKPOINT — 2026-11-01 L3 slice A (silent session re-check + resume): PR #180 Q1-Q4 folded in, pushed, CI UNVERIFIED (resume here)

**Branch:** `feat/2026-10-31-l3a-silent-recheck`, rebased on `main` after PR #175 was squash-merged (`main` @ 8de6fa2); PR targets `main`. Skill renumbered 146 -> 149 at rebase (main took 145-148).
**Commit identity:** `Taher (via Claude session) <lkdigitalworks@gmail.com>`. PAT only through `git -c http.extraHeader`, never in the remote URL or repo.
**Rules in force:** no build or run; no Qt in the sandbox (CI is the QML oracle); branch always; push without asking; scope short enough for one chat turn; honest trade-offs; tests plus test plan for every change.
**Design:** `docs/superpowers/specs/2026-10-31-l3-session-lifecycle-design.md` (section 8 = as built). **Test plan:** `docs/superpowers/test-plans/2026-10-31-l3-session-lifecycle-test-plan.md`. **Skill 149.**

## 2026-11-01 PR #180 Q1-Q4 fold-in (latest session; resume here)
**Owner took the default recommendation for Q1-Q4.** Same branch/PR. **Commit identity this session:** `Taher (via Claude session) <lkdwtaher@gmail.com>`. Sandbox clone at `/home/claude/InventoryManagerUI` (resets between sessions: clone again and `git checkout feat/2026-10-31-l3a-silent-recheck`).
- [x] Q1 `SessionRecheck.changeKind`: unreadable (`unverified`) answer with no block showing -> `none` (silent only; full loads still block).
- [x] Q2 `AccessState.STATE_MOVED` + copy; `AuthService._applyAccess` `kind === "tenant"` -> `accessBlock = "moved"`, switches nothing; `Main.qml` `_allDialogs()` / `_closeAllForWorkspaceChange()` (also `confirmReturnSheet`, `staffActionSheet`, 3 overlays) on `onAccessBlockChanged`; `AccessBlockedPage` button "Continue" for moved.
- [x] Q3 `ensureFreshToken` -> `refreshIdToken(true)`. Q4 `AccessState.roleLabel` in the role toast.
- [x] Extra fix: blocked screen no longer falls back to the OLD shop name for a refusal about another workspace.
- [x] Tests: script suite 741 of 741 in the sandbox (new `accessStateMoved.test.js`, 22 Q scenarios, workspace monkey profile, 28 mutants and wiring rules); QML tests `tst_SessionRecheck.qml`, `tst_AccessState.qml` updated, NOT RUN (CI only).
- [x] Docs: KNOWN-ISSUES (Q1-Q3 closed, 2 new entries), test plan section 10 + N17-N21, design F13-F16, Skill 149 items 15-17, README, AGENTS, SKILLS-INDEX.
- [x] Commit d329c2c (code + tests) pushed; docs commit follows.
**NEXT:** read CI on PR #180 (QML Tests is the first real run of the new QML test functions; fix any failure on the same branch); then device steps B0, H1-H6, N8-N21 by the owner; then L4 design. Open (KNOWN-ISSUES): Back list misses 2 popups; in-flight write around a workspace change.

## 2026-11-01 PR #180 review sweep (earlier session)
**Scope:** full review of PR #180 (requesting-code-review + qt-qml-review + ponytail-audit), fixes added to the SAME branch (no new branch: the PR is the branch). **Commit identity this session:** `tsadmin <tsadmin@gmail.com>` (owner's instruction); the PAT goes only through `git -c http.extraHeader`, never the remote URL.
- [x] Cloned repo, read AGENTS/CHECKPOINT/SKILLS-INDEX, read the full diff (17 files), ran the Qt QML linter on the 4 changed QML/JS files (nothing new vs `main` apart from the `var` style the files already use; `!==` flagged as loose equality is a linter false positive), traced every emitter, sign-out path, seq bump and token-refresh consumer by grep.
- [x] F1 an unreadable answer used up the 60 s window, so an expired-token 401 check followed by the refresh success dropped the real check. Fixed in `_applyAccess` (window freed only for an answer that decided nothing).
- [x] F2 an unreadable first answer marked the stores synced, so a later definitive answer saw "nothing changed" and the lists stayed stale until a relaunch (main re-synced on every trigger). Fixed: only a verified answer marks synced.
- [x] F3 a failed refresh started by a resume reported through `authFailed`, which writes into Add staff (while provisioning) and Invite/Forgot dialogs. Fixed: `refreshIdToken(silent)`, only `onAppResumed` passes true.
- [x] F4 sign-out now resets both spacing windows.
- [x] Tests: 6 scenarios, 11 behaviour mutants, 11 wiring mutants, 6 wiring rules, monkey model updated (4 seeds x 6000 steps agree); whole script suite 659 of 659. Test plan section 9 + device steps N13-N16. Skill 149 items 11-13. KNOWN-ISSUES 4 entries.
- [x] CI on `55a9cd7`: QML Tests, E2E Tests, Firestore + Storage Rules Tests, Functions Tests all success (read 2026-11-01); Deploy jobs skipped as designed. Review report posted as a PR comment. Device steps B0, H1-H6, N8-N16 NOT run (owner).
**Decisions left for the owner (not changed, see KNOWN-ISSUES 2026-11-01):** Q1 unreadable member doc for a DIFFERENT workspace blocks "unverified" even silently (pinned by an existing scenario); Q2 a silent workspace switch resyncs stores under open forms with no notice; Q3 make `ensureFreshToken` (timer, Gateway, PhotoQueue, LockManager, AnalysisService) silent on failure too; Q4 role toast shows the raw role id.
**NEXT:** read CI on PR #180; then L4 design (unchanged from below).

## Done
- [x] `qml/helper/SessionRecheck.js`: `canStart` (60 s spacing, one in flight, a check out for 120 s is lost and replaceable) and `changeKind` (block / unblock / tenant / role / none).
- [x] `AuthService.qml`: `checking` flag (bound by no UI), `requestRecheck` = the only door to `_loadUserProfile(true)`, `_sessionOpen`, `_recheckOrLoad` (open session silent, else full load), `onAppResumed` (refreshes an expiring token first), `roleChanged` signal, silent branches in `_loadUserProfile` / `_verifyMembership` / `_applyAccess` (answer that changes nothing touches nothing), sign-out clears `checking`, refresh answer dropped when the refresh token changed since it was sent.
- [x] `Main.qml`: `Connections { target: Qt.application }` resume hook (thin), role toast, Staff overlay closes on a role change when `!canViewStaff`.
- [x] Tests (sandbox: whole script suite 659 of 659; 631 as the PR was opened, 462 before slice A): `sessionRecheck.test.js` 37 (33 mutants), `sessionRecheckBehavior.test.js` 101 (47 scenarios, 49 mutants, 4 seeded monkeys x 6000 steps with pinned coverage), `sessionRecheckWiring.test.js` 51 (47 mutants), `tests/tst_SessionRecheck.qml` 25 functions (CI only; its model-style test was replayed in Node). Existing `accessBlockBehavior` / `accessBlockWiring` pins moved to the new call shapes.
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
