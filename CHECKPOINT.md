# CHECKPOINT — 2026-09-30: DELETE-FEATURE-ROADMAP item 1 part B — S2b (park terminal writes), BRAINSTORM GATE OPEN, NO CODE YET

**Branch:** `feat/2026-09-30-s2b-park-terminal-writes` (off `main` @ `0d77f9a`, which already contains S1 + S2a via PR #97).
**Previous checkpoint archived to:** `docs/superpowers/specs/2026-09-30-s1-s2a-merged-CHECKPOINT.md`.
**Skills invoked:** brainstorming, qt-qml, qt-ui-design, ponytail; caveman FULL (chat replies only).
**Commit identity:** `Taher <dextran52@gmail.com>` (this claude.ai account's email, per this session's prompt; earlier sessions used other addresses, one per account).

## Standing instructions (unchanged)
Branch only, push without asking (PAT only in the push header, never in `.git/config`/repo), no build/run, no Qt tooling in sandbox (CI is the QML signal), tests toward 100% + test plan (Skill 49 template) + SKILLS/AGENTS/README as needed, honest advisor who grills before deciding, small scope per session so another account can resume from the remote branch.

## Step log
1. Read memory (staff-delete-ui, stuck-write-retry-discard, ways-of-working, overview, engineering-lessons) + plan `2026-09-29-gateway-park-retry-discard-plan.md` + archived checkpoint. "s2b slice" = plan slice **S2b: park terminal writes** (S2a persistence already merged).
2. Cloned repo, branched. Read the four skills, `StuckWrites.js`, `OutboxStore.qml` (`dueItems`, `nextDueInMs`, `markFailed`, `setStuckMeta`, `wakeStuck`, `retryNow`), `Gateway.qml` (`_noteFailure`, `resumeStuck`, `retryStuck`, `_pruneStuck`, `drainNow`).

## Code facts traced (2026-09-30, nothing run)
- `StuckWrites.noteFailure` returns true only when the count **equals** THRESHOLD (5). After that it keeps counting; `terminal` is refreshed on every counted failure.
- `terminal` is set ONLY by the body string `write-rejected` (HTTP 500). A 403 `no-tenant-context` (suspended member) or 404 never sets it, so those never park (P1).
- `OutboxStore.dueItems()` and `nextDueInMs()` know nothing about a parked flag; a parked item would keep the drain timer spinning and keep re-sending.
- `OutboxStore.wakeStuck()` (S2a, at launch) makes every `stuck` item due; it must NOT wake a parked item.
- `dueItems()` uses a per-pass `claimed` key map; `_isItemBlocked` only looks at in-flight keys. A parked item that is merely skipped would let a later same-key sibling (queued while the first was in flight) send ahead of it.
- `retryNow()` resets `attempts` and `nextAttemptAt` only; it keeps `stuck` (S1 deviation D1).
- `enqueue()` coalesces into any not-in-flight item for the key, so a parked item absorbs later edits (P3, no new code).

## Open design questions (asked in chat, unanswered at time of writing)
- **Q-S2b-1 park rule:** (A) park whenever the write is stuck AND the latest answer is `write-rejected` (state rule; a write that failed transiently then got rejected also parks; Retry that is rejected again re-parks after 1 attempt) vs (B) plan text: park only on the failure that tips over THRESHOLD and only if that answer is rejected (edge rule; Retry re-parks after 5 more attempts; a write rejected only after the tip never parks).
- **Q-S2b-2 siblings:** (A) a parked item still blocks later same-key writes (they wait behind it, in order) vs (B) siblings pass a parked item.

## Defaults assumed unless Taher overrules (no question asked)
- `parked`, `parkedAt` on the outbox item; `OutboxStore.setParked/clearParked`; `dueItems`/`nextDueInMs`/`wakeStuck` skip parked; Retry (extend `retryStuck`) clears parked.
- Gateway gets `parkedCount`; header caption and dialog rows show a rejected/parked wording; Retry on a parked row; no Discard (S3).
- Server untouched, so no Node tests planned (say so in the test plan).

## Honest flags for Taher
- S2b alone gives a rejected write a Retry button that will be rejected again; the only real exit is S3 Discard. Not a regression (today it retries forever), but merge S2b into the S3 branch and ship them to `main` together (same pattern as #100 into #97).
- Parking stops the 3-minute hammer but the record's later edits pile up behind the parked item until Retry/Discard.

## NEXT SESSION — start here
1. Get Taher's answers to Q-S2b-1 / Q-S2b-2 (above). 2. Write `docs/superpowers/specs/2026-09-30-s2b-park-terminal-writes-design.md`. 3. Implement + tests (`tst_StuckWrites`, `tst_OutboxStore`, `tst_Gateway`) + test plan + docs. 4. Push, open PR, wait for CI.
