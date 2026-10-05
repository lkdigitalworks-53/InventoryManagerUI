# CHECKPOINT — 2026-10-05 session: PH3b slice S-A (resume here)

**Branch:** `feat/2026-10-05-ph3b-sweeper-lib` (off `main` @ `a565bbd`). Slice **S-A only**: pure functions in `functions/lib/photoCleanup.js` + unit tests. No `index.js` change (that is S-B), no QML, no deploy, nothing built or run except the Node functions suite.
**Commit identity:** `dextran52@gmail.com` (user, this session), passed per commit with `git -c`, never in global config. Push with PAT in the header only (never write the PAT into any file/memory).
**Standing rules:** clone each session; branch only; push without asking; no app build/run; no Qt tooling in sandbox (CI = QML signal; no QML here anyway); small scope, resumable by another account; honest advisor; tests + test plan for every change; update SKILLS/AGENTS/README as needed; terse "caveman" replies.
**Previous checkpoint archived:** `docs/superpowers/specs/2026-10-05-ph3b-design-merged-CHECKPOINT.md` (PH3b design v2 + reviews, PRs #124/#125 merged).
**Baseline:** functions suite 491/491 green on `main` (Node 22.22.2, `cd functions && npm ci && node --test`).

## Task
Implement PH3b slice S-A. Design: `docs/superpowers/specs/2026-09-30-photos-s3-s4-design.md` "PH3b". Test plan: `docs/superpowers/test-plans/2026-10-05-ph3b-scheduled-cleanup-test-plan.md` section 1 (UP, UD, US, UR, UL, UM = 57 cases).

## Step log
1. Read memory + CHECKPOINT + spec PH3b + test plan + `photoCleanup.js`; cloned repo; baseline 491/491.
2. Branch created, old checkpoint archived, this checkpoint written (commit b45d8fc).
3. Implemented in `functions/lib/photoCleanup.js`: constants (`GRACE_MS` ... `ALERT_TAG`), `parseMarkerPath`, `delayMs`, `selectDue`, `readAllMarkers`, `runCleanupSweep`; `sweepMarker` failure patch now carries `lastAttemptAtMs` (optional `deps.now`).
4. Tests: +33 in `functions/test/photoCleanup.test.js` (UP, UD, US, UM), new `functions/test/cleanupSweep.test.js` (+33: UL, UR, extras). Suite 557/557 green; `photoCleanup.js` line/branch/function coverage 100%.
5. Docs: test plan status + actual counts, test-plans README row, spec S-A DONE + deviation, AGENTS.md PH3b status, SKILLS 102 rule 9.
6. Pushed + PR opened (see PR link in chat; number recorded below once known).

## Decisions made without asking (flag in PR for Taher)
- `deps.park(env, path, reason)` instead of `(env, tenantId, productId, reason)`: malformed markers may have no parsable path. Reversible in S-B.
- `parked` is checked before malformed in `selectDue` (else a malformed marker is re-parked and re-alerted every run).
- A THROWN `sweep` is WARNING + `failed`, never parks (attempts were not incremented). Only `{ok:false}` at `attempts+1 >= PARK_AT` parks.
- Per-env summary log is always INFO; the ERROR `PH3B_ALERT` lines are separate (env-failed, backlog, marker-parked, park-failed).
- One run-wide `RUN_BUDGET_MS` clock (not per env).

## NEXT
1. Taher reviews + merges the S-A PR (CI: functions suite only; no QML touched).
2. **S-B** (`feat/2026-10-05-ph3b-sweeper-binding`): `index.js` P3 fix `updateMarker` -> `markerRef.update(patch)`; `exports.cleanupPendingMarkers = onSchedule(...)`; `listMarkers` via `readAllMarkers` + `collectionGroup("pending_cleanup")` (map Timestamp -> `createdAtMs`); `park` = `scopedDb(env).doc(path).update({parked:true, parkedAtMs, lastError})`; harness `update` + `collectionGroup`; functional tests FS01-FS10.
3. **S-C**: e2e `test/e2e/cleanupSweep.e2e.test.js` (+ `checks.yml`), AGENTS runbook, KNOWN-ISSUES, roadmap.
4. Taher deploys ALL functions manually, creates the alert (runbook), runs test plan section 4.
