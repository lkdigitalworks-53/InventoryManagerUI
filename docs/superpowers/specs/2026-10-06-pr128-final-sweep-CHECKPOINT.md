# CHECKPOINT — 2026-10-06 session 2: PR #128 final sweep + CI-reporting fix (resume here)

**Resume branch:** `fix/2026-10-06-ci-junit-parser` (stacked on `feat/2026-10-06-ph3b-sweeper-e2e-docs` = PR #128). Merge #128 first; the stacked PR then retargets to `main`.
**Commit identity:** `Taher (via Claude session) <lkdigitalworks@gmail.com>` (repo-local). Push with the PAT in the push URL only; never in a file / git config / memory.
**Rules in force:** branch only, no app build/run, no Qt tools in the sandbox (CI is the signal), tests + test plan per change, docs updated, caveman mode. NOTHING IS DEPLOYED.
**Previous checkpoint:** PR #128's first session (S-C written) is in git history of `feat/2026-10-06-ph3b-sweeper-e2e-docs` (7f7091b).

## Step log
1. Cloned fresh, read memory + skills (requesting-code-review, ponytail-audit, qt-qml-review), checked out PR #128 (`7f7091b`).
2. CI for `7f7091b`: all 5 checks green (QML 1910, Functions 370, Rules 45, E2E 63, comment job). No review comments. `mergeable_state: clean`.
3. Review of the deploy-bound code (S-A `photoCleanup.js`, S-B `index.js` binding, S-C e2e + CI wiring + docs). No Critical / Important code defect found (see PR comment on #128 for the full report).
4. FOUND: PR comment under-counts tests. E2E stayed 63 after +7 tests; Functions showed 370 vs 585 local (open item O1). Reproduced with real `node --test` JUnit output. Two causes: raw `>` in names (215 of 585), and bare node testcases dropped next to a `<testsuite>` file.
5. PR #128 branch: E2 test registers its audit doc for cleanup before the tick; AGENTS / spec / test-plans README / Skill 104 now say CI green (commits 227aa60, 6263a39).
6. Stacked branch: `parse-junit.js` rewritten (quote-aware tags, count all testcases), +10 tests, 52/52 script tests, 100% line/branch. Test plan, SKILLS 105, roadmap entry, README row. Proven: 7 of 9 new tests fail on the old parser.
7. Sandbox only used plain Node (functions suite 585/585 green locally, script tests). No Qt, no app, no emulator.

## Decisions (defaults applied; Taher may veto in the PR)
- CI-reporting fix is a SEPARATE stacked PR, not folded into #128: different concern (tooling), keeps #128 reviewable, no conflict risk.
- M1-M5 (KNOWN-ISSUES) re-reviewed against the code: all accurate, no code change. M1 stays.
- O1 CLOSED: not a missing-tests problem; the report was wrong (see step 4).

## Open items (need Taher)
1. Read the E2E job log of PR #128 once: confirm `cleanupSweep.e2e.test.js` printed 7 passing tests (the sandbox cannot reach the Actions log host; the `&&` chain proves exit 0, not the count).
2. BEFORE deploy: look at the `pending_cleanup` collection group in the `(default)` (prd) database, and in `test`, `dev1`, in the Firebase console. The first scheduled tick sweeps ALL THREE databases, including prd, and deletes `stock_batches` (cost layers) and photos for every due marker whose product is gone. Only dev1 is in the DV plan; the schedule cannot be limited to it.
3. Deploy ALL functions, accept the Cloud Scheduler API prompt, create the alert (`specs/2026-10-05-ph3b-alert-runbook.md`), run DV-1..DV-9 on `dev1`. DV-1 must also confirm the first tick log shows no `FAILED_PRECONDITION` / index error on `collectionGroup("pending_cleanup")` (the emulator does not enforce indexes; design says none is needed).
4. After PH3b is proven: PH4 client (403 terminal, `Qt.uuid()` photo ids, `deleteProduct` stops removing photos, Q13 toast), BC2 follow-ups, PH5.

## NEXT (next session)
1. If CI is red on the stacked PR: fix only `.github/scripts/parse-junit.js` and its test file.
2. If #128 merged: retarget the stacked PR to `main` (GitHub does it automatically when the base branch is deleted).
3. After the stacked PR merges: check the PR comment shows Functions 585 and a higher E2E count.
