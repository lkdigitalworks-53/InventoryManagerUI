# PR #99 sweep 2: checkpoint (2026-09-30, second review pass, different account)

Commit identity: `lkdwtaher@gmail.com`. Branch: `review/2026-09-30-pr99-sweep2`, stacked on PR #99 head `1cb9d77` (which already contains the sweep-1 fixes R1..R5 from #101).
Skills run: superpowers:requesting-code-review, ponytail:ponytail-review, qt-development-skills:qt-qml-review (manual, no subagent tool in chat: lint script + six-domain read).
Rules: branch only; push with PAT held only in the push URL, never in git config; no build/run; no Qt tooling here (CI is the QML signal).

- [x] 1 Clone, review branch, identity set, PAT never written to `.git/config`
- [x] 2 PR #99 metadata (10 files, +379/-15, mergeable clean); CI on `1cb9d77`: 5/5 green (QML, Functions, Rules, E2E, summary)
- [x] 3 Read full diff, `PhotoQueue.qml`, `deleteProduct`, `AuthStore` (`loadSession`, `applyAuth`), `AuthService.ensureFreshToken`, `PhotoQueueLogic.js`, server dedupe branch, `Main.qml` photo signal handlers, `InventoryStore.applyPhotoIds`
- [x] 4 qt_qml_lint.py on PR-added lines: 0 real findings (4 JS-2 hits are `!==` false positives; JS-1 `var` is repo-wide style)
- [x] 5 Added 4 tests to `tst_PhotoQueue.qml` for token-watcher edges (breaker open, failed untouched on hourly refresh, backoff respected, deterministic monkey)
- [x] 6 Docs: test plan section "PR #99 sweep 2" + device checklist, cascade count 7 -> 8 and F4 count 5 -> 9 in the followups checkpoint; no new SKILL (no new lesson beyond Skill 85/86)
- [x] 7 Committed f2cd84f, pushed, stacked PR opened into the PR #99 branch (CI result below)

## Verified NOT bugs (traced, do not re-investigate)
- Cold-start identity race (`loadSession` sets `idToken` before `tenantId`): `_tokenWatcher` binds after `AuthService` construction has already run `loadSession`, so no change signal fires mid-load. Sign-in paths have an empty queue (`clear()` on sign-out).
- 401 with a stale token is `transient` in `PhotoQueueLogic` (only 400/404/409/413 are terminal): an early drain with an expired token retries, never parks the photo.
- Late upload confirmation for a deleted product: `applyPhotoIds` returns early on unknown id; `_replaceItem` cannot resurrect a discarded item.
- F1 dedupe path: server returns current `photoIds` on `already: true`, so a recovered item does not blank the local cache.

## Open findings (decision or follow-up, not changed in this PR)
- D1 (decision): F1 recovery does not count an attempt. A photo that kills the process mid-upload every time is never capped (the module's own stated goal is bounded retry). Option A keep (current, no budget burned by ordinary OS kills). Option B count it through `reduceQueueItem(failed, 0)` (bounded, but 8 force-closes park a healthy photo behind Retry). Advice: keep A until a real crash loop is seen; revisit if `readFileBase64` OOM is ever reproduced.
- L1 (pre-existing, low): breaker open + eligible item => `drainNow` calls `_reschedule()` which arms a 250 ms timer, so it re-fires at 4 Hz for the whole cooldown (60 s up to 600 s). Fix: floor the timer at `_breaker.cooldownUntil - now` while open. Not in this PR (scope).
- R5 remains device-only: `drainNow(true)` skipping the refresh cannot be observed headlessly (QML functions are read-only, `ensureFreshToken` no-ops unauthenticated).
- No e2e possible for F1/F2/F4: client-only, `NativeFile`/`ImageProcessor` do not exist under qmltestrunner (file header of `tst_ProductPhotosE2E.qml`). Device test plan is the proof.
