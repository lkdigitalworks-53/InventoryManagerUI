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
- [ ] 2. Design doc `specs/2026-11-10-r5a-restock-dialog-design.md`.
- [ ] 3. Code: `RestockFlow` (partyFor, newPartyChoice, limits, refusal texts), `AuthTextField.maxLength`, `RestockDialog`.
- [ ] 4. Tests (Node real-body + QML twin), mutants.
- [ ] 5. Docs: test plan, status doc section 11, KNOWN-ISSUES, Skill, SKILLS-INDEX, AGENTS, README.
- [ ] 6. Full suites, commit, push, open PR.
- [ ] 7. Read CI (next session / Taher).
