# CHECKPOINT — 2026-10-27 session 7: final-sweep review of PR #167 (resume here)

**Branch:** `review/2026-10-27-pr167-final-sweep`, stacked on `pr167` head `8a3904b` (`feat/2026-10-26-signout-guard`, base `main` @ `9c010f0`). Open the PR **into** `feat/2026-10-26-signout-guard`, not into `main`.
**Commit identity:** `tsadmin@gmail.com` (Taher's instruction this session; earlier sessions used other ids). PAT comes from the chat prompt only: push with `git -c http.extraHeader="Authorization: Basic $(printf 'x-access-token:%s' "$PAT" | base64 -w0)"`, never in the remote URL, `.git/config`, the repo or memory. After a push `grep -c ghp_ .git/config` must print 0.
**Rules in force:** no build/run; no Qt in the sandbox (CI is the QML oracle); push without asking; short scope; honest trade-offs; tests + test plan for every change; caveman FULL for chat only.
**Skills used:** `requesting-code-review`, `ponytail:ponytail-audit`, `qt-development-skills:qt-qml-review` (lint only: no Qt, so no qmllint and no agent-run QML).
**Previous checkpoint archived:** `docs/superpowers/specs/2026-10-27-pr167-final-sweep-prev-CHECKPOINT.md`.

## Steps (this session)
- [x] 1. Read the three skills, cloned, fetched `pull/167/head`, made the stacked review branch.
- [x] 2. Read design, `SignOutGuard.js`, `SignOutSheet.qml`, the `Main.qml` + `BottomSheet.qml` diffs, the test file, the test plan, the docs diff.
- [x] 3. Verified against the stores: every symbol the sheet reads exists (`OutboxStore.revision/inFlightCount/isInFlight`, `PhotoQueue.revision`, `InventoryStore.getById`, `Constants.*`, `GhostButton.textColor`); item field names match (`opType`, `ops`, `terminal`, `stuck`, photo `state`); `signOut(` call sites = 2 in `qml/`, 0 in `src/` + `main.cpp`; new files are picked up by the CMake `GLOB_RECURSE` and by `qmltestrunner -input tests`; Leave workspace is hidden for owners.
- [x] 4. Ran lint on the 4 touched QML files, filtered to changed lines: 82 hits, all kinds the whole repo has (`var`, property order, `property var`).
- [x] 5. Independent fuzz of `SignOutGuard.build`: 20000 runs of JSON-shaped junk, 0 throws, invariants hold; 5000 items build in 18 ms (V8).
- [x] 6. Fixes (all in this branch): sheet title follows the live count; Skill 136 cross-reference fixed; design D-S0-5 + README + test plan say the pending-mint fix is a separate PR and must merge first; test plan counts, E1, E10, new section 2b; new `.github/scripts/__tests__/signOutGuardWiring.test.js` (43/43 locally, 31 mutants, fix-revert 6 red -> 43 green); Skill 138 + index (138 skills); AGENTS + README lines.
- [x] 7. Report: `docs/superpowers/specs/2026-10-27-pr167-final-sweep-review.md` (0 must-fix, 4 should-fix all fixed, 4 nice or open).
- [x] 8. Local checks: script tests all green (109 before + 43 new), `skills-index.js --check` current.
- [x] 9. Pushed `review/2026-10-27-pr167-final-sweep` @ `b99c7a5`; review PR is **#169** (base `feat/2026-10-26-signout-guard`). Token check after push: `.git/config` 0 hits, none in tracked files. Still to do: read CI on the review PR head; recount QML / Functions / Rules / E2E from the CI comment (this change adds no QML test; the Node test is in the script-tests job).
- [ ] 10. Taher: merge the review PR into `feat/2026-10-26-signout-guard`, merge `fix/2026-10-26-pending-mints-tenant-scope` (before the restock device rows), then #167; run the on-device plan rows.

## Open questions for Taher (defaults applied, vetoable)
- Q-R1: should a photo with many `attempts` count as "Needs attention" like a stuck outbox item? (default: no, wait for device evidence)
- Q-R2: items queued during the Leave-workspace round-trip are discarded unwarned (test-plan E10). Add a busy state on Profile while it runs? (default: observe first)
- Q-R3: `Constants.danger` fails AA contrast (3.76:1). Change the token in its own PR? (default: yes, separate PR)
- Q-R4: gate the sheet's summary binding on `visible` (perf, untestable here)? (default: no until queues over 1000 are realistic)

## NEXT (each its own branch and session)
1. CI read on the review PR; fix whatever is red (suspects: none expected, no QML test added; the Node wiring test runs in the script-tests job).
2. Pending-mints PR (`feat` branch `fix/2026-10-26-pending-mints-tenant-scope`): its SKILLS entry is Skill 137 and its commit message and docs may still say 133; check on rebase. #167/#168 use 136/138.
3. S2f-3 client wording, S2d kinds on deltas, S2f-6 counters, P2 HSN/GSTIN (see the archived checkpoint for the roadmap table).

**PUSH RESULT (session 7):** branch pushed, PR #169 opened against `feat/2026-10-26-signout-guard`. CI not read yet (next session: step 9).
