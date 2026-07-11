# Session Checkpoint — Product tax export/import + Size field

**Started:** 2026-07-10
**Status:** Plan written and self-reviewed, awaiting commit confirmation + execution-approach choice

## Step log

1. ✅ Cloned `InventoryManagerUI` fresh (`main`, up to date with origin, clean tree).
2. ✅ Confirmed `main` already has phase-0/1/2 pagination + the 403 tenant-context-race fix merged
   (commit `2179d5d`, test `tst_TenantContextRaceGuard.qml`) — the bug Taher was chasing at last
   session's end appears resolved already. `SalesPage.qml → AnalysisService` cutover is still
   deferred per the last checkpoint's note (not touched by this session's scope).
3. ✅ Explored existing product schema, export/import pipeline, and dialogs:
   - `qml/model/InventoryStore.qml` — products already carry `taxable` (bool) + `taxPercent`
     (number). Both are captured in Add/Edit dialogs, tracked in history diffs, but **explicitly
     left out of export** — two TODO comments already in the code:
     - `InventoryStore.qml` ~line 498 (upsertMany overwrite path)
     - `qml/pages/ImportPreviewDialog.qml` ~line 438 (`_validateProductRows`)
   - `src/XlsxService.cpp` — `kProductHeaders` (export/import column list) has no tax columns yet.
     `readSheet()` is generic/header-driven, so adding headers here is most of the import-read work.
   - Found a **latent bug**: the commented-out overwrite-path code in `InventoryStore.upsertMany()`
     references bare `taxable`/`taxPercent` variables (not `r.taxable`/`r.taxPercent`) — would throw
     if uncommented as-is. Needs a real fix, not just an uncomment.
   - `SKILLS.md` Skill 24 documents a **separate, not-yet-built** roadmap item: product `hsnCode`
     (P2, India-compliance roadmap). Confirmed via `grep` that `hsnCode` does not exist anywhere in
     the codebase yet. This is a scope fork worth confirming with Taher (existing taxable/taxPercent
     vs. also pulling in HSN).
   - Product dialogs (`AddProductDialog.qml`, `EditProductDialog.qml`) form layout mapped out for
     "Size" field placement — recommending a standalone field beside/near Category+Unit grouping
     (see design doc once written).
   - `InventoryStore.addProduct()` is already a 13-positional-argument function (2 call sites) —
     flagging this as a pre-existing smell that a 14th positional arg for `size` would worsen;
     `updateProduct(id, fields)` by contrast uses a named-fields object already, so Size there is
     low-risk regardless of the addProduct() decision.
4. ✅ Scoping answers from Taher:
   - Tax scope = existing `taxable`/`taxPercent` fields only. **No HSN code** in this pass.
   - **One combined spec + branch** for both features (tax export/import + Size field).
5. ✅ Further code tracing before finalizing design:
   - `InventoryStore.addProduct()` (13 positional args) has only **one live call site**
     (`AddProductDialog.qml:502`). The `DataModel.qml onAddProduct` handler + `Logic.qml addProduct`
     signal is **dead code** — never emitted anywhere (grepped, zero hits). Its param list is
     already stale (missing `party`/`unitCost`), confirming it's a pre-existing vestigial path, not
     something this session broke. Plan: leave it untouched, note as out-of-scope dead code.
   - `InventoryStore._mergeRecord()` is also **dead code** — defined but never called (`upsertMany`'s
     real overwrite path builds its own inline `fields` object, doesn't use `_mergeRecord`).
     It already has correct-looking `taxable`/`taxPercent` merge logic baked in from a prior
     half-finished attempt at this exact feature — but since it's unused, it's not load-bearing.
   - `src/XlsxService.cpp` `readSheet()` reads columns **by fixed position** (`col+1` against the
     `kProductHeaders` list index), not by matching header text found in the file. **New columns
     must be appended at the end of `kProductHeaders`/`writeProductsSheet`, never inserted in the
     middle**, or every column after the insertion point silently misaligns for anyone re-importing
     an older export. This means "Size" will not sit next to "Unit" in the exported sheet — it'll
     trail at the end alongside the new tax columns. Flagging this as a hard constraint, not a
     preference.
   - Asked Taher two more decisions (addProduct signature: positional vs. fields-object refactor;
     dead `_mergeRecord`: leave vs. delete). **Awaiting answer.**

6. ✅ Final decisions from Taher:
   - `addProduct()`: add `size` as a 14th positional arg (no fields-object refactor).
   - `_mergeRecord()`: leave the dead code alone, out of scope.
7. ✅ Traced every place product fields get enumerated (`grep sellingPrice` across `qml/`) to make
   sure nothing else needs touching: `OrderDetailDialog.qml`, `NewOrderDialog.qml`, `SalesPage.qml`
   only read price/sellingPrice for order math — not in scope. `InventoryPage.qml`'s product card
   is a compact "Name / SKU · price" row — adding Size there is a nice-to-have, not required by
   "read/write/export/import"; flagging as optional, not building it by default (YAGNI).
   `_normalizeRecord()` (the new-row import path) **already correctly handles** `taxable`/
   `taxPercent` — no changes needed there. Only the **overwrite path** (`upsertMany`) and
   `ImportPreviewDialog._validateProductRows()` need the actual wiring.
8. ✅ Design approved by Taher, with one added instruction: **during implementation, invoke
   `qt-development-skills:qt-qml` and `qt-development-skills:qt-ui-design` skills.** Read both now:
   - `qt-qml`: confirms existing codebase conventions (qsTr() wrapping, Layout.* sizing, no
     anchors+Layout mixing) already match what the repo does — no deviation needed, just keep
     following them in the new fields/columns.
   - `qt-ui-design`: this is a "small edit to an existing design" (adding a field to an existing
     form) — checklist doesn't trigger; principles (Jakob's Law, Proximity/Similarity, Ockham's
     Razor) already back the standalone-field placement decided during brainstorming.
