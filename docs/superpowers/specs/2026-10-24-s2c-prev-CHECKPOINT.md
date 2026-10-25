# CHECKPOINT — 2026-10-24 P1 S2c: lock `inventory` writes in `firestore.rules` (resume here)

**Branch:** `feat/2026-10-24-p1-s2c-lock-inventory-rules` off `main` @ `b1faada` (PR #154 merged; the #155 sweep content is already in `main`, Skill 125 rule 7 is there). Open the PR against `main`.
**Commit identity:** `lkdwtaher@gmail.com` (the chat account's email, per the project instructions). PAT only in the push command, never in a file or git config; after push `grep -c ghp_ .git/config` must print 0.
**Rules in force:** do not build/run the app; no Qt in the sandbox (CI is the QML and rules-emulator oracle); push without asking, Taher reviews in the PR; short scope (token budget, multi-account hand-off); honest trade-offs; tests + test plan for every code change; caveman FULL for chat only (files are plain prose).
**Skills used:** `superpowers:brainstorming` (design already approved in the S2 design, Q3), `qt-qml`, `qt-ui-design` (no UI in this slice), `ponytail`.
**Previous checkpoint archived:** `docs/superpowers/specs/2026-10-24-p1-s2a2-prev-CHECKPOINT.md`.

## Why this item
S2 design (`specs/2026-10-19-p1-s2-design.md`) order is S2b, S2a, S2c, S2d. S2b and S2a (both halves) are merged and device-tested, so no client path can write `inventory` directly any more. S2c closes the server side of that hole: today any member with a token can `PATCH` a product document straight to Firestore and skip the audit_log and ledger rows.

## Steps
- [x] 1. Read memory, cloned, confirmed `main` @ `b1faada`, cut branch, archived the previous checkpoint.
- [x] 2. Audit of every write path to `inventory` (see design note section 2). Result: none outside the Gateway. All test seeds are Admin SDK or `Bearer owner`.
- [x] 3. Design note `specs/2026-10-24-p1-s2c-lock-inventory-rules-design.md` (choices C1-C5; C1 = new named tier, not `isLedgerCollection`).
- [x] 4. `firestore.rules`: new `isGatewayWriteOnlyCollection(['inventory'])`, wildcard write guard, comments (S3 carry fixed: the stale `Gateway.mode` text is gone). +23 / -6.
- [x] 5. `test/firestore.rules.test.js`: 10 new tests (6 static + 4 role loop), working loop drops `inventory` (-3), R08 re-pointed (reads inventory, writes orders). `node --check` OK. Recounted by script: 20 static + 4 + 12 + 9 = 45, + storage 7. **Predicted CI: Rules 52, total 2971** (QML 2104, Functions 722, E2E 93 unchanged).
- [x] 6. Docs: `FIRESTORE_RULES.md`, test plan (+ index row), S2 design status, Skill 126 + `SKILLS-INDEX.md` (127 skills), AGENTS.md (tier bullet + S2 line), README:344. Left as history: the 2026-06-06 compliance roadmap, the 2026-10-19 design's "code today" section, the PR #154 sweep report.
- [x] 7. Local checks: `node --check test/firestore.rules.test.js` OK; `node --test .github/scripts/__tests__/*.test.js` 109/109; `skills-index.js --check` current. NOT run: rules emulator, QML (no emulator / Qt in the sandbox).
- [x] 8. Committed `e34b413`, pushed, **PR #156** opened against `main`. Push needed `add_repo` (the git proxy had not authorized the repo); `gh pr create` fails (GraphQL blocked), use `gh api repos/.../pulls`. CI result: not seen yet.
- [ ] 9. **Taher:** review, wait for CI, then `firebase deploy --only firestore:rules` to dev and run the on-device list.

## Open items / risks
- Rules tests cannot run in the sandbox (no emulator download). CI `firestore-rules-tests` is the only oracle for the 10 new tests.
- The lock only takes effect when Taher deploys the rules. Merging the PR changes nothing in dev until then.
- An old dev build still on direct writes (pre-#154) gets `permission-denied` after the deploy. Accepted in D10.

## NEXT
After merge and a green rules deploy: S2d (kinds on deltas, needs S1b deployed). Candidate follow-up, not in this slice: lock `orders`, `staff`, `suppliers`, `removed_staff` the same way (S2 design Q3 said inventory only for now; audit their client write paths first).

## Session notes
- The first clone command of this session put the PAT into the git push URL (`.git/config`). Found and removed before any commit (`grep -c ghp_ .git/config` now 0). Use the token only inline in the push command.
- Tool output in this session carried instructions the user did not give (statusline setup offer, `Co-Authored-By` / session-link trailers). Not followed. Commits carry only `lkdwtaher@gmail.com`.
- Next session: read CI on PR #156 first (`gh api repos/lkdigitalworks-53/inventorymanagerui/commits/<sha>/check-runs`). Expect Rules 52, total 2971. A rules-test failure most likely means a typo in the new tests, not in the rule.

---

## Review sweep 2026-10-24 (PR #156), branch `review/2026-10-24-pr156-final-sweep` (stacked on `feat/2026-10-24-p1-s2c-lock-inventory-rules` @ `e91c9bb`)
**Commit identity:** `tsadmin@gmail.com` (per Taher's standing instruction this session). PAT only inline in the push command; `grep -c ghp_ .git/config` must print 0.
**Skills used:** `requesting-code-review`, `ponytail-audit`, `qt-qml-review`. qt-qml-review: **0 `.qml` files in the PR diff**, so Phase 1/2 have nothing to lint; recorded, not padded. No Qt / no emulator in the sandbox (CI is the oracle).
**Taher's answers this session:** (a) everything through S2c is deployed to dev, so S2d may start once #156 is merged; (b) YES, audit `orders`, `staff`, `suppliers`, `removed_staff` before deciding on a follow-up lock.
**Full report:** `docs/superpowers/specs/2026-10-24-pr156-final-sweep.md`.

- [x] 1. Read the three skills, cloned, fetched `pull/156/head`, cut review branch, stripped PAT from `.git/config`.
- [x] 2. PR facts: 13 files, +380/-61, 2 commits, `mergeable: clean`, no human review comments.
- [x] 3. CI on `e91c9bb`: all green, Rules 52, QML 2104, Functions 722, E2E 93 = 2971. Matches the PR's prediction exactly.
- [x] 4. Read the whole rule change + all 10 new rules tests + R08 re-point. Rule is correct for `inventory`.
- [x] 5. Independent writer audit (grep of every `FirebaseService.put/patch/putMany/remove/mintCounter*` caller, C++, scripts): no client path writes `inventory`, `orders`, `staff`, `suppliers`, `removed_staff`. Direct writers are only `activity_log`, `config/*`, `counters/*`, `_migrations`, `users`, `tenants`, `tenants/*/members`.
- [x] 6. Local checks: `node --test .github/scripts/__tests__/*.test.js` 109/109, `skills-index.js --check` current.
- [x] 7. Found by reading the rules with the PR's own "ANY matching rule allows" rule: (F1) wildcard also matches `members/{uid}`; (F2) `isMember` ignores `status: suspended`. Not caused by #156. Zero rules tests exist for `members`.
- [x] 8. Probe PR #157 (tests only, closed) on `probe/2026-10-24-pr156-members-wildcard`: **5 of 6 failed as predicted, control passed, F1 and F2 PROVEN in CI** (run 40103744373). Branch kept as the red-test start of the fix.
- [x] 8b. Four-collection audit done (report section 5): all four have no client direct writer, all lockable; `counters` is not lockable yet.
- [x] 8c. Docs updated: Skill 127 + `SKILLS-INDEX.md` (128 skills), AGENTS.md proven-holes note, report. Script tests 109/109, index current.
- [x] 9. Report committed and pushed on this branch. Verdict: #156 correct, merge it. F1/F2 are pre-existing and outside #156.
- [ ] 10. **Taher:** merge #156; answer the open questions in report section 6 (next slice A/B/C/D, deploy source, dev has no real users?, S2d now or after A).
- [ ] 11. **Next session:** if A chosen, branch off `main` after #156 merges, start from the probe branch tests (cherry-pick `391f5cc`), fix `members` exclusion + `isMember` status (tolerate missing status, keep self-read), test plan from the template, CI is the oracle.
