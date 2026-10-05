# CHECKPOINT — 2026-10-05 session: PH3b slice S-B (resume here)

**Branch:** `feat/2026-10-05-ph3b-sweeper-binding`, STACKED on `feat/2026-10-05-ph3b-sweeper-lib` (PR #126, S-A, open). PR base for S-B = the S-A branch (re-target to `main` after #126 merges). Slice **S-B only**: `functions/index.js` binding + test harness + functional tests. No QML, no deploy, nothing built/run except the Node functions suite.
**Commit identity:** `Taher (via Claude session) <lkdwtaher@gmail.com>`, passed per commit with `git -c`, never in global config. Push with the PAT in the push URL only (never written to a file/memory/git config).
**Standing rules:** clone each session; branch only; push without asking; no app build/run; no Qt tooling in sandbox (CI = signal); small scope, resumable by another account; honest advisor; tests + test plan for every change; update SKILLS/AGENTS/README as needed; terse "caveman" replies.
**Previous checkpoint archived:** `docs/superpowers/specs/2026-10-05-ph3b-sa-CHECKPOINT.md` (S-A).
**Baseline:** functions suite 557/557 green on the S-A head (Node 22.22.2, `cd functions && npm ci && node --test`).

## Task
S-B per design `docs/superpowers/specs/2026-09-30-photos-s3-s4-design.md` "PH3b" (Slices, S-B) and test plan `docs/superpowers/test-plans/2026-10-05-ph3b-scheduled-cleanup-test-plan.md` section 2 (FS01-FS10).
Scope: (1) P3 fix `updateMarker` -> `markerRef.update(patch)`; (2) `exports.cleanupPendingMarkers = onSchedule(...)`; (3) `listMarkers` via `readAllMarkers` + `collectionGroup("pending_cleanup")`; (4) `park` -> `doc(path).update({parked, parkedAtMs, lastError})`; (5) harness `update`, `collectionGroup`, database-aware `getFirestore(app, dbId)`; (6) functional tests FS01-FS10.

## Verified facts (this session, sandbox)
- Installed firebase-functions: `onSchedule(...)` returns fn with `__endpoint` = `{timeoutSeconds, maxInstances, region:[..], scheduleTrigger:{schedule, retryConfig:{retryCount}}}` and `.run(event)`. FS01 reads these paths.
- `firebase-functions/logger` exports a mutable `write` (structured, `severity` + `message`).
- Marker `createdAt` is a Firestore server Timestamp (`serverTimestamp` passed by `applyMutation`); the binding must convert it to ms.

## Step log
1. Read memory, S-A checkpoint, PH3b design + test plan, `photoCleanup.js`, `index.js`, harness. Cloned repo, branched off PR #126 head, baseline 557/557.
2. Archived S-A checkpoint, wrote this checkpoint.
3. Implemented: `timestampToMs` (pure, `lib/photoCleanup.js`); `index.js` P3 fix (`updateMarker` -> `update`), `CLEANUP_ENVS`, `listPendingMarkers`, `parkPendingMarker`, `cleanupLog`, `exports.cleanupPendingMarkers` (onSchedule). Commit 73fd7d1.
4. Harness (`testSupport/handlerHarness.js`): `update` (NOT_FOUND on a missing doc), `collectionGroup` (limit/startAfter, default path order), `getFirestore(app, dbId)`, `docDb` scoping, `onStorageDeleteFiles` hook.
5. Tests: new `functions/test/index.handlers.cleanupScheduler.test.js` (19: FS01-FS10 + FS02b, FS11, FS11b, FS12-FS17 incl. seeded monkey FS14); +6 unit UT01-UT06 in `photoCleanup.test.js`. Suite 582/582 (557 + 25), recount with `cd functions && node --test`. `photoCleanup.js` 100/100/100; no uncovered line in the new `index.js` block.
6. Mutation check: 5 deliberate binding bugs, each failed the suite, binding restored.
7. Docs: AGENTS PH3b status, spec S-B DONE + deviations, test plan status + section 2.1, test-plans README row, SKILLS 103.
8. Pushed; PR opened against the S-A branch (see the PR link in the chat / `gh` list).

## Decisions made without asking (flag in PR for Taher)
- `timestampToMs` lives in the S-A lib file (testable, 100% covered) rather than inline in `index.js`.
- `park` does not also `console.error`: `runCleanupSweep` already logs the ERROR `PH3B_ALERT marker-parked`; a second line would double the alert.
- Logging via `firebase-functions/logger.write({severity, message, ...})` so `message` is `jsonPayload.message`. UNVERIFIED on real Cloud Logging (DV-1 / DV-9 prove it).
- Harness: one shared document store for the three databases, scans scoped by `mockState.docDb` (default `"test"`).
- Branch name `feat/2026-10-05-ph3b-sweeper-binding` (the name planned in the S-A checkpoint).

## NOT verified
Real `onSchedule` deploy, Cloud Scheduler API/location, cursor-without-orderBy on the real Admin SDK, no-index claim (DV-1), structured-log field names in Cloud Logging, emulator e2e (S-C). Nothing is deployed.

## NEXT
1. Taher reviews + merges #126 (S-A) then this S-B PR (re-target base to `main` after #126 merges).
2. **S-C** (`feat/2026-10-05-ph3b-sweeper-e2e-docs`): `test/e2e/cleanupSweep.e2e.test.js` E1-E5 + add to `.github/workflows/checks.yml` `node --test` list (needs `workflow` PAT scope, see learnings), AGENTS runbook line (replace "Until PH3b exists"), KNOWN-ISSUES limits, roadmap status. Expect one CI correction round (two Admin SDK versions, storage emulator host).
3. Taher: deploy ALL functions manually, accept Cloud Scheduler API prompt, record the deploy here, create the alert (runbook), run test plan section 4 (DV-1..DV-9).
4. After PH3b: PH4 client (403 terminal, `Qt.uuid()` photo ids, `deleteProduct` stops removing photos, Q13 toast), then BC2 client, PH5.
