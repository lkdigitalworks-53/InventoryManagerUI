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

## Slice 1 (order fix) — DONE in code
- [x] `OrdersStore`: `_serverBase` (exact decoded server image per order; fed by load, refresh, conflict, remote result; set to `after` on every local write), `_beforeFor`, used by `buildOrderUpdate` (edit + completion), `applyAdjustment`, `deleteOrder`.
- [x] Delete logs Activity only on `Gateway.mutationApplied`; refused / discarded deletes log nothing.
- [x] All internal writes of `orders` go through `_setOrders`; an outside write drops every base (falls back to the rebuilt copy).
- [x] Tests: `.github/scripts/__tests__/orderCasBase.test.js` (CB-1..CB-24, incl. 300-seed monkey, real server `_deepEqual`); `tst_ActivityLog_deleteEntries.qml` updated; two old refresh test files adapted to `_setOrders`.
- [x] Local suites: scripts 1039/1039, functions 1290/1290. QML not run (CI).
- [ ] QML twin tests, test plan, README/AGENTS/SKILLS entries, KNOWN-ISSUES.

## Slice 2 (subtle refresh) — see below, updated as it is built
