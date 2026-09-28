# CHECKPOINT — 2026-09-28: DELETE-FEATURE-ROADMAP next-item pick — item 1 remainder (stuck-write Retry/Discard + server error classification) — DECISIONS NEEDED, no code yet

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
7. Committed and pushed; opened draft PR (docs only).

## Findings that shape the decision

- Server (`functions/index.js`): every `applyMutation` / batch / delta exception -> `500 write-failed`. Poison write and transient blip look identical to the client. Five `write-failed` sites in `functions/index.js` (`recordMutation`, the delta handler, one more single-write endpoint, `recordMutationsBatch`, and the operation endpoint).
- Client today: 5 server-side failures (~3 min) -> "stuck" -> toast + caption. Retry/backoff/drop unchanged; stuck state is in memory (resets on relaunch).
- Discard needs a rollback story per store. Hooks that exist today: `mutationConflicted` handled in 5 stores (Supplier, Orders, StockBatch, Staff, Inventory); `batchMutationFailedPermanently` handled in 3 (Supplier, Orders, Inventory). Party / Category / OrderChannel and the operation sender have **no** rollback hook.
- Consequence: counter-only "stuck" (heuristic) is unsafe to hang a Discard button on — a 3-minute outage would offer to destroy valid writes. That is the argument for classifying on the server first.

## Open decisions for Taher (see options doc for trade-offs and my recommendation)

| # | Question |
|---|---|
| Q1 | Sequence: C (server classification, client still never drops) first, then B (Retry/Discard) in a later session? Or B only? Or both in one PR? |
| Q2 | Discard semantics: roll back local state to the item's `before`, or drop + re-pull from Firestore? |
| Q3 | Persist the "parked" flag in the outbox (survives relaunch) or keep it in memory? |
| Q4 | Where does Retry/Discard live: tap on the existing header caption -> simple dialog, or a new Sync Issues page? |
| Q5 | Item 4: is a Storage plan active now, and what is the state of the photos branch? |

## Not done

- No code, no tests, no test plan, no `SKILLS.md`/`AGENTS.md`/`README.md` change: docs-only PR, nothing to test. Test plan follows the implementation PR.
- Nothing built or run.
