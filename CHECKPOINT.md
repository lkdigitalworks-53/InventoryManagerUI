# CHECKPOINT — 2026-11-10 PR #186 device-test fixes — resume here

**Branch:** `fix/2026-11-10-pr186-order-cas-base`, cut from PR #186's head (`feat/2026-11-04-l4b-refresh-row` @ `ac1473e`). Not stacked on `main`: #186 is not merged.
**Commit identity:** `taher.lkdw@gmail.com` in every commit message (Taher's instruction for this session). PAT via a GIT_ASKPASS script outside the repo, never in `.git/config`; Taher rotates it.
**Rules in force:** no build/run, no Qt in the sandbox (CI is the QML oracle), branch + push without asking, tests + test plan, honest trade-offs, caveman-full in chat only, short scope per turn.
**Skills used:** `systematic-debugging`, `qt-qml`, `qt-ui-design`, `ponytail`.
**Previous checkpoint archived:** `docs/superpowers/specs/2026-11-10-pr186-sweeps-prev-CHECKPOINT.md`.

## Reports (Taher, device test of PR #186)
1. The "Updated N minutes ago" row is too prominent and takes space.
2. Order edited in the Firestore console, app refreshed, then every edit / complete / delete is refused ("updated elsewhere — your change didn't save"); a refused delete still wrote an "Order deleted" Activity entry. Products do not show it.
   Reproduction (Taher): changed `quantity` of a line inside `products` in the console, refreshed, set status completed, saved: rejected, all later edits rejected too.

## Root cause (matches the reproduction)
The server deep-compares `before` with the stored doc (`applyMutation`, `recordOperation`). The app sent a `before` REBUILT from the local copy by `_normalizeOrder`, which recomputes items/subtotal/discount/tax/total from the lines. A hand-changed quantity (totals untouched) makes the stored doc differ from its own rebuild, so every write 409s for ever. Delete logged its Activity entry at tap time, before the ack.

## Taher's reproduction (confirms the root cause)
Console: changed `quantity` inside `products`. App: refreshed, opened the order, set status completed, saved -> rejected "updated elsewhere"; all later edits rejected. Matches F2/F3 of `specs/2026-11-10-order-cas-base-design.md`: the rebuilt `before` recomputes totals from the lines, the stored totals were untouched.

## Slice 1 (order fix) — DONE, pushed (commit `71f2a6a`)
- [x] `OrdersStore`: `_serverBase`, `_beforeFor`, `_setOrders` + `onOrdersChanged`, ack-gated delete Activity (see design D-1..D-4).
- [x] `orderCasBase.test.js` (25), `tst_ActivityLog_deleteEntries.qml` updated, old refresh tests adapted.

## Slice 2 (subtle refresh button) — DONE in code (Taher: pull-to-refresh is too much effort; a subtle button whose text shows for a while, then disappears)
- [x] `RefreshRow.qml` -> `RefreshAction.qml` (ghost 38 dp icon, first header action on the five pages, caption Popup armed by its own tap, hides 3.5 s after the refresh settles). Pages restored from `main` then one block inserted each.
- [x] `refreshRowWiring.test.js` replaced by `refreshActionWiring.test.js` (41 incl. 38 hand mutants). Helper wording "refresh button".
- [x] Docs: design `specs/2026-11-10-order-cas-base-design.md`, addendum in the L4b design, test plan + index row, KNOWN-ISSUES (two entries), README, AGENTS, Skill 160 + `SKILLS-INDEX.md`.
- Suites run here: scripts 1049/1049, functions 1290/1290. QML not run (CI).

## NEXT
1. Read CI on the branch head (QML twins, `OrdersStore` edits, `RefreshAction` compile only in CI). Fix any red job first.
2. Taher: device steps in the test plan (H1 is his exact reproduction; H5/N4/N5/N6/E4 for the button). Veto or accept D-1..D-4 and A-D1..A-D4.
3. Open PR (base = PR #186's branch `feat/2026-11-04-l4b-refresh-row`, stacked) and merge into #186 once CI is green and he has tested.
4. Follow-ups, own PRs: check every other store's stored shape against its rebuild (`before` is rebuilt in inventory, suppliers, staff, batches); header crowding on Orders (four icons) if a narrow phone elides the title.

## Not done / honest gaps
- Nothing built or run on a device. The popup's look, position and fade are device-only.
- QML test files and the page/component edits were never loaded by Qt here.
- The root cause is confirmed by Taher's reproduction and by code reading, not by a server log.
