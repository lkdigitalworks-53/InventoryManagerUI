# CHECKPOINT — 2026-11-09 REVIEW SWEEP of PR #188 (Restock Confirm fix) and PR #183 (R4) — resume here

**Branch:** `review/2026-11-09-pr188-pr183-sweep`, stacked on `fix/2026-11-09-restock-confirm-noop` (PR #188 head `7005e51`; `main` @ `415b11c`). **Commit identity:** `taher.lkdw@gmail.com` in author and in every commit message. PAT per command only (`git -c http.extraHeader=...`); after a push `grep -c ghp_ .git/config` must print 0. Rules in force: no build/run, no Qt in the sandbox (CI is the QML oracle), branch + push without asking, tests + test plan, honest trade-offs.
**Skills used:** `requesting-code-review` (reviewer checklist applied by hand: plan alignment, quality, architecture, testing, production readiness), `qt-qml-review` (phase 1 linter not run: needs the skill's python script, QML read by hand; phase 2's six agent missions applied as a reading checklist: bindings, layout, loading, delegates, states, performance), `ponytail-audit` (whole-tree scans for the bug class, lean check).
**Ask (Taher):** deep full sweep of PR #188, then of PR #183 for further bugs. Chat turn split: A = #188, B = #183/R3/R4, C = fixes + tests, D = docs + push.

## Steps
- [x] 1. Read memory, three review skills, CHECKPOINT of #188, PR #188 and #183 bodies. Clone, branch off #188 head.
- [x] 2. (A) #188: diff read; `RestockDialog._confirm`, `BottomSheet` busy rules, `qmlImportScan`, guard + `restockDialogConfirm` tests read; guard proven red when the import is removed; independent scans (helper .js -> .js, QML type per directory, singleton in qmldir): tree clean; CI of #188 read: all 4 jobs green.
- [x] 3. (B) #183: `InventoryStore.restock/_applyRestock/onRestock*`, `RestockFlow`, `RestockPlan` (R3), `Gateway.recordOperation/_finishOperation/_addOperationWaiter`, `DataModel` route and sale guard, `OutboxStore.hasQueuedOperationFor`, picker filter, import overwrite path, `FailureCause.forRestock`, `SendPolicy`: no data-loss bug; findings F-1, F-2, F-3 and notes O-1..O-3 in the test plan.
- [x] 4. (C) F-1: `RestockFlow.qtyFromField` + dialog; Node QF-1..15, CF-18..20; 7 mutants killed.
- [x] 5. (C) F-2: `Gateway._callSafely` at three call sites; Node GI-1..11; 6 mutants killed.
- [x] 6. (C) F-3: `qmlTreeResolution.guard.test.js` (SC-1..6, TR-0..3); 4 mutants killed. QML twins (5 cases) written, CI only.
- [x] 7. Node suites: `functions/` 1257/1257, `.github/scripts` 906/906.
- [x] 8. (D) Docs: test plan `2026-11-09-pr188-pr183-sweep-test-plan.md` (+ README row), Skill 157 + SKILLS-INDEX, AGENTS, README, KNOWN-ISSUES (D-C now fixed).
- [ ] 9. Commit, push, open stacked PR (base = #188's branch), read CI. See "State" below for the last confirmed step.
- [ ] 10. Taher: veto D-C2 / D-G, merge this PR into #188's branch, then #188; device test H2 (typed quantity).

## Decisions for Taher
D-C2 (read the typed quantity at the tap; refuse, do not clamp) and D-G (Gateway swallows and logs caller exceptions): reasons and alternatives in the test plan. Open notes O-1 (dead `restockConfirmed` signal), O-2 (import summary over-counts a product refused by the restock hold): roadmap, no code.

## Resume
Everything pushed is on the remote branch; read `git log` and this file. CI is the QML oracle (5 new QML twin cases were never run). The previous checkpoint (PR #188's) follows unchanged below.

---

# CHECKPOINT — 2026-11-09 Restock Confirm button does nothing (PR #183 device test) — resume here

**Branch:** `fix/2026-11-09-restock-confirm-noop`, cut from `main` @ `415b11c` (PR #183 merged, R4 restock).
**Commit identity:** author email `lkdwtaher@gmail.com`, and the same address in every commit message (Taher's instruction of 2026-11-09, replaces earlier identities). Push per command with `git -c http.extraHeader=...`, never in a URL, `.git/config`, the repo or memory. Taher rotates the PAT after the work; do not spend tokens on it. After a push `grep -c ghp_ .git/config` must print 0.
**Rules in force:** no build or run until Taher says so; no Qt in the sandbox (CI is the QML oracle); always a branch; push without asking; short scope per chat turn; honest trade-offs; tests and a test plan for every change; update skills, AGENTS, README as needed; caveman FULL in chat only, documents in normal prose.
**Skills used:** `systematic-debugging` (the four phases, no fix before root cause), `qt-qml`, `qt-ui-design` (no UI change, wording of one error toast only), `ponytail-audit` (scope: the files this fix touches plus a whole-tree scan for the same bug class).
**Previous checkpoint archived:** `docs/superpowers/specs/2026-11-09-r4-pr183-merged-prev-CHECKPOINT.md`.

## Report (Taher, device test of PR #183)
The Restock dialog's **Confirm** button does nothing: no toast, no spinner, no close.

## Root cause (Phase 1, read from code, proven by a failing test before the fix)
`qml/pages/RestockDialog.qml` called `RestockFlow.costFromText(...)` (added in the #183 review sweep, D-2) but never imported `RestockFlow.js`. `qml/helper/qmldir` lists only three singletons, so `import "../helper"` does NOT expose the helper `.js` files; every other file names each one (`import "../helper/X.js" as X`). The unresolved name throws `ReferenceError` on the first line of the tap that touches it, which is BEFORE `busy = true`: nothing changes on screen and the error only goes to the log. Not caught earlier because the dialog imports the Felgo chain and cannot load under `qmltestrunner`; `InventoryStore` (which has the import) was fully tested and the pure helper has its own tests, so every test passed.
Phase 2 (pattern): a whole-tree scan (new guard TREE-2) found exactly ONE file with this fault, `RestockDialog.qml`. Nothing else in `qml/`, `tests/`, `test/`.

## Steps
- [x] 1. Fresh clone `~/work/InventoryManagerUI` (note: `$HOME` is `/root`; the Write tool resolves `/home/claude`, so write to `/root/work/...`), branch, read memory, systematic-debugging, RestockDialog, InventoryStore.restock, RestockFlow, Gateway.recordOperation.
- [x] 2. Failing guard first: `functions/test/qmlHelperImports.guard.test.js` + `testSupport/qmlImportScan.js` (scanner SCAN-1..12, TREE-0..3, RD-1..3). RED on the old tree (TREE-2, RD-1, RD-3).
- [x] 3. Fix 1 (root cause): `import "../helper/RestockFlow.js" as RestockFlow` in `RestockDialog.qml`. Guard 19/19.
- [x] 4. Fix 2 (defence in depth, decision D-A): the tap body moved into `RestockDialog._confirm()` with one try/catch: an exception is logged and shown ("Something went wrong. Check the stock before trying again"), `busy` cleared when it was thrown before the answer; product and quantity captured at the tap (the callback used to re-read `qtyField.value` / `productId` when a slow answer arrived).
- [x] 5. `functions/test/restockDialogConfirm.test.js`: runs the REAL `_confirm` body in a vm with fake stores. CF-1..17 (18 tests). 14/14 hand mutants killed (`/tmp/mut.py`, list in the test plan).
- [x] 6. Functions suite full run after both new files: 1218/1218. Script tests (`.github/scripts/__tests__`): 905/905 (after regenerating SKILLS-INDEX with `node .github/scripts/skills-index.js --write`).
- [x] 7. Docs: test plan `2026-11-09-restock-confirm-noop-test-plan.md` + README index row, Skill 156 + SKILLS-INDEX, AGENTS, README, KNOWN-ISSUES (SpinBox commit, unverified).
- [x] 8a. Code commit `bd8d9ca`, docs commit `bee28ab` pushed. **PR #188** opened (needed `add_repo` push access for the API call; git push itself worked without).
- [x] 8b. CI on `bee28ab` ALL GREEN: QML 2882/2882, Functions 1218/1218, Rules 108/108, E2E 111/111 = 4319/4319. No product code changed after CI.
- [ ] 8c. Taher: device test of PR #188 (test plan on-device section, especially H1, N4, E1, E-SB1), veto window on D-A (the `_confirm()` + try/catch refactor), then merge.

## Next (not started)
1. If E-SB1 shows +10: fix the SpinBox commit in a separate small PR (lead in `docs/superpowers/KNOWN-ISSUES.md`), check other dialogs with an editable SpinBox.
2. R5 (restock dialog redesign, wording for too-large/reserved-text) stays as planned in `ATOMIC-OPERATIONS-STATUS.md`.

## Decisions (vetoable in the PR)
- D-A: refactor the handler into `_confirm()` + try/catch (not only the one-line import). For: the same silent failure class cannot hide again, a stuck-busy sheet is impossible, the real function body is testable in Node. Against: a bigger diff than one line, one more wording the person can see. Alternative rejected: lint guard only (loud in CI, still silent on a phone if a different error is ever thrown).
- D-B: NO QML twin of the dialog tests (the dialog cannot load under `qmltestrunner`; a stand-in would test the stand-in). Node vm + the import guard + the device checklist cover it.
- D-C: NOT changed, flagged for the device test (E-SB1 in the test plan): an editable `SpinBox` only commits typed text on focus loss or Enter, so typing 25 and tapping Confirm straight away may still send 10. Unverified (platform and focus policy dependent), so not fixed speculatively (systematic-debugging, no fix without evidence).

## Resume
If interrupted: the branch on the remote holds everything pushed; read `git log` on it and this file. Remaining work is docs (step 7) and the PR (step 8). CI is the QML oracle; this change has NO QML test of its own (all Node).
