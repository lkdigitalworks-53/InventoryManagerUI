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
