# CHECKPOINT — roadmap check-in + item 1 (batch-id mint) analysis presented

**Session date:** 2026-09-01
**Branch:** `docs/2026-09-01-roadmap-triage-and-item1-analysis` (off `main` @ `50874b5`, post-PR#49-merge)
**Previous checkpoint archived to:** `docs/superpowers/specs/2026-09-01-pr49-landing-CHECKPOINT.md`
(its own arc — landing PR #49 — closed; confirmed merged via GitHub API,
`merged_at: 2026-09-01T03:06:26Z`).

## What this session is

Fresh clone, read `CHECKPOINT.md` and `docs/superpowers/E2E-TESTING-ROADMAP.md` live. Instructed to
confirm PR #49's resolution and pick up the next roadmap item; if it's gated on Taher's input,
analyze and present rather than guess.

## PR #49 — checked, not blindly "removed" as asked

Taher's instruction was "remove that item from roadmap if still there." Checked first: the roadmap's
PR #49 entry is not a stale blocking item — it already lived under "Coordination / process (not
code)" correctly marked `resolved, 2026-09-01`, consistent with how every other closed item in this
doc stays documented under "Resolved this arc" for context (the doc is explicit about being a living
record, not just a todo list). Deleting it would have thrown away accurate history for no reason.
What it actually needed: one stale sentence ("PR #49 itself now mergeable; Taher to review/merge via
GitHub") corrected to reflect that it's now actually merged, not just mergeable — fixed, with the
GitHub API's `merged_at` timestamp as the citation. Flagging this rather than silently doing what was
asked, since what was asked didn't match what the doc actually needed.

## Roadmap item picked up: item 1 (silent batch-id-mint swallow) — status check, not new work

All three open roadmap items are explicitly gated on Taher's input (roadmap's own framing, unchanged
this session). Per the 2026-08-30 triage session (on the never-merged, now-superseded
`docs/2026-08-30-roadmap-next-item-triage` branch), Taher had already picked item 1 and chosen to run
its on-device N3 test himself rather than have a synthetic stopgap built. No result has come back yet
as of this session.

**Re-verified the analysis directly against current code rather than trusting that branch's
carried-forward claims** (it predates the PR #49 merge, so treated as informative, not authoritative):

- Confirmed and corrected a documentation error the abandoned branch had already found but never
  landed on `main`: the roadmap's "five of six" call-site claim (and the entry title's separate,
  also-wrong "3 of 4") didn't match `DataModel.qml`/`StockBatchStore.qml`. Actual, grep-verified
  counts — `InventoryStore.qml:490` (addProduct) and `:1008` (restock) both call
  `StockBatchStore.addBatch()` with no callback (2 of 2 unprotected); `DataModel.qml` calls
  `topUpOldest()` at 6 sites, 3 with a callback (`:538,:626,:1031`) and 3 without (`:689,:971,:1097`).
- New finding, verified by reading `topUpOldest()` (`StockBatchStore.qml:418-460`) directly:
  its callback fires unconditionally regardless of `result.ok` — contrast `addBatch()`, which
  correctly passes `callback(null)` on failure vs. `callback(doc)` on success. So the 3 `topUpOldest`
  call sites that DO pass a callback still get no error signal. This is the detail that widens the
  fix's scope past "add missing callbacks" — the callback *contract* needs the fix first.
- Both corrections written into `docs/superpowers/E2E-TESTING-ROADMAP.md` in place.

**orderMath.js parity (item 2), re-verified same way**: source parity confirmed still holding; real
gap is `lineTax()`/`refundPerUnit()` having zero Node-side test coverage (confirmed via `grep` across
`functions/test/` — neither name appears). This scoping was also done on the abandoned branch and
never landed on `main` — brought forward and written into the roadmap entry.

**Full corrected analysis, the N3 status, and item 2/3's current state presented to Taher in-chat
this turn** — this file is for resumability, not a substitute for that conversation.

### Done
- [x] Fresh clone, branch created off current `main` (post-PR#49-merge)
- [x] Read `CHECKPOINT.md`, `docs/superpowers/E2E-TESTING-ROADMAP.md` live
- [x] Verified PR #49's merge status via GitHub API rather than trusting the doc or the instruction
      at face value
- [x] Corrected the PR #49 entry's one stale sentence (mergeable → actually merged)
- [x] Re-verified item 1's call-site counts directly against `DataModel.qml`/`StockBatchStore.qml`
      via `grep` + direct reads — corrected the roadmap's two inconsistent, wrong counts
- [x] Found and documented `topUpOldest()`'s missing error channel in its callback contract (new
      finding this session, via direct code read)
- [x] Re-verified and landed item 2's (orderMath.js) scoping, previously done but never merged
- [x] Added a 2026-09-01 check-in note on item 1's N3 status (still awaiting Taher's on-device result)
- [x] Archived the completed PR#49-landing `CHECKPOINT.md` to `docs/superpowers/specs/`
- [x] This file
- [x] Committed and pushed (PAT used transiently in push URL only)

### Explicitly not touched, and why
- No production code changed — this session is doc-only (roadmap corrections + this checkpoint),
  consistent with all three roadmap items being gated on Taher's input and brainstorming's hard
  gate (no implementation before an approved design).
- The abandoned `docs/2026-08-30-roadmap-next-item-triage` branch left as-is on the remote (not
  deleted, not merged as-is — it's behind current `main` by the PR #49 merge, so merging it directly
  would have reverted `functions/lib/httpResponse.js`). Its useful, still-accurate content was
  independently re-verified and re-applied fresh on this branch instead. Flagging it here so a
  future session doesn't act on that branch directly.
- Item 1's fix shape untouched — still needs Taher's N3 result before a shape decision is even
  well-founded (surface error / retry-on-sync / narrower fix — see roadmap entry).
- Item 3 (`loadingMore` guard) — no code or doc changes; Skill 39 already documents the `_resetPending`
  fix design in full, nothing new to verify or add. Still purely Taher's rarity-vs-complexity call.

## Next action if resumed

Waiting on Taher's response to what was presented this turn: either his N3 result (unblocks item 1's
fix-shape decision), a decision to prioritize item 2 or item 3 instead, or some combination. Don't
guess which — check chat history for his actual reply before proceeding to design work on anything.
