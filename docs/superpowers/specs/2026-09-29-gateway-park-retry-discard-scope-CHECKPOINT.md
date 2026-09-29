# CHECKPOINT — 2026-09-29: DELETE-FEATURE-ROADMAP item 1 part B — SCOPE PLANNED (docs only), P1-P3 DECIDED

**Session date:** 2026-09-29
**Branch:** `docs/2026-09-29-delete-roadmap-next-item-options`, off `main` @ `88eeb68` (PR #93 merged, photos PR #84 merged).
**Previous checkpoint archived to:** `docs/superpowers/specs/2026-09-28-gateway-write-error-classification-CHECKPOINT.md`
**Skills invoked by Taher:** `superpowers:brainstorming`, `qt-development-skills:qt-qml`, `ponytail:ponytail`, caveman FULL (chat replies only).
**Commit identity:** `Taher (via Claude session) <dextran52@gmail.com>`.

## Standing instructions (unchanged)

Branch only, push without asking, PAT never written to the repo, no build/run, no Qt tooling in sandbox (CI is the QML signal), tests toward 100% + test plan + SKILLS/AGENTS/README, honest advisor who grills before deciding, small scope per session.

## Step log

1. Read notes, cloned repo, read roadmap + previous checkpoint. Roadmap left: item 1 part B, item 4.
2. Taher: photos scope (item 4) is handled separately, focus on B, plan only this session so the next session implements sequentially.
3. Traced B: `OutboxStore`, `StuckWrites.js`, `Gateway` senders, store hooks, `syncFromFirebase`, `GlassHeader`.
4. Findings: Party / Category / OrderChannel do not use `Gateway` (dropped from B); `syncFromFirebase()` full resync is a usable Discard re-pull for all 6 gated stores and handles create/update/delete uniformly.
5. Wrote `docs/superpowers/specs/2026-09-29-gateway-park-retry-discard-plan.md`: design, 4 slices S1-S4, tests per slice, edge cases, open decisions P1-P4. Roadmap status updated. Pushed.
6. Taher answered P1-P3 (all recommended options). Decisions table added to the plan doc, checkpoint updated, pushed. **No code changed.**

## NEXT SESSION — start here

1. P1-P3 are decided (terminal-only park, full-store resync via one DataModel handler, merge-and-stay-parked); see the plan doc's Decisions table. P4 not asked, default = S1 dialog/Retry-now first.
2. Start **S1 only** on a new branch off `main`: tappable `GlassHeader` caption -> dialog listing stuck writes with Retry-now; `describeItem.js`; tests + test plan. No persistence, no Discard.
3. Do not combine slices. S2 (park + persist) only after S1 merges. S3 (Discard) last.

## Not done

Nothing built or run. No SKILLS/AGENTS/README change (nothing implemented). Server untouched, so no Node tests planned for B.

## Parallel workstream: photo follow-ups (from PR #84 review)

Separate checkpoint, does not touch the roadmap-B work above: `docs/superpowers/specs/2026-09-29-pr84-photo-followups-CHECKPOINT.md`.
