# PR #133 final sweep (PH4 client), 2026-10-07

Skills run: `superpowers:requesting-code-review` (no subagent tool in this session: the reviewer template was applied by hand to `origin/main...HEAD`), `ponytail:ponytail-audit` (scoped to the PR diff and the files it touches; **no whole-tree scan was run**, token budget), `qt-development-skills:qt-qml-review` (Phase 1 lint run for real on 4 files; **qmllint not run**, no Qt in the sandbox by rule; the six agent passes done by hand on changed code only).

Evidence run here (re-run 2026-10-08 after rebasing onto `main` @ 33c6661, #133 squash-merged): `photoQueueLogic.parity.test.js` 39/39, whole `functions` suite 601/601, `.github/scripts/__tests__` 76/76, `skills-index.js --check` current (110 skills). QML tests are CI-only.

**Rebase note (2026-10-08):** #133 was squash-merged with its later commits, so findings 1 and 2 below (orphaned comments) are already fixed on `main` and this PR no longer touches those lines; the conflicting hunks in `InventoryStore.qml` / `PhotoQueue.qml` kept `main`. The sweep's `cleanup()` was merged into the `cleanup()` that `main` already had (it now also restores `PhotoQueue.items`). The sweep's skill was renumbered 108 -> 109 because `main` already has a Skill 108.

## Verdict
Mergeable after this sweep. No Critical or Important code defect found. One decision for Taher (R1) is recommended before production, not before merge.

## Strengths
Decision rules live in pure functions with strict truth tables (`shouldDiscardOnFailure`, `=== false`), the XHR file keeps one `if`. Item 2 was dropped on CI evidence instead of stubbing. Tests hit the real code. 403 trade-off and the paged-list caveat are written next to the code.

## Fixed in this sweep (Minor)
| # | Finding | Fix |
|---|---|---|
| 1 | `InventoryStore.hasProduct` was inserted between `photoIdsFor`'s doc comment and the function: comment orphaned | moved above the comment |
| 2 | `PhotoQueue._productExistsLocally` inserted between `_upload`'s comment and `_upload`: same | moved above the comment |
| 3 | `Gateway.qml` header said `current` is null only for a malformed edge case; PR now relies on null = row gone (server returns `current: null` for a missing doc) | comment states the real contract |
| 4 | Parity test "`_reschedule` rule max(due, breakerWait)" re-implemented `Math.max`, never called `_reschedule`: false assurance | removed (-7 lines) |
| 5 | C32 nulls `PhotoQueue.items` and restores it at the end of the test; a failed `compare()` aborts the test and leaves it null for later tests | `cleanup()` restores it |
| 6 | Double blank line in the Node mirror; stale counts (34/34, 29/29, 597); test plan line "NOT TESTABLE until PH4"; PR title still said "uuid photo ids" | fixed |

## Decisions and open risks
- **R1 (DECIDED 2026-10-08: option b, built on branch `feat/2026-10-08-photos-ph4-r1-404-body`, stacked on this PR):** 404 is judged by status only. Misrouted/undeployed endpoint + product not in the first 50 loaded rows + drain at startup = photo and local file discarded, unrecoverable. Options: (a) accept while dev-only (now); (b) also require body `error === "product-not-found"` (~3 lines + mirror + cases; I recommend this); (c) also require `!hasMore` (wider, delays discard on big lists). Not changed here because it alters a rule Taher chose.
- **R2:** malformed 409 without `current` is read as "row gone". Server always sends it. Documented, not coded.
- **R3 (honest coverage statement):** the `_upload` discard `if` and the `_reschedule` L1 line have no unit harness (PhotoQueue TESTABILITY NOTE). Their pure parts are 100% covered (QML + Node); the wiring is covered only by on-device steps 3 and 6 in the PR body. "100%" is not true for those two lines.
- **R4:** D5 monkey test compares the function with its own expression, adding no coverage beyond D1-D4. Kept because monkey tests are mandated.

## ponytail-audit (diff scope), ranked
1. delete: parity test re-implementing `Math.max`. Done. -7 lines.
2. shrink: none worth the churn. `_productExistsLocally` try/catch guards a destructive path: keep. The Node mirror duplicate is the repo's mandated hand-kept pattern: keep.
net: -7 lines, -0 deps. Whole-tree audit not run.

## qt-qml-review
Lint on changed lines: 1 ORD-1 (`PhotoQueue.qml:236`, one-line `catch (e) { return undefined }`, false positive) and 7 JS-1 `var` in `tst_PhotoQueueLogic.qml` (file-wide repo convention, 57 pre-existing, not churned). Hand passes: no bindings, layout, loader, delegate or state code changed; `hasProduct` is O(n) but runs only on a failed upload.
