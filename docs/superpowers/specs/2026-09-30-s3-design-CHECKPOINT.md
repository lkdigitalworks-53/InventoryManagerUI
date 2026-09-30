# CHECKPOINT — 2026-09-30: DELETE-FEATURE-ROADMAP item 1 part B — S3 (Discard + resync) DESIGN, decisions open

**Branch:** `design/2026-09-30-s3-discard-resync`, stacked on PR #106 (`feat/2026-09-30-s2b-park-terminal-writes`, CI all green at `35c899e`). Docs only, no code.
**Previous checkpoint archived to:** `docs/superpowers/specs/2026-09-30-s2b-CHECKPOINT.md`.
**Skills invoked by Taher:** brainstorming, qt-qml, qt-ui-design, ponytail; caveman FULL (chat replies only).
**Commit identity:** `Taher (via Claude session) <lkdigitalworks@gmail.com>` (per Taher's instruction this session).

## Standing instructions (unchanged)
Branch only, push without asking (PAT only in the push URL, never in `.git/config`), no build/run, no Qt tooling in the sandbox (CI is the QML signal), tests toward 100% + test plan + SKILLS/AGENTS/README, honest advisor (grill before deciding), small scope per session (tokens run out, other accounts resume from the remote branch).

## Step log
1. Read memory, skills, cloned repo (PAT stripped from remote), PR #106 = S2b, open, clean, CI green.
2. Traced Gateway (`_noteFailure`, `retryStuck`, `_pruneStuck`, `_reschedule`, `_finishOperation`), OutboxStore (`enqueue` coalesce, `markSent`, `retryNow`), StuckWrites, DescribeItem, StuckWritesSheet, DataModel wiring, stores' `syncFromFirebase`/`_resetPending`, ConfirmDialog, Main back-button list, PhotoQueue.
3. Wrote design `docs/superpowers/specs/2026-09-30-s3-discard-resync-design.md`: D1-D6 proposed, Q-S3-1..5 OPEN. Findings: merged edits die with Discard; `removed_staff` tombstone merge means resync does not fully revert it; `recordOperation` has no production caller yet; no verified way to force a real `write-rejected` on device.
4. Roadmap + plan status lines updated. Pushed, PR stacked on #106.

## NEXT SESSION — start here
1. Get Taher's answers to Q-S3-1..5 (defaults if he says "your call": all A). Brainstorming gate stays closed until then.
2. Implement S3 in ONE PR on a new branch stacked on this one (or on #106 if merged): `StuckWrites.entitiesOf`, `Gateway.discardParked` + `parkedWriteDiscarded`, `DataModel` handler, sheet Discard + confirm, tests, test plan (Skill 49 template), SKILLS/AGENTS/README, CHECKPOINT.
3. Merge order: #106 -> this design PR -> S3 code PR. S2b must not reach `main` without S3.
4. Flag to Taher at implementation: no on-device recipe for a real `write-rejected` yet.
