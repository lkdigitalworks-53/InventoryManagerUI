# GitHub Actions PR Checks Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development
> (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use
> checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a GitHub Actions workflow that runs all three of the repo's existing test suites
(QML, Cloud Functions, Firestore rules) on every pull request, with per-suite rich pass/fail
reporting — no app build.

**Architecture:** One workflow file, `.github/workflows/pr-checks.yml`, triggered on
`pull_request`. Three independent, parallel jobs (`qml-tests`, `functions-tests`,
`firestore-rules-tests`), each: installs its own toolchain, runs its suite with JUnit XML output,
uploads that XML as an artifact, then posts a named PR check via `dorny/test-reporter` showing
exactly which tests failed. Getting `npm ci` working in the two Node jobs requires reversing an
existing `.gitignore` rule that excludes `package-lock.json`, so that's Task 1.

**Tech Stack:** GitHub Actions (`ubuntu-latest` runners), `jurplel/install-qt-action`, Qt 6.8.x
`qmltestrunner`, Node 20 (`node --test`), `firebase-tools` + Firestore emulator, `dorny/test-reporter`.

## Global Constraints

- No real app/Felgo build in this workflow — deliberately test-only (Taher's explicit decision;
  Felgo can't run on a GitHub-hosted runner — see the design spec's Context section).
- PRs are same-repo only (Taher + trusted collaborators, no external forks) — `GITHUB_TOKEN` has
  write access, so the fork-safe two-workflow pattern is not needed here.
- Node jobs pin to Node **20**, matching `functions/package.json`'s `"engines": { "node": "20" }`
  — not whatever the runner's default happens to be.
- `npm ci` (not `npm install`) in every CI install step — requires committed lockfiles (Task 1).
- Every step that can fail on purpose (the actual test-running step) must be followed by
  `if: always()` on the artifact-upload and report steps, or a real test failure would prevent the
  PR check from ever being posted.
- Report every suite as its own named check (`QML Tests`, `Functions Tests`,
  `Firestore Rules Tests`) via `dorny/test-reporter`, reporter type `java-junit` (this is
  dorny/test-reporter's generic JUnit-XML-schema parser — the name is historical, not
  Java-specific; it's exactly the schema both `qmltestrunner -o file,junitxml` and
  `node --test --test-reporter=junit` produce).
- Do not add path filters / conditional job skipping — rejected in the design spec (QML/Node math
  parity risk).
- Expect the very first real run to surface genuine, previously-unknown failures in
  `tst_ActivityLog.qml`, `tst_Gateway.qml`, `tst_OutboxStore.qml`, and/or the Firestore rules
  suite — these have never run in a real qmltestrunner/CI environment before. That's the
  workflow doing its job, not a bug in this plan.

---

## Task 1: Fix `.gitignore` and commit real lockfiles

**Files:**
- Modify: `.gitignore` (remove the `*package-lock.json` line)
- Create: `package-lock.json` (repo root)
- Create: `functions/package-lock.json`

**Interfaces:**
- Consumes: nothing (first task).
- Produces: two committed lockfiles that Tasks 3 and 4's `npm ci` steps depend on existing in the
  repo (a workflow step running `npm ci` against an uncommitted/absent lockfile fails outright).

- [ ] **Step 1: Remove the gitignore rule**

In `.gitignore`, delete this line (it currently appears once, alongside `.vscode/*`):

```
*package-lock.json
```

- [ ] **Step 2: Generate the root lockfile**

Run: `npm install --no-audit --no-fund`
Expected output (exact wording may vary slightly by npm version, package count will not):
```
added 87 packages in 13s
```
This creates `package-lock.json` at the repo root (`lockfileVersion: 3`, generated from the
existing `devDependencies`: `@firebase/rules-unit-testing`, `firebase`).

- [ ] **Step 3: Verify `npm ci` works against the generated root lockfile**

Run: `rm -rf node_modules && npm ci --no-audit --no-fund`
Expected: `added 87 packages in <a few seconds>`, exit code 0. If this fails, do not proceed —
it means the lockfile Step 2 produced is inconsistent with `package.json`, which would break the
`firestore-rules-tests` job later.

- [ ] **Step 4: Generate the functions lockfile**

Run: `cd functions && npm install --no-audit --no-fund`
Expected output:
```
added 230 packages in <time varies>
```
(You'll also see `npm warn EBADENGINE` if your local Node isn't v20 — harmless locally, the CI job
pins Node 20 explicitly so this warning won't appear there.)

- [ ] **Step 5: Verify `npm ci` works against the generated functions lockfile**

Run: `cd functions && rm -rf node_modules && npm ci --no-audit --no-fund`
Expected: `added 230 packages in <a few seconds>`, exit code 0.

- [ ] **Step 6: Run the functions test suite once more as a sanity check**

Run: `cd functions && node --test`
Expected: `# pass 48`, `# fail 0` (48/48 — this suite was already verified working; this step is
just confirming the fresh `npm ci`-installed `node_modules` didn't change that).

- [ ] **Step 7: Commit**

```bash
cd /path/to/InventoryManagerUI
git add .gitignore package-lock.json functions/package-lock.json
git commit -m "chore: commit lockfiles for reproducible CI installs (npm ci)

Reverses the previous *package-lock.json gitignore rule. Needed so the
upcoming PR-checks workflow can use npm ci instead of npm install."
```

---

## Task 2: Workflow file + `qml-tests` job

**Files:**
- Create: `.github/workflows/pr-checks.yml`

**Interfaces:**
- Consumes: nothing from Task 1 directly (this job doesn't touch Node/npm at all).
- Produces: the workflow's trigger block and job-list structure that Tasks 3 and 4 append to;
  the "QML Tests" named check that will appear on every PR once this is pushed.

- [ ] **Step 1: Create the workflow file with the trigger and the `qml-tests` job**

```yaml
name: PR Checks

on:
  pull_request:
    types: [opened, synchronize, reopened]

jobs:
  qml-tests:
    name: QML Tests
    runs-on: ubuntu-latest
    permissions:
      checks: write
      contents: read
    steps:
      - uses: actions/checkout@v4

      - name: Install Qt
        uses: jurplel/install-qt-action@v4
        with:
          version: '6.8.*'
          modules: 'qtdeclarative'

      - name: Run QML tests
        env:
          QT_QPA_PLATFORM: offscreen
          QT_FORCE_STDERR_LOGGING: 1
          QT_LOGGING_TO_CONSOLE: 1
        run: qmltestrunner -input tests -platform offscreen -o results.xml,junitxml

      - name: Upload QML test results
        if: always()
        uses: actions/upload-artifact@v4
        with:
          name: qml-test-results
          path: results.xml

      - name: Report QML test results
        if: always()
        uses: dorny/test-reporter@v1
        with:
          name: QML Tests
          path: results.xml
          reporter: java-junit
```

Note the `Run QML tests` step deliberately has **no** `continue-on-error`. `qmltestrunner` exits
non-zero when tests fail (verified: exit code 3 when 3 of 268 tests failed) — we want that to make
the job fail for real. The two steps after it use `if: always()` specifically so they still run
and post results even when that happens; without `if: always()` a real test failure would skip
straight past artifact upload and reporting, and the PR would show a bare failed step instead of a
detailed check.

- [ ] **Step 2: Validate the YAML parses correctly**

Run: `python3 -c "import yaml; yaml.safe_load(open('.github/workflows/pr-checks.yml'))" && echo OK`
Expected: `OK`

- [ ] **Step 3: Re-confirm the underlying command against a local Qt install (sanity check only — the exact Qt 6.8.x behavior on the runner can't be verified from a sandbox with no route to download.qt.io)**

If a local Qt6 with `qmltestrunner` is available: run
`qmltestrunner -input tests -platform offscreen -o /tmp/results.xml,junitxml` from the repo root,
then check `/tmp/results.xml` starts with `<?xml version="1.0" encoding="UTF-8" ?>` and contains
`<testsuite name="qmltestrunner" ... tests="268"`. If no local Qt6 is available, skip this step —
it's a nice-to-have re-confirmation, not a hard gate, since Task 5 is the real verification.

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/pr-checks.yml
git commit -m "ci: add QML tests job to PR checks workflow"
```

---

## Task 3: Add `functions-tests` job

**Files:**
- Modify: `.github/workflows/pr-checks.yml` (append a new job under `jobs:`, after `qml-tests`)

**Interfaces:**
- Consumes: `functions/package-lock.json` from Task 1.
- Produces: the "Functions Tests" named check.

- [ ] **Step 1: Append the `functions-tests` job**

Add this immediately after the `qml-tests` job's last line (`reporter: java-junit`), still nested
under the top-level `jobs:` key at the same indentation as `qml-tests`:

```yaml
  functions-tests:
    name: Functions Tests
    runs-on: ubuntu-latest
    permissions:
      checks: write
      contents: read
    steps:
      - uses: actions/checkout@v4

      - uses: actions/setup-node@v4
        with:
          node-version: '20'
          cache: 'npm'
          cache-dependency-path: functions/package-lock.json

      - name: Install dependencies
        working-directory: functions
        run: npm ci

      - name: Run functions tests
        working-directory: functions
        run: node --test --test-reporter=junit --test-reporter-destination=results.xml

      - name: Upload functions test results
        if: always()
        uses: actions/upload-artifact@v4
        with:
          name: functions-test-results
          path: functions/results.xml

      - name: Report functions test results
        if: always()
        uses: dorny/test-reporter@v1
        with:
          name: Functions Tests
          path: functions/results.xml
          reporter: java-junit
```

This job does **not** touch `functions/package.json`'s existing `"test": "node --test"` script —
it calls `node --test` directly with the extra `--test-reporter` flags so local `npm test` keeps
its normal human-readable output.

- [ ] **Step 2: Validate the YAML parses correctly**

Run: `python3 -c "import yaml; d = yaml.safe_load(open('.github/workflows/pr-checks.yml')); assert list(d['jobs'].keys()) == ['qml-tests', 'functions-tests']; print('OK')"`
Expected: `OK`

- [ ] **Step 3: Re-run the exact command locally to reconfirm**

Run: `cd functions && node --test --test-reporter=junit --test-reporter-destination=/tmp/functions-results.xml`
Expected: exits 0 (this was already verified earlier: 48/48 pass). Then check
`/tmp/functions-results.xml` starts with `<?xml version="1.0" encoding="utf-8" ?>` and contains
48 `<testcase` entries: `grep -c '<testcase' /tmp/functions-results.xml` → `48`.

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/pr-checks.yml
git commit -m "ci: add Functions tests job to PR checks workflow"
```

---

## Task 4: Add `firestore-rules-tests` job

**Files:**
- Modify: `.github/workflows/pr-checks.yml` (append a new job under `jobs:`, after
  `functions-tests`)

**Interfaces:**
- Consumes: `package-lock.json` (root) from Task 1.
- Produces: the "Firestore Rules Tests" named check.

- [ ] **Step 1: Append the `firestore-rules-tests` job**

Add this immediately after the `functions-tests` job's last line (`reporter: java-junit`), at the
same indentation as `qml-tests` and `functions-tests`:

```yaml
  firestore-rules-tests:
    name: Firestore Rules Tests
    runs-on: ubuntu-latest
    permissions:
      checks: write
      contents: read
    steps:
      - uses: actions/checkout@v4

      - uses: actions/setup-node@v4
        with:
          node-version: '20'
          cache: 'npm'
          cache-dependency-path: package-lock.json

      - uses: actions/setup-java@v4
        with:
          distribution: 'temurin'
          java-version: '21'

      - name: Install root dependencies
        run: npm ci

      - name: Install firebase-tools
        run: npm install -g firebase-tools

      - name: Run Firestore rules tests
        run: firebase emulators:exec --only firestore "node --test test/ --test-reporter=junit --test-reporter-destination=results.xml"

      - name: Upload rules test results
        if: always()
        uses: actions/upload-artifact@v4
        with:
          name: firestore-rules-test-results
          path: results.xml

      - name: Report rules test results
        if: always()
        uses: dorny/test-reporter@v1
        with:
          name: Firestore Rules Tests
          path: results.xml
          reporter: java-junit
```

`firebase emulators:exec` runs the Firestore emulator, waits for it to be ready, runs the quoted
command against it, and propagates that command's exit code — so a real test failure here fails
the step exactly like the other two jobs.

- [ ] **Step 2: Validate the YAML parses correctly**

Run: `python3 -c "import yaml; d = yaml.safe_load(open('.github/workflows/pr-checks.yml')); assert list(d['jobs'].keys()) == ['qml-tests', 'functions-tests', 'firestore-rules-tests']; print('OK')"`
Expected: `OK`

- [ ] **Step 3: Note the one thing that genuinely can't be pre-verified**

This is the one piece of the whole workflow that was **not** run for real anywhere before this
plan — no sandbox used to write this plan had network egress to the Firebase emulator's download
host. Don't skip this job or mark it lower-confidence in the YAML; just go into Task 5 knowing
this is the most likely job to need a follow-up fix on the very first real run.

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/pr-checks.yml
git commit -m "ci: add Firestore rules tests job to PR checks workflow"
```

---

## Task 5: Push and verify against a real pull request

**Files:** none (verification only).

**Interfaces:**
- Consumes: the fully assembled `.github/workflows/pr-checks.yml` from Tasks 2-4 and the
  lockfiles from Task 1.
- Produces: the first real, confirmed-working (or confirmed-and-fixed) run of all three checks.

This task cannot be completed inside a sandbox — it requires Taher's go-ahead to push with his
GitHub PAT, per the established workflow.

- [ ] **Step 1: Get explicit go-ahead from Taher and push the branch**

```bash
git push https://<PAT>@github.com/lkdigitalworks-53/InventoryManagerUI.git ci/github-actions-pr-checks
```

- [ ] **Step 2: Open a pull request** from `ci/github-actions-pr-checks` into `main` (via the
  GitHub UI, or `gh pr create` if the `gh` CLI is authenticated).

- [ ] **Step 3: Watch the three checks run** on the PR's Checks tab. For each of `QML Tests`,
  `Functions Tests`, `Firestore Rules Tests`, confirm it appears and completes (pass or fail —
  either is informative at this stage).

- [ ] **Step 4: Triage whatever the first run actually shows**, in this likely order of what
  could go wrong:
  - `qml-tests`: if `jurplel/install-qt-action` errors on the `modules: 'qtdeclarative'` value,
    check the action's README for the current module list and adjust. If Qt installs fine but
    `AuthStore.qml`'s `Settings` type is still unavailable, the Qt version pin needs bumping past
    6.8 (this would mean my diagnosis of *which* 6.x minor added it was slightly off, not that the
    fix direction was wrong).
  - `functions-tests`: lowest-risk job — this one was fully verified end-to-end already. A
    failure here most likely means an actions/setup-node or npm registry hiccup, not a real code
    issue.
  - `firestore-rules-tests`: genuinely untested until now. If `firebase emulators:exec` fails to
    start the emulator, check the job log for a Java version complaint or a port conflict on 8080.
  - Any **test-level** failures (not tooling failures) in `tst_ActivityLog`, `tst_Gateway`,
    `tst_OutboxStore`, or the Firestore rules suite are real findings about the app, not this
    workflow — report them to Taher as such rather than treating them as CI bugs to paper over.

- [ ] **Step 5: Update the checkpoint doc** (`CHECKPOINT.md`) with what Task 5 actually found, and
  archive it to `docs/superpowers/specs/` once the workflow is confirmed working end-to-end, per
  the project's established checkpoint convention.

---

## Self-Review

**Spec coverage:** all five design-doc sections have a task — trigger/permissions (Task 2),
`qml-tests` (Task 2), `functions-tests` (Task 3), `firestore-rules-tests` (Task 4), lockfiles
(Task 1), real-world verification (Task 5, since the design doc's own "Open items" section says
this can only be confirmed on a real runner).

**Placeholder scan:** no TBD/TODO/"add appropriate handling" — every step has a real command, a
real expected output, or an explicit, honest statement of what couldn't be pre-verified and why
(the Qt 6.8.x exact behavior, the Firestore rules test) rather than a vague placeholder.

**Type/name consistency:** job names (`qml-tests`, `functions-tests`, `firestore-rules-tests`)
and their `results.xml` artifact paths match between the job that produces them and the two steps
that consume them (upload-artifact, test-reporter) in every task. Reporter check names (`QML
Tests`, `Functions Tests`, `Firestore Rules Tests`) match what's referenced in Task 5's triage
step and the original design doc.
