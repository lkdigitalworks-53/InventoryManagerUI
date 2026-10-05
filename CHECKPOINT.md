# CHECKPOINT — 2026-10-06 session: PH3b slice S-C (resume here)

**Branch:** `feat/2026-10-06-ph3b-sweeper-e2e-docs` off `main` @ `cdc8b0c` (PR #127 merged). Slice **S-C only**: emulator e2e `test/e2e/cleanupSweep.e2e.test.js` (E1-E5), `checks.yml` wiring, docs. NO deploy, NO app build, NO Qt tools; CI is the signal (emulator not runnable in sandbox).
**Commit identity:** `Taher (via Claude session) <lkdigitalworks@gmail.com>` (repo-local). Push with PAT in push URL only; never in a file / git config / memory.
**Previous checkpoint archived:** `docs/superpowers/specs/2026-10-05-pr127-ph3b-sb-final-sweep-CHECKPOINT.md`.
**Design status:** COMPLETE (spec "PH3b", test plan section 3). No open design question blocks S-C.

## Step log
1. Cloned fresh, read memory, last checkpoint, spec PH3b, test plan section 3, `index.js` binding, `photoCleanup.js`, `recordOperation.e2e.test.js`, CI e2e job.
2. Branched, archived the PR #127 checkpoint, wrote this file.
3. Wrote `test/e2e/cleanupSweep.e2e.test.js` (E0-E6, 7 tests). Chained as a 2nd `node --test` in the existing e2e `firebase emulators:exec` string in `.github/workflows/checks.yml` (+ artifact path `results-cleanupSweep.xml`). Sandbox checks done: `node --check`, bracket balance, guard exits 1 without emulator hosts, `functions/index.js` loads in-process with fake hosts (`cleanupPendingMarkers.run` is a function, region asia-south1, `logger.write` mutable, root admin 14.2.0 vs functions admin 12.7.0 coexist). NOT RUN: the e2e itself (no emulator).
4. Docs: AGENTS (S-C status + runbook un-park text), KNOWN-ISSUES (new PH3b limits M1-M5 section, item 3 reworded), roadmap entry, test plan section 3 (E0, E6 added), test-plans README row, spec S-C DONE + deviations, SKILLS 104.
5. Functions suite re-run: unchanged (no functions code touched).

## Decisions (recommended defaults applied; Taher may veto in PR)
- M1 (env order dev,test,prd shares one 240 s budget): KEEP. Design v2 silent, reorder = 17 assertion edits, only bites after many slow sweeps. Documented in KNOWN-ISSUES.
- M2-M5: documented in KNOWN-ISSUES, no code change.
- O1 (CI Functions count 369 vs local 582): still unverified; needs Taher to read the `# tests` line in the CI log.

## NEXT
1. Taher: review PR; READ THE CI E2E JOB. Expect one correction round on `cleanupSweep.e2e.test.js` (E0 first: named databases `dev1`/`test` in the emulator; then admin-major coexistence, `GCLOUD_PROJECT`, storage host). If E0 fails only on the named databases, the cheap fix is to let E0-only skip, not to change `index.js`.
2. Taher: O1 (CI Functions count 369 vs local 582): read the `# tests` line in the Functions job log once.
3. Taher: deploy ALL functions, accept the Cloud Scheduler API prompt, record the deploy here, create the alert (`specs/2026-10-05-ph3b-alert-runbook.md`), run test plan section 4 (DV-1..DV-9) on `dev1` only.
4. After PH3b is proven: PH4 client (403 terminal, `Qt.uuid()` photo ids, `deleteProduct` stops removing photos, Q13 toast), BC2 follow-ups, PH5.
5. Next session if CI is red: fix only the e2e file, push to this branch.
