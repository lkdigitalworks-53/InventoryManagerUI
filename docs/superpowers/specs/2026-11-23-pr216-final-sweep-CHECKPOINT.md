# CHECKPOINT: PR #216 final sweep (review + fixes in the same PR) - resume here

**PR:** #216 `Picker v2 S5e-3b`, branch `feat/2026-11-23-picker-s5e3b-names-for-text-buttons-and-fields`, base `main` @ `13e08e8`, head at sweep start `8e81d32`.
**Rules in force (owner, this session):** clone fresh; fixes go on the PR branch itself (owner said so, overrides "always a new branch" for this one task); push without asking; no build, no run of the app; no Qt in the sandbox (CI is the oracle); no parallel agents; every commit message carries `tsadmin@gmail.com`; tests + test plan + docs for every change; short steps so another account can take over from the remote branch.
**Skills used:** requesting-code-review, qt-qml-review (Phase 1 python lint, Phase 2 done by hand in passes, no parallel agents), ponytail-audit.

## Steps
- [x] 0. Cloned, PR #216 metadata read (25 files, +501/-55, 2 commits, mergeable clean).
- [x] 1. This checkpoint created (before any review work).
- [x] 2. Pass A: QML diff read line by line (12 QML files, not 14: 14 counts tests/docs). Context of every touched button/field read.
- [x] 3. Pass B: qt_qml_lint.py on the 12 changed QML files; filtered to changed lines only: 5 hits (see log). Baseline noise (~1000 lines) is old, not this PR. qmllint not run (no Qt, CI only).
- [x] 4. Pass C: tests read (pickerS5e3bNames, pickerS5e3Names, qmlButtonScan, completionsSyncingWiring). Gap found: monkey S5E3B-24 passed an empty name trivially (`out.includes("")`).
- [x] 5. Pass D: docs read (test plan diff, KNOWN-ISSUES numbering 97/120-130, Skill 187, AGENTS, README). Numbering consistent. Plan doc and root CHECKPOINT only skimmed.
- [x] 6. Baseline measured on PR head: functions 2327/2327, scripts 1199/1199, skills-index current.
- [x] 7a. F-1 fixed (fallback `|| qsTr("item")` on 4 field names), S5E3B-24 hardened, S5E3B-28/29 added, 6/6 mutants killed, docs updated (test plan row + check 193, Skill 187 rule 11, KI 131-134, AGENTS, README).
- [x] 7b. Ponytail lean read done: nothing to delete. One merge candidate NOT done: `run` and `nameOf` helpers are copied in pickerS5e3Names.test.js and pickerS5e3bNames.test.js (same qsTr mock, must change together). Root CHECKPOINT.md updated.
- [x] 8. Pushed `842ea90`. CI on it: Functions, Rules, QML, E2E success; Deploy skipped; PR summary comment job was still running when read. Counts not read.
- [x] 9. Final report given. NEXT (owner): decide KI 130 (tab selected state), KI 129 (five dead Profile rows announced as buttons), check 193 on a device, answer plan Q1 to Q3.

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

- F-1 FIXED (KI 131). F-2 logged KI 132. F-3 logged KI 133. Guard fragility logged KI 134. DEL-1 18 hits in OrderDetailDialog (2 new from this PR) logged in KI 133.
- Not fixed on purpose, needs owner decision (see final report): tab selected state (KI 130), five dead Profile rows now announced as buttons (KI 129).
