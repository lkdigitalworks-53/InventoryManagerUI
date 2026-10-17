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
- [x] 10. Taher answered Q-A1..Q-A5 (generic mint; hide product while restock pending; activity in-op; server derives seed; one PR per consumer) and asked for a gap analysis of prior atomic work + a PR
- [x] 11. Wrote `docs/superpowers/ATOMIC-OPERATIONS-STATUS.md` (what was built, 10 gaps G1-G10 with evidence, non-atomic path table, order of work). New finding G4: random-key op queued offline is lost on sign-out (outbox cleared) -> open Q-A6
- [x] 12. Spec section 6 updated (answers recorded, Q-A6 open); test plan updated (R10, device 2b)
- [x] 13. PR #147 opened for design review (https://github.com/lkdigitalworks-53/InventoryManagerUI/pull/147).  Brainstorming gate: plan only after approval.
- [x] 14. Taher answered Q-A6: sign-out popup with brief operation details + consequences (warn-and-allow, not block). Spec 4b, test plan S series, status doc updated. Proposed as PR 0 before the engine (Q-A7).
- [ ] 15. **Taher: confirm Q-A7 (guard first), review PR #147, approve.** Then next account: writing-plans, then R1..R6 in the design, each own branch off `main`, after PR #146 merges.

## Resume here
Read `ATOMIC-OPERATIONS-STATUS.md`, then design v2 section 6 (Q-A7 open). Do not write the plan or product code until PR #147 is approved and Q-A7 answered.
