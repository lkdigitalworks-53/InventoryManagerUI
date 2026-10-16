# CHECKPOINT — 2026-10-16 Restock as one atomic operation: DESIGN session

**Branch:** `docs/2026-10-16-restock-atomic-operation-design` (off `main` @ `6c6f358`). Commit identity `tsadmin@gmail.com`. PAT only in push commands, never stored.
**Rules in force:** no build/run until told; no Qt tools in sandbox (CI is the proof); branch + push without asking; honest trade-offs, grill before deciding; short scope (several Claude accounts hand over via this file).
**Previous checkpoint archived:** `docs/superpowers/specs/2026-10-16-pr144-prev-CHECKPOINT.md` (PR #144 Task 11; its steps 6-7 are Taher's CI/device/merge, untouched here).

## Request
Next task on the atomic-operations roadmap after #144/#145: **restock as one atomic operation** (KNOWN-ISSUES top entry, decided 2026-09-30, unbuilt). Design in this session if needed, else implement.

## Classification: architectural (brainstorming skill)
New `opType` (server deploy), new client flow, changes what a restock writes. Spec first, approval, then plan. So this session writes the spec + test plan only, no product code.

## Steps
- [x] 1. Loaded skills: brainstorming, qt-qml, qt-ui-design, ponytail
- [x] 2. Cloned repo, read E2E roadmap, KNOWN-ISSUES entry, `InventoryStore.restock`, `StockBatchStore.addBatch/nextBatchId`, `Gateway.recordOperation`, `operationLogic.js`, `DataModel` completion flow
- [x] 3. **Found PR #146 (P1 S1a, branch `feature/2026-10-16-p1-s1a-server-movements`) edits `operationLogic.js` and adds `DEFAULT_KIND_BY_OPTYPE = { completeOrder: "sale" }`.** Restock must send explicit `receipt` movements or add a default. Build only after #146 merges.
- [x] 4. Wrote design `docs/superpowers/specs/2026-10-16-restock-atomic-operation-design.md` (status DRAFT, 7 open questions Q-RS-1..7, each with options, trade-offs, my recommendation)
- [x] 5. Wrote test plan `docs/superpowers/test-plans/2026-10-16-restock-atomic-operation-test-plan.md` (PLANNED, nothing written or run)
- [x] 6. Docs: KNOWN-ISSUES status line, E2E roadmap line, test-plans README row, Skill 122, SKILLS-INDEX
- [x] 7. Taher answered Q-RS-1..7 in chat (D1-D7 in the design): keep sequential minted ids, online-only restock; purchase record inside the op; ActivityLog not audit; NO open-time id (store in-flight guard instead); skip server shape check; skip Syncing caption; `recordOperation` deployed + device-tested.
- [x] 8. Design + test plan updated to D1-D7. Pushed back on two points (D1 gaps/offline cost, D4 double-tap now rests on a guard)
- [ ] 9. **Taher: approve the updated spec (and confirm id gaps are acceptable).** Brainstorming gate: no plan before this.
- [ ] 10. Next account: after approval, write the implementation plan (writing-plans skill), then build R1..R6 from the design's build order, each on its own branch off `main`, after #146 merges.

## Resume here
Read the design doc section 4 (decisions) first. Do not write the plan or product code until step 9 is answered.
