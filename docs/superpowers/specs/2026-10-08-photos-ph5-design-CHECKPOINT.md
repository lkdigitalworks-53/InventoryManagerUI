# CHECKPOINT — 2026-10-08 session: photos PH5 design + implementation (resume here)

**Branch:** `docs/2026-10-08-ph5-legacy-photourl-design` off `main` @ 78fa742. Docs only. NOTHING BUILT, NOTHING RUN, NOTHING DEPLOYED.
**Commit identity:** `dextran52@gmail.com`. Push with the PAT in the git header only (never in a file / config / memory).
**Not this workstream:** root `CHECKPOINT.md` (skills-index / PR #131-#133). Not touched.
**Rules:** branch only; no build/run; no Qt tooling in sandbox (CI decides); push without asking; honest advisor, grill before deciding; small scope so another account can resume.
**Taher's ask:** "start the next roadmap item while PH4 is tested; conclude all pending design questions; design this session; if design is already complete go straight to implementation; at the end list done + next steps."

## Step log
1. Read memory + cloned repo. Roadmap order (DELETE-FEATURE-ROADMAP, 2026-10-05): PH3b -> PH4 -> PH5 -> atomic-operation work. PH3b merged (#126-#128), PH4 = PR #133 (open, under test) => next item = **PH5** (legacy product `photoUrl` removal).
2. PH5 design was NOT complete: parent spec left "decide remove-vs-blank then" and the test plan had 8 cases marked "decide at PH5".
3. Traced every product `photoUrl` site (grep), XlsxService export/template, ImportPreviewDialog, `upsertMany` overwrite vs new path, `_mergeRecord` (dead), `gatewayLogic._deepEqual`, CI workflow scope.
4. KEY FINDING: server CAS compares whole documents with identical key sets; every stored product has `photoUrl:""`/`photoUpdatedAt:""`; removing them client-side makes `before` mismatch => permanent 409 on every pre-PH5 product (fresh tenants fine). Also: `test/felgo-dependent/` is not run by CI, so dialog/page cases cannot be automated.
5. Wrote design (`specs/2026-10-08-photos-ph5-legacy-removal-design.md`, ledger Q-P5-1..6 with trade-offs + recommended defaults), test plan (`test-plans/2026-10-08-photos-ph5-test-plan.md`, 30 automated + device plan), parent-spec pointer, test-plans index row, roadmap status line.

6. Taher answered: Q1 remove; Q2 silent ignore (no warning, helper H dropped); Q3 fresh tenants only; Q4/Q5 defaults; Q6 unanswered -> default. Implemented on `feat/2026-10-08-photos-ph5-legacy-removal` (stacked on #135): store, dialog, page, StorageService comments, ImportPreviewDialog, XlsxService (14 cols), QML tests S01-S03/S11/S13/S14/D1, Node guards G01-G11 + F42/F42b, Skill 107 (+ index regenerated), AGENTS, KNOWN-ISSUES, test plan status. Node 599/599 in sandbox; QML/C++ CI-only.
7. My mistake logged in Skill 107 rule 6: `git checkout <path>` after a mutation check reverted my uncommitted C++ edit to HEAD; noticed via guard count, re-applied, final tree verified (guards 71/71).

## NEXT (resume here)
1. Wait for CI on the PH5 PR (QML S01-S14/D1, C++ build are CI-only). Fix from the PR bot comment if red.
2. Taher: device plan section 6 of `test-plans/2026-10-08-photos-ph5-test-plan.md` on a FRESH tenant (export 14 columns, import round trip, no legacy button).
3. Optional next session: e2e E01-E03 in `test/e2e/`; delete dead `_mergeRecord` in a cleanup PR.
4. Merge order: #135 (design) -> PH5 PR; both independent of #131-#133 except SKILLS numbering (renumber Skill 107 and regenerate the index if #133 lands first).
5. Roadmap after PH5: atomic-operation work (`plans/2026-09-20-atomic-operation-outbox.md`); open elsewhere: #133 result, PH3b deploy + DV-1..DV-9, item 1 S4 cleanup, item 4 on-device check.
