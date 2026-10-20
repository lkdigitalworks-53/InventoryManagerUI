# CHECKPOINT — 2026-10-21 P1 S2b: PR #151 deep review (resume here)

**Branches:** `docs/2026-10-19-p1-s2-design` (design + checkpoint, off `main` @ `fe9aa86`), and `feat/2026-10-19-p1-s2b-delete-runcutover` stacked on it (S2b code). Open the PR for the feat branch against `main` only after the docs branch is merged, or against the docs branch (Skill 121: squash-merge of a parent makes a stacked PR conflict).
**Commit identity:** `tsadmin@gmail.com` (this session's rule; earlier branches used other ids, left as is). PAT only in the push command, never in a file or git config; after push `grep -c ghp_ .git/config` must print 0.
**Rules in force:** do not build/run the app; no Qt in the sandbox (CI is the QML oracle); push without asking, Taher reviews in the PR; short scope (token budget, multi-account hand-off); honest trade-offs and grill before decisions; tests + test plan for every code change; caveman FULL.
**Skills used:** `brainstorming` (path: ARCHITECTURAL, hard gate: no code before approval), `qt-qml`, `qt-ui-design`, `ponytail`. Review session 2026-10-21 (no app code changed): `requesting-code-review`, `ponytail`, `qt-qml-review`.
**Previous checkpoint archived:** `docs/superpowers/specs/2026-10-18-p1-s1b-prev-CHECKPOINT.md`.

## Why this item
S1b checklist (deploy + device test) is Taher's and in progress. Next item in the P1 design (section 4) is S2. It was never designed (spec section 8 leaves UX open), so this session designs it.

## Steps
- [x] 1. Read skills, cloned repo, read S1b checkpoint, P1 design spec, branch cut.
- [x] 2. Code audit (findings in the design doc section 1): direct mode only in `recordMutation`/`recordEdit`/`recordMutations`; `runCutover` has no client caller; no client writes `inventory` outside the Gateway; stock paths (`restock`, `deductStock`, `creditStockNoBatch`) all send plain deltas so the server derives `adjustment`; `OutboxStore.enqueueDelta` SUMS coalesced deltas, so `movements` must be concatenated (new trap).
- [x] 3. Draft design `docs/superpowers/specs/2026-10-19-p1-s2-design.md`: split S2a-S2e, order, trade-offs, open questions Q1-Q5. README pointer added.
- [x] 4. Committed and pushed (no PR opened: Taher reviews the branch).
- [x] 5. Taher answered Q1-Q3 (all as recommended): wait for CA before pickers, S2b first, lock `inventory` only. Design bumped to rev 2.
- [x] 6. **S2b implemented** on the feat branch: deleted `exports.runCutover`, `lib/cutoverLogic.js`, `test/cutoverLogic.test.js`, 9 handler tests, harness mock; added 1 guard test (2 mutants caught). `node --test` 740 -> 722, 0 fail. README, AGENTS.md, Skill 123 + index, test plan + test-plans index row.
- [x] 7a. **Taher (2026-10-21):** S1a/S1b functions deployed to dev, on-device checklists done, all fine. Ticked in `test-plans/2026-09-24-p1-stock-movements-test-plan.md` (S1 gate R3 is now met: S2d may start after S2a/S2c).
- [ ] 7b. **Taher:** merge PR #151, deploy functions to dev (answer YES to the delete prompt for `runCutover`), run the on-device list in `test-plans/2026-10-19-p1-s2b-delete-runcutover-test-plan.md`. NOT done: the 2026-10-21 deploy was of S1a/S1b from `main`, before #151, so `runCutover` is still live on dev.
- [x] 9. PR #151 deep review 2026-10-21 (server diff read in full, CI 2964/2964 seen, `node --test` re-run locally 722/722, guard mutants 1+2 caught, merge clean, no revert of main). Verdict: no Critical, no Important. Minor findings M1-M5 below.
- [x] 10. 2026-10-21 Taher decisions: Q1 keep client `runCutover` for S2a; Q2 fix M1-M3 in PR #151 (done, below); Q3 no reset path, no prod yet (design Q6). `node --test` 722/722 after the fixes.
- [ ] 8. Next slice, own session: **S2a** (delete `direct` mode + client `runCutover`/`cutoverUrl`/`cutoverFinished`, drop `stock_movement` from `Gateway._collections`, rewrite the `tst_Gateway.qml` cases that force `"direct"`; CI is the only oracle). Then S2c (rules lock + rules test), then S2d (needs S1b deployed).

## PR #151 review findings (all Minor; M1-M3 FIXED 2026-10-21, M4 accepted)
- M1 FIXED: `testSupport/handlerHarness.js` lines 85-88: `deleteCollectionResult/Error`, `zeroInventoryStockResult/Error` are dead (nothing reads them).
- M2 FIXED: S2b test plan says `git grep -n -i cutover -- functions` finds none; it finds 5 (comments + the guard test). Reword the claim.
- M3 FIXED: AGENTS.md ~689 now says "All 11 Cloud Functions" with the 11 names (checked: each export calls `scopedDb`).
- M4 ACCEPTED: Guard pins the NAME `runCutover` and the lib file, not the capability: `exports.wipeLedger = ...` would pass (mutant 3 probe). Accepted: tests cannot pin intent.
- M5 FIXED: This checkpoint's old header said "No code this session": fixed here.
- Left on purpose, tracked for S2a: `Gateway.qml` `cutoverUrl`, `cutoverFinished`, `runCutover()` (about 45 lines, no caller, no test) still point at the deleted endpoint. QML lint on that block: only pre-existing JS-1/JS-2 style hits, nothing in the PR diff (PR touches 0 QML lines).

## Open items / risks
- Q4 (damaged returns: `sales_return` vs `destroyed`) and Q5 (`valueAtCost` client-stated) stay open for S2e/S2d.
- S2d/S2e must not ship before the S1b deploy + device checklist passes (R3).
- S2a rewrites `tst_Gateway.qml` cases that force `"direct"`: CI is the only oracle.
- Deleting the `runCutover` export does not delete the deployed function; Taher confirms the prompt on `firebase deploy`.

## NEXT
Taher reviews/merges the PR and deploys. Then S2a in a new session on a new branch off `main`.
