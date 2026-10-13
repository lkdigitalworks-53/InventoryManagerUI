# PR #97 final-sweep review: checkpoint (2026-09-30)

Skills run: superpowers:requesting-code-review, ponytail:ponytail-review, qt-development-skills:qt-qml-review.
Branch: `review/2026-09-30-pr97-final-sweep`, stacked on `feat/2026-09-29-stuck-writes-dialog-retry-now` (PR #97 head `06e9f8d`). Scope: S1 + S2a (22 files, +1881/-28). Commit identity `taher.lkdw@gmail.com`.

- [x] 1 Clone, branch, identity set, PAT stripped from `.git/config`
- [x] 2 PR metadata: open, `mergeable_state` clean, CI on `06e9f8d` 5/5 green (QML, Functions, Rules, E2E, PR comment)
- [x] 3 Read in full: `Gateway` diff, `OutboxStore` diff + enqueue/coalesce/markFailed/load paths, `StuckWrites.js`, `DescribeItem.js`, `StuckWritesSheet.qml`, `GlassHeader` tap, `Main.qml` wiring + back handler
- [x] 4 `qt_qml_lint.py` on changed lines only: no real finding (`var`, ORD-1, BND-1 = repo idiom; BND-2 `items = arr` = existing idiom). `qmllint` not run (no Qt, by instruction)
- [x] 5 Review method caveat: the chat has no subagent tool, so the six qt-qml-review agents and the code-reviewer subagent were done as ONE manual pass over the same categories
- [x] 6 Verified, not assumed: `_inFlightKeys` is reassigned (reactive), `OutboxStore` loads in `Component.onCompleted` (before `resumeStuck`), every `Constants.*` / `GhostButton` / `Toast` the sheet uses exists, `BottomSheet` hides the primary button on `""`, `_handleBack` covers the sheet, all 5 `_noteFailure` sites run after `markFailed`, test-count claims match (19 tests + 2 `_data` = 21 in `tst_DescribeItem`)
- [x] 7 Fixed R1, R2 (docs/comment only, no logic)

## Fixed

- R1 `AGENTS.md` StuckWrites entry cited Skill 86 (main's) for the S2a persistence; after the renumber it is Skill 88.
- R2 `Main.qml` `onTenantContextReady`: the "Flush ... queued offline" comment sat above the `resumeStuck` comment, away from `drainNow()`. Comments reordered. No code change.

## Not fixed (deliberate), with reason

- I-1 (conf 65) `Gateway._noteFailure` -> `resumeStuck()` -> `OutboxStore.wakeStuck()` runs after `markFailed`. If the first failure of a launch is on a persisted-stuck item AND lands before `Main.qml` calls `resumeStuck()`, the wake overwrites that item's fresh backoff: one extra immediate retry. Bounded (once per launch). Fix would be hydrating without waking from `_noteFailure`; cannot be tested without Qt. Verify on device: stuck write, force-close, relaunch, watch for a second send in the log.
- I-2 (conf 60) `StuckWritesSheet._rows` returns a new array each evaluation, so the `Repeater` rebuilds every delegate on each outbox revision. A failure landing mid-tap can eat the press or flicker. Verify on device with 3+ stuck rows.
- I-3 (conf 60) Header `MouseArea` margin -8dp equals `Constants.space2`, so it touches the leading (back) button's slot. Only while the stuck caption shows. Verify: tap the back button's right edge while the caption is visible.

## Ponytail (list only, nothing applied)

- `OutboxStore.qml` `setStuckMeta`: shrink. `JSON.stringify` of two whole items (a batch is up to 200 entries) on every failure; compare `failures`/`stuck`/`terminal` directly. Skipped: behaviour change with no Qt runner.
- `StuckWritesSheet.qml` `_stuckWatcher/_outboxWatcher/_inFlightWatcher` (+ `OutboxStore.inFlightCount`): yagni. The binding engine already tracks the reads inside `stuckRows()` (`items`, `_inFlightKeys`). Skipped: relies on QML tracking subtleties I cannot run, and a dead-binding bug would be silent. Keep until device-verified.
- net: about -12 lines possible, none applied.

## Verdict

No Critical or Important finding. Safe to merge #97. Merge as a MERGE COMMIT (not squash), as already decided, so S1 (`6b7a2cf`, `8c792f8`) and S2a (`6ca450d`) stay separately revertable.
