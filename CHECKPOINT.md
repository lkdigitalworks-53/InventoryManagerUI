# CHECKPOINT: 2026-11-03 product picker v2, design audit (docs only) - resume here

**Branch:** `docs/2026-11-03-product-picker-v2-design`, cut from `main` @ `4c88ed9` (PR #181, R3 restock plan, merged).
**Commit identity:** author `Taher <lkdwtaher@gmail.com>`, and that email is also in every commit message, as this session's project instructions say. The R3 checkpoint recorded `taher.lkdw@gmail.com` as the later instruction; the brief asks Taher which is right. The PAT comes from the chat prompt only and is passed per command with `git -c http.extraHeader=...`, never in a remote URL, `.git/config`, the repo or memory. After a push `grep -c ghp_ .git/config` must print 0.
**Rules in force:** no build or run until Taher says so; no Qt in the sandbox (CI is the QML oracle); always a branch; push without asking; short scope per chat turn; honest trade-offs and grilling before decisions; tests of every kind and a test plan in the standard format (Skill 49) for every code change; update skills, AGENTS and README on a need basis; caveman FULL in chat only, documents in normal prose; do not touch other PRs or branches.
**Skills used:** `brainstorming` (hard gate: no code before the design is approved), `qt-qml`, `qt-ui-design`, `ui-ux-pro-max` (accessibility and touch rules), `ponytail` (smallest complete slices). SKILLS-INDEX read first, then Skills 5, 78 and 83 in full.
**Previous checkpoint archived:** `docs/superpowers/specs/2026-11-03-r3-merged-prev-CHECKPOINT.md`. R3 is merged; its next step (R4 restock rewrite, then R5) is untouched and recorded there.

## The ask
Product picker in New Order and Edit Order: detailed, searchable, editable item counts, seamless. Robustness first. Slices that each finish in one chat turn. Check whether a design already exists and whether it is relevant, correct and current.

## Steps
- [x] 1. Cloned the public repo fresh into `/home/claude/InventoryManagerUI` (the first attempt used `rm -rf`, the sandbox denied it, cloned without deleting instead).
- [x] 2. Found the existing design: `origin/feature/product-picker-search`, docs only, July 15, never implemented, `main` 423 commits ahead of it.
- [x] 3. Audited it against `main` (13 claims, table in the brief section 3). Verdict: direction reusable, NOT safe to implement as written (it would delete the pending-mint guard), and it does not cover the new requirements.
- [x] 4. Read the current pickers: `NewOrderDialog.qml` (`_pickerProducts`, `_rebuildPickerNames`, `addSelectedProduct`, `changeQty`) and `OrderDetailDialog.qml` (`_rebuildCatalog`, `_availableStock`, the add handler); `BottomSheet.qml`; `SearchField.qml`; `ChipScroller.qml`; `AvatarBadge.qml`; `InventoryPage._filteredProducts`.
- [x] 5. Wrote `docs/superpowers/specs/2026-11-03-product-picker-v2-audit-and-decisions.md`: audit, guard inventory, requirements, UI options, units, decisions D1 to D6, slices S0 to S5, test strategy, risks, not-checked list. Every checkable claim re-verified against the code before commit (one count corrected).
- [x] 6. Skill 152 added, `SKILLS-INDEX.md` regenerated, script tests run.
- [ ] 7. Taher answers D1 to D4 (and the commit-identity and whole-units questions). Until then nothing below can start.
- [ ] 8. Record the decisions in the brief, write the approved design (`specs/<date>-product-picker-v2-design.md`) and the test plan in the standard format, then S1.

## Open decisions (full text and trade-offs in the brief, section 8)
- D1 interaction model: A single tap, B open sheet with steppers (recommended), C inline.
- D2 unavailable products: hide (current) or show disabled with a reason (recommended).
- D3 row detail and filters: recommended set in brief section 5; photo, sort and barcode are the trim or extend points.
- D4 quantity meaning: "add N more" (recommended) or "set the total".
- D5 `BottomSheet` `scrollBody` opt-in and D6 helpers-first delivery: defaults taken, vetoable.

## NEXT (resume rule)
1. Read the brief. If Taher has answered D1 to D4, record them, write the design and the test plan, and start S1 (pure helpers: `ProductSearch.js`, `ProductPickability.js`, `PickerDraft.js`) on a new branch off `main`, dormant, pinned by a caller grep. S1 first steps: check whether `InventoryStore.products` excludes products with a delete in flight, and read `CompletionPlan` for the per-line change cost the cap check needs.
2. If he has not answered, ask again; do not write code.
3. Do not touch `origin/feature/product-picker-search`.
