# CHECKPOINT — photos workstream: pending items, DESIGN-ONLY session (2026-09-30)

**Branch:** `docs/2026-09-30-photos-pending-design` (off `main` @ `0d77f9a`). **Commit identity:** `tsadmin@gmail.com`.
**Skills invoked:** brainstorming, qt-qml, qt-ui-design, ponytail; caveman FULL (chat only).
**Rules:** branch only; push without asking (PAT only in the push URL, never in `.git/config` or repo); no build/run; no Qt tooling in sandbox (CI is the QML signal); design only this session, NO code; honest advisor, grill before each decision; one question per chat turn.
**Predecessor checkpoint:** `2026-09-29-pr84-photo-followups-CHECKPOINT.md` (S1/S2 done via PR #99; S3/S4 were its NEXT list).
**Not this workstream:** root `CHECKPOINT.md` (delete-roadmap item 1, stuck-writes S2b). Do not touch it.

## Step log

1. Read brainstorming, qt-qml, qt-ui-design, ponytail SKILL.md.
2. Cloned repo, set identity. Read root `CHECKPOINT.md`, photo design spec, photo test plan (final-sweep table F1-F5), PR #84 follow-ups checkpoint, PR #99 sweep 1 + 2 checkpoints, `DELETE-FEATURE-ROADMAP.md` item 4.
3. **Verified against code on `main`** (not just docs): F3, F5, N1, N2 (role IS on `ctx`), P2 (see evidence below). Found one item no doc lists: no server-side cascade on product delete (see C1).
4. GitHub REST API returned an abuse-detection rate limit on an unauthenticated call: open PR list NOT fetched. Open-PR state unknown to this session; `git branch -r` shows no photo branch besides the merged `feature/2026-09-21-product-photos-firebase-storage`.
5. This file written, pushed.

## Pending inventory (evidence = read in code this session)

| ID | Item | Evidence | Layer | My advice |
|---|---|---|---|---|
| F3 | `uploadProductPhoto` writes both Storage objects before the 404 (product missing) / 409 (cap) checks inside the transaction | `functions/index.js` ~L1052-1096: `bucket.file().save()` x2, then `runTransaction` returns 404/409 | server | fix, option (a) read-first |
| F5 | `applyMutation` deep-equals the WHOLE doc incl. `photoIds` against client `before`; a photo confirmed between edit and drain 409s an unrelated edit | `functions/lib/gatewayLogic.js` ~L158 `_deepEqual(current, params.before)` | server | fix, option (a) server ignores+preserves `photoIds` |
| N2 | No role check on `uploadProductPhoto` / `deleteProductPhoto` (viewer can upload/delete) | role already on `ctx` (`deriveContext`, L102); `recordMutation` already has a role check pattern L154-159 | server | decide with F3 (same files) |
| C1 | **New.** No server-side cascade when a product is deleted. Photo cleanup is client-only (`InventoryStore.deleteProduct` calls `removeProductPhoto` per `photoIds`). Offline/killed app/in-flight upload at delete time = permanent Storage orphans | grep of `functions/` shows no photo handling in the delete path | server | decide; this is DELETE-ROADMAP item 4's real content |
| N1 | Client photo id `photo-<Date.now()>-<rand 0..999999>` on a PUBLIC-READ path; server accepts any id without `/` or `..` | `StorageService._nextPhotoId`; `photoValidation.isSafePathSegment` | client+server | decide (uuid vs server-minted) |
| P2 | `InventoryStore.setPhoto` dead code | only hit: its own definition + comments, no callers in qml/tests | client | delete (ponytail) |
| N3 | Duplicate Skill 75/76 headings in `SKILLS.md` | per predecessor checkpoint | docs | renumber, check cross-refs |
| P1 | Delete `FailedTileGeometry.js` (~-300 lines) | predecessor advised NO | client | advise no; owner call |
| D1 | F1 recovery does not count an attempt: a photo that kills the process every time is never capped | PR #99 sweep 2 | client | keep until a real crash loop is seen |
| L1 | Breaker open + eligible item re-arms a 250 ms timer for the whole cooldown (60-600 s) | PR #99 sweep 2 | client | low; fold into any PhotoQueue touch |
| OC | No disk cache for photos synced from another device (blank offline) | design spec "Known limits" | C++ | not now (YAGNI) |
| DV | On-device verification gap: server cleanup + Storage never confirmed on a real Storage plan | roadmap item 4 | device | test plan item, not code |

## Decision ledger (all OPEN at time of writing; updated below as Taher answers)

| # | Question | Options | Status |
|---|---|---|---|
| Q1 | F3: how to stop orphans on 404/409 | (a) read product+count first; (b) write then delete on failure; (c) accept | OPEN |

## NEXT (resume here)

Continue the decision ledger top to bottom, one question per turn. When all are answered: write the design doc
`docs/superpowers/specs/2026-09-30-photos-s3-s4-design.md`, test plan from `docs/superpowers/test-plans/README.md` template, then mark the slices ready for an implementation session.
