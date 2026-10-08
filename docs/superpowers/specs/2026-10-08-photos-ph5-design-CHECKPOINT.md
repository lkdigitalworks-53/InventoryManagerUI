# CHECKPOINT — 2026-10-08 session: photos PH5 design (resume here)

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

## NEXT (resume here)
1. Taher answers Q-P5-1..6 in the PR/chat ("defaults" = A, B, a, B, A, A-or-B for Q-P5-6).
2. Then implement PH5 in ONE PR on `feat/2026-10-08-photos-ph5-legacy-removal`; commit order is in the design ("Design" section). Tests first, then code.
3. At implementation: new Skill (number assigned at rebase, #133 holds 107-108), regenerate `SKILLS-INDEX.md`, update AGENTS/README/KNOWN-ISSUES.
4. Still open elsewhere: PR #133 CI/device result; PH3b deploy + DV-1..DV-9; roadmap item 1 S4 cleanup; item 4 on-device photo-on-delete check; atomic-operation work.
