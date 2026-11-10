# CHECKPOINT — 2026-11-10 Atomic ops R5a: restock dialog (typed supplier joins the operation, limits, wording) — resume here

**Branch:** `feat/2026-11-10-r5a-restock-dialog-supplier-in-op`, cut from `main` @ `515ab19` (R4 #183, #188, #190 merged).
**Commit identity:** `dextran52@gmail.com` in every commit message (Taher, 2026-11-10). PAT only through `git -c http.extraHeader=...` per command, never in a URL, `.git/config`, the repo or memory; after a push `grep -c ghp_ .git/config` must print 0. Taher rotates it; no tokens on that topic.
**Rules in force:** no build/run, no Qt in the sandbox (CI is the QML oracle), branch + push without asking, tests + test plan, honest trade-offs, caveman FULL in chat only (documents in normal prose), short scope per chat turn.
**Skills used:** `superpowers:brainstorming`, `qt-qml`, `qt-ui-design`, `ponytail`.
**Previous checkpoint archived:** `docs/superpowers/specs/2026-11-10-pr190-merged-prev-CHECKPOINT.md`.

## Task (next on `ATOMIC-OPERATIONS-STATUS.md`, section 10): R5
R5 as written has four parts. Split decided this session (vetoable, see design D-R5-1):
- **R5a (this branch, client only, no server deploy):** P1 (the dialog's "add new supplier" no longer mints and creates the supplier BEFORE the restock; the typed name goes into the operation), limits (`maxLength` on the reason and supplier fields, a unit-cost ceiling), person-facing wording for the new refusals.
- **R5b (next branch):** `activity_log` entity INSIDE the operation (Q-A3), id parameter on `ActivityLog.record`, server stamps `actorUid`, rules check, P2 (`TransactionStore.recordPurchase` removal and the doc-shape guard move). Server deploy BEFORE client.

## Steps
- [x] 1. Read memory, status doc, designs R1-R4, `operationLogic.js`, `RestockPlan/Flow/FailureCause`, `RestockDialog`, `ActivityLog`, `SupplierStore.addSupplier`. Clone, branch, archive checkpoint.
- [x] 2. Design doc `specs/2026-11-10-r5a-restock-dialog-design.md`.
- [x] 3. Code: `RestockFlow` (supplierFor structured, partyFor, newPartyChoice, limits, texts), `AuthTextField.maxLength`, `RestockDialog` ("Use", pending name, hint, limits).
- [x] 4. Tests: `restockR5a.test.js` (37), adjusted CF-17, RD-2, F-9, E-3; QML twin 5 functions; 26/26 mutants killed (`/tmp/mut.py`, list in the test plan).
- [x] 5. Docs: test plan + index row, status doc section 11, KNOWN-ISSUES, Skill 159 + SKILLS-INDEX regenerated, AGENTS, README.
- [x] 6. Full suites (functions 1327/1327, scripts 905/905), commit `a047d07`, pushed, PR #191 opened.
- [ ] 7. Read CI on PR #191 (QML oracle: `tst_RestockFlow` 19 functions; fix red first). Taher: veto D-R5-1..7, device steps 1-21.

## Next session (pick up here)
1. Read CI of PR #191; fix only what CI shows.
2. Then R5b on a NEW branch off `main` after #191 merges: `activity_log` inside the operation (operation-only entity map in `operationLogic.js`, NOT `ENTITY_COLLECTIONS`; server stamps `actorUid` + timestamp; rules check; `ActivityLog.record(id)` parameter; planner op + `reflect` + `_applyRestock` writes the row from results; budget formula +1 write/+1 audit), then P2 (`TransactionStore.recordPurchase` removal, doc-shape guard moved). Server deploy BEFORE client. Design notes: `specs/2026-11-10-r5a-restock-dialog-design.md` section 5.
3. Then R6 (docs + device test of the whole arc). Add-product slice also fixes `AddProductDialog`'s inline add-supplier row.
