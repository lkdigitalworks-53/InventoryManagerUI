# Test plan — CI JUnit parser undercount (`.github/scripts/parse-junit.js`)

**Branch:** `fix/2026-10-06-ci-junit-parser`, stacked on `feat/2026-10-06-ph3b-sweeper-e2e-docs` (PR #128).
**Covers:** the PR-comment summary under-reported tests. Found 2026-10-06 while reviewing PR #128: its CI E2E count stayed 63 after 7 tests were added, and open item O1 (CI Functions 370 vs local 582-585) had no explanation.
**Root causes (both reproduced in the sandbox with plain Node, real `node --test --test-reporter=junit` output):**
1. node's JUnit reporter writes `>` raw inside attribute values (test names such as `F31 ... -> 400`). The tag regex `[^>]*` ended inside the name and the open-tag branch swallowed the following self-closing testcases. Functions: 585 real, 370 reported = 585 - 215 names containing `>`.
2. When any `<testsuite>` exists in the concatenated artifact text (qmltestrunner's `results.xml`), only testsuite blocks were scanned, so bare node `<testcase>`s (`recordOperation`, `cleanupSweep`) were dropped. E2E reported QML only.
**Not covered / out of scope:** test content of the app. Job pass/fail was never affected (exit codes gate the jobs); only the PR comment's counts and failed-test list were wrong. A failing test whose name had `>` could have been missing from the comment's list while the job was red.
**Change:** count every `<testcase>` in the document with quote-aware tag matching; testsuite wrappers are no longer consulted (they carried nothing the summary uses).
**Final sweep (2026-10-05, review PR stacked on this one):** (1) the tag body now also refuses a raw `<` (XML forbids it in a tag; node and Qt write `&lt;`, verified), which makes the scan linear: 320 KB of truncated tags took 20 s, now 2 ms; real 585-test replay unchanged. (2) `decodeXmlEntities` is no longer exported (no other user). (3) Known limit, not fixed on purpose: attribute values must be double-quoted (both generators do it; a single-quoted value containing `>` would undercount).

## 1. Unit tests (run, green: `node --test .github/scripts/__tests__/*.test.js` = 55/55 after the PR #129 final sweep (52 before); `parse-junit.js` 100% line / 100% branch)
| ID | What |
|---|---|
| existing 16 + 26 in other script files | unchanged, still green |
| U1 | `>` in a testcase name does not swallow neighbours (happy) |
| U2 | failing testcase whose name AND failure message contain `>`: full name + message reported |
| U3 | self-closing `<failure/>` (qmltestrunner) next to a `>` name |
| U4 | `<error>` and `<skipped>` with `>` names classified separately from neighbours |
| U5 | nested `<testsuite>` with `>` in suite names: each testcase counted once |
| U6 | document with no testcase (comments, empty suite): 0 (negative) |
| U7 | testcase without name, failure without message/body: placeholders (edge) |

## 2. Regression tests (each pins one of the two causes; 7 of 9 new cases FAIL on the old parser, verified by running them against `git show HEAD~:...`)
| ID | What |
|---|---|
| R1 | bare node testcases counted when a `<testsuite>` file is concatenated first (cause 2; the exact E2E shape) |
| R2 | 585-case node-shaped fixture with 215 `->` names counts 585 (cause 1; the exact Functions numbers) |
| R3 | MONKEY: 5 seeded runs x 300 testcases, random `>`, ` > `, `->`, escaped `&<"`, quotes, 10% failures: count, failed and failedTests exact |
Real-data replay (sandbox): the real 585-test functions JUnit file parses to 585 (old parser: 370); a QML-style suite + two node files parses to 8 (old: 2).

| H1 | HARDENING: 20000 unterminated `<testcase` tags parse in under 2 s (FAILS on the pre-sweep parser, verified) |
| H2 | HARDENING: a truncated final tag (runner killed mid-write) keeps the complete testcases before it (guard: passes on both) |
| H3 | HARDENING: raw `<` inside an attribute value ends that tag, neighbours still counted (FAILS on the pre-sweep parser, verified) |

## 3. E2E
None for the parser itself. The next CI run of any PR is the end-to-end check. Expected: Functions 585 (not 370), and E2E higher than 63 by up to 24 (`cleanupSweep` 7 is certain to be new; `recordOperation` 17 only if its tests are flat, not inside `describe`: unverified, the E2E job log was not readable from the sandbox). Whatever the number, compare it with the `# tests` lines in the E2E job log.

## On-device test plan
Not applicable: CI tooling only, no app, QML or Firebase code touched. Sections kept for the convention:
- **Happy path:** open the PR comment after the next push; per-job counts match each job log.
- **Negative:** break one test whose name contains `->` on a scratch branch; the comment must list it by full name.
- **Edge cases:** a job that produced no XML still shows "no test results" (unchanged path).
- **Affected areas:** `.github/scripts/parse-junit.js` only; `build-summary.js` and `post-ci-comment.js` untouched (their tests green).
- **Regression:** counts that stay constant after adding tests are a red flag, compare with a local run.
