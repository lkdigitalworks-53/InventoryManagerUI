# CHECKPOINT: 2026-11-11 picker v2 slice S3 (New Order wired) - resume here

**Branch:** `feat/2026-11-11-picker-s3-new-order`, cut from `main` @ `977cde0` (PR #187, picker S2, merged).
**Commit identity:** every commit message text contains `tsadmin@gmail.com` (Taher's instruction of 2026-11-11; older commits carry other addresses). The PAT comes from the chat prompt only and is passed per command with `git -c http.extraHeader=...`. It is never stored in `.git/config`, the repo, a document or memory. (This session's first clone put it in the remote URL; the URL was cleaned straight after.)
**Rules in force:** no build or run until Taher says so; no Qt in the sandbox (CI is the QML oracle); always a branch; push without asking; short scope per chat turn; honest trade-offs and a veto window in the PR; tests and a test plan for every change; out-of-scope findings go to `docs/superpowers/KNOWN-ISSUES.md`, not into code.
**Skills used:** `brainstorming` (design approved as a whole on 2026-11-03; S3 sub-decisions S3-D1..D8 are vetoable in the PR, same as S2), `qt-qml`, `qt-ui-design`, `ponytail`.
**Previous checkpoint archived:** `docs/superpowers/specs/2026-11-11-pr187-merged-prev-CHECKPOINT.md`.

## Scope (design brief section 9, slice S3)
Wire `NewOrderDialog` to `ProductPickerSheet`; delete `productNames`, `_pickerProducts`, `_rebuildPickerNames`, the combo and the add button. Carried requirements closed here (KNOWN-ISSUES "Product picker v2: carried requirements"): item 1 (dry run of `CompletionPlan` before "Add to order"), item 3 (parity gap, verified by reading), item 4 (valid selling price), item 5 (id matching), item 7 (pending-mint revision counter). NOT in S3: `OrderDetailDialog` (S4), accessibility and big-catalog polish (S5), any server or rules change.

## Steps
- [x] 1. Clone, skills read, branch cut, old checkpoint archived, this file.
- [x] 2. Read design, audit, S2 plan, KNOWN-ISSUES carried list, sheet, helpers, stores, `NewOrderDialog`.
- [ ] 3. Plan doc `plans/2026-11-11-product-picker-v2-s3-new-order.md` with S3-D1..D8.
- [ ] 4. `NewOrderPicker.js` (pure) + Node tests + QML twin.
- [ ] 5. `PickerSheetModel.build`: optional `commitCheck` hook + tests.
- [ ] 6. `StockBatchStore.mintRevision`, `NewOrderDialog` wiring, wiring tests, dormancy tests updated on purpose.
- [ ] 7. Run Node suites, hand mutants.
- [ ] 8. Docs: test plan, KNOWN-ISSUES, README, AGENTS, Skill 162, SKILLS-INDEX.
- [ ] 9. Commit, push, read CI, open PR (REST API).
- [ ] 10. For Taher: veto window on S3-D1..D8, device checks, merge; next S4 (Edit Order).

## Findings so far (read from code)
- Parity gap (carried item 3): a HELD row (`dependsOn`) is never sent, so it never fails, so `StuckWrites.isParkedItem` (needs `terminal` + `stuck` or failures) cannot become true for it. `hasParkedForEntity` and `unsyncedByEntity` therefore only differ for a damaged saved row; the failure direction is safe (completion refuses with a message). No code change.
- `StockBatchStore._pendingMints` has no revision (confirmed). `OutboxStore.revision` ticks on every item change, so a queued restock or edit ticks it. `InventoryStore.revision` ticks on `products`.
- Dry run is feasible: `CompletionPlan.build` is pure; the sale docs are one per line with a quantity; so a stub `saleDocs` gives the same operation count as the real one.
