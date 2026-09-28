# CHECKPOINT — 2026-09-28: DELETE-FEATURE-ROADMAP next-item pick — item 1 remainder (stuck-write Retry/Discard + server error classification) — DECISIONS MADE, docs phase complete, no code yet

**Session date:** 2026-09-28
**Branch:** `docs/2026-09-28-gateway-stuck-write-retry-discard-options`, off `main` @ `e83cc6b` (PR #88 merged).
**Previous checkpoint archived to:** `docs/superpowers/specs/2026-09-26-sales-analysis-deleted-product-labels-CHECKPOINT.md`
**Skills invoked by Taher:** `qt-development-skills:qt-qml`, `qt-development-skills:qt-ui-design`, `superpowers:brainstorming`, `ponytail:ponytail`, caveman FULL (chat replies only).
**Commit identity:** `Taher (via Claude session) <dextran52@gmail.com>`.

## Standing instructions from Taher (unchanged)

- Branch only, never `main`; push without asking (Taher reviews in the PR). PAT only for `git push` / PR API, never written to the repo.
- No build/run of the app, no Qt tooling in sandbox; CI is the only QML signal.
- Every code change: tests toward 100% + test plan from template + `SKILLS.md`/`AGENTS.md`/`README.md` as needed.
- Honest advisor: trade-offs, grill before deciding, do not just agree.
- Small scope per session (token budget); leave a resumable remote branch.

## Step log

1. Read project notes. Cloned repo. `main` head = PR #88 merge; items 2 and 3 confirmed RESOLVED in roadmap.
2. Read `DELETE-FEATURE-ROADMAP.md`. Status of each item:
   - Item 1 (HIGH): **PARTIAL.** PR #75 shipped surface-only (toast + header caption). Open: (B) park + Retry/Discard, (C) server error classification.
   - Item 2: RESOLVED (PR #80 + 2026-09-25 tombstone follow-up).
   - Item 3: RESOLVED (PR #88, merged).
   - Item 4: **Blocked, not a code task.** Photo cleanup on delete needs an active Storage plan + on-device check. Only Taher can unblock. Unmerged branch `feature/2026-09-21-product-photos-firebase-storage` exists — status unknown to this session.
3. Picked item 1 remainder as the next pending, most important item. Not archived (roadmap still has pending work).
4. Traced code (read-only): `Gateway._send/_sendBatch/_sendDelta/_sendOperation`, `OutboxStore.markFailed`, `qml/helper/StuckWrites.js`, `functions/index.js` `recordMutation` catch, store rollback hooks.
5. Wrote options + questions doc: `docs/superpowers/specs/2026-09-28-gateway-stuck-write-retry-discard-options.md`.
6. Roadmap item 1 got a dated status line pointing at the options doc.
7. Committed, pushed, opened draft PR #92 (docs only).
8. Taher answered Q1-Q5. Recorded decisions in options doc, this file, roadmap, memory. Marked PR #92 ready and merged it (Taher asked).

## Findings that shape the decision

- Server (`functions/index.js`): every `applyMutation` / batch / delta exception -> `500 write-failed`. Poison write and transient blip look identical to the client. Five `write-failed` sites in `functions/index.js` (`recordMutation`, the delta handler, one more single-write endpoint, `recordMutationsBatch`, and the operation endpoint).
- Client today: 5 server-side failures (~3 min) -> "stuck" -> toast + caption. Retry/backoff/drop unchanged; stuck state is in memory (resets on relaunch).
- Discard needs a rollback story per store. Hooks that exist today: `mutationConflicted` handled in 5 stores (Supplier, Orders, StockBatch, Staff, Inventory); `batchMutationFailedPermanently` handled in 3 (Supplier, Orders, Inventory). Party / Category / OrderChannel and the operation sender have **no** rollback hook.
- Consequence: counter-only "stuck" (heuristic) is unsafe to hang a Discard button on — a 3-minute outage would offer to destroy valid writes. That is the argument for classifying on the server first.

## Decisions (Taher, 2026-09-28) — also in the options doc

| # | Question | Answer |
|---|---|---|
| Q1 | Sequence | C first (server classification, client never drops); B later |
| Q2 | Discard | Re-pull from Firestore |
| Q3 | Parked flag | Persisted, survives relaunch |
| Q4 | UI | Tappable header caption -> dialog |
| Q5 | Item 4 | Storage plan active; photos branch works, merges in a couple of days; queue item 4 as next priority (on-device check) |

## NEXT SESSION — start here

1. Fresh clone, new branch off `main`, e.g. `fix/2026-09-29-gateway-write-error-classification`.
2. Scope = "If Option 1 is chosen" sketch in the options doc: pure `classifyWriteError(e)` in `functions/lib/`, wire the five `write-failed` catch sites in `functions/index.js`, Node tests (real `npm test` works in sandbox: `cd functions && npm ci && npm test`, baseline 251 passing), client reads new statuses in `Gateway.qml` / `StuckWrites.js` with a `terminal` flag, `GlassHeader` caption text by flag.
3. Client must still never drop a write in this PR.
4. Needs `superpowers:writing-plans` first (brainstorming terminal state), then implement, test plan (Skill 49 template), `SKILLS.md`, `KNOWN-ISSUES.md`, roadmap status.
5. Then B. Then item 4 when the photos branch has merged.

## Not done

- No code, no tests, no test plan, no `SKILLS.md`/`AGENTS.md`/`README.md` change: docs-only PR, nothing to test. Test plan follows the implementation PR.
- Nothing built or run.
