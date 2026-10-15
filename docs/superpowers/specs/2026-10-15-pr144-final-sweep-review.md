# Final-sweep review — PR #144 (Task 11 "Saved. Syncing…"), 2026-10-15

Skills run: requesting-code-review, ponytail-audit, qt-qml-review (Phase 1 `qt_qml_lint.py` run; `qmllint` and Phase-2 sub-agents not available in this chat, their checklists were applied by hand). Nothing built, nothing on a device.
Scope read in full: `DataModel.qml` (completion state machine, all `_openCompletions` sites), `OrderDetailDialog.qml` caption, `tst_DataModel_completionsSyncing.qml` (17 cases), `completionsSyncingWiring.test.js`, design + test plan. Load assumed: one operator, a few open completions at a time.

## Strengths
- One funnel: `grep` shows exactly one raw `delete _openCompletions[` (inside `_closeOpen`); `_refreshSyncing` runs after `undo` is set. No path found where `undo` stays set after the entry closes.
- New object per change is the right fix for an unobservable `var` map; proven by `syncingOrderIdsChanged` spy.
- Tests recount the raw bookkeeping independently (seeded monkey, 60 runs x 14 steps); discard, reopen, late conflict, re-plan, exhaustion, local failure all covered.
- PR body is honest (what ran, what did not, defaults taken).

## Findings
### Must fix
1. **PR was un-mergeable and a "resolve conflicts" click would have reverted main.** PR #144 has base `main` but its branch carries the pre-squash #139 commits (merge-base `d426773`, main now `0f081f2`). Net diff vs main showed 19 files incl. deletions in `FailureCause.js` (-5), `tst_FailureCause.qml` (-19), `tst_Gateway.qml` (-8), completion-error-cause test plan (-214). Fix done here: Task 11's 2 commits re-applied onto main (only `CHECKPOINT.md` conflicted, branch side kept) and joined by a merge commit whose parents are PR head + `origin/main`. Net diff vs main is now the 14 Task 11 files only. Merging this stacked PR into #144's branch makes #144 clean. No force-push.

### Should fix
2. **RESOLVED 2026-10-15 (Taher chose B; see design D-5).** **A parked/stuck completion keeps saying "Saved. Syncing…"** (`DataModel.qml` `_onCompletionResult`, `OrderDetailDialog.qml:603`). `Gateway.stuckCount` / `StuckWrites` track parked writes, but nothing tells `_openCompletions`, so `undo` stays set while the header says "not syncing" and `StuckWritesSheet` offers Retry/Discard. Two screens, two stories. Design D-1 relied on the header line covering this; the caption does not know about it. Options: A keep + document; B hide caption when the key is parked (read `StuckWrites` by requestId; ~+6 lines + 2 tests); C neutral wording ("Saved on this device"). Recommendation: B. Needs Taher's call.
3. **CI green (2858/2858) was for the pre-squash tree**, not main + Task 11. Re-run happens on this stacked PR; check it before device testing.

### Investigation (confidence 70)
4. **`dataModel` resolves by dynamic scope.** It is the first use of the bare id in `OrderDetailDialog.qml`; it works only because `Main.qml:772` creates the dialog in the same context as `id: dataModel` (`Main.qml:183`). `OrdersPage.qml` does the same; `ImportPreviewDialog` injects `dataModelRef` instead. Verify on device: no `ReferenceError: dataModel is not defined` in the log when opening an order. If wanted: inject a property (~+3 lines).

### Nice to have
5. `completionsSyncing` is read by nothing in production (only tests + guard). Plan asked for it. Keep or delete (-3 lines, -1 mutant).
6. The node guard pins source text with regexes: brittle to reformatting. Behaviour is already covered by the QML test; acceptable, do not extend.
7. Test plan header said the QML file was "CI-only": now stale, CI ran it (QML 2094/2094). Fixed.
8. Lint: nothing specific to Task 11 beyond repo-wide conventions (`var`, ORD-1 property order); same as the main baseline. Caption `Text` has no `wrapMode` (short string; matters only for very large fonts).

## Verdict
Logic is correct and well tested. Ready after: #1 (done here), CI green on this stacked PR, and a decision on #2. Device-test the plan in the PR, plus one extra case: park the completion (Stuck writes sheet) and look at the caption.

Lean: -3 lines possible (item 5). Not checked: device behaviour, `qmllint` type checks, Gateway internals beyond the stuck/parked hooks, restock design.
