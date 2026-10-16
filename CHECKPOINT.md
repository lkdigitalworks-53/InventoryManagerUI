# CHECKPOINT — 2026-10-16 Restock as one atomic operation: DESIGN session

**Branch:** `docs/2026-10-16-restock-atomic-operation-design` (off `main` @ `6c6f358`). Commit identity `tsadmin@gmail.com`. PAT only in push commands, never stored.
**Rules in force:** no build/run until told; no Qt tools in sandbox (CI is the proof); branch + push without asking; honest trade-offs, grill before deciding; short scope (several Claude accounts hand over via this file).
**Previous checkpoint archived:** `docs/superpowers/specs/2026-10-16-pr144-prev-CHECKPOINT.md` (PR #144 Task 11; its steps 6-7 are Taher's CI/device/merge, untouched here).

## Request
Next task on the atomic-operations roadmap after #144/#145: **restock as one atomic operation** (KNOWN-ISSUES top entry, decided 2026-09-30, unbuilt). Design in this session if needed, else implement.

## Classification: architectural (brainstorming skill)
New `opType` (server deploy), new client flow, changes what a restock writes. Spec first, approval, then plan. So this session writes the spec + test plan only, no product code.

## Steps
- [x] 1-6. Skills loaded, repo read, design v1 + test plan v1 + docs pushed (see git log)
- [x] 7. Taher answered v1 questions, then **corrected me: server-side id minting inside the transaction was never rejected; he wants ALL calls (id create, CRUD, transaction, audit) in one atomic operation with one transaction id.** My v1 error: called it "the rejected option C" and overstated a counter race (client REST mint and server Admin txn on the same doc serialise safely).
- [x] 8. Design v2: new `mint` op kind + `{{placeholder}}` substitution inside `applyOperation`; counters rolled back on rejection (gapless); replay returns minted ids; restock = first consumer; key created at tap; paper walk-through of create-product and order-create; import needs chunking (named limit)
- [x] 9. Test plan v2 rewritten (server mint cases, restock, regression incl. `completeOrder` golden marker, monkeys, emulator e2e, device plan)
- [ ] 10. **Taher: answer Q-A1 (generic mint vs per-opType server builders), Q-A2 (hide product while restock pending vs temp batch id), Q-A3 (ActivityLog in-op), Q-A4 (counter seed), Q-A5 (one PR per consumer, order) and approve spec v2.** Brainstorming gate: no plan before this.
- [ ] 11. Next account after approval: writing-plans, then R1..R6 in the design, each own branch off `main`, after PR #146 merges.

## Resume here
Read design v2 section 6 (open questions). Do not write the plan or product code until step 10 is answered.
