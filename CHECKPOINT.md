# CHECKPOINT: 2026-11-20 P1 S4b-2 (stock register page on the phone) - resume here

**Branch:** `feat/2026-11-20-p1-s4b2-register-page`, cut from `main` @ `6951b1d` (#205 S2d-2 merged).
**Design:** `docs/superpowers/specs/2026-11-12-p1-s4b-register-client-design.md` section 5 (designed there; this session adds section 8 "S4b-2 as built" with the calls below).
**Previous checkpoint archived:** `specs/2026-11-20-pr205-sweep-merged-prev-CHECKPOINT.md`.
**Commit rule (this session's prompt):** every commit message carries `allibaas52@gmail.com`; git user email is the same. (Earlier PRs used `lkdwtaher@gmail.com` then `tsadmin@gmail.com`: do not rewrite them.)
**Rules in force:** no build/run; no Qt in the sandbox (CI is the oracle); branch + push without asking; tests + test plan for every change; out-of-scope findings go to `docs/superpowers/KNOWN-ISSUES.md`; one short scope per session (token-limited, multi-account). Node tests run here: `cd functions && npm ci && node --test`; `.github` suite: `node --test .github/scripts/__tests__`. PAT per command via `git -c http.extraHeader`, never stored in the repo, a doc or memory.

## Why S4b-2 (not S3 or S2e-2)
- S2e-2 pickers and S4c export wait for the CA answers (CA-QUESTIONS.md). S3 (`batchRef`) is queued behind C-3 Phase 3 per the P1 design table.
- S4b-2 needs no CA answer, makes P1 visible on a dev tenant, and shows what derived `adjustment` rows look like (design section 7 advice 1).

## Scope of THIS PR (kept to one chat turn)
In: pure page glue `qml/helper/StockRegisterPage.js`; page `qml/pages/StockRegisterPage.qml`; "Stock register" row in ProfilePage (role-gated); overlay + Back + close-on-change wiring in `Main.qml`; `StockRegisterService.clear()` on sign-out; Node tests + wiring tests + QML twin; test plan; docs.
Out (documented in KNOWN-ISSUES): emulator e2e QML-to-endpoint case, date-picker for custom range (typed YYYY-MM-DD in v1), share/print/export (S4c), value columns (S2e), device role-gating proof (needs a non-owner login).

## Steps (tick as done)
- [x] 0. Clone, read memory + P1 designs + service/model + Main/Profile patterns, picked S4b-2, cut branch.
- [x] 1. Pure glue `StockRegisterPage.js` + Node tests (67 tests, 52 hand mutants killed; mutants run under a non-UTC zone because the sandbox is UTC).
- [x] 2. Page QML + ProfilePage row + Main wiring + sign-out clear.
- [x] 3. Wiring tests (63, incl. page function bodies run in a vm + 31 page mutants) + QML twin tests/tst_StockRegisterPage.qml; SRS-04 dormancy replaced by SRW-13; sessionRecheckWiring pin extended for the new overlay. Whole .github suite 1193 green.
- [x] 4. Test plan `test-plans/2026-11-20-p1-s4b2-register-page-test-plan.md` + README row (device steps 1..22).
- [x] 5. Docs: design section 8, KNOWN-ISSUES (S4b-2 section), ATOMIC-OPERATIONS-STATUS 13, README, AGENTS, Skill 180 + SKILLS-INDEX (was written as 178 here; 178 is AP3b); row extracted to `qml/components/StockRegisterRow.qml` per qt-qml skill.
- [x] 6. Pushed, PR #209 opened, CI on be60ef5: QML, Functions, Rules, E2E all green (summary comment job last checked in progress).

## Review sweep of PR #209 (2026-11-21, separate session; commits carry `tsadmin@gmail.com`)
Reviewed on the PR branch itself (fixes go in the same PR). PAT only via `git -c http.extraHeader`, never stored. Run the script suite with a glob: `node --test .github/scripts/__tests__/*.test.js` (the directory form fails on Node 22).
- [x] `897cab8` docs: AP3b references restored to Skill 178 (AGENTS x2, README, ATOMIC-OPERATIONS-STATUS); Skill 180 moved to the end of SKILLS.md; index regenerated.
- [x] `66b4d3f` code: F-A page clock refreshed when the overlay opens (`refreshPeriod()`, no `onVisibleChanged`); F-B overlay closes in `onSignedOut`; F-C figures `HorizontalFit` (never elided first); F-E `asOfText` Invalid Date guard; F-G stray import blank line. CI green (QML, Functions, E2E, Rules).
- [x] docs: test plan steps 23 to 27, KNOWN-ISSUES S4b-2 items 14 to 18, Skill 180 rules 9 to 12, README and AGENTS clause.
- Checked and dismissed: error replacing the old answer is a pinned decision (SRW-24/25); Back button 40 dp copies ActivityPage; every component, property and token exists; service drops answers after a tenant or role change.
- Not run (no Qt here): qmllint, QML tests, `HorizontalFit` inside a Layout, the Android `-` key. Device steps 23 to 26 cover them.
- Script suite: 1199/1199.

## NEXT
Human review of PR #209 and the 27-step device pass in the test plan (steps 23 to 26 are the review sweep additions; item 14 of KNOWN-ISSUES S4b-2 is the open overlay sign-out gap for Profile, Staff and Activity). Then S4b-3 (emulator e2e QML to endpoint, date picker for custom range, optional header split), then S3 or what the CA answers unblock. Do not force-push.
