# Session Checkpoint — GitHub Actions PR checks (build/test)

**Started:** 2026-07-31
**Branch:** `ci/github-actions-pr-checks`
**Status:** Brainstorming in progress (per `superpowers:brainstorming`). No design approved yet,
no workflow YAML written yet.

## Step log

1. Cloned `InventoryManagerUI` fresh into the sandbox (per standing session instructions).
2. Archived the stale root `CHECKPOINT.md` (left over from the completed/merged
   `feature/analysis-by-name-chart-all-views` session, last touched 2026-07-12) to
   `docs/superpowers/specs/2026-07-12-analysis-by-name-chart-all-views-CHECKPOINT.md`.
3. Created branch `ci/github-actions-pr-checks` off `main`.
4. Explored the repo for CI feasibility ahead of brainstorming. Key findings:

   **No existing CI.** `.github/` only has agent config files (`qt-qml-review`, `qt-cpp-review`,
   etc.); no `.github/workflows/`.

   **Three independent test surfaces exist, already written:**
   - `tests/*.qml` (28 files) — Qt Quick Test, run via `qmltestrunner`. Historical baseline:
     140 cases passing (verified locally by Taher via Felgo's bundled Qt). 3 newer suites
     (`tst_Gateway`, `tst_OutboxStore`, and one more per AGENTS.md) are **written but never
     actually run**, even locally.
   - `functions/test/*.test.js` (48 tests) — plain Node `node --test` against `functions/lib/`
     pure-logic modules. No emulator, no network. `cd functions && npm test`.
   - `test/firestore.rules.test.js` — needs the Firebase emulator:
     `firebase emulators:exec --only firestore "node --test test/"`. Not yet run anywhere
     (sandbox sessions have had no network path to the emulator distribution).

   **QML tests appear Felgo-independent by design.** Every `tests/tst_*.qml` file imports only
   `QtQuick`, `QtTest`, and pure `.pragma library` `.js` helpers (or the `qml/model` singleton
   directory, which itself imports only `QtQuick`/`QtCore`). The project's own convention
   (documented in `AGENTS.md`) is that anything needing the full Felgo `App` context
   (`dp()`/`sp()`/`Theme`/`GlassHeader`) is deliberately kept OUT of this suite. This suggests the
   QML test job could plausibly run on a stock open-source Qt6 install on a Linux runner, with
   no Felgo SDK at all — but this is not yet verified by actually running it.

   **A real app "build" is very likely infeasible on a standard GitHub-hosted runner.**
   `CMakeLists.txt` starts with `find_package(Felgo REQUIRED)`, and `main.cpp` directly
   `#include <FelgoApplication>` — so even a C++ syntax/compile check of the entry point requires
   the proprietary, license-gated Felgo SDK. `CMakePresets.json` only defines Windows/MinGW
   presets pointing at `C:/Felgo/...`. Felgo does offer a separate hosted product, "Felgo Cloud
   Builds," for this exact problem — but it's its own platform (connects to GitHub directly), not
   something wired up through a `.github/workflows/*.yml` file.

   **Flagged, not yet actioned (adjacent finding, not this task):** `CMakeLists.txt` has a
   `PRODUCT_LICENSE_KEY` hardcoded in plaintext, committed to a public repo. Raised to Taher for
   awareness; out of scope for the CI task unless he wants it addressed.

5. Presented findings to Taher; asked scoping questions one at a time. Answers:
   - **Build**: skip real compile entirely. CI covers tests only (no Felgo, no self-hosted
     runner, no Felgo Cloud Builds — those stay out of scope for this workflow).
   - **Fork/trust model**: PRs are same-repo only (Taher + trusted collaborators), no external
     forks. This means the default `pull_request`-triggered `GITHUB_TOKEN` has full write
     permissions — no need for the more complex fork-safe two-workflow pattern.
   - **Result reporting**: rich — a PR check showing which specific tests failed, not just a
     pass/fail summary. Requires JUnit XML + a reporting action (`dorny/test-reporter`).
   - **Structure**: confirmed **Approach A** — three independent parallel jobs (`qml-tests`,
     `functions-tests`, `firestore-rules-tests`), one check per surface. Rejected a single
     sequential job (strictly slower, no benefit) and path-filtered conditional jobs (real risk
     given documented QML/Node math-parity fixtures that must stay in sync — a path filter could
     let a parity break through undetected).

6. **Empirically verified feasibility instead of trusting docs/assumptions** (installed Qt6 +
   Node tooling directly in the sandbox — network egress allows `archive.ubuntu.com` and
   `registry.npmjs.org`):
   - `functions/test`: ran for real, **48/48 pass**. Confirmed Node's built-in
     `--test-reporter=junit --test-reporter-destination=<file>` produces valid JUnit XML — this
     is the reporting mechanism the `functions-tests` and `firestore-rules-tests` jobs will use.
   - `tests/*.qml`: ran for real via `qmltestrunner -input tests -platform offscreen` after
     installing `qt6-declarative-dev-tools` + `qml6-module-qtqml-workerscript` +
     `qml6-module-qtquick-window` + `qml6-module-qtcore` from apt (Ubuntu noble ships Qt 6.4.2).
     Result: **265/268 pass, no Felgo involved at all** — confirms the hypothesis that this suite
     is genuinely Felgo-independent. The 3 failures are exactly the 3 suites `AGENTS.md` flagged
     as never having been run (`tst_ActivityLog`, `tst_Gateway`, `tst_OutboxStore`) — but the
     cause is a **Qt version gap**, not a real test bug or a Felgo dependency: `AuthStore.qml`
     uses `import QtCore`'s `Settings` type, which Ubuntu noble's Qt 6.4.2 doesn't have yet (it
     landed in a later Qt 6.5+ minor). This is concrete evidence for pinning a newer Qt via
     `jurplel/install-qt-action` (can't confirm the exact fix in-sandbox — `download.qt.io` isn't
     in the allowed egress list here — but the diagnosis is solid and the fix is standard).
   - `test/firestore.rules.test.js`: not run this session either (same known sandbox limitation
     as prior sessions — no egress to the Firestore emulator's download host). Real GitHub Actions
     runners have full internet access, so this should work there, but it genuinely will be
     exercised for the very first time in CI.
   - Cleaned up: removed scratch verification files, confirmed `git status` clean before
     continuing. `functions/node_modules` created locally for the test run; already covered by
     `functions/.gitignore`.

7. **Found and flagged an existing, deliberate repo convention that conflicts with the "rich
   reporting" design**: `.gitignore` has `*package-lock.json` — lockfiles for both root and
   `functions/` are intentionally excluded, not an oversight (the rule was reinforced, not
   accidental, per `git log -p .gitignore`). This matters because `npm ci` (the standard,
   reproducible, cacheable CI install command) requires a committed lockfile; without one the
   workflow has to fall back to `npm install` (works, but not reproducible/cacheable the same
   way). Asked Taher which way he wants to go.

8. Lockfile decision: commit `package-lock.json` for root + `functions/`, remove the
   `*package-lock.json` rule from `.gitignore`, use `npm ci` in CI.
9. Presented the full concrete design (trigger, 3 job specs, reporting, lockfile handling, risks
   to expect) conversationally; Taher approved.
10. Wrote and committed the design spec:
    `docs/superpowers/specs/2026-07-31-github-actions-pr-checks-design.md`.

## Next steps

- Taher reviews the written spec doc itself (not just the chat summary) and confirms/adjusts.
- Hand off to `writing-plans` for the implementation plan.
- Implementation not started — no workflow YAML, no lockfiles, no `.gitignore` edit yet.

## 2026-07-31 (continued) — Plan written

11. Wrote the implementation plan via `superpowers:writing-plans`:
    `docs/superpowers/plans/2026-07-31-github-actions-pr-checks.md`. 5 tasks: (1) fix `.gitignore`
    + commit real lockfiles, (2) workflow file + `qml-tests` job, (3) `functions-tests` job,
    (4) `firestore-rules-tests` job, (5) push + verify against a real PR (can't be done from a
    sandbox — needs Taher's PAT go-ahead).
12. While drafting, re-verified everything empirically rather than writing from memory:
    - Regenerated real lockfiles: root `package-lock.json` (87 packages), `functions/package-lock.json`
      (230 packages). Confirmed `npm ci` works cleanly against both.
    - Confirmed `qmltestrunner -input tests -platform offscreen -o results.xml,junitxml` produces
      valid JUnit XML (268 testcases, 3 failures, matches the earlier 265/268 finding) and that
      `qmltestrunner`'s real exit code is non-zero on failure (3, matching the failure count) —
      confirmed this properly via a non-piped exit-code check, not just visual output (a piped
      `| tail` check would have masked this). This is why the plan's QML step has no
      `continue-on-error` and relies on `if: always()` on the two steps after it instead.
    - Confirmed `node --test --test-reporter=junit --test-reporter-destination=<file>` on the
      `functions/` suite produces valid JUnit XML.
    - Drafted the full 3-job workflow YAML and validated it parses with `python3 -c "import
      yaml..."` (no `act`/Docker available in this sandbox to actually run it — GitHub API rate
      limited the sandbox IP when attempting to fetch `actionlint` for deeper validation, so YAML
      syntax validation is as far as pre-push verification goes).
    - Left the working tree's generated `node_modules`/lockfiles uncommitted during this
      exploration — Task 1 of the plan is what actually produces and commits them; kept the
      plan-vs-execute boundary clean rather than jumping ahead.

## Next steps

- Present execution options to Taher (subagent-driven vs inline) per `writing-plans`.
- Execute the plan once Taher picks an approach.
- Task 5 (push + real PR) needs Taher's explicit PAT go-ahead — cannot be skipped or simulated.

## 2026-07-31 (continued) — Executing the plan (inline, per Taher's choice)

**Task 1 — DONE.** Added a root `node_modules/` gitignore rule (flagged to Taher: root had none
before, only `functions/` and `scripts/` did — this was going to bite someone the first time
`npm install` ran at root, which is exactly what this task does). Removed the
`*package-lock.json` rule. Regenerated + verified `npm ci` against both lockfiles (root: 87
packages, `functions/`: 230 packages). Re-ran `functions/node --test`: 48/48 pass. Committed
(`4993cc7`).

Next: Task 2 (workflow file + `qml-tests` job).

**Task 2 — DONE.** Created `.github/workflows/pr-checks.yml` with trigger + `qml-tests` job.
Validated YAML syntax. Re-ran `qmltestrunner -input tests -platform offscreen -o
results.xml,junitxml` locally: same result as during planning (268 tests, 3 failures, exit code
3). Committed (`6d29b8f`).

**Task 3 — DONE.** Appended `functions-tests` job. Validated YAML. Re-confirmed
`node --test --test-reporter=junit --test-reporter-destination=...`: exit 0, 48 testcases in the
XML. Committed (`bb2b832`).

**Task 4 — DONE.** Appended `firestore-rules-tests` job. Validated YAML (all 3 jobs present, step
counts match plan: 5/6/8). Installed `firebase-tools` (15.25.1) for real and ran the actual
`firebase emulators:exec` command — confirmed it's syntactically/structurally correct and gets as
far as `downloading cloud-firestore-emulator-v1.22.0.jar...` before hitting the same known
sandbox network wall as prior sessions (no route to the emulator's download host). This is the
expected, documented limit — not a new problem. Committed (`f23ca93`).

**Tasks 1-4 complete.** Full workflow at `.github/workflows/pr-checks.yml`, 3 jobs, all committed
locally on `ci/github-actions-pr-checks`. Nothing pushed yet.

Next: Task 5 — needs Taher's explicit go-ahead + PAT to push and open the real PR. Cannot proceed
without that.

## 2026-07-31 (continued) — Pushed

First push attempt failed: `refusing to allow a Personal Access Token to create or update
workflow ... without workflow scope` — the initial PAT lacked the `workflow` scope required by
GitHub for any push touching `.github/workflows/*`. Nothing was pushed (rejected atomically).
Taher generated a new PAT with `workflow` scope; second push succeeded. Branch
`ci/github-actions-pr-checks` is now live on GitHub (5 commits: lockfiles/gitignore, then one
commit per job, then two checkpoint commits). Taher is regenerating this second token now that
the push succeeded, per his stated plan — not reusing it for anything further (e.g. `gh pr
create`).

**Still open:** opening the actual PR against `main` and watching the three checks run for the
first time — the real Task 5 verification. Waiting on Taher to open it (link:
https://github.com/lkdigitalworks-53/InventoryManagerUI/pull/new/ci/github-actions-pr-checks) and
report back what the checks show.

## 2026-07-31 (continued) — First real CI run: 2 of 3 checks failed, debugged and fixed

Taher opened the PR. Results: `functions-tests` passed (as expected — fully verified
end-to-end beforehand). Two failures, both root-caused and fixed locally before pushing again
(didn't want to guess and burn another round-trip):

1. **`qml-tests`**: `jurplel/install-qt-action` failed —
   `ERROR: The packages ['qtdeclarative'] were not found while parsing XML of package
   information!`. Cause: `qtdeclarative` is part of Qt's default essential package set, not an
   addon module — passing it via `modules:` makes aqt look for it in the addon-module XML, where
   it doesn't exist. Confirmed via web search (other install-qt-action users hit the identical
   error for the identical reason — requesting an already-default package through `modules:`).
   Fix: removed the `modules: 'qtdeclarative'` line entirely; the default install already
   includes it.

2. **`firestore-rules-tests`**: `Could not find '.../--test-reporter=junit'`. Cause: the command
   put the positional `test/` path before the `--test-reporter=*` flags — Node's `--test` CLI
   doesn't parse flags after a positional argument, so it treated `--test-reporter=junit` as
   another file path to load. **Reproduced this exact failure mode locally** (got the analogous
   "cannot find module" error), then verified the fix (flags moved before the path) gets past
   argument parsing and into actual test execution — it only fails locally due to no live
   emulator in this sandbox, the same known limitation as before, not this bug.

Committed both fixes as `e7664b7` with the reasoning in the commit message. Pushed using the same
token from the prior push (Taher explicitly authorized reuse for this fix-and-push round).

**Still open:** re-run the checks on the PR with these fixes and confirm all three go green (or
surface the next real thing to fix/triage).

## 2026-07-31 (continued) — All 3 checks passed on PR. New feature: also run on push to main

PR checks all green (`functions-tests`, `qml-tests`, `firestore-rules-tests`). PR not yet merged
(`main` still at `96a84e6` — verified via `git fetch origin main`), so continuing on the same
branch/PR rather than opening a new one for this extension.

Taher asked for the same checks to also run after a PR merges, against latest `main`, same
results pattern. Presented 3 structural options (same-file two-trigger / separate duplicated
file / reusable workflow_call split) with trade-offs; Taher picked same-file. Also confirmed no
extra alerting needed beyond the existing Checks-tab pattern.

Implemented: renamed workflow `PR Checks` → `Checks` (file `pr-checks.yml` → `checks.yml`, git
detected as a rename) since it's no longer PR-only. Added `push: branches: [main]` alongside the
existing `pull_request` trigger. Confirmed this can't double-fire on merge: the `pull_request`
trigger only listens for `[opened, synchronize, reopened]`, not `closed`, so a merge produces
exactly one `push` event → one workflow run. Committed (`4fcdf8e`). Pushed (`006c815`), using the
still-valid token per Taher's confirmation.

**Still open:** the actual push-to-main behavior can only be confirmed once this PR is merged —
that's the only way to produce a real push event against `main`. Told Taher to check the Actions
tab for a "Checks" run against the merge commit after merging.
