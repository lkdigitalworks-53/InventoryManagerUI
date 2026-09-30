# CHECKPOINT — 2026-09-30: DELETE-FEATURE-ROADMAP item 1 part B — S2b (park terminal writes), IMPLEMENTED, CI PENDING

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

## Decisions (Taher, 2026-09-30)
- Q-S2b-1 = **A** state rule: parked whenever stuck AND latest answer `write-rejected`; a rejected Retry re-parks after 1 attempt.
- Q-S2b-2 = **A**: a parked item holds its keys; later same-record writes wait behind it.
- Defaults I chose (overrulable in the PR): parked is DERIVED (`stuck && terminal`), no `parked`/`parkedAt` field; Retry clears `terminal`; reuse `stuckTerminalCount` as the parked count; copy updated (toast, caption, row, button). See design doc `docs/superpowers/specs/2026-09-30-s2b-park-terminal-writes-design.md` (D1-D7).

## Step log (continued)
3. Asked Q-S2b-1/2 via buttons; Taher answered A/A. Wrote design doc (D1-D7).
4. Code: `StuckWrites.isParkedItem/isParked/clearTerminal`; `OutboxStore` (`dueItems` claims parked keys, `nextDueInMs` ignores parked + what waits behind, `wakeStuck` skips parked, `retryNow` deletes `terminal`); `Gateway` (`_noteFailure` toast wording, `retryStuck` clears terminal); copy in `GlassHeader`, `StuckWritesSheet`.
5. Tests: 17 `tst_StuckWrites`, 25 `tst_OutboxStore`, 19 `tst_Gateway` new; 2 OutboxStore tests + 1 Gateway test updated for the new semantics (rejected stuck writes are no longer due). Node-ran `StuckWrites.js` logic: 37450 assertions OK. `tst_OutboxStore` / `tst_Gateway` NOT run (need Qt). Brace balance per edited file checked (Gateway test file has a pre-existing +9 from braces in strings).
6. Docs: design doc, test plan + index row, plan status, roadmap, SKILLS Skill 89, AGENTS, README. Commit identity `Taher <dextran52@gmail.com>`.

## Honest flags for Taher
- S2b alone gives a rejected write a Retry button that will be rejected again; the only real exit is S3 Discard. Merge S2b into the S3 branch and ship to `main` together (same pattern as #100 into #97).
- Everything else on a parked record queues behind it until Retry/Discard.
- No verified recipe yet to force a real `write-rejected` on device (403/404 setups are NOT rejections). The test plan says so; ask for a recipe before the on-device pass.
- Likely CI trouble spots: `tst_OutboxStore` operation-member test (`enqueueOperation` shape), `tst_Gateway` monkey (real singleton graph).

## NEXT SESSION — start here
1. Check CI on the S2b PR; fix failures from the real `results.xml`. 2. Taher on-device pass (test plan section 3). 3. Then **S3 only** (Discard + resync), new branch off this one or off `main` after merge; opens with the brainstorming gate.
