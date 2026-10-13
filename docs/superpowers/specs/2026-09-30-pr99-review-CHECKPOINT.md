# PR #99 full-sweep review: checkpoint (2026-09-30)

Skills run: superpowers:requesting-code-review, ponytail:ponytail-review, qt-development-skills:qt-qml-review.
Branch: `review/2026-09-30-pr99-full-sweep`, stacked on `fix/2026-09-29-pr84-photo-queue-followups` (PR #99 head `8824f66`).

- [x] 1 Clone, branch, identity `taher.lkdw@gmail.com`, PAT stripped from `.git/config`
- [x] 2 Read PR metadata (9 files, +289/-13), CI on `8824f66` all green (5/5)
- [x] 3 Read full `PhotoQueue.qml`, `deleteProduct`, `AuthStore.applyAuth`, `AuthService.refreshIdToken`, server dedupe (`functions/index.js` audit_log/requestId)
- [x] 4 qt_qml_lint.py on changed files: no findings on PR-added lines (remaining hits are pre-existing)
- [x] 5 Fix R1..R5 (see test plan "PR #99 review additions"); docs renumbered Skill 82 -> 85 (main already has 82-84); Skill 86 added
- [x] 6 Push, open stacked PR into PR #99 branch (merged as #101, CI green on 1cb9d77)
- [x] 7 CI was green, nothing to fix (continued in 2026-09-30-pr99-sweep2-CHECKPOINT.md)

Open / not fixed (deliberate): cold-start race (`loadSession` sets `idToken` before `tenantId`, watcher drain skips on identity gate; covered by the `_load()` timer); in-flight upload at delete time can orphan Storage objects (server item 4); F3/F5 server work.
