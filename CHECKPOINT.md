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
- [ ] 8. Commit, push, open PR (in progress; PR number goes here).
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
