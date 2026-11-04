# CHECKPOINT — 2026-11-04 L4b refresh row ("last updated" + tap to refresh) — resume here

**Branch:** `feat/2026-11-04-l4b-refresh-row`, cut from `main` @ `17db878` (PR #182 L4a merged and device tested).
**Commit identity:** every commit message names `dextran52@gmail.com` (Taher's standing rule); git author set to the same.
**Rules in force:** no build or run until Taher says so; no Qt in the sandbox (CI is the QML oracle); always a branch; push without asking; one focused slice per chat turn; honest trade-offs; tests and a test plan for every change; caveman-full replies.
**Skills used:** `brainstorming` (decisions B-D1..B-D9, defaults built, all vetoable in the PR), `qt-qml`, `qt-ui-design` (+ ux pass), `ponytail` (smallest design that is robust).
**Previous checkpoint archived:** `docs/superpowers/specs/2026-11-04-l4a-merged-prev-CHECKPOINT.md` (L4a + review sweep + edit-form hold; its NEXT item 3 is this slice).

## Why this slice
L4a NEXT item 3: "L4b: pull-to-refresh on the lists + last updated caption, calls `DataModel.requestRefresh("manual")`. Needs a qt-ui-design pass first."

## Steps
- [x] 1. Read memory, cloned fresh, read L4a design, coordinator, pages, GlassHeader, Toast, Icon, AppScrollView.
- [x] 2. Branch created, previous checkpoint archived.
- [x] 3. Design `specs/2026-11-04-l4b-refresh-row-design.md` (facts F1-F9, decisions B-D1..B-D10). B-D1 departs from the plan: a tap row, not a pull gesture (StopAtBounds, untestable gesture, Sales swipe handler).
- [x] 4. `qml/helper/RefreshCaption.js` (pure) + `refreshCaption.test.js` (35 tests, 33 mutants killed).
- [x] 5. `DataModel`: `lastSyncMs`, `refreshState`, `_request`/`manualRefresh()`, `_abandonWant`, signal `manualRefreshUnfinished`, hung-read watchdog (poll timer on while a run is out), `_lostCancelled`.
- [x] 6. `qml/components/RefreshRow.qml`; first child on Inventory, Orders, Staff, Dashboard, Sales (not Activity); `Main.qml` props, `requestManualRefresh()`, toasts.
- [x] 7. Tests: coordinator scenarios + 17 mutants in `refreshBehavior.test.js`, `refreshRowWiring.test.js` (28), one L4a rule repointed (`_request`), one L4a assertion changed on purpose (timer stays on while running), QML twins `tst_RefreshCaption.qml` (8) and `tst_DataModel_refreshRow.qml` (6), CI only.
- [x] 8. Test plan, README, AGENTS, KNOWN-ISSUES (new entry + L4a hung-read entry updated), Skill 156 + index (renumbered from 152 on rebase: main took 152-155).
- [x] 9. Sandbox: script suite 994/994, `functions` untouched.
- [ ] 10. Push, open PR, read CI (next session).

## NEXT
1. Read CI on the PR head (QML twins and the `DataModel`/page edits compile only in CI). Fix anything it shows.
2. Taher: veto or accept B-D1..B-D10 (first: tap row instead of pull gesture; Dashboard included although its activity feed is not refreshed). Device steps in the test plan.
3. L4c: add `ActivityLog`, categories, channels to the refresh; incremental refresh; sign-in sync on the shadow fetch; consider the one-helper refactor of the six store copies.
4. Atomic-ops arc: R4 (`InventoryStore.restock` rewrite) is still next there.

## Not done / honest gaps
- Nothing built or run on a device; the row's look, spacing and feel are device-only.
- QML tests and the page edits ran in CI only (not yet read).
- Pull gesture not built (B-D1).
