# Design: GitHub Actions PR checks — tests only, three parallel jobs

**Date:** 2026-07-31
**Status:** Approved by Taher in chat. Not yet implemented.
**Scope:** CI for pull requests against `InventoryManagerUI`. Deliberately test-only — see
"Explicitly out of scope" for why a real app build isn't part of this.

## Context

No CI exists today — `.github/` only has agent config files, no `.github/workflows/`.

**A real Felgo/Qt app build cannot run on a standard GitHub-hosted runner.**
`CMakeLists.txt` starts with `find_package(Felgo REQUIRED)`, and `main.cpp` directly
`#include <FelgoApplication>` — Felgo is a licensed, proprietary SDK with no public installer, and
`CMakePresets.json` only defines Windows/MinGW presets pointing at `C:/Felgo/...`. There is no way
to even syntax-check the C++ entry point without the SDK installed. Taher explicitly chose to skip
real compilation for this workflow rather than stand up a self-hosted runner or wire in Felgo Cloud
Builds (Felgo's own separate hosted build product) — see "Explicitly out of scope."

**Three independent test surfaces already exist**, and were run for real this session (not just
read) to confirm they're actually CI-viable:
- `tests/*.qml` (28 files, Qt Quick Test / `qmltestrunner`) — every file imports only `QtQuick`,
  `QtTest`, and pure `.js`/`qml/model` singletons, none of which import Felgo. Verified: ran
  `qmltestrunner -input tests -platform offscreen` against plain Ubuntu Qt 6.4.2 (via apt) —
  **265/268 pass, zero Felgo involved.** The 3 failures are exactly the 3 suites `AGENTS.md`
  already flags as never having been run (`tst_ActivityLog`, `tst_Gateway`, `tst_OutboxStore`),
  and the cause is a Qt *version* gap — `AuthStore.qml`'s `import QtCore` `Settings` type doesn't
  exist in Qt 6.4.2, only in later 6.5+ minors. This is why the job pins a newer Qt explicitly
  instead of trusting whatever `apt` ships.
- `functions/test/*.test.js` (48 tests) — plain `node --test`, no emulator, no network. Verified:
  ran it, **48/48 pass**. Also verified `node --test --test-reporter=junit
  --test-reporter-destination=<file>` produces valid JUnit XML.
- `test/firestore.rules.test.js` — needs the Firebase emulator
  (`firebase emulators:exec --only firestore ...`). **Not run this session** — this sandbox has no
  network route to the emulator's download host (same limitation noted in prior sessions). Real
  GitHub Actions runners have normal internet access, so this is expected to work, but it will be
  exercised for the first time ever when this workflow first runs.

**Adjacent finding, flagged but explicitly not part of this work:** `CMakeLists.txt` has a
`PRODUCT_LICENSE_KEY` hardcoded in plaintext, committed to this public repo. Raised to Taher for
awareness; out of scope here unless he asks for it separately.

## Design

### 1. Trigger
`.github/workflows/pr-checks.yml` triggers on `pull_request` (`opened`, `synchronize`,
`reopened`), no `branches:` restriction. Trust model: same-repo only (Taher + trusted
collaborators, no external forks), confirmed with Taher — so the default `pull_request`
`GITHUB_TOKEN` has full write permissions and the workflow doesn't need the more complex
fork-safe two-workflow pattern that a public repo accepting outside contributions would require.

### 2. Job `qml-tests`
- `jurplel/install-qt-action`, pinned to Qt `6.8.x` with the `qtdeclarative` module (closest
  realistic match to what Felgo bundles; the exact patch version isn't load-bearing — any 6.8.x
  has `Settings` in `QtCore`). This is a deliberate choice over raw `apt` packages, precisely
  because of the version-gap failure mode confirmed above.
- Run: `qmltestrunner -input tests -platform offscreen -o results.xml,junitxml`
- `dorny/test-reporter@v1` (`if: always()`) reads `results.xml` → posts a "QML Tests" check with
  per-test pass/fail.
- `actions/upload-artifact` for `results.xml`.

### 3. Job `functions-tests`
- `actions/setup-node@v4`, Node `20` (matches `functions/package.json`'s `engines` field — not
  whatever happens to be on the runner), `cache: npm`, `cache-dependency-path:
  functions/package-lock.json`.
- Run: `cd functions && npm ci && node --test --test-reporter=junit
  --test-reporter-destination=results.xml`
- `dorny/test-reporter@v1` (`if: always()`) → "Functions Tests" check.
- `actions/upload-artifact` for `results.xml`.

### 4. Job `firestore-rules-tests`
- `actions/setup-node@v4` (Node 20) + `actions/setup-java@v4` (the emulator needs a JVM) +
  `npm install -g firebase-tools`.
- Run: `npm ci` (root) then `firebase emulators:exec --only firestore "node --test test/
  --test-reporter=junit --test-reporter-destination=results.xml"`
- `dorny/test-reporter@v1` (`if: always()`) → "Firestore Rules Tests" check.
- `actions/upload-artifact` for `results.xml`.

All three jobs run in parallel — they're independent, nothing here has a real ordering
dependency.

### 5. Lockfiles
`.gitignore` currently has `*package-lock.json`, excluding lockfiles for both root and
`functions/` — confirmed via `git log -p .gitignore` this was a deliberate, reinforced rule, not
an oversight. Taher chose to reverse it for CI's sake:
- Remove the `*package-lock.json` line from `.gitignore`.
- Generate and commit `package-lock.json` at root and in `functions/`.
- Both install steps use `npm ci` (reproducible, cacheable) instead of `npm install`.

## Explicitly out of scope

- **A real Felgo/app build.** No self-hosted runner, no Felgo Cloud Builds integration — Taher's
  explicit choice this round. Either could be revisited later as a separate, deliberate piece of
  work with its own trade-off discussion (self-hosted runner = real build fidelity but exposes his
  own machine as a CI target; Felgo Cloud Builds = real product for this but lives outside
  GitHub Actions entirely).
- **Fork-safe two-workflow reporting pattern.** Not needed given the same-repo/trusted-collaborator
  trust model. If that ever changes (outside contributors start opening PRs), this needs
  revisiting — the current design assumes `GITHUB_TOKEN` has write access, which forks don't get.
- **Path-filtered/conditional jobs.** Considered and rejected: the project's own docs document
  hand-kept parity between `qml/helper/*.js` and `functions/lib/*.js` (paired fixture files that
  must be updated together). A path filter could let a change slip through without triggering the
  paired suite. All three suites run in low-single-digit seconds to a couple minutes anyway, so
  there's no real time savings being given up.
- **Fixing the hardcoded `PRODUCT_LICENSE_KEY`.** Flagged to Taher, not part of this task.
- **Investigating/fixing the 3 previously-unrun QML suites or the untested Firestore rules test
  ahead of time.** The whole point of this workflow is to surface exactly this kind of gap — not
  pre-fixing it defeats the purpose. Taher should expect the very first CI run may show real,
  new failures here, not treat that as the workflow being broken.

## Files touched
`.github/workflows/pr-checks.yml` (new), `package-lock.json` (new, root),
`functions/package-lock.json` (new), `.gitignore` (remove the `*package-lock.json` line).

## Verification done this session (not deferred to implementation)
Ran, for real, in the sandbox (network egress allows `archive.ubuntu.com` and
`registry.npmjs.org`):
- `functions/test` via `node --test` — 48/48 pass, JUnit reporter output format confirmed valid.
- `tests/*.qml` via `qmltestrunner -input tests -platform offscreen` (apt Qt 6.4.2 +
  `qml6-module-qtqml-workerscript`, `qml6-module-qtquick-window`, `qml6-module-qtcore`) —
  265/268 pass; remaining 3 diagnosed as a Qt version gap, not a Felgo dependency or a real bug.

Not verified this session (sandbox network limitation, not a design gap):
- The exact Qt 6.8.x behavior (no route to `download.qt.io` from this sandbox).
- `test/firestore.rules.test.js` under the real Firebase emulator (no route to the emulator's
  download host from this sandbox).
- `dorny/test-reporter`'s actual behavior against a real GitHub Actions `pull_request` event —
  can only be confirmed by opening a real PR once this is pushed.

## Open items carried into the implementation plan
- Confirm/adjust the exact Qt 6.8.x patch version once running on a real runner.
- First CI run may reveal genuine, previously-unknown failures in `tst_ActivityLog.qml`,
  `tst_Gateway.qml`, `tst_OutboxStore.qml`, and/or the Firestore rules suite — expected, not a
  workflow bug.
