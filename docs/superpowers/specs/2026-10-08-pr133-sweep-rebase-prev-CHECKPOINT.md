# CHECKPOINT — 2026-10-06 session: SKILLS-INDEX + safe doc trim (resume here)

**Branch:** `chore/2026-10-06-skills-index-doc-trim` off `main` @ b455f72 (#129 and #130 merged). Docs/CI-tooling only. NOTHING IS DEPLOYED.
**Commit identity:** `taher.lkdw@gmail.com`. Push with the PAT in the push URL only; never in a file / git config / memory.
**Design:** `docs/superpowers/specs/2026-10-06-skills-index-design.md` (D1-D5, vetoable in the PR).
**Previous checkpoint archived:** `docs/superpowers/specs/2026-10-05-pr129-final-sweep-CHECKPOINT.md`.

## Plan (tick as done)
- [x] 1 generator `.github/scripts/skills-index.js` + tests (unit, edge, negative, monkey, repo-state)
- [x] 2 rename older duplicate `Skill 89` -> `89b`; generate `SKILLS-INDEX.md`
- [x] 3 AGENTS.md read-order rule; SKILLS.md overview note; README script list
- [x] 4 trim: README Concurrency blocks that cite an existing Skill; dead refs; false Staff-delete status row
- [x] 5 test plan + index row, Skill 106, roadmap/README rows
- [~] 6 push, open PR, CI green, update memory

## Step log
1. Cloned, branch from main, read brainstorming + ponytail skills, scanned SKILLS/AGENTS/README (no exact duplicate long lines; README "Concurrency" = 34 KB dated changelog; 8 dead-looking refs; duplicate `Skill 89`).
2. Generator + 21 tests (100% cover, mutation check: 3 new tests fail with the duplicate rule off). Older duplicate `Skill 89` -> `89b`. Index: 107 skills, 11.5 KB vs 306 KB.
3. README trim by rule (cites existing Skill, >=85% identifiers found there, >=7 identifiers): 5 of 25 blocks, 9,019 bytes. AGENTS: stale Staff-delete row fixed, dead path removed, rule 3 "Read order". SKILLS: overview note, dead path removed, Skill 106.
4. Test plan + README index row. Script tests 76/76.

## NEXT
1. Taher: review the PR; veto D1-D5 if wanted. Merge when CI is green.
2. Later (not done, medium confidence, listed in the PR): README blocks 770/825/601/797 (~4.6 KB, scores 0.80-0.83), AGENTS stale status sections, 69 archived CHECKPOINT files.
3. PH3b: deploy + DV-1..DV-9 are still open (steps given in chat, test plan section 4).

5. 2026-10-06 later: Taher said "trim readme then move to ph4". Stacked branch `chore/2026-10-06-readme-trim-2` (base = PR #131 branch) removes 4 more README blocks (5,509 B; README now 47.6 KB). Then PH4 brainstorming started (design gate: no code until Taher approves).

6. PH4 client on `feat/2026-10-06-photos-ph4-client` (PR #133, base = README-trim branch, which sits on #131): items 1 (403 terminal), 4 (L1: `breakerWaitMs` + one QML line), 5 (Q13 toast) built; item 3 was #113; item 6 no change. **Item 2 (`Qt.uuid` ids) DROPPED**: first CI run failed C07 with `Property 'uuid' of object Qt is not a function`; the StorageService change was reverted, old id scheme stays. Tests: Node parity 33/33 (after the PR #133 sweep) + functions 596 run for real; QML CI-only (re-run pending after the revert push). Skill 107 + index regenerated. OPEN QUESTIONS for Taher: (a) purge queued photos when a delete conflicts with `current: null` (not done); (b) stronger photo id later via Math.random v4 or C++ QUuid?
## NEXT
Merge order: #131 -> #132 -> #133. Then PH5 (legacy `photoUrl` removal) or PH3b deploy + DV-1..DV-9.
7. Taher answered the Q13 question (2026-10-06): row gone -> discard queued photos; row present + no photos row = first photo (already handled). Built on the same branch: `_onMutationConflicted` purges queued photos when `current` is null; `InventoryStore.hasProduct`; `PQL.shouldDiscardOnFailure` + one `if` in `PhotoQueue._upload` (404 and row gone locally -> `discard`). Tests C27-C32 (QML, CI-only) + D1-D5 (Node 34/34). Item 2 stays dropped (Taher: leave it).
8. 2026-10-07 (new session, Taher): "check for product should be full data, not the first 50" + "load the requested skills, do the full review". Cloned, read PR #133, found `hasProduct()` answering `false` from a PAGED list. Fixed on the PR branch: `PQL.productPresence` (+ Node mirror), `InventoryStore.listComplete` / three-state `hasProduct` / `clear()` resets `hasMore`. Tests: Node P1-P6 (file 40/40), whole functions suite 602/602 (after `npm ci`); QML C31 reworked + C33-C36 + PQL P1-P5 (CI only). Docs: Skill 108, test plan follow-up 2 + >50-products device case, SKILLS-INDEX regenerated. Commit identity `dextran52@gmail.com`.
9. (done, see 10) was: run `qt_qml_lint.py` on the PR's QML files, ponytail-audit scan, whole-file qml review (no subagents exist in this chat: the six agent passes are done by hand and say so), push, wait for CI. Then Taher reviews PR #133.
10. 2026-10-07 review results (PR #133 files, whole files). Phase 1 `qt_qml_lint.py` on InventoryStore.qml, PhotoQueue.qml, 2 test files: 408 hits, 0 real defects on PR lines. Noise: JS-1 `var` (329, house style, no `let/const` anywhere in qml/model), JS-2 (60: linter regex flags every `!==`, proved with a 4-line check; the 2 hits on my `hasProduct` lines are that bug), BND-1 `property var` (8, arrays/objects), STY-1 (2, QtTest roots). Real but PRE-EXISTING, not in this PR, not changed: LDR-3 `Qt.createQmlObject` Timer in `PhotoQueue._reschedule` (declare a child `Timer` instead), ORD-1 ordering in PhotoQueue.qml 59/68 and InventoryStore.qml 500/807/1032/1240. One real PR defect FIXED: `_productExistsLocally` sat between `_upload`'s comment and `_upload` (comment moved back). No qmllint in the sandbox (not installed on purpose). The six qml-review agents are not available in chat; the six domains were done by hand: layout/states/delegates/loaders = N/A (non-visual singletons, grep 0 hits), bindings/lifecycle/performance read for the PR regions. Verified, NOT a bug: a photo for a product with a queued create is held by `drainCandidates` (`OutboxStore.hasPendingForEntity`), and `UnsyncedOverlay` replays only updates, so the partial-list fix does not reopen a pending-create discard.
11. ponytail-audit (function-definition scan only: 939 defs; deps/classes/wrappers NOT scanned). 10 functions with ZERO references anywhere (src, tests, docs): AuthService.checkEmailProviders(20 lines), LoginPage._formIsValid(9), StaffStore.departmentList(8), SalesPage._recentTransactions(6), SalesStore.maxOrdersValue(6), SalesStore.maxRevenueValue(6), InventoryStore.markupPercentFor(6), InventoryStore.stockPercent(4), InventoryStore.stockStatus(3), DataModel.updateOrderInModel(3, named in AGENTS.md:343) = -71 lines. NOT applied (audit is read-only; out of PR #133 scope; Taher decides). Optional shrink in this PR: inline `productPresence` (-9 lines, -2 mirrors) at the cost of Node-testability.
## NEXT
Wait for CI on PR #133 (QML C31/C33-C36, PQL P1-P5 are CI-only). Taher answers the open questions in chat.
7. Taher answered the Q13 question (2026-10-06): row gone -> discard queued photos; row present + no photos row = first photo (already handled). Built on the same branch: `_onMutationConflicted` purges queued photos when `current` is null; `InventoryStore.hasProduct`; `PQL.shouldDiscardOnFailure` + one `if` in `PhotoQueue._upload` (404 and row gone locally -> `discard`). Tests C27-C32 (QML, CI-only) + D1-D5 (Node, 33/33 after the sweep). Item 2 stays dropped (Taher: leave it).

## 2026-10-07 PR #133 final sweep (branch `review/2026-10-07-pr133-final-sweep`, base = PR #133 branch `feat/2026-10-06-photos-ph4-client`)
**Commit identity:** `taher.lkdw@gmail.com`. Review note: `docs/superpowers/specs/2026-10-07-pr133-final-sweep-review.md`. NOTHING IS DEPLOYED, app not built or run.
- [x] 1 clone, branch off #133 head (25709fd), read memory + 3 skills
- [x] 2 diff read (15 files, +297/-22); Node parity 33/33, functions 596/596, script tests 76/76, index current; QML lint on 4 files (only false positive / repo-convention hits on changed lines)
- [x] 3 fixes: 2 orphaned doc comments, stale Gateway contract comment, removed tautological test, test `cleanup()`, counts, test plan line, KNOWN-ISSUES, Skill 109 + index
- [~] 4 push, open stacked PR, retitle #133, wait for CI (QML only runs there)
NEXT: Taher decides R1 (404 body check, recommended before prod). Merge the sweep PR into #133's branch, then squash-merge #133 when CI is green. After: PH5 or PH3b deploy + DV-1..DV-9.
