# CHECKPOINT: PR #216 final sweep (review + fixes in the same PR) - resume here

**PR:** #216 `Picker v2 S5e-3b`, branch `feat/2026-11-23-picker-s5e3b-names-for-text-buttons-and-fields`, base `main` @ `13e08e8`, head at sweep start `8e81d32`.
**Rules in force (owner, this session):** clone fresh; fixes go on the PR branch itself (owner said so, overrides "always a new branch" for this one task); push without asking; no build, no run of the app; no Qt in the sandbox (CI is the oracle); no parallel agents; every commit message carries `tsadmin@gmail.com`; tests + test plan + docs for every change; short steps so another account can take over from the remote branch.
**Skills used:** requesting-code-review, qt-qml-review (Phase 1 python lint, Phase 2 done by hand in passes, no parallel agents), ponytail-audit.

## Steps
- [x] 0. Cloned, PR #216 metadata read (25 files, +501/-55, 2 commits, mergeable clean).
- [x] 1. This checkpoint created (before any review work).
- [x] 2. Pass A: QML diff read line by line (12 QML files, not 14: 14 counts tests/docs). Context of every touched button/field read.
- [x] 3. Pass B: qt_qml_lint.py on the 12 changed QML files; filtered to changed lines only: 5 hits (see log). Baseline noise (~1000 lines) is old, not this PR. qmllint not run (no Qt, CI only).
- [ ] 4. Pass C: tests read (pickerS5e3bNames, pickerS5e3Names, qmlButtonScan, completionsSyncingWiring).
- [ ] 5. Pass D: docs read (plan, test plan, KNOWN-ISSUES, Skill 187, AGENTS, README, CHECKPOINT).
- [ ] 6. Run the Node suites (functions, scripts, skills-index) to measure the baseline.
- [ ] 7. Fix findings (one commit per group), add tests, update test plan and docs.
- [ ] 8. Push, read CI.
- [ ] 9. Final report: done / next.

## Findings log
Session 2 (account B) started at step 2, repo cloned fresh, remote URL clean, git user tsadmin@gmail.com.
- Lint on changed lines: ORD-1 at NotificationsSheet:72 and SalesPage:808 are FALSE POSITIVES (the `id` is first in its own `contentItem: Text` block; the linter reads the sibling `background` block). ORD-1 at DashboardPage:438 is style only (`Accessible.ignored` before `text`), no behaviour. DEL-1 at OrderDetailDialog:729, :835 is a real but old pattern (`model.name` in a delegate with no required property; the file already does this on dozens of lines). Not fixed here (a rewrite of that delegate is its own slice); logged.
- ProfilePage uidBtn: child Text 'ID: ...' left unignored ON PURPOSE (test comment line 159). Not a finding.
- No .ts/.qm files in repo: changing Dashboard 'See all  >' key to 'See all' loses no translation.
- Candidate F-1 (low): four field names `.arg(modelData.name)` / `.arg(model.name)` have no fallback, member buttons do (`memberLabel`). Empty or missing name speaks 'Price of ' or 'Price of undefined'. To verify against Qt `String.arg(undefined)` behaviour in tests.
- Candidate F-2 (low): two members with the same displayName speak the same 'Remove Asha'.
- Candidate F-3 (pre-existing, log only): MemberManagementDialog ToolTip texts 'Activate', 'Suspend', 'Remove member' are not qsTr.

## If this session is cut off
Resume at the first unticked step. Re-measure before claiming any count: `cd functions && npm ci && node --test`, `node --test .github/scripts/__tests__/*.test.js`, `node .github/scripts/skills-index.js --check`.
