# CHECKPOINT — 2026-10-26 S2f-7 `provisionMember` add-only (resume here)

**Branch:** `fix/2026-10-26-s2f7-provision-member-target-guard`, cut from `main` @ `b494d52` (PR #161 merged). PR number: see GitHub.
**Commit identity:** `dextran52@gmail.com` (Taher's instruction, 2026-10-26). PAT comes from the chat prompt only: pass it with `git -c http.extraHeader="Authorization: Basic $(printf 'x-access-token:%s' "$PAT" | base64 -w0)"`, never in the remote URL, `.git/config`, the repo or memory. After a push `grep -c ghp_ .git/config` must print 0.
**Rules in force:** no build/run; no Qt in the sandbox (CI is the QML + rules + e2e oracle); push without asking; short scope per session; honest trade-offs; tests + test plan for every change; caveman FULL for chat only.
**Skills used:** `superpowers:brainstorming` (design doc; decisions defaulted and marked vetoable because Taher asked for one turn, so the interactive approval gate was NOT run), `ponytail` (add-only instead of a hierarchy copy), `qt-qml` (one string, one test file), `qt-ui-design` (nothing to design: endpoint dormant).
**Previous checkpoint archived:** `docs/superpowers/specs/2026-10-26-s2f4-pr161-merged-prev-CHECKPOINT.md`. Main moved while this PR was open (#147 merged, atomic-ops design docs only); its checkpoint is archived as `docs/superpowers/specs/2026-10-26-pr147-merged-prev-CHECKPOINT.md`.

## Where the compliance roadmap stands (verified in code on `main` @ `b494d52`, 2026-10-26)
| Item | Status |
|---|---|
| P0 gateway + immutable `audit_log` | **Done**, live since 2026-07-29. Ledger collections are read-only to clients. |
| S2f authz hardening | S2f-1 gateway trusts member doc (#159) done; S2f-2 members rules + D-1 hierarchy (#160, #164) done; S2f-4+5 default-deny writes (#161) done; **S2f-7 `provisionMember` add-only: THIS PR**. Open: S2f-3 client wording (suspended/removed screen), S2f-6 server-side counter minting (`counters` still any-role writable, design needed), sweep findings 9 (plain-text 500 on a Firestore blip) and 11 (tenant-id charset). |
| P1 stock taxonomy | S1a, S1b done and deployed (device checklists passed 2026-10-21). S2a (direct mode + client cutover deleted), S2b, S2c (`inventory` write-locked) done. **S2d not started** (kinds on deltas: `Gateway.recordDelta(..., movements)`, `OutboxStore` must CONCATENATE movements when coalescing, restock = `receipt`, returns = `sales_return`; needs S1b deployed, which it is). S2e parked until the CA answers which 56(2) columns need intent kinds (Q1). S3 (`sale` per FIFO batch with `batchRef`) not started; a derived `sale` row exists today. S4 (opening/closing register report) not started. |
| P2 tax identity (HSN, GSTIN) | **Not started** (0 hits for `hsnCode`/`gstin` in `qml/`, `functions/`). Client-only, effort S. |
| P3 legal docs + acceptance, P4 DPDP consent, P5 erasure/retention, P6 breach, P7 warehouse | **Not started.** Dates from the master spec: Consent Manager live 2026-11-13, full DPDP compliance 2027-05-13. |
| Deferred (56(12), 56(15), OIDAR) | Out of scope per the master spec. |
| Pending, not compliance | Multi-role login (DRAFT `specs/2026-10-25-multi-role-login-design.md`; `Gateway.provisioningAvailable` still `false`). S2f-7 was a prerequisite for flipping it. |

## Steps (this session)
- [x] 1. Read memory, cloned, read the master roadmap, S2 and S2f designs, PR #159/#161 sweeps, checked code for each roadmap item.
- [x] 2. Chose S2f-7 (see design doc section 1 for severity, honest: needs an owner/admin token, endpoint dormant client-side).
- [x] 3. Wrote `lib/memberProvisionLogic.js` (pure), wired `provisionMember` (member read first inside the transaction, 409 `member-exists`, one warning per refusal).
- [x] 4. Tests: Functions 835 -> **866/866** run locally (11 unit + 20 handler). New lib 100%. Fix-revert: 14 of 31 red. 8 mutants, all caught (one equivalent for outcomes: owner check changes only the log reason).
- [x] 5. e2e +5 in `recordOperation.e2e.test.js` (NOT run: no emulator). QML: `AuthService._provisionErrorMessage("member-exists")` + `tests/tst_ProvisionErrorMessage.qml` (4 functions, NOT run: no Qt).
- [x] 6. Docs: design, test plan (curl-based server steps + phone regression), Skill 132 + SKILLS-INDEX regenerated, AGENTS, README, S2f design row, test-plans index, KNOWN-ISSUES (2 entries).
- [ ] 7. Read CI on the PR head; fix whatever is red (suspects: the 5 e2e tests, `tst_ProvisionErrorMessage.qml`; recount from the CI comment, do not trust predictions).
- [ ] 8. Taher: merge, `firebase deploy --only functions`, run the plan's curl rows (DN1-DN9) and the phone regression rows (DR1-DR4).

## Questions open for Taher (defaults applied, vetoable in the PR)
1. Add-only (A, default) or role-editor with the hierarchy inside the endpoint (B)?
2. Unknown role -> 400 instead of silent `staff`?
3. `audit_log` rows for membership changes before staff login goes live (recommended)?

## NEXT (suggested order, each its own branch and session)
1. S2f-3 client wording + suspended/removed screen (QML, CI-only), or the membership audit-log design if Taher wants Q3 first.
2. S2d kinds on deltas (the P1 core; the largest remaining S2 slice, needs a strong coalescing test set).
3. S2f-6 counters (design first).
4. P2 HSN/GSTIN: never started although the master spec said "start immediately"; cheap and client-only. P3/P4 before the DPDP dates above.

## Update 2026-10-26 (session 6: final-sweep review of PR #165, stacked branch `review/2026-10-26-pr165-final-sweep`)
**Commit identity this session:** `taher.lkdw@gmail.com`. **Skills used:** `superpowers:requesting-code-review`, `ponytail:ponytail-audit`, `qt-development-skills:qt-qml-review` (lint only, no Qt).
- [x] 1. Read memory, skills, cloned, fetched `pull/165/head`; CI on `f7c2bf7` green 3191 (QML 2118, Functions 866, Rules 106, E2E 101).
- [x] 2. Read all server + client paths and tests; ran `npm test` 866/866 and script tests 109/109 locally.
- [x] 3. Report: `specs/2026-10-26-pr165-final-sweep.md` (0 must-fix, 6 should-fix, 3 nice).
- [x] 4. Fixes: message reword + 1 QML test, D14 + test plan + counts corrected, 2 KNOWN-ISSUES entries, Skill 133 + index (134 skills), design Q4/Q5.
- [ ] 5. Read CI on the review PR head; recount from the CI comment (expect QML 2119).
- [ ] 6. Taher: answer Q1-Q5 in the design; merge review PR into #165's branch, then #165; `firebase deploy --only functions`; run DN/DR rows of the test plan.

