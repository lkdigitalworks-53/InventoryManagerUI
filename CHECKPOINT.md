# CHECKPOINT — 2026-10-08 session 2: PH4 R1 (404 body check), stacked on PR #134 (resume here)

**Branch:** `feat/2026-10-08-photos-ph4-r1-404-body` (PR #138). REBASED 2026-10-09 onto `main` @ 38ac768 (#133, #134, #135 merged); 1 commit unique. NOTHING IS DEPLOYED, app not built or run.
**Decision (Taher, 2026-10-08):** R1 option (b): a 404 discards a queued photo only if the body error is `product-not-found` AND the product is absent from the COMPLETE local list.
**Commit identity:** `dextran52@gmail.com`. PAT only in the git extraHeader.
**Previous checkpoints archived:** `docs/superpowers/specs/2026-10-08-pr134-rebase-prev-CHECKPOINT.md`, `docs/superpowers/specs/2026-10-09-pr138-rebase-prev-CHECKPOINT.md` (main's #135 rebase checkpoint).

## Plan (tick as done)
- [x] 1 confirm server body: `{ok:false,error:"product-not-found"}` (`functions/index.js` L1183/L1207, `photoCleanup.js` L78), covered by server tests
- [x] 2 `PQL.errorCodeOf` + `shouldDiscardOnFailure(status, exists, errorCode)` (QML helper + Node mirror), one changed `if` in `PhotoQueue._upload`
- [x] 3 tests: Node R1-1..R1-7 (46/46 parity, 608/608 functions), QML R1-R3 + D1-D4/P5 updated (CI only); mutation check: dropping the code check fails 4 tests
- [x] 4 docs: test plan follow-up 3 + 4 device steps, KNOWN-ISSUES item 1 resolved, Skill 109 rule 5 note, review note R1 decided
- [x] 5 pushed, stacked PR #138 opened on #134's branch
- [x] 6 2026-10-09 rebase: `git rebase --onto origin/main e6a1d21` (#134 was squash-merged as b4d426a); only `CHECKPOINT.md` conflicted: kept this PR's, archived main's
- [~] 7 force-push with lease pinned to old head e5b161d; re-run Node tests; wait for CI (QML tests are CI-only)

## NEXT
Taher: read CI on #138, squash-merge when green. After: PH5 implementation (PR #136 content was folded into #135's branch; check what main holds), or PH3b deploy + DV-1..DV-9.
Known gap: the `_upload` `if` wiring is device-only (see test plan R1 device steps).