9. ✅ Wrote spec to `docs/superpowers/specs/2026-07-10-product-tax-export-size-field-design.md`.
   Self-review pass found two internal-consistency gaps and fixed them inline: (a) final column
   order wasn't pinned down consistently between the Decisions table and Workstreams A4/B3 — now
   states the exact final `kProductHeaders` tail explicitly; (b) `addProduct()`'s new `size` param
   position wasn't explicit — now states the full 14-arg signature with `size` last.
10. ✅ Created branch `feature/product-size-and-tax-export` off `main` (local only — not pushed;
    no PAT provided yet this session).
11. ✅ Committed to `feature/product-size-and-tax-export` (commit `009d17c`). Local git identity
    set to match the repo's existing commit convention (`Taher <taher@lkdigitalworks.com>`) — noted
    here for transparency; nothing pushed (no PAT provided this session).
12. ✅ Handed off to `superpowers:writing-plans`. Re-verified exact current code for every file
    before drafting (line numbers/content unchanged since initial clone — no edits made yet).
    Found one more spec gap during this pass, fixed inline in the spec:
    - `InventoryStore._clone()` (called by all 8 mutator functions) whitelists product fields when
      rebuilding the array — `size` was missing from that whitelist. Without this fix, Size would
      silently vanish the very next time *any* product anywhere gets mutated (add/edit/restock/
      import). Added as its own explicit plan step + its own regression check in the on-device
      test plan.
    - Also confirmed `ImportPreviewDialog.qml` does **not** already import `ImportMath.js`
      (verified via `qml/helper/qmldir` — not registered there either) — added as a concrete plan
      step rather than an ambiguous "confirm if present" step.
13. ✅ Wrote plan to `docs/superpowers/plans/2026-07-10-product-tax-export-size-field.md` — 7 tasks:
    (1) `ImportMath.js` pure Taxable/Tax% parsers + TDD tests, (2) `InventoryStore.qml` schema +
    bug fixes, (3) `XlsxService.cpp` export/import columns + README, (4) `AddProductDialog.qml`
    Size UI, (5) `EditProductDialog.qml` Size UI + history label, (6) `ImportPreviewDialog.qml`
    wiring, (7) on-device test plan doc. Self-review pass done (spec coverage, placeholder scan,
    type consistency) — clean.
15. ✅ Committed spec amendment + plan (`bf56079`). Taher confirmed: commit now, execution approach
    = subagent-driven.
