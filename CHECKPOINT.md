# CHECKPOINT — 2026-09-29: PR #84 final-sweep review + docs trim (no app code changed)

**Branch:** `docs/2026-09-29-pr84-final-sweep-docs-trim`, off PR #84 head `6e18011`. Target PR base: `feature/2026-09-21-product-photos-firebase-storage`.
**Commit identity:** `tsadmin@gmail.com`. **Skills used:** requesting-code-review, qt-qml-review (lint filtered to PR-added lines), ponytail-review.
**Standing rules:** branch only, push without asking (owner reviews in PR); PAT only for `git push`/API, never written to the repo; no build/run, no Qt tooling (CI is the only QML signal); small scope per session; be an honest advisor, trade-offs before decisions.
**History:** the per-round PR #84 checkpoints that used to fill this file (824 lines) are in git history at `6e18011:CHECKPOINT.md`.

## Steps done
1. Cloned repo, fetched `refs/pull/84/head`. 59 files, +7096/-248, 44 commits. CI on head SHA all green (the 1643-test bot comment is from 09-24 and stale).
2. Ran qml lint on PR-added lines: 112 hits, mostly the repo's `var`/`==` convention. Real ones are in the findings below.
3. Read all new QML, PhotoQueue logic, functions handlers, rules, C++ additions, store diffs.
4. Docs trim: 4 addendum test plans folded into `test-plans/2026-09-21-product-photos-firebase-storage-test-plan.md` (now: root-cause table, gaps F1-F5, one current on-device checklist); README index updated; executed 779-line implementation plan deleted and its 4 references repointed; this file compacted.

## Verdict: do NOT merge yet — fix F1 and F2 first (small, both need tests)
| # | Sev | Finding |
|---|---|---|
| F1 | Must | `PhotoQueue._upload` persists `state:"uploading"`; `_load()` does not reset it and `drainCandidates`/`_reschedule` only take `enqueued`/`retrying`. App killed or OS-suspended mid-upload => spinner forever, no Retry/Discard, counts toward the 10 limit. |
| F2 | Must | `InventoryStore.deleteProduct` never purges that product's queued/failed photos. They upload after the delete lands, get 404 (terminal), sit in the queue forever with no UI to discard; local files never removed. |
| F3 | Should | `uploadProductPhoto` saves both Storage objects before the product-exists / 10-photo checks; 404/409 leave orphaned objects. Pre-read the product, or delete on those outcomes. |
| F4 | Should | `_upload` idToken-empty branch returns without re-arming the drain. |
| F5 | Should | Full-doc inventory `update` mutations carry `before.photoIds`; a photo confirmed between edit and drain makes the edit 409. Server should ignore/preserve `photoIds` in the `before` comparison. |
| N1 | Note | `photoId` is `Date.now()` + 6 digits, but `storage.rules` comment calls it "random" and reads are public. Use `Qt.uuid()` (strip braces). Also `abc_t` vs thumb of `abc` can collide; a uuid removes it. |
| N2 | Note | No role check on photo endpoints (same known gap as `recordMutation`, KNOWN-ISSUES.md). Legacy sync clears `photoUrl` at queue time; Discard after terminal failure then loses the photo. |
| N3 | Note | Touch targets: cover-remove x is 20dp, Retry 36dp, Discard 28dp. `SKILLS.md` has two "Skill 75" and two "Skill 76" headings. |
| P1 | Ponytail | `FailedTileGeometry.js` (78) + test (209) + spec (65): contrast calculators exist only for tests; scaling for tile sizes that never occur (tile is fixed 72dp). Anchors in `FailedTileOverlay` replace it: about -300 lines. |
| P2 | Ponytail | `InventoryStore.setPhoto` (dead, kept "not this task's job"), `clearPhotoSource` path, `EnvConfig.storagePrefixForEnv` + server twin duplicate an env map already mirrored in `PhotoUrl.js`. |

## NEXT SESSION — start here
1. Fresh clone, branch off `feature/2026-09-21-product-photos-firebase-storage` (or off this branch once merged into it).
2. Fix F1 (reset `uploading` -> `enqueued` in `_load()` before `_reschedule()`), F2 (discard queued items in `deleteProduct`), with the tests named in the test plan's F1-F5 table. F3-F5 only if the owner agrees (grill the trade-offs first).
3. Update test plan + SKILLS.md; wait for CI (do not run Qt locally).

## Other open work (main's own handoff was overwritten by PR #84's checkpoint)
- Gateway write-error classification (roadmap item 1): decisions Q1-Q5 in `docs/superpowers/specs/2026-09-28-gateway-stuck-write-retry-discard-options.md`; branch `fix/2026-09-28-gateway-write-error-classification` already exists remotely.
- Roadmap item 4 (photo cleanup on product delete) depends on this PR merging.

## Not done
No app code, no rules/functions change, no build or run.
