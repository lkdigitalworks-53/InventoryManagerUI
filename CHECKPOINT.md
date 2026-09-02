# CHECKPOINT — feature/product-order-delete-ui

Session date: 2026-08-30
Branch: `feature/product-order-delete-ui` (rebased onto `origin/main` @ `d2d9932`, 8 commits
ahead, about to push)

## Status: third rebase done, pushing

Single-pass session per explicit instruction — no interactive review gate used; decisions
documented in the spec doc for after-the-fact review instead.

## What's done

1. Archived the stale root `CHECKPOINT.md` (described already-merged handler-test work,
   commit `d1087b6`) to `docs/superpowers/specs/2026-08-29-functions-remaining-endpoint-handlers-CHECKPOINT.md`.
2. Branched off `main`.
3. Wrote spec: `docs/superpowers/specs/2026-08-30-product-order-delete-ui.md`.
4. Wrote plan: `docs/superpowers/plans/2026-08-30-product-order-delete-ui.md`.
5. **Commit `ec1d74f`** — row-level delete buttons: `Constants.qml` ("trash" icon token),
   `InventoryPage.qml` (ProductCard delete button), `OrdersPage.qml` (order row delete button).
6. **Commit `ba5ab20`** — success toasts (`Main.qml`) + delete-specific conflict wording
   (`Gateway.qml`'s `mutationConflicted` gains `action` 4th param, `InventoryStore.qml`/
   `OrdersStore.qml`'s `_onMutationConflicted` branch on it).
7. Wrote 5 test files (not yet committed): `tests/tst_DataModel_deleteGuards.qml`,
   `tests/tst_InventoryStore_mutationConflicted.qml`, 2 new cases appended to
   `tests/tst_OrdersStore_sync.qml`, `tests/tst_InventoryPage_deleteButton.qml`,
   `tests/tst_OrdersPage_deleteButton.qml` (the last two are this repo's first page-level
   UI-interaction tests — flagged as higher-risk in their own header comments and in the test
   plan).
8. Wrote test plan: `docs/superpowers/test-plans/2026-08-30-product-order-delete-ui-test-plan.md`,
   added its row to `docs/superpowers/test-plans/README.md`'s index.

## Also done (second pass, same session)

- Rebased onto `origin/main` (3 new commits: Skill 53 handler-parity test coverage, Skill 54
  sandbox-capability correction, `main` merge). Two conflicts:
  - `CHECKPOINT.md` — kept mine per explicit instruction (main's version described the
    unrelated handler-parity-coverage-gap session; this file is scratch/current-session by
    convention anyway).
  - `docs/superpowers/specs/2026-08-29-functions-remaining-endpoint-handlers-CHECKPOINT.md` —
    add/add: both this branch and `main` independently archived the same stale prior
    CHECKPOINT.md. Took `main`'s version — strict superset of mine, with an added "Post-hoc
    correction" section documenting the exact same commit-vs-checkpoint discrepancy I'd noticed
    myself but hadn't written into the archived file.
  - Everything else (`AGENTS.md`, `SKILLS.md`, `README.md`, `functions/test/*`,
    `scripts/setup-sandbox-qmltestrunner.sh`) applied clean, no overlap with this branch.
  - Force-pushed after rebase (`--force-with-lease`), history rewritten, new SHAs.
- Added 6 entries to `docs/superpowers/KNOWN-ISSUES.md` (existing file, appended, not
  replaced): the `_send` terminal-failure gap as it applies to deletes, staff delete's
  identical missing-UI gap, product-delete's orphaned stock-batch/photo gap, the Skill-54
  sandbox-capability discovery (this session's 5 test files were written assuming no toolchain
  exists here — that assumption is now outdated per `main`'s own Skill 54, not yet acted on),
  and the memory/remote branch-name mismatch noticed earlier this session.

## Also done (third pass, same session) — CI debug from attached logs

Real CI run (`1_QML_Tests.txt` + `results.xml`, 11 failures out of 709 tests) debugged and fixed:

- **9x `DataModel_deleteGuards` failures** — `ReferenceError: logic is not defined` in
  `DataModel.qml`'s dispatcher Connections block. Pre-existing bug on `main` (file isn't in this
  branch's diff), never caught before since no test had exercised these handlers via real signal
  dispatch. Root cause: `logic` never declared anywhere in the file; correct identifier is
  `dispatcher`. Fixed all 34 real call sites (`logic.` → `dispatcher.`), left the one comment
  mention alone (describes the correct external call pattern). Real-world implication: a blocked
  delete likely failed silently in production too, not just in the new toast — correction note
  added to the spec doc and KNOWN-ISSUES.md rather than silently editing the earlier claim.
- **2x compile failures** (`tst_InventoryPage_deleteButton`, `tst_OrdersPage_deleteButton`) —
  `Type X unavailable` traced to `Constants.qml`'s `import Felgo`, which the CI "QML Tests" job
  (plain Qt 6.8 only, confirmed by reading `.github/workflows/checks.yml`) can never satisfy.
  Architectural, not a test bug. Moved both files to new `test/felgo-dependent/` (no workflow job
  scans it), with a README and corrected header comments; content/assertions unchanged.
- Test plan and KNOWN-ISSUES.md updated to match reality instead of the earlier "not yet run,
  higher risk" framing, which undersold what was actually wrong.

## Also done (fifth pass, same session) — third rebase

`origin/main` moved 18 more commits (PR-CI-comment tooling under `.github/scripts/`, a
`_resetPending` guard applied to 6 stores including `InventoryStore.qml`/`OrdersStore.qml` --
the same two files this branch's `action`-param conflict-toast fix touches). Checked before
rebasing: main's change sits near the top of each file (`_resetAndFetch`/`_fetchFromFirebase`),
this branch's change is in `_onMutationConflicted` further down -- different regions, confirmed
no overlap. Rebase bore that out: only conflict was `CHECKPOINT.md` again, same resolution as
the last two passes. Verified post-rebase that both changes coexist correctly in both files
(`_resetPending` present, `action === "delete"` branch present) rather than just trusting a
clean rebase exit code.

## Key facts for resuming if interrupted before push

- Nothing has been pushed yet as of this checkpoint being written — `origin/main` has no
  awareness of this branch.
- Local git identity was not pre-configured in this sandbox; set to
  `lkdigitalworks-53 <lkdigitalworks@gmail.com>` (matching the last 3 commits' authorship on
  `main`) to allow committing at all.
- No toolchain in this sandbox — none of the 5 test files have been run. Brace-balance was
  checked via a Python character-walk on every touched `.qml` file (all balanced), per this
  project's established substitute-verification convention.
- Also noticed but explicitly NOT acted on this session (see spec doc's "Out of scope"): staff
  delete UI has the identical gap; the memory-recorded active branch
  `fix/chunked-batch-import-over-200-rows` doesn't exist on the remote (closest match:
  `fix/bulk-import-chunking-durable-status`) — worth Taher's attention separately, unrelated to
  this branch.