16. ⚠️ **Environment limitation found and flagged before starting execution:** this chat interface
    has no subagent-dispatch tool (no Task/agent-spawning primitive — only bash/view/str_replace/
    create_file/etc.), so `superpowers:subagent-driven-development` as literally specified (fresh
    isolated-context subagent per task + separate reviewer subagent) can't run here. Also flagged:
    its "continuous execution, don't pause between tasks" directive conflicts with Taher's standing
    "show full diff before action" rule anyway. **Adapted approach Taher approved:** I execute each
    task myself (implement, run real tests where they exist, explicitly self-review the diff
    against that task's spec section), then **stop and show the diff for review before each
    commit** — no continuous unattended execution, no fabricated "subagent" narration.
17. ✅ **Task 1 done** (`7e992d5`). Installed real Qt6 QML test tooling in the sandbox via apt
    (`qml6-module-qttest` + transitive `QtQml.WorkerScript`/`QtQuick.Window` modules — Qt 6.4.2 vs.
    project's 6.8.3, fine for pure-JS logic). Genuine TDD cycle: wrote 10 tests, ran → confirmed
    red, implemented `parseTaxableCell`/`parseTaxPercentCell`, ran → all 15 pass.
18. ℹ️ Taher: "commit and move ahead, I'll review at last after you push." This **overrides** the
    earlier "stop before every commit" agreement — proceeding through Tasks 2–7 continuously,
    committing each as I go, self-reviewing against the plan/spec but not pausing for interim
    approval. Flagged to Taher: no PAT provided this session, so nothing can actually be pushed
    yet regardless of how far I get.

19. ✅ **All 7 tasks executed and committed**, continuously, per Taher's "commit and move ahead"
    instruction:
    - Task 1 (`7e992d5`): `ImportMath.js` Taxable/Tax% parsers — genuine TDD (red confirmed, then
      green), 15/15 tests passing under a real `qmltestrunner` I installed via apt in this sandbox.
    - Task 2 (`23c37b2`): `InventoryStore.qml` — size schema + the `_clone()` load-bearing fix +
      the overwrite-path tax bug fix. qmllint clean (module-resolution noise only), brace/paren
      balanced.
    - Task 3 (`6f3976e`): `XlsxService.cpp` — Size/Taxable/Tax % columns, appended only, README
      rows. Brace/paren balanced (no C++ compiler available in this sandbox — QXlsx/Firebase
      headers aren't installed, and a full app build wasn't attempted per the standing
      don't-build/run rule).
    - Task 4 (`93db982`): `AddProductDialog.qml` Size field UI.
    - Task 5 (`535d198`): `EditProductDialog.qml` Size field UI + history label.
    - Task 6 (`6e1ee18`): `ImportPreviewDialog.qml` wiring — closes out both original TODOs.
    - Task 7 (`090100a`): on-device test plan doc.
    - Plan checkboxes marked complete (`11ee46a`).
20. ✅ **Final holistic self-review done:** re-ran the ImportMath tests one more time (still 15/15
    green after all later edits) — confirmed `DataModel.qml`/`Logic.qml`/`InventoryPage.qml`
    genuinely untouched (diff against `main` is empty for all three, matching the spec's
    out-of-scope list) — `size` reference counts across every touched file are sane and consistent
    with the plan.
21. ⚠️ **Nothing pushed.** No PAT provided this session. Branch `feature/product-size-and-tax-export`
    is fully committed locally, ready for Taher's review and push whenever he provides credentials.

## Honest limitations of this session's verification (for Taher's review)

- Task 1's tests are real and genuinely green — the strongest verification in this session.
- Tasks 2, 3: no automated tests exist for these files in this project (data-layer QML / C++
  export service) — verified via qmllint/brace-balance sanity checks only, **not** a real
  compile or app run. The on-device test plan (Task 7) is where the real verification happens,
  and Taher hasn't run it yet.
- Tasks 4, 5, 6: QML page-level UI/logic — same caveat, sanity-checked only, not run.
- No subagent-driven review occurred (flagged and agreed earlier — this chat interface has no
  subagent-dispatch tool). All "self-review" here was me re-checking my own work, not independent
  review.

## Next steps

- Taher reviews the full branch diff.
- Taher runs the on-device test plan (`docs/superpowers/2026-07-10-on-device-test-plan-tax-size.md`)
  when he builds/runs the app (his call, not done automatically here).
- Push once Taher provides a PAT.
- Then `superpowers:finishing-a-development-branch` for the merge/PR decision.

## Key files in scope so far

- `qml/model/InventoryStore.qml` (schema, `_normalizeRecord`, `_mergeRecord`, `upsertMany`,
  `addProduct`, `updateProduct`)
- `qml/pages/AddProductDialog.qml`, `qml/pages/EditProductDialog.qml`
- `qml/pages/ImportPreviewDialog.qml` (`_validateProductRows`)
- `src/XlsxService.cpp` / `.h` (`kProductHeaders`, `writeProductsSheet`, `readSheet`, `writeReadmeSheet`)
- `qml/Main.qml` (`_exportProducts`)
