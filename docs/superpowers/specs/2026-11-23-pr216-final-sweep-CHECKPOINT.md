# CHECKPOINT: PR #216 final sweep (review + fixes in the same PR) - resume here

**PR:** #216 `Picker v2 S5e-3b`, branch `feat/2026-11-23-picker-s5e3b-names-for-text-buttons-and-fields`, base `main` @ `13e08e8`, head at sweep start `8e81d32`.
**Rules in force (owner, this session):** clone fresh; fixes go on the PR branch itself (owner said so, overrides "always a new branch" for this one task); push without asking; no build, no run of the app; no Qt in the sandbox (CI is the oracle); no parallel agents; every commit message carries `tsadmin@gmail.com`; tests + test plan + docs for every change; short steps so another account can take over from the remote branch.
**Skills used:** requesting-code-review, qt-qml-review (Phase 1 python lint, Phase 2 done by hand in passes, no parallel agents), ponytail-audit.

## Steps
- [x] 0. Cloned, PR #216 metadata read (25 files, +501/-55, 2 commits, mergeable clean).
- [x] 1. This checkpoint created (before any review work).
- [ ] 2. Pass A: QML diff read line by line (14 files).
- [ ] 3. Pass B: qt_qml_lint.py on the 14 changed QML files; compare with the main baseline so only NEW findings count.
- [ ] 4. Pass C: tests read (pickerS5e3bNames, pickerS5e3Names, qmlButtonScan, completionsSyncingWiring).
- [ ] 5. Pass D: docs read (plan, test plan, KNOWN-ISSUES, Skill 187, AGENTS, README, CHECKPOINT).
- [ ] 6. Run the Node suites (functions, scripts, skills-index) to measure the baseline.
- [ ] 7. Fix findings (one commit per group), add tests, update test plan and docs.
- [ ] 8. Push, read CI.
- [ ] 9. Final report: done / next.

## Findings log
(empty so far)

## If this session is cut off
Resume at the first unticked step. Re-measure before claiming any count: `cd functions && npm ci && node --test`, `node --test .github/scripts/__tests__/*.test.js`, `node .github/scripts/skills-index.js --check`.
